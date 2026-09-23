import Foundation
import Testing

@testable import VigilCore

@Suite("Status copy")
struct StatusCopyTests {

  /// Every case, so the rules below are claims about the whole enum rather
  /// than about the four reasons someone happened to think of.
  static let everyReason: [WakeReason] = [
    .agentsWorking(count: 1),
    .agentsWorking(count: 3),
    .manualOverride,
    .paused(until: Date(timeIntervalSince1970: 1_700_000_000)),
    .noAgents,
    .batteryBelowFloor(percent: 12, floor: 15),
    .onBatteryAndPluggedInRequired,
    .lowPowerMode,
    .tooHot(state: .serious),
    .tooHot(state: .critical),
  ]

  // MARK: - The wording

  @Test("the manual hold says who is doing the holding")
  func manualOverrideNamesTheUser() {
    #expect(WakeReason.manualOverride.statusDetail == "You're keeping it awake")
  }

  @Test("the battery guardrail never says floor")
  func batteryFloorAvoidsOurVocabulary() {
    let reason = WakeReason.batteryBelowFloor(percent: 12, floor: 15)
    #expect(reason.statusDetail == "Battery 12%, below the 15% you set")
    // Spelled out separately from the literal above so the intent survives a
    // rewrite: whatever this line becomes, it must not teach the user a word
    // that only exists inside our settings file.
    #expect(!reason.statusDetail.lowercased().contains("floor"))
  }

  @Test("mains-only names the choice as the user's")
  func mainsOnlyNamesTheChoice() {
    #expect(
      WakeReason.onBatteryAndPluggedInRequired.statusDetail
        == "On battery — you chose mains power only")
  }

  @Test("heat is a limit on the hold, not a warning about the Mac")
  func heatDescribesTheHold() {
    #expect(WakeReason.tooHot(state: .critical).statusDetail == "Your Mac is too hot to hold awake")
    // Below critical the machine is merely warm, and saying more would be
    // alarming about something the user cannot act on.
    #expect(WakeReason.tooHot(state: .serious).statusDetail == "Your Mac is running hot")
  }

  @Test("the reasons that were already right are left alone")
  func untouchedReasons() {
    #expect(WakeReason.agentsWorking(count: 1).statusDetail == "1 agent working")
    #expect(WakeReason.agentsWorking(count: 3).statusDetail == "3 agents working")
    #expect(WakeReason.noAgents.statusDetail == "No agents are running")
    #expect(WakeReason.lowPowerMode.statusDetail == "Low Power Mode is on")
    // The time renders in the user's locale, so only the part we wrote is
    // asserted — pinning the rest would make this fail on a 24-hour clock.
    let paused = WakeReason.paused(until: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(paused.statusDetail.hasPrefix("Paused until "))
  }

  @Test("every reason says something")
  func nothingIsBlank() {
    for reason in Self.everyReason {
      #expect(!reason.statusDetail.isEmpty, "\(reason) has no detail")
      // DESIGN.md: state the reason, always. "Inactive" is the failure.
      #expect(reason.statusDetail.count > 8, "\(reason) says too little to be a reason")
    }
  }

  @Test("the headline follows whether the Mac is actually being held")
  func headlineFollowsTheHold() {
    for reason in Self.everyReason {
      let expected = reason.holdsWake ? "Keeping your Mac awake" : "Your Mac can sleep"
      #expect(reason.statusHeadline == expected)
    }
  }

  // MARK: - Where the line has to survive leaving the app

  @Test("the assertion name is ASCII for every reason there is")
  func assertionNameIsAlwaysASCII() {
    // The regression this exists for: `pmset` prints the assertion name in a
    // context that is not UTF-8, so one em dash becomes "Keeping your Mac
    // awake ? 3 agents working". It has been fixed once and come back twice.
    for reason in Self.everyReason {
      let name = reason.assertionName
      let isASCII = name.allSatisfy { $0.isASCII }
      #expect(isASCII, "\(reason) gave pmset \(name)")
      #expect(!name.contains("—"))
    }
  }

  @Test("the em dash arrives as a hyphen rather than disappearing")
  func emDashSurvivesAsAHyphen() {
    // Stripping it would be ASCII and unreadable: "On battery you chose mains
    // power only" reads as a sentence with a word missing.
    #expect(
      WakeReason.onBatteryAndPluggedInRequired.assertionName
        == "Your Mac can sleep - On battery - you chose mains power only")
    #expect(
      WakeReason.agentsWorking(count: 3).assertionName
        == "Keeping your Mac awake - 3 agents working")
  }

  @Test("the tooltip keeps its typography")
  func statusLineIsAllowedTheEmDash() {
    // The panel and the tooltip render UTF-8 perfectly well; only the pmset
    // path is constrained, and constraining both would be cargo cult.
    #expect(WakeReason.noAgents.statusLine == "Your Mac can sleep — No agents are running")
    #expect(
      WakeReason.manualOverride.statusLine == "Keeping your Mac awake — You're keeping it awake")
  }

  @Test("folding covers the punctuation our copy actually picks up")
  func foldsTheCharactersThatTurnUp() {
    #expect(StatusCopy.asciiOnly("a — b") == "a - b")
    #expect(StatusCopy.asciiOnly("a – b") == "a - b")
    #expect(StatusCopy.asciiOnly("waiting…") == "waiting...")
    #expect(StatusCopy.asciiOnly("it’s on") == "it's on")
    #expect(StatusCopy.asciiOnly("say “yes”") == "say \"yes\"")
    // ICU puts a narrow no-break space before AM/PM, so every paused status
    // carries one. Dropping it would print "5:30PM".
    #expect(StatusCopy.asciiOnly("5:30\u{202F}PM") == "5:30 PM")
    #expect(StatusCopy.asciiOnly("café") == "cafe")
    #expect(StatusCopy.asciiOnly("already plain") == "already plain")
  }
}
