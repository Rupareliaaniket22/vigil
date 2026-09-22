import FlyingFox
import FlyingSocks
import Foundation
import OSLog
import VigilCore

/// Receives lifecycle events from agent hooks over a Unix domain socket.
///
/// A socket file rather than a loopback TCP port: `127.0.0.1` is reachable by
/// every other user account on the machine, whereas a socket inside a 0700
/// directory is reachable only by its owner and root.
///
/// There is deliberately no shared-secret header. Any token would have to live
/// in a file beside the socket under the same permissions, so anyone able to
/// read it could already connect — it would add ceremony, not security.
/// File-scoped so the request handlers, which run off the main actor, can log
/// without hopping back to it.
private let log = Logger(subsystem: Vigil.subsystem, category: "bridge")

/// A hook event is a few hundred bytes. Anything approaching this is either a
/// bug in a hook or something deliberately probing the socket; either way we
/// should not materialise it in memory.
private let maximumBodyBytes = 64 * 1024

@MainActor
final class EventBridge {

  private var task: Task<Void, Never>?
  private let onEvent: @MainActor (AgentEvent) -> Void

  init(onEvent: @escaping @MainActor (AgentEvent) -> Void) {
    self.onEvent = onEvent
  }

  func start() {
    let path = Vigil.socketPath
    do {
      try Self.prepareSocketDirectory(for: path)
    } catch {
      log.error(
        "could not prepare socket directory: \(error.localizedDescription, privacy: .public)")
      return
    }

    let server = HTTPServer(address: sockaddr_un.unix(path: path))
    let handle = onEvent

    Task {
      await server.appendRoute("POST /event") { (request: HTTPRequest) in
        // Check the declared length before reading anything, so an oversized
        // body is refused rather than buffered.
        if let declared = request.headers[.contentLength].flatMap(Int.init),
          declared > maximumBodyBytes
        {
          log.notice("refused a \(declared, privacy: .public) byte event payload")
          return HTTPResponse(statusCode: .payloadTooLarge)
        }

        let data: Data
        do {
          data = try await request.bodyData
        } catch {
          return HTTPResponse(statusCode: .badRequest)
        }

        // A body with no declared length still gets checked once read.
        guard data.count <= maximumBodyBytes else {
          log.notice("refused a \(data.count, privacy: .public) byte event payload")
          return HTTPResponse(statusCode: .payloadTooLarge)
        }

        // Hook payloads are shell-assembled JSON: assume nothing.
        guard let event = try? AgentEvent.decode(from: data) else {
          log.debug("rejected malformed event payload (\(data.count, privacy: .public) bytes)")
          return HTTPResponse(statusCode: .badRequest)
        }

        await MainActor.run { handle(event) }
        return HTTPResponse(statusCode: .ok)
      }

      // Health check, so `install.sh` can verify the app is listening.
      await server.appendRoute("GET /health") { _ in
        HTTPResponse(statusCode: .ok, body: Data(#"{"ok":true}"#.utf8))
      }

      do {
        log.info("bridge listening at \(path, privacy: .public)")
        try await server.run()
      } catch {
        log.error("bridge stopped: \(error.localizedDescription, privacy: .public)")
      }
    }
    .store(in: &task)
  }

  func stop() {
    task?.cancel()
    task = nil
    try? FileManager.default.removeItem(atPath: Vigil.socketPath)
  }

  /// Create the containing directory 0700 and clear any socket left behind by a
  /// previous run — `bind` fails on an existing path.
  private static func prepareSocketDirectory(for path: String) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
      atPath: dir,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    // createDirectory does not reapply permissions to an existing directory.
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)

    if FileManager.default.fileExists(atPath: path) {
      try FileManager.default.removeItem(atPath: path)
    }
  }
}

extension Task where Success == Void, Failure == Never {
  fileprivate func store(in slot: inout Task<Void, Never>?) { slot = self }
}
