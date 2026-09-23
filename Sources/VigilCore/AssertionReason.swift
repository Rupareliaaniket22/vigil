import Foundation

/// Turning a power assertion's raw reason into something worth showing.
///
/// What IOKit reports ranges from a readable sentence to 300 characters of XPC
/// plumbing. On an ordinary Mac the raw strings look like this:
///
///     coreaudiod    com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep
///     runningboardd xpcservice<com.apple.weather.widget([osservice<…(502)>:3378])…
///     powerd        Powerd - Prevent sleep while display is on
///
/// Printing those verbatim makes the panel a debug dump. Dropping them all
/// makes it a list of bare process names. This picks the middle.
public enum AssertionReason {

  /// A reason fit to display, or nil when nothing useful survives.
  public static func presentable(_ reason: String, processName: String) -> String? {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let stripped = strippingLeadingName(from: trimmed, processName: processName)
    guard !stripped.isEmpty, !looksLikeAnIdentifier(stripped) else { return nil }

    // Long but genuine prose still needs a ceiling — the row truncates
    // visually, but VoiceOver would read the whole thing aloud.
    return String(stripped.prefix(120))
  }

  /// Remove a leading restatement of the process name.
  ///
  /// "Powerd - Prevent sleep while display is on" carries real information
  /// after the prefix. Discarding the whole string because it mentions the
  /// process throws away the only informative reason on a typical Mac.
  static func strippingLeadingName(from reason: String, processName: String) -> String {
    guard !processName.isEmpty,
      reason.lowercased().hasPrefix(processName.lowercased())
    else { return reason }

    let remainder = reason.dropFirst(processName.count)
    let separators = CharacterSet(charactersIn: " -–—:·,").union(.whitespaces)
    let cleaned = remainder.drop { $0.unicodeScalars.allSatisfy(separators.contains) }

    // If nothing but the name was there, there is no reason to show.
    return cleaned.isEmpty ? "" : String(cleaned)
  }

  /// Whether this reads as machine plumbing rather than an explanation.
  static func looksLikeAnIdentifier(_ text: String) -> Bool {
    // Structural punctuation from XPC descriptions.
    if text.contains(where: { "<>{}[]".contains($0) }) { return true }
    // Reverse-DNS, with no prose around it.
    if text.hasPrefix("com.") || text.hasPrefix("org.") { return true }
    // A single unbroken token is a symbol, not a sentence.
    if !text.contains(" ") && text.count > 24 { return true }
    return false
  }
}
