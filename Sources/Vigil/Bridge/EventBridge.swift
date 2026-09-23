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

  /// Whether the bridge is actually listening.
  ///
  /// Reported rather than only logged: an app that is running but silently
  /// receiving nothing looks identical to one that is working, right up until
  /// someone's overnight run dies.
  enum Status: Equatable {
    case starting
    case listening(path: String)
    case failed(reason: String)
  }

  private(set) var status: Status = .starting

  private var task: Task<Void, Never>?
  private let onEvent: @MainActor (AgentEvent) -> Void
  private let onStatusChange: @MainActor (Status) -> Void

  init(
    onEvent: @escaping @MainActor (AgentEvent) -> Void,
    onStatusChange: @escaping @MainActor (Status) -> Void = { _ in }
  ) {
    self.onEvent = onEvent
    self.onStatusChange = onStatusChange
  }

  private func report(_ status: Status) {
    self.status = status
    onStatusChange(status)
  }

  func start() {
    let path = Vigil.socketPath
    do {
      try Self.prepareSocketDirectory(for: path)
    } catch {
      log.error(
        "could not prepare socket directory: \(error.localizedDescription, privacy: .public)")
      report(.failed(reason: error.localizedDescription))
      return
    }

    let server = HTTPServer(address: sockaddr_un.unix(path: path))
    let handle = onEvent
    let statusChanged = onStatusChange

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
        await MainActor.run { statusChanged(.listening(path: path)) }
        try await server.run()
        // A clean return means we were cancelled on quit, not that we failed.
      } catch {
        log.error("bridge stopped: \(error.localizedDescription, privacy: .public)")
        let reason = error.localizedDescription
        await MainActor.run { statusChanged(.failed(reason: reason)) }
      }
    }
    .store(in: &task)
  }

  func stop() {
    task?.cancel()
    task = nil
    // Only remove the socket if we were the one bound to it. Quitting a second
    // instance must not delete the first instance's socket.
    if case .listening(let path) = status {
      try? FileManager.default.removeItem(atPath: path)
    }
  }

  /// Whether something is already listening on this socket.
  ///
  /// A socket file left by a crashed run and one owned by a live instance look
  /// identical on disk. Unlinking the live one leaves that instance running and
  /// bound to a path nothing can reach any more — it keeps its menu bar icon and
  /// silently never receives another event.
  static func isSocketLive(at path: String) -> Bool {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxLength else { return false }

    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      path.withCString { source in
        strncpy(
          UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
          source, maxLength - 1)
      }
    }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
        connect(descriptor, addr, size)
      }
    }
    return connected == 0
  }

  /// Create the containing directory 0700 and clear a socket left behind by a
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
      // Only unlink it if nothing is listening. Otherwise we would deafen a
      // running instance rather than replacing a stale file.
      guard !isSocketLive(at: path) else { throw BridgeError.alreadyRunning }
      try FileManager.default.removeItem(atPath: path)
    }
  }

  enum BridgeError: LocalizedError {
    case alreadyRunning
    var errorDescription: String? {
      "Another copy of Vigil is already running and listening for agent events."
    }
  }
}

extension Task where Success == Void, Failure == Never {
  fileprivate func store(in slot: inout Task<Void, Never>?) { slot = self }
}
