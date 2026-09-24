import Foundation
import Testing

@testable import Vigil

/// A socket path that does not fit must be refused, not silently truncated.
///
/// `sockaddr_un.sun_path` is a fixed-size buffer, and the address builder the
/// bridge hands to its server copies into it without complaining. A longer path
/// therefore *binds*, at a truncated path, and the bridge reports itself
/// listening — while `hooks/vigil-hook.sh` rebuilds the full path from `$HOME`,
/// finds no socket there and exits 0. Every event is dropped in silence, Vigil
/// holds nothing, and the Mac sleeps in the middle of a run with the panel
/// saying the bridge is up. The socket file is not even cleaned up on quit,
/// because `stop()` unlinks the path it asked for rather than the one it got.
///
/// Reachable on a real Mac only with a long home — a mounted network home, or
/// anything run against a redirected `CFFIXED_USER_HOME` under a deep
/// temporary directory, which is how this app is tested. It was found that
/// second way: three fake-home runs each left a stray socket named `App` or
/// `Appl` beside `Library/Application Support`, the truncation point moving by
/// exactly the length of the home's own name.
///
/// The limit is asked of `sockaddr_un` rather than written down here, so this
/// says "one byte over is refused" on any platform rather than "105 is
/// refused" on this one.
/// `@MainActor` because `EventBridge` is: the bridge owns the socket and the
/// status the panel renders. Nothing here waits on anything, so this costs a
/// hop and no time.
@MainActor
@Suite("The bound on a socket path")
struct SocketPathBoundTests {

  private var limit: Int { EventBridge.maximumSocketPathBytes }

  private func path(bytes: Int) -> String {
    "/" + String(repeating: "a", count: bytes - 1)
  }

  @Test("a path that exactly fills the address is allowed")
  func exactlyAtTheLimitFits() {
    #expect(EventBridge.fitsInSocketAddress(path(bytes: limit)))
  }

  @Test("one byte over is refused")
  func oneByteOverIsRefused() {
    #expect(!EventBridge.fitsInSocketAddress(path(bytes: limit + 1)))
  }

  @Test("an ordinary home's socket path fits with room to spare")
  func theRealPathFits() {
    #expect(EventBridge.fitsInSocketAddress(Vigil.socketPath))
  }

  /// Measured in UTF-8 bytes, not characters. `sun_path` holds bytes, so a
  /// home directory with an accented or non-Latin name fills it faster than
  /// its length in characters suggests — and counting characters would let
  /// exactly those users through to a truncated bind.
  @Test("the limit counts bytes, not characters")
  func countsBytesNotCharacters() {
    let wide = "/" + String(repeating: "é", count: limit / 2 + 1)
    #expect(wide.count < limit)
    #expect(wide.utf8.count > limit)
    #expect(!EventBridge.fitsInSocketAddress(wide))
  }

  /// The two places that build a socket address agree. `isSocketLive` already
  /// refused an over-long path before `start()` did; a fix that guarded only
  /// one of them would leave the pair able to disagree about the same path.
  @Test("a path the bind refuses is not reported as live either")
  func liveCheckAgrees() {
    #expect(!EventBridge.isSocketLive(at: path(bytes: limit + 1)))
  }
}
