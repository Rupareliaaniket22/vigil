/// The two lines one ledger row shows, with the readable one first.
///
/// The ledger answers "why won't my Mac sleep?", and it used to answer like
/// this:
///
///     powerd       Prevent sleep while display is on      1h 38m
///     coreaudiod   com.apple.audio.BuiltInSpeakerDevice…  2h 04m
///
/// The emphasis is inverted. Nobody knows what `powerd` is, and everybody
/// knows what "your display is on" means — yet the sentence is the demoted
/// grey half while the daemon name holds the position the eye lands on first.
/// So the sentence leads and the name follows it:
///
///     Your display is on     powerd           1h 38m
///     Audio is playing       coreaudiod       2h 04m
///     Music                  Playing audio        4m
///
/// The process name is demoted rather than dropped. A ledger that hides which
/// process is responsible stops being something anyone can check against
/// `pmset`, and being checkable is the only reason this section exists.
public struct LedgerPhrase: Sendable, Equatable {

  /// The line that leads the row.
  public let primary: String

  /// The demoted half. Nil when nothing worth showing survived cleaning.
  public let secondary: String?

  /// Whether `primary` is a sentence we wrote rather than the process name.
  ///
  /// Nothing about the row is drawn differently for it. It is here so a caller
  /// need not infer it by comparing `primary` against the name it passed in —
  /// the accessibility label and any future "show me what IOKit actually said"
  /// affordance both have to know which of the two they are holding.
  public let isPhrase: Bool

  /// Build both lines for one process holding an assertion.
  ///
  /// `reason` is IOKit's raw string. Handing over an already-cleaned one is
  /// safe: `AssertionReason.presentable` leaves its own output alone, so the
  /// app layer can pass whichever it happens to have.
  public init(processName: String, reason: String? = nil) {
    // Exact and case-insensitive, never a substring. `somepowerdaemon`
    // contains `powerd`, and a ledger that confidently announces your display
    // is on when it isn't is worse than one that stays quiet.
    if let phrase = Self.phrases[processName.lowercased()] {
      primary = phrase
      // The phrase is a better telling of the raw reason, so keeping both
      // would say one thing twice. What the phrase dropped is which process
      // it was — echoed here exactly as IOKit spelled it, not as the table
      // key, so it can still be matched against `pmset -g assertions`.
      secondary = processName
      isPhrase = true
      return
    }

    // Anything we have never seen falls through to precisely what the panel
    // showed before this type existed. The phrases are an addition; a process
    // we cannot describe must never come out of here worse than it went in.
    primary = processName
    secondary = AssertionReason.presentable(reason ?? "", processName: processName)
    isPhrase = false
  }

  /// What each system process is really telling the user.
  ///
  /// Keyed lowercase, because the lookup is case-insensitive. Deliberately
  /// short: these are the daemons that actually turn up in the ledger on an
  /// ordinary Mac, and every one of them is a claim about the machine that we
  /// have to be right about. A daemon whose assertion we have not watched
  /// behave gets no entry — a confident wrong sentence is worse than the bare
  /// name it replaced, which is the one thing this change must not do.
  ///
  /// `caffeinate` is absent on purpose, being the best-known wake-holder of
  /// the lot: it already says what it is, and `readsAsHuman` below is the
  /// generalisation of why it needs nothing from us.
  static let phrases: [String: String] = [
    "powerd": "Your display is on",
    "coreaudiod": "Audio is playing",
    "windowserver": "The screen is in use",
    "bluetoothd": "A Bluetooth device is connected",
    "mediaremoted": "Media is playing",
    "sharingd": "Something is being shared",
    "backupd": "Time Machine is backing up",
    "kernel_task": "The system is busy",
  ]

  /// Whether a process name is already something a person can read.
  ///
  /// This is the test that stops the table above from growing into a list of
  /// every app in the world. `Music`, `Spotify`, `zoom.us` and `Slack` need no
  /// sentence — the name is the sentence — and new ones ship every week, so an
  /// allow-list of them is a job that can never be finished.
  ///
  /// The opposite list can be. The processes that need a phrase are Unix
  /// daemons and kernel threads, and those follow two naming conventions that
  /// app names essentially never do: all lowercase with a trailing `d`
  /// (`powerd`, `sharingd`, `runningboardd`), or an underscore (`kernel_task`,
  /// `mds_stores`). Everything else reads as human.
  ///
  /// `WindowServer` is the honest exception — it clears this bar and still
  /// explains nothing — which is why the table above is exact and consulted
  /// first rather than gated on this.
  ///
  /// Being wrong here is cheap in both directions, because nothing rendered
  /// branches on it: a process with no table entry leads with its own name
  /// either way, so misjudging `sublime_text` costs nothing. What this decides
  /// is which names would *deserve* a sentence — the bar a proposed new entry
  /// has to fail before it earns a row, which `LedgerPhraseTests` enforces.
  public static func readsAsHuman(_ processName: String) -> Bool {
    // Kernel and BSD-era names. No app anyone ships has one.
    if processName.contains("_") { return false }

    let separated = processName.contains { $0 == " " || $0 == "." || $0 == "-" }
    let lowercase = processName == processName.lowercased()
    // Four characters is the shortest we will call a daemon, because `bird` —
    // CloudDocs' — is the shortest one macOS actually ships. Below that the
    // `d` is the word rather than a suffix.
    if lowercase, !separated, processName.hasSuffix("d"), processName.count >= 4 {
      return false
    }
    return true
  }
}
