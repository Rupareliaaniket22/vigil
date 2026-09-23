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
  }

  /// Ask the first time we actually have something to say, rather than at
  /// launch — a permission prompt before the app has demonstrated any value is
  /// the fastest route to being denied.
  private static var hasRequestedAuthorization = false

  static func notify(_ event: Event) {
    Task { await send(event) }
  }

  private static func send(_ event: Event) async {
    let center = UNUserNotificationCenter.current()

    if !hasRequestedAuthorization {
      hasRequestedAuthorization = true
      do {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
      } catch {
        log.notice(
          "notification authorization failed: \(error.localizedDescription, privacy: .public)")
        return
      }
    }

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
      content.body = "\(reason). An agent is still working and may not finish."
      // Their work is genuinely at risk; this one should cut through.
      content.interruptionLevel = .timeSensitive
      content.sound = .default
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
