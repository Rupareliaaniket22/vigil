import Foundation

enum Vigil {
  static let subsystem = Bundle.main.bundleIdentifier ?? "dev.vigil.app"
  static let displayName = "Vigil"

  /// Where the hook bridge listens. A Unix socket rather than a loopback TCP
  /// port: loopback is reachable by every other user account on the Mac, a
  /// socket file is not, and `getpeereid` gives us a uid the caller cannot forge.
  static var socketPath: String {
    let dir = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Vigil", isDirectory: true)
    return dir.appendingPathComponent("bridge.sock").path
  }
}
