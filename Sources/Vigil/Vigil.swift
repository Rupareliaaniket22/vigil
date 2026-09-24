import Foundation

enum Vigil {
  /// The unified-log subsystem, which is the bundle identifier whenever there
  /// is a bundle to read it from.
  ///
  /// The literal is only reached by a binary running outside a bundle — `swift
  /// run`, and the smoke build before it is packaged — and it has to be the
  /// same string `BUNDLE_ID` in the Makefile is, or a `log show --predicate`
  /// that works against the shipped app silently returns nothing for the one
  /// case somebody is most likely to be debugging. It used to say
  /// `dev.vigil.app`, which was the identifier before the first release and is
  /// no longer anything.
  static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.rupareliaaniket22.vigil"
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
