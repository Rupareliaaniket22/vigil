import Foundation

/// Recognising the settings files Vigil cannot safely edit.
///
/// `JSONSerialization` parses JSON, not JSONC, and several of these hosts
/// document comments as allowed. Their users write them. Refusing with "check
/// it is valid JSON" sends someone to look for a syntax error in a file that
/// their own editor is perfectly happy with, so the refusal has to name the
/// real reason.
///
/// Vigil will not strip the comments and write the file back: a settings file
/// is the user's, and silently deleting the notes they left themselves to gain
/// the right to edit it is not a trade we get to make on their behalf.
public enum SettingsFile {

  /// Whether this text carries JSON-with-comments.
  ///
  /// Scans with a string-literal state machine rather than searching for `//`,
  /// because `"url": "https://example.com"` contains a `//` that is not a
  /// comment, and a false positive here refuses a file Vigil could have edited.
  public static func containsComments(_ text: String) -> Bool {
    var inString = false
    var escaped = false
    var previous: Character?

    for character in text {
      if escaped {
        escaped = false
        previous = character
        continue
      }
      if inString {
        if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        previous = character
        continue
      }
      if character == "\"" {
        inString = true
        previous = character
        continue
      }
      if previous == "/", character == "/" || character == "*" { return true }
      previous = character
    }
    return false
  }
}
