import Foundation

/// What the panel says about the current decision.
///
/// The wording lives beside the decision rather than in the app layer for the
/// same reason the decision itself does: it is the part worth testing. Copy
/// that leaks our vocabulary, or that carries typography into a place that
/// cannot render it, is a bug — and a bug nobody can write a test for comes
/// back. `assertionName` below has come back twice already.
extension WakeReason {

  /// The headline. Deliberately short enough never to wrap in a 340pt panel —
  /// a two-line headline breaks the baseline everything beside it aligns to.
  public var statusHeadline: String {
    // Read off `holdsWake` rather than taken from the decision: `WakePolicy`
    // sets `holdIdleAssertion` from exactly this, so asking the decision would
    // be asking the same question through one more object.
    holdsWake ? "Keeping your Mac awake" : "Your Mac can sleep"
  }

  /// The reason, underneath. Splitting headline from detail means the panel
  /// always answers "what" first and "why" second, instead of one long
  /// sentence that has to wrap.
  public var statusDetail: String {
    switch self {
    case .agentsWorking(let count):
      "\(count) agent\(count == 1 ? "" : "s") working"
    case .manualOverride:
      // Names who made the choice. "Kept awake manually" reads as something
      // that happened to the Mac, and the person most in need of this line is
      // the one who has forgotten it was them who flipped the switch.
      "You're keeping it awake"
    case .paused(let until):
      "Paused until \(until.formatted(date: .omitted, time: .shortened))"
    case .noAgents:
      "No agents are running"
    case .batteryBelowFloor(let percent, let floor):
      // Not "below your 15% floor". *Floor* is our word for it, and someone
      // meeting it here is being asked to learn a piece of our vocabulary in
      // the middle of being told why their run stopped. "the 15% you set"
      // asks nothing of them and still says whose number it is.
      "Battery \(percent)%, below the \(floor)% you set"
    case .onBatteryAndPluggedInRequired:
      // Likewise the actor: this is a setting they chose, not a state the Mac
      // has landed in, and saying so is the difference between a guardrail
      // that looks deliberate and one that looks broken.
      "On battery — you chose mains power only"
    case .lowPowerMode:
      "Low Power Mode is on"
    case .tooHot(let state):
      // "too hot to stay awake safely" invites the question of what unsafe
      // means, and the answer is nothing: the machine is not in danger, the
      // hold is simply released.
      state == .critical ? "Your Mac is too hot to hold awake" : "Your Mac is running hot"
    }
  }

  /// One line, for the menu bar tooltip.
  public var statusLine: String { "\(statusHeadline) — \(statusDetail)" }

  /// The same sentence, in ASCII, for the power assertion's own name — so
  /// `pmset -g assertions` explains itself too.
  ///
  /// `pmset` prints the name through a context that is not UTF-8, where an em
  /// dash arrives as a replacement character and the line reads "Keeping your
  /// Mac awake ? 3 agents working". That has been fixed once and reintroduced
  /// twice, both times by someone reaching for the nicer dash in `statusLine`
  /// without knowing where it ended up. So this folds rather than trusting
  /// anyone to remember: there is nothing left here to type wrongly.
  public var assertionName: String {
    // Composed with the ASCII separator as well as folded. The fold is the
    // guarantee; this is so the common case never depends on it.
    StatusCopy.asciiOnly("\(statusHeadline) - \(statusDetail)")
  }
}

/// Helpers for copy that has to survive leaving the app.
enum StatusCopy {

  /// Typography mapped to what it means in ASCII.
  ///
  /// The spaces are not decoration: since ICU 72 the separator before AM/PM is
  /// a narrow no-break space, so every "Paused until 5:30 PM" carries one, and
  /// dropping it rather than translating it would print "5:30PM".
  private static let asciiEquivalents: [Character: String] = [
    "—": "-", "–": "-", "‑": "-", "·": "-", "…": "...",
    "’": "'", "‘": "'", "“": "\"", "”": "\"",
    "\u{00A0}": " ", "\u{202F}": " ", "\u{2009}": " ",
  ]

  /// `text` with nothing outside ASCII left in it.
  static func asciiOnly(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for character in text {
      if character.isASCII {
        out.append(character)
      } else if let equivalent = asciiEquivalents[character] {
        out.append(equivalent)
      } else {
        // An accent is the only other thing our own copy plausibly picks up,
        // and stripping it leaves the word readable. Whatever survives that is
        // dropped rather than replaced with a question mark: the stray "?" is
        // the artefact this function exists to remove, and printing our own
        // would be the same bug wearing a badge.
        out += String(character)
          .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
          .filter(\.isASCII)
      }
    }
    return out
  }
}
