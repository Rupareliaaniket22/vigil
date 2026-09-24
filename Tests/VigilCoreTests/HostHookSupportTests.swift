import Foundation
import Testing

@testable import VigilCore

private let script = "/Users/x/.vigil/hooks/vigil-hook.sh"
private let floor = HookFloor(executable: "gemini", since: HostVersion(0, 19, 0))

@Suite("Reading a host's version")
struct HostVersionTests {

  @Test("a plain release parses")
  func plain() {
    #expect(HostVersion("0.19.0")?.components == [0, 19, 0])
    #expect(HostVersion("0.1.22")?.components == [0, 1, 22])
  }

  @Test("a leading v is not part of the number")
  func leadingV() {
    #expect(HostVersion("v0.19.0") == HostVersion("0.19.0"))
  }

  /// Every host writes something after the number sooner or later, and none of
  /// it changes which release line the copy belongs to.
  @Test("a suffix is ignored")
  func suffix() {
    #expect(HostVersion("0.19.0+build7") == HostVersion("0.19.0"))
    #expect(HostVersion("3.21.18 (darwin-arm64)") == HostVersion("3.21.18"))
  }

  /// The one judgement call in the parser, made in the direction of not
  /// accusing. SemVer orders a pre-release below its release, which would put
  /// `0.19.0-preview.1` one notch under a floor of `0.19.0` and report a copy
  /// that plainly carries the hook subsystem as too old. Gemini CLI published
  /// `v0.19.0-preview.1` and `v0.19.0` within an hour of each other off the
  /// same branch.
  @Test("a pre-release belongs to the release it precedes")
  func preRelease() {
    #expect(HostVersion("0.19.0-preview.1") == HostVersion("0.19.0"))
    #expect(!(HostVersion("0.19.0-preview.1")! < HostVersion("0.19.0")!))
  }

  /// A floor written as `0.19` and a copy reporting `0.19.0` are one release,
  /// and a comparison that said otherwise would refuse a copy that is fine.
  @Test("missing trailing components are zero")
  func trailingZeros() {
    #expect(HostVersion("0.19") == HostVersion("0.19.0"))
    #expect(HostVersion("0.19")! < HostVersion("0.19.1")!)
  }

  @Test("components compare as numbers, not as text")
  func numericOrder() {
    // The whole reason this is not a string compare: "0.9.0" sorts after
    // "0.19.0" alphabetically and is four releases behind it.
    #expect(HostVersion("0.9.0")! < HostVersion("0.19.0")!)
    #expect(HostVersion("0.1.22")! < HostVersion("0.19.0")!)
  }

  @Test("something with no number in it is not a version")
  func notAVersion() {
    #expect(HostVersion("") == nil)
    #expect(HostVersion("unknown") == nil)
    #expect(HostVersion("v") == nil)
  }

  /// The text is kept verbatim so the sentence shown to the user says what the
  /// host says. Printing our own reassembly would disagree with `--version` on
  /// the machine the notice is about.
  @Test("the host's own spelling survives")
  func keepsText() {
    #expect(HostVersion("v0.19.0-preview.1")?.text == "v0.19.0-preview.1")
  }
}

@Suite("Whether a host could run the hooks at all")
struct HostHookSupportTests {

  @Test("no floor recorded means no opinion")
  func noFloor() {
    let verdict = HostHookSupport.verdict(
      copies: [HostCopy(path: "/usr/local/bin/gemini", version: HostVersion("0.1.22"))],
      floor: nil)
    #expect(verdict == .notChecked)
    #expect(verdict.isUsable)
  }

  /// The case the whole design turns on. Vigil searches a written-down list of
  /// install locations, not the user's `PATH` — it runs from a GUI bundle and
  /// does not have one — and people run agents through `npx`, `mise`, a nix
  /// shell and wrapper scripts that leave nothing on disk to find. Finding
  /// nothing must never become "not installed".
  @Test("finding nothing is never a problem")
  func foundNothing() {
    let verdict = HostHookSupport.verdict(copies: [], floor: floor)
    #expect(verdict == .notFound)
    #expect(verdict.isUsable)
    #expect(verdict.explanation(host: "Gemini CLI") == nil)
  }

  /// A shim, a wrapper script or a single-file binary is a perfectly healthy
  /// install whose layout simply does not write a version down.
  @Test("a copy with no version in its layout says nothing")
  func undated() {
    let verdict = HostHookSupport.verdict(
      copies: [HostCopy(path: "/Users/x/.asdf/shims/gemini", version: nil)], floor: floor)
    #expect(verdict == .undated)
    #expect(verdict.isUsable)
  }

  @Test("a current copy is nothing to report")
  func supported() {
    let verdict = HostHookSupport.verdict(
      copies: [HostCopy(path: "/opt/homebrew/bin/gemini", version: HostVersion("0.46.0"))],
      floor: floor)
    #expect(verdict == .supported)
    #expect(verdict.isUsable)
  }

  @Test("a copy exactly at the floor is current")
  func atTheFloor() {
    let verdict = HostHookSupport.verdict(
      copies: [HostCopy(path: "/opt/homebrew/bin/gemini", version: HostVersion("0.19.0"))],
      floor: floor)
    #expect(verdict == .supported)
  }

  /// The one shape worth a word, and the claim holds whatever the user's `PATH`
  /// order is: there is no copy here that could fire the hook.
  @Test("the only copy being below the floor is worth saying")
  func tooOld() {
    let verdict = HostHookSupport.verdict(
      copies: [HostCopy(path: "/usr/local/bin/gemini", version: HostVersion("0.1.22"))],
      floor: floor)
    #expect(!verdict.isUsable)
    #expect(verdict.foundVersions.map(\.text) == ["0.1.22"])
  }

  /// The rule the whole thing rests on, stated as a test because it is the
  /// place a false accusation would come from. A Mac holding both an ancient
  /// copy and a current one is a Mac where the user plausibly runs the current
  /// one, and Vigil cannot see which — so it says nothing, exactly as it does
  /// when it cannot read a trust file.
  @Test("one current copy anywhere buys the whole Mac silence")
  func mixed() {
    let verdict = HostHookSupport.verdict(
      copies: [
        HostCopy(path: "/usr/local/bin/gemini", version: HostVersion("0.1.22")),
        HostCopy(path: "/opt/homebrew/bin/gemini", version: HostVersion("0.46.0")),
      ],
      floor: floor)
    #expect(verdict == .supported)
    #expect(verdict.explanation(host: "Gemini CLI") == nil)
  }

  /// An undated copy might be anything, so it counts as a reason to stay quiet
  /// rather than as one more vote for "too old".
  @Test("an undated copy beside an old one keeps Vigil quiet")
  func oldBesideUndated() {
    let verdict = HostHookSupport.verdict(
      copies: [
        HostCopy(path: "/usr/local/bin/gemini", version: HostVersion("0.1.22")),
        HostCopy(path: "/Users/x/.local/share/mise/shims/gemini", version: nil),
      ],
      floor: floor)
    #expect(verdict == .supported)
    #expect(verdict.isUsable)
  }

  @Test("every copy below the floor is worth saying")
  func allOld() {
    let verdict = HostHookSupport.verdict(
      copies: [
        HostCopy(path: "/usr/local/bin/gemini", version: HostVersion("0.1.22")),
        HostCopy(path: "/opt/homebrew/bin/gemini", version: HostVersion("0.9.0")),
      ],
      floor: floor)
    #expect(!verdict.isUsable)
    #expect(verdict.foundVersions.map(\.text) == ["0.1.22", "0.9.0"])
  }

  /// Every clause in the sentence is hedged to the strength of the evidence,
  /// and the two numbers are both in it: a user who does run a newer copy needs
  /// enough in the sentence to tell that Vigil is looking at the wrong one.
  @Test("the sentence names what was found, the floor, and what to do")
  func wording() {
    let verdict = HostHookSupport.verdict(
      copies: [HostCopy(path: "/usr/local/bin/gemini", version: HostVersion("0.1.22"))],
      floor: floor)
    let sentence = verdict.explanation(host: "Gemini CLI")
    #expect(sentence?.contains("can see") == true)
    #expect(sentence?.contains("0.1.22") == true)
    #expect(sentence?.contains("0.19.0") == true)
    #expect(sentence?.contains("update it") == true)
    // The panel's half keeps the hedge — it is the claim, not a softener.
    #expect(verdict.panelNote(host: "Gemini CLI")?.contains("can find") == true)
  }

  @Test("only the too-old verdict says anything at all")
  func silentOtherwise() {
    for verdict: HostHookSupport in [.notChecked, .notFound, .undated, .supported] {
      #expect(verdict.explanation(host: "Gemini CLI") == nil)
      #expect(verdict.panelNote(host: "Gemini CLI") == nil)
      #expect(verdict.isUsable)
    }
  }

  /// Gemini CLI is the only host read for a floor. Guessing one for the others
  /// would produce exactly the confident wrong answer the field exists to
  /// remove, so nil has to mean "not established" and stay that way.
  @Test("only the host that was read for a floor has one")
  func onlyGeminiHasAFloor() {
    #expect(AgentIntegration.gemini.hookFloor?.since == HostVersion("0.19.0"))
    #expect(AgentIntegration.gemini.hookFloor?.executable == "gemini")
    #expect(AgentIntegration.claudeCode.hookFloor == nil)
    #expect(AgentIntegration.codex.hookFloor == nil)
    #expect(AgentIntegration.cursor.hookFloor == nil)
  }
}

@Suite("A hook of ours that says the wrong thing")
struct OutdatedHookTests {

  /// The old pre-quoting form: an unquoted path, and `working` baked into every
  /// event including the ones that end a turn. Both are what re-running the
  /// install fixes, and neither could be seen — `isVigilHook` matches the
  /// script's filename, so this satisfied `missingEvents` and `retiredEvents`
  /// alike and read as `ready`. The panel said the agent was reporting, no
  /// "Update" was ever offered, and every failure the quoting fix addressed
  /// stayed live for anyone who had installed before it.
  private func oldForm(_ integration: AgentIntegration) -> [String: Any] {
    var hooks: [String: Any] = [:]
    for event in integration.allEvents {
      let command = "\(script) \(integration.id.rawValue) \(event) working"
      hooks[event] = [["hooks": [["type": "command", "command": command]]]]
    }
    return ["hooks": hooks]
  }

  @Test("an install in the old command form is named event by event")
  func namesOldEntries() {
    let settings = oldForm(.claudeCode)
    let outdated = HookConfiguration.outdatedEvents(
      in: settings, scriptPath: script, integration: .claudeCode)
    // Every event: the path is unquoted in all of them, whatever the state.
    #expect(outdated.sorted() == AgentIntegration.claudeCode.allEvents.sorted())
  }

  /// The half that was invisible. Nothing else in the file disagrees with what
  /// Vigil expects, so without this the state word is `ready`.
  @Test("the old form looks complete to every other check")
  func looksCompleteOtherwise() {
    let settings = oldForm(.claudeCode)
    #expect(
      HookConfiguration.missingEvents(
        in: settings, scriptPath: script, integration: .claudeCode
      ).isEmpty)
    #expect(
      HookConfiguration.retiredEvents(
        in: settings, scriptPath: script, integration: .claudeCode
      ).isEmpty)
  }

  @Test("and now reads as out of date rather than ready")
  func readsAsOutOfDate() {
    let settings = oldForm(.claudeCode)
    #expect(
      HookConfiguration.setupState(
        missingEvents: HookConfiguration.missingEvents(
          in: settings, scriptPath: script, integration: .claudeCode),
        expectedEvents: AgentIntegration.claudeCode.allEvents,
        retiredEvents: HookConfiguration.retiredEvents(
          in: settings, scriptPath: script, integration: .claudeCode),
        outdatedEvents: HookConfiguration.outdatedEvents(
          in: settings, scriptPath: script, integration: .claudeCode)
      ) == .outOfDate)
  }

  /// Re-running the install is the fix, so it has to actually be one.
  @Test("re-running the install clears it")
  func installClearsIt() {
    let updated = HookConfiguration.install(
      into: oldForm(.claudeCode), scriptPath: script, integration: .claudeCode)
    #expect(
      HookConfiguration.outdatedEvents(
        in: updated, scriptPath: script, integration: .claudeCode
      ).isEmpty)
  }

  @Test("what Vigil writes today is not out of date")
  func freshInstallIsClean() {
    for integration in AgentIntegration.all {
      let settings = HookConfiguration.install(
        into: [:], scriptPath: script, integration: integration)
      #expect(
        HookConfiguration.outdatedEvents(
          in: settings, scriptPath: script, integration: integration
        ).isEmpty)
    }
  }

  /// Cursor's entries are flat rather than nested, and the check has to read
  /// both shapes — the version of this that saw only nested entries is how
  /// Cursor came to duplicate its hooks on every install.
  @Test("a flat entry in the old form is seen too")
  func flatShape() {
    let event = AgentIntegration.cursor.allEvents[0]
    let settings: [String: Any] = [
      "hooks": [event: [["command": "\(script) cursor \(event) working"]]]
    ]
    #expect(
      HookConfiguration.outdatedEvents(
        in: settings, scriptPath: script, integration: .cursor) == [event])
  }

  /// A host's own additions are not evidence of an old install. Refusing them
  /// would turn every hand-tuned settings file into a permanent "Update" badge.
  @Test("an extra key beside the right command is not an old install")
  func extraKeysAreFine() {
    let registration = AgentIntegration.claudeCode.registrations[0]
    let event = registration.event
    let command = HookConfiguration.command(
      scriptPath: script, integration: .claudeCode, registration: registration)
    let settings: [String: Any] = [
      "hooks": [
        event: [["hooks": [["type": "command", "command": command, "somethingNew": true]]]]
      ]
    ]
    #expect(
      HookConfiguration.outdatedEvents(
        in: settings, scriptPath: script, integration: .claudeCode
      ).isEmpty)
  }

  /// Another tool's hook is not ours however it is written, and must never be
  /// counted as an old install of Vigil's.
  @Test("somebody else's hook is not an old one of ours")
  func otherToolsHook() {
    let event = AgentIntegration.claudeCode.allEvents[0]
    let settings: [String: Any] = [
      "hooks": [event: [["hooks": [["type": "command", "command": "/opt/other/hook.sh"]]]]]
    ]
    #expect(
      HookConfiguration.outdatedEvents(
        in: settings, scriptPath: script, integration: .claudeCode
      ).isEmpty)
  }
}

@Suite("A host too old to run what we installed")
struct HostTooOldStateTests {

  /// The third way a perfect settings file can be inert, and the quietest:
  /// nothing anywhere on the machine distinguishes it from a working install.
  @Test("a complete install on a host below the floor is not ready")
  func tooOldBeatsReady() {
    let verdict = HostHookSupport.verdict(
      copies: [HostCopy(path: "/usr/local/bin/gemini", version: HostVersion("0.1.22"))],
      floor: floor)
    #expect(
      HookConfiguration.setupState(
        missingEvents: [], expectedEvents: ["BeforeAgent"], host: verdict) == .hostTooOld)
  }

  /// Precedence, stated once. A host too old to have a hook subsystem cannot be
  /// made to run one by trusting it, so the more fundamental refusal leads.
  @Test("too old outranks untrusted")
  func outranksUntrusted() {
    let verdict = HostHookSupport.verdict(
      copies: [HostCopy(path: "/usr/local/bin/gemini", version: HostVersion("0.1.22"))],
      floor: floor)
    #expect(
      HookConfiguration.setupState(
        missingEvents: [], expectedEvents: ["BeforeAgent"],
        trust: .untrusted(events: ["BeforeAgent"]), host: verdict) == .hostTooOld)
  }

  /// An install that is not there yet is answered by "Set up", whatever the
  /// host's version — the first step is the same either way, and a row saying
  /// the host is too old with no hooks installed would be answering a question
  /// nobody had reached.
  @Test("an agent that was never set up still reads as not set up")
  func neverSetUp() {
    let verdict = HostHookSupport.verdict(
      copies: [HostCopy(path: "/usr/local/bin/gemini", version: HostVersion("0.1.22"))],
      floor: floor)
    #expect(
      HookConfiguration.setupState(
        missingEvents: ["BeforeAgent"], expectedEvents: ["BeforeAgent"], host: verdict)
        == .notSetUp)
  }

  /// Every quiet verdict has to leave the existing states exactly as they were.
  @Test("a host Vigil cannot speak for changes nothing")
  func quietVerdictsAreInert() {
    for verdict: HostHookSupport in [.notChecked, .notFound, .undated, .supported] {
      #expect(
        HookConfiguration.setupState(
          missingEvents: [], expectedEvents: ["BeforeAgent"], host: verdict) == .ready)
      #expect(
        HookConfiguration.setupState(
          missingEvents: [], expectedEvents: ["BeforeAgent"],
          trust: .untrusted(events: ["BeforeAgent"]), host: verdict) == .untrusted)
    }
  }

  /// The default has to keep every existing call site meaning what it meant.
  @Test("saying nothing about the host is the default")
  func defaultsToNoOpinion() {
    #expect(
      HookConfiguration.setupState(missingEvents: [], expectedEvents: ["BeforeAgent"]) == .ready)
  }
}
