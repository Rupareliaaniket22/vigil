import Testing

@testable import VigilCore

@Suite("Ledger phrases")
struct LedgerPhraseTests {

  @Test("a known system process leads with what it actually means")
  func knownProcessesLeadWithThePhrase() {
    let expected = [
      ("powerd", "Your display is on"),
      ("coreaudiod", "Audio is playing"),
      ("WindowServer", "The screen is in use"),
      ("bluetoothd", "A Bluetooth device is connected"),
      ("mediaremoted", "Media is playing"),
      ("sharingd", "Something is being shared"),
      ("backupd", "Time Machine is backing up"),
      ("kernel_task", "The system is busy"),
    ]
    for (name, phrase) in expected {
      let row = LedgerPhrase(processName: name, reason: "whatever IOKit felt like saying")
      #expect(row.primary == phrase)
      // The name is demoted, never dropped: the row still has to be something
      // you can match against `pmset`.
      #expect(row.secondary == name)
      #expect(row.isPhrase)
    }
  }

  @Test("the table covers every process the design promises and nothing else")
  func tableIsBounded() {
    // A bound worth asserting. The failure mode this guards is the table
    // quietly becoming a list of apps, which is the thing `readsAsHuman`
    // exists to make unnecessary.
    #expect(LedgerPhrase.phrases.count == 8)
  }

  @Test("an unknown process falls back to exactly what the panel showed before")
  func unknownFallsBackUnchanged() {
    // Byte for byte the old two columns: the process name, and whatever
    // `AssertionReason` could rescue from the raw string. Compared against the
    // real function rather than a literal, so the two can never drift apart.
    let raw = "Playing audio"
    let row = LedgerPhrase(processName: "Music", reason: raw)
    #expect(row.primary == "Music")
    #expect(row.secondary == AssertionReason.presentable(raw, processName: "Music"))
    #expect(!row.isPhrase)
  }

  @Test("an unknown daemon is left alone too, however unreadable its name")
  func unknownDaemonIsNotImprovised() {
    // `runningboardd` fails the readability test and still gets no sentence.
    // Wanting to write one is exactly the impulse the bounded table refuses.
    let row = LedgerPhrase(
      processName: "runningboardd",
      reason: "xpcservice<com.apple.weather.widget([osservice<com.apple.chronod(502)>:3378])>")
    #expect(row.primary == "runningboardd")
    // The reason was XPC plumbing, so nothing survives to demote.
    #expect(row.secondary == nil)
    #expect(!row.isPhrase)
  }

  @Test("caffeinate keeps its own words")
  func caffeinateIsAlreadyPlain() {
    let row = LedgerPhrase(processName: "caffeinate", reason: "caffeinate command-line tool")
    #expect(row.primary == "caffeinate")
    #expect(row.secondary == "command-line tool")
    #expect(!row.isPhrase)
  }

  @Test("a missing reason leaves a name and nothing after it")
  func handlesNoReason() {
    let row = LedgerPhrase(processName: "Spotify")
    #expect(row.primary == "Spotify")
    #expect(row.secondary == nil)
  }

  @Test("the name matches whatever case IOKit reports it in")
  func matchesCaseInsensitively() {
    #expect(LedgerPhrase(processName: "PowerD").primary == "Your display is on")
    #expect(LedgerPhrase(processName: "windowserver").primary == "The screen is in use")
    #expect(LedgerPhrase(processName: "KERNEL_TASK").primary == "The system is busy")
    // The demoted half still echoes the spelling that was reported, not ours.
    #expect(LedgerPhrase(processName: "PowerD").secondary == "PowerD")
  }

  @Test("the name matches exactly, never as a substring")
  func neverMatchesASubstring() {
    // Announcing that someone's display is on when it is not would be worse
    // than the daemon name it replaced.
    for name in ["somepowerdaemon", "powerdaemon", "mypowerd", "powerd2", "coreaudiodx"] {
      #expect(LedgerPhrase(processName: name).primary == name)
      #expect(!LedgerPhrase(processName: name).isPhrase)
    }
  }

  @Test("an ordinary app name needs no sentence from us")
  func appNamesReadAsHuman() {
    for name in ["Music", "Spotify", "zoom.us", "Slack", "Google Chrome", "caffeinate", "Xcode"] {
      #expect(LedgerPhrase.readsAsHuman(name), "\(name) reads perfectly well already")
    }
  }

  @Test("a daemon or kernel name does not")
  func daemonNamesDoNotReadAsHuman() {
    for name in [
      "powerd", "coreaudiod", "runningboardd", "nsurlsessiond", "bluetoothd",
      "kernel_task", "mds_stores",
    ] {
      #expect(!LedgerPhrase.readsAsHuman(name), "\(name) tells a user nothing")
    }
  }

  @Test("every phrase we wrote is for a name that needed one")
  func everyEntryEarnsItsPlace() {
    // The rule's real job, enforced rather than described: a future entry for
    // `Spotify` fails here. `WindowServer` is the one name that clears the
    // readability bar and still explains nothing, named so it reads as a
    // decision rather than an oversight.
    for name in LedgerPhrase.phrases.keys where name != "windowserver" {
      #expect(!LedgerPhrase.readsAsHuman(name), "\(name) is plain enough without us")
    }
  }
}
