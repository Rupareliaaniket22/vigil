import Foundation
import Testing

@testable import VigilCore

/// What Vigil is allowed to do without asking.
///
/// Every case here is a claim about consent rather than about files, which is
/// why the function under test takes three arguments and no paths: the whole
/// argument is decidable from what the file says and what the user has already
/// decided, and none of it should need a disk to be argued about.
@Suite("Acting without asking")
struct HookMaintenanceTests {

  /// The first install. Nobody has said anything either way, and wiring an
  /// agent up is the entire job — so it happens, and the panel says so
  /// afterwards.
  @Test("an agent Vigil has never touched is set up")
  func firstRunInstalls() {
    #expect(
      HookMaintenance.action(
        for: .notSetUp, manages: true, hasBeenSetUp: false) == .install)
  }

  /// The one that must not regress. Removal is a decision; an app that argues
  /// with it on the next panel open has not given the user a Remove button, it
  /// has given them a button that flickers.
  @Test("an agent the user has removed is never put back")
  func removalSticks() {
    #expect(
      HookMaintenance.action(
        for: .notSetUp, manages: true, hasBeenSetUp: true) == nil)
  }

  /// The recurring cost this whole change exists to remove. Vigil's own
  /// entries drifting from what this version writes is maintenance of a job
  /// already granted — and the evidence that it was granted is in the user's
  /// settings file, because `outOfDate` is only reachable when our entries are
  /// already in it.
  @Test("an install Vigil wrote and has since outgrown is brought up to date")
  func staleInstallIsRepaired() {
    #expect(
      HookMaintenance.action(
        for: .outOfDate, manages: true, hasBeenSetUp: true) == .install)
  }

  /// And it does not need Vigil's own memory to do it. Somebody upgrading from
  /// a build that recorded nothing still has our hooks in their file, which is
  /// the only evidence this case needs.
  @Test("a stale install is repaired even with nothing remembered about it")
  func staleInstallNeedsNoMemory() {
    #expect(
      HookMaintenance.action(
        for: .outOfDate, manages: true, hasBeenSetUp: false) == .install)
  }

  /// A host refusing Vigil's hooks is answered, not reported. There is no
  /// "first approval" branch and deliberately no memory of one: what the
  /// host's record covers is the hook entry rather than the script it points
  /// at, so an approval limited to entries Vigil would itself write cannot
  /// sanction anything the user did not get. `CodexSelfTrustTests` is where
  /// that limit is actually held; this only says the attempt is made.
  @Test(
    "a host refusing our hooks is answered without asking",
    arguments: [true, false])
  func trustIsAutomatic(setUpBefore: Bool) {
    #expect(
      HookMaintenance.action(
        for: .untrusted, manages: true, hasBeenSetUp: setUpBefore) == .trust)
  }

  /// Nothing to do, and nothing that would help. Re-installing cannot change a
  /// state that exists precisely because the install is complete, so a Mac
  /// that acted here would rewrite the same file forever.
  @Test(
    "states nothing can act on are left alone",
    arguments: [HookSetupState.ready, .hostTooOld])
  func quietStates(state: HookSetupState) {
    #expect(
      HookMaintenance.action(
        for: state, manages: true, hasBeenSetUp: true) == nil)
    #expect(
      HookMaintenance.action(
        for: state, manages: true, hasBeenSetUp: false) == nil)
  }

  /// The escape hatch, and it has to be total: with it off there is no state
  /// and no history that makes Vigil touch a file on its own. Every row goes
  /// back to carrying a button and waiting.
  @Test(
    "with automatic management off, nothing happens by itself",
    arguments: [
      HookSetupState.ready, .outOfDate, .notSetUp, .untrusted, .hostTooOld,
    ])
  func escapeHatchIsTotal(state: HookSetupState) {
    for setUp in [true, false] {
      #expect(
        HookMaintenance.action(for: state, manages: false, hasBeenSetUp: setUp) == nil)
    }
  }
}
