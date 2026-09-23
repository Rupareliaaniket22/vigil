import Foundation
import Testing

@testable import VigilCore

private func bytes(_ text: String) -> Data { Data(text.utf8) }

@Suite("Whether the privileged helper matches the app that drives it")
struct HelperIntegrityTests {

  @Test("identical bytes are current")
  func identical() {
    let helper = bytes("#!/bin/bash\ncase \"$1\" in on) ;; esac\n")
    #expect(HelperIntegrity.state(installed: helper, bundled: helper) == .current)
    #expect(HelperIntegrity.state(installed: helper, bundled: helper).notice == nil)
  }

  /// The real drift, reduced to what actually differs: a usage string written
  /// before the third verb existed. Nothing about the behaviour changed, which
  /// is the point — a check that only fired on behavioural differences would
  /// have to understand shell, and would have said nothing here.
  @Test("a helper from an older build is out of date")
  func drifted() {
    let installed = bytes("#!/bin/bash\n# usage: vigil-clamshell on|off\n")
    let bundled = bytes("#!/bin/bash\n# usage: vigil-clamshell on|off|sleep\n")
    let state = HelperIntegrity.state(installed: installed, bundled: bundled)

    #expect(state == .outOfDate)
    #expect(state.needsAttention)
  }

  /// A single byte has to be enough. The whole argument for hashing rather
  /// than comparing behaviour is that we cannot know which byte matters.
  @Test("one byte is a difference")
  func oneByte() {
    #expect(HelperIntegrity.state(installed: bytes("a"), bundled: bytes("b")) == .outOfDate)
  }

  /// Lid-closed support that was never set up is not a fault, and must not
  /// produce a notice for a feature the user has not turned on.
  @Test("no helper at all is not a problem")
  func absent() {
    let state = HelperIntegrity.state(installed: nil, bundled: bytes("x"))
    #expect(state == .notInstalled)
    #expect(state.notice == nil)
    #expect(!state.needsAttention)
  }

  /// A check that could not run is not evidence of a fault. An app bundle
  /// missing its resource must not make every installed helper read as wrong.
  @Test("a missing bundled copy says nothing", arguments: [Data?.none, Data()])
  func unreadable(bundled: Data?) {
    let state = HelperIntegrity.state(installed: bytes("x"), bundled: bundled)
    #expect(state == .unreadable)
    #expect(state.notice == nil)
    #expect(!state.needsAttention)
  }

  /// The notice is the only thing the user ever sees, so it carries the two
  /// things that make this worth showing: why a shell script's comments matter
  /// (it runs as root) and what to do about it.
  @Test("the notice explains why it matters and what to do")
  func wording() {
    let notice = try! #require(HelperIntegrity.State.outOfDate.notice)
    #expect(notice.contains("root"))
    #expect(notice.contains("reinstall"))
    #expect(
      !notice.lowercased().contains("tamper"),
      "a hash difference cannot support that claim — writing there already needs root")
  }

  @Test("the digest is lowercase hex SHA-256")
  func digest() {
    // The empty string's SHA-256, which every implementation agrees on.
    #expect(
      HelperIntegrity.digest(Data())
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  }
}
