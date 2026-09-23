import Testing

@testable import VigilCore

@Suite("Assertion reasons")
struct AssertionReasonTests {

  @Test("keeps the informative part after a process-name prefix")
  func stripsLeadingName() {
    // The one genuinely useful reason on an idle Mac. Discarding it because it
    // mentions the process was throwing away the only signal in the list.
    #expect(
      AssertionReason.presentable(
        "Powerd - Prevent sleep while display is on", processName: "powerd")
        == "Prevent sleep while display is on")
  }

  @Test("drops a reason that is only the process name")
  func dropsBareRestatement() {
    #expect(
      AssertionReason.presentable("caffeinate command-line tool", processName: "caffeinate")
        == "command-line tool")
    #expect(AssertionReason.presentable("caffeinate", processName: "caffeinate") == nil)
  }

  @Test(
    "rejects XPC plumbing",
    arguments: [
      "xpcservice<com.apple.weather.widget([osservice<com.apple.chronod(502)>:3378])(502)>",
      "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep",
      "someVeryLongUnbrokenSymbolNameWithNoSpacesAtAll",
    ])
  func rejectsIdentifiers(raw: String) {
    #expect(AssertionReason.presentable(raw, processName: "someDaemon") == nil)
  }

  @Test("keeps ordinary prose")
  func keepsProse() {
    #expect(
      AssertionReason.presentable("Playing audio", processName: "Music") == "Playing audio")
    #expect(
      AssertionReason.presentable("Agent 'claude-code' is working", processName: "Vigil")
        == "Agent 'claude-code' is working")
  }

  @Test("caps length so VoiceOver doesn't read an essay")
  func capsLength() {
    let long = String(repeating: "a reason ", count: 40)
    let result = AssertionReason.presentable(long, processName: "x")
    #expect((result?.count ?? 0) <= 120)
  }

  @Test("empty and whitespace-only reasons produce nothing")
  func handlesEmpty() {
    #expect(AssertionReason.presentable("", processName: "x") == nil)
    #expect(AssertionReason.presentable("   \n ", processName: "x") == nil)
  }
}
