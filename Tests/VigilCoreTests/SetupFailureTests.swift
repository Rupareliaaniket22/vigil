import Foundation
import Testing

@testable import VigilCore

/// The installer's real sentences, at the length they really reach: one of them
/// lists every hook entry in somebody's settings file. A summary that reads
/// well against "oops" and badly against these is not a summary.
private let claudeReason =
  "/Users/somebody/.claude/settings.json is read-only. Vigil left it alone — "
  + "make it writable and try again."
private let geminiReason =
  "/Users/somebody/.gemini/settings.json holds hook entries Vigil doesn't "
  + "recognise (PreToolUse, PostToolUse, Stop). Vigil left them alone rather "
  + "than replace them — add Vigil's hook by hand, or move that entry out of "
  + "the way and try again."
private let codexReason =
  "/Users/somebody/.codex/config.toml already records that hook in a form Vigil "
  + "can't rewrite safely. Vigil changed nothing — open Codex and run /hooks to "
  + "approve them there."

private func failure(_ host: String, _ reason: String) -> SetupFailure {
  SetupFailure(host: host, reason: reason)
}

/// What the user is told when a maintenance pass goes wrong.
///
/// One pass touches every agent on the Mac without anybody pressing anything,
/// so it is the one error path in the app with no human standing by to notice
/// that the explanation belongs to a different agent from the one they are
/// looking at.
@Suite("Explaining a maintenance pass that failed")
struct SetupFailureTests {

  @Test("a pass with nothing wrong says nothing")
  func silenceWhenNothingFailed() {
    #expect(SetupFailure.summary(of: []) == nil)
  }

  /// The single-failure sentence is the installer's own, unchanged. It already
  /// names the file it could not write, and prefixing it with the agent's name
  /// would say the same thing twice in two lines.
  @Test("one failure reads exactly as the installer wrote it")
  func oneFailureIsUntouched() {
    #expect(SetupFailure.summary(of: [failure("Claude Code", claudeReason)]) == claudeReason)
  }

  /// The defect, stated as the user met it: both agents failed in one pass and
  /// only the last was reported, so the first had failed with no way at all to
  /// learn why.
  @Test("two failures in one pass both reach the user")
  func bothFailuresSurvive() throws {
    let summary = try #require(
      SetupFailure.summary(of: [
        failure("Claude Code", claudeReason),
        failure("Gemini CLI", geminiReason),
      ]))
    #expect(summary.contains(claudeReason), "the first agent's reason was the one being lost")
    #expect(summary.contains(geminiReason))
    #expect(summary.contains("Claude Code"))
    #expect(summary.contains("Gemini CLI"))
  }

  /// And the names are on the first line, which is the line every view has room
  /// for. The reasons are host-supplied and unbounded; the names are not, and
  /// they are the half that tells somebody which agent to go and look at.
  @Test("the agents that failed are named before any reason is given")
  func theNamesComeFirst() throws {
    let summary = try #require(
      SetupFailure.summary(of: [
        failure("Claude Code", claudeReason),
        failure("Gemini CLI", geminiReason),
        failure("Codex", codexReason),
      ]))
    let headline = try #require(summary.split(separator: "\n").first).description
    #expect(headline == "Claude Code, Gemini CLI and Codex didn't finish.")
    // No Oxford comma, and the whole headline stays one short line however
    // long the reasons under it are.
    #expect(!headline.contains(", and "))
    #expect(headline.count < 80)
  }

  /// Four agents is the most a Mac can have, and it must not cost four times
  /// the height. The bound is the first line: everything after it is what the
  /// views already hold to a line cap and put on `.help()`.
  @Test("the worst case a Mac can reach is still one short line to read")
  func fourFailuresStayBounded() throws {
    let summary = try #require(
      SetupFailure.summary(of: [
        failure("Claude Code", claudeReason),
        failure("Codex", codexReason),
        failure("Gemini CLI", geminiReason),
        failure("Cursor", claudeReason),
      ]))
    let lines = summary.split(separator: "\n")
    #expect(lines.count == 5, "a headline and one line per failure, never a paragraph each")
    #expect(try #require(lines.first).count < 80)
    for failed in ["Claude Code", "Codex", "Gemini CLI", "Cursor"] {
      #expect(summary.contains(failed))
    }
  }

  /// An install and an approval are two writes, so one agent can fail twice in
  /// a pass. Both reasons are kept — they are different failures — and the
  /// headline names it once.
  @Test("one agent failing twice is named once and explained twice")
  func oneAgentTwice() throws {
    let summary = try #require(
      SetupFailure.summary(of: [
        failure("Codex", claudeReason),
        failure("Codex", codexReason),
      ]))
    #expect(
      try #require(summary.split(separator: "\n").first).description == "Codex didn't finish.")
    #expect(summary.contains(claudeReason))
    #expect(summary.contains(codexReason))
  }

  @Test("the house style for a list has no Oxford comma")
  func listStyle() {
    #expect(SetupFailure.list([]) == "")
    #expect(SetupFailure.list(["Codex"]) == "Codex")
    #expect(SetupFailure.list(["Codex", "Cursor"]) == "Codex and Cursor")
    #expect(SetupFailure.list(["A", "B", "C"]) == "A, B and C")
  }
}
