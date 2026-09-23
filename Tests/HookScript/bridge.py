#!/usr/bin/env python3
"""Stand-in processes for the hook-script tests.

The hook talks to one thing — a Unix socket at
`$HOME/Library/Application Support/Vigil/bridge.sock` — so a fake home with a
fake socket in it is the whole bridge these tests need. The real app never
starts, which is the point: `make integration` covers the real app, and it
cannot run while a Vigil instance is already on the machine.

Three subcommands, each a separate process so the timing test can kill one
without waiting on another:

  listen SOCKET LOG READY   accept HTTP POSTs, append each body to LOG
  drip INTERVAL SESSION COUNT   write a JSON object forever, never close
  run ...                   run the hook against a drip, with a hard timeout

python3 is assumed. It ships with the Command Line Tools, and
`Scripts/integration-test.sh` already relies on it.
"""

import os
import socket
import subprocess
import sys
import threading
import time


def listen(path, log, ready):
    """A socket that answers the hook the way Vigil's bridge does."""
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(path), exist_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(8)
    open(log, "w").close()
    # Written last: the test waits on this file, so it must not appear until
    # the socket is actually accepting. A test that raced the listener would
    # find no socket, and the hook exits 0 the moment it sees none — every
    # assertion below would pass against a hook that did nothing at all.
    with open(ready, "w") as f:
        f.write("ready\n")

    while True:
        conn, _ = server.accept()
        threading.Thread(target=_serve, args=(conn, log), daemon=True).start()


def _serve(conn, log):
    conn.settimeout(5)
    try:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(65536)
            if not chunk:
                return
            data += chunk
        head, _, body = data.partition(b"\r\n\r\n")
        length = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":")[1])
        while len(body) < length:
            chunk = conn.recv(65536)
            if not chunk:
                break
            body += chunk
        with open(log, "a") as f:
            f.write(body.decode("utf-8", "replace") + "\n")
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
    except Exception as exc:  # noqa: BLE001 - surfaced to the test as a log line
        with open(log, "a") as f:
            f.write("LISTENER-ERROR %r\n" % (exc,))
    finally:
        conn.close()


def drip(interval, session, count_file):
    """A host that hands over its payload a line at a time and never stops.

    The shape the volume bounds cannot see. Every line resets a per-line
    timeout, so on bytes and lines alone this producer keeps the hook alive
    until it has emitted 4096 lines — over an hour at this interval.
    """
    out = sys.stdout
    out.write('{"session_id":"%s","cwd":"/tmp/vigil-hook-test",\n' % session)
    out.flush()
    written = 0
    while True:
        out.write('"filler_%06d":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",\n' % written)
        out.flush()
        written += 1
        with open(count_file, "w") as f:
            f.write(str(written))
        time.sleep(interval)


def run(hook, home, interval, session, timeout, count_file):
    """Run the hook against a never-ending producer, with a hard timeout."""
    with open(count_file, "w") as f:
        f.write("0")
    producer = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "drip", str(interval), session, count_file],
        stdout=subprocess.PIPE,
    )
    env = dict(os.environ)
    env["HOME"] = home
    started = time.time()
    hook_process = subprocess.Popen([hook, "claude-code", "UserPromptSubmit", "working"],
                                    stdin=producer.stdout, env=env)
    producer.stdout.close()
    killed = 0
    try:
        code = hook_process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        hook_process.kill()
        hook_process.wait()
        code = -1
        killed = 1
    elapsed = time.time() - started
    producer.kill()
    producer.wait()
    with open(count_file) as f:
        lines = int(f.read().strip() or "0")
    # key=value rather than JSON: the caller is bash 3.2, which has no parser.
    print("rc=%d killed=%d elapsed=%.2f lines=%d" % (code, killed, elapsed, lines))


if __name__ == "__main__":
    command = sys.argv[1]
    if command == "listen":
        listen(sys.argv[2], sys.argv[3], sys.argv[4])
    elif command == "drip":
        drip(float(sys.argv[2]), sys.argv[3], sys.argv[4])
    elif command == "run":
        run(sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5],
            float(sys.argv[6]), sys.argv[7])
    else:
        sys.exit("unknown subcommand: %s" % command)
