import Foundation
import OSLog
import UserNotifications
import VigilCore

/// The two moments worth interrupting someone for.
///
/// Deliberately not notified: starting a hold, releasing it normally, or an
/// agent going idle. Those are expected, the menu bar already shows them, and a
/// utility that pings on every routine transition gets muted within a day.
@MainActor
enum Notifier {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "notifications")

  enum Event {
    /// Every agent stopped. The thing the user walked away waiting for.
    case allAgentsFinished(count: Int)
    /// We stopped holding the Mac awake while work was still running. This one
    /// matters: their run may not survive, and nothing else would tell them.
    case guardrailStoppedHold(reason: String)
    /// Work began with a guardrail already in force, so we never started
    /// holding. Same stakes, different sentence — nothing stopped, because
    /// nothing had started.
    case guardrailPreventedHold(reason: String)
  }

  /// Ask the first time we actually have something to say, rather than at
  /// launch — a permission prompt before the app has demonstrated any value is
  /// the fastest route to being denied.
  private static var hasRequestedAuthorization = false
  /// Nil until asked. False means the user said no, and kept saying no every
  /// time we posted anyway — so we stop posting rather than logging a failure
  /// on every guardrail for the rest of the session.
  private static var isAuthorized: Bool?

  static func notify(_ event: Event) {
    Task { await send(event) }
  }

  private static func send(_ event: Event) async {
    let center = UNUserNotificationCenter.current()

    if !hasRequestedAuthorization {
      hasRequestedAuthorization = true
      do {
        isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
      } catch {
        isAuthorized = false
        log.notice(
          "notification authorization failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    guard isAuthorized == true else { return }

    let content = UNMutableNotificationContent()

    switch event {
    case .allAgentsFinished(let count):
      content.title = count == 1 ? "Agent finished" : "Agents finished"
      content.body =
        count == 1
        ? "Your agent has stopped working. Your Mac can sleep normally now."
        : "All \(count) agents have stopped working. Your Mac can sleep normally now."
      // Routine good news — deliver quietly.
      content.interruptionLevel = .passive

    case .guardrailStoppedHold(let reason):
      content.title = "Vigil stopped holding your Mac awake"
      // The title is the "what", so the body carries only the "why" — whatever
      // the caller handed us. A whole status line arrives here today, and
      // "Your Mac can sleep — Battery 18%, below the 20% you set. An agent is
      // still working and may not finish." spends its opening clause arguing
      // with its own title.
      content.body =
        "\(NotificationPolicy.detail(inStatusLine: reason)). "
        + "An agent is still working and may not finish."
      // Their work is genuinely at risk; this one should cut through.
      content.interruptionLevel = .timeSensitive
      content.sound = .default

    case .guardrailPreventedHold(let reason):
      // "isn't", not "stopped". Nothing stopped — there was never a hold to
      // stop. Reporting a state as an event is how an app ends up describing
      // something that did not happen, and someone who catches it once stops
      // believing the alert that matters.
      content.title = "Vigil isn't holding your Mac awake"
      content.body =
        "\(NotificationPolicy.detail(inStatusLine: reason)). "
        + "An agent has started, and your Mac may sleep before it finishes."
      // Not time-sensitive, and silent, unlike the one above. This fires the
      // instant work begins — the person is still at the keyboard, and can
      // plug in or change the setting from the banner's own app. A sound at
      // the moment they pressed return reads as an error chime for having
      // pressed it.
      content.interruptionLevel = .active
    }

    do {
      try await center.add(
        UNNotificationRequest(
          identifier: UUID().uuidString, content: content, trigger: nil))
    } catch {
      log.notice("could not post notification: \(error.localizedDescription, privacy: .public)")
    }
  }
}
