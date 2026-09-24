import Foundation
import OSLog
import UserNotifications
import VigilCore

/// The moments worth interrupting someone for.
///
/// Deliberately not notified: starting a hold, releasing it normally, an agent
/// stopping to ask its user a question, or one of several agents going idle.
/// Those are expected, the menu bar already shows them, and a utility that
/// pings on every routine transition gets muted within a day.
///
/// What to say and whether it makes a noise are both decided in `VigilCore`,
/// by `NotificationPolicy.Watch`. This file writes the sentences and posts
/// them; it keeps no memory of its own, because the two pieces of memory it
/// used to keep — here and in `AppModel` — were each half of a question and
/// neither could answer it.
///
/// Both sounds are `UNNotificationSound`s rather than anything played here.
/// An `NSSound` would ignore Focus and Do Not Disturb — it is the app deciding
/// when the user may be disturbed, and it would be wrong at 3am on exactly the
/// night this feature is for. Handing the sound to the notification makes that
/// the system's decision, which is the only place it belongs.
@MainActor
enum Notifier {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "notifications")

  enum Event {
    /// Every agent stopped, and every one of them said it had finished. The
    /// thing the user walked away waiting for.
    case allAgentsFinished(count: Int)
    /// Every agent stopped, and at least one stopped without finishing.
    case runEndedBadly(count: Int)
    /// Every agent stopped reporting and Vigil gave up waiting. Nobody said
    /// the work was done, so nobody gets told it was.
    case lostContact(count: Int)
    /// We stopped holding the Mac awake while work was still running. This one
    /// matters: their run may not survive, and nothing else would tell them.
    case guardrailStoppedHold(reason: String)
    /// Work began with a guardrail already in force, so we never started
    /// holding. Same stakes, different sentence — nothing stopped, because
    /// nothing had started.
    case guardrailPreventedHold(reason: String)
  }

  /// Whether macOS will let us speak, asked fresh every time we have something
  /// to say.
  ///
  /// Deliberately not cached, and the cache is what this replaces. The old
  /// version asked once, stored the answer, and treated a *thrown* request as
  /// a no for the rest of the process. `requestAuthorization` throws
  /// `UNErrorDomain` 1 — "Notifications are not allowed for this application" —
  /// on the very first ask on a machine where the user has not answered the
  /// system's prompt yet, which is every machine on its first run. The prompt
  /// is still on screen at that moment; pressing Allow changed nothing,
  /// because the answer had already been written down as no and nothing ever
  /// read it again. A menu bar app that is never quit therefore went the whole
  /// of its life silent: no completion chime, no run-ended alert, no guardrail
  /// warning, and one line in the unified log to say so.
  ///
  /// So: read the system's own record on every send, and ask only while it
  /// says the question is still open. That makes a grant take effect on the
  /// next notification rather than on the next launch, and a refusal cost one
  /// cheap read rather than a prompt. `.notDetermined` is the only state that
  /// asks, so a user who said no is not asked again — macOS remembers that for
  /// us, which is the whole reason it is the one keeping the record.
  ///
  /// The moment of the asking is `Notifier.askToSpeakIfNeeded()`, called when
  /// the panel first opens, and it is not where it used to be. The old rule was
  /// to ask no earlier than the first thing worth saying, on the reasoning that
  /// a prompt before the app has shown any value is the fastest route to being
  /// denied. That reasoning holds for most apps and is exactly wrong for this
  /// one: the first thing Vigil ever has to say is that a long run has
  /// finished, and the person it is saying it to has, by definition, gone away.
  /// macOS delivers the permission prompt as a Notification Center banner
  /// rather than a modal, so nobody presses Allow, the banner expires, and the
  /// notification that triggered it is discarded. Every time, on every machine.
  /// Vigil had never delivered a single notification to anyone.
  ///
  /// The panel is the fix because it is the one moment that is both: the user
  /// is present and looking at the app, and the app has already shown them
  /// something — their agents, the ledger, what is holding the Mac awake. Value
  /// demonstrated, person in the room.
  private static func isAllowedToSpeak() async -> Bool {
    var status = await authorizationStatus()
    if status == .notDetermined {
      do {
        _ = try await UNUserNotificationCenter.current()
          .requestAuthorization(options: [.alert, .sound])
      } catch {
        // Not a refusal, and not a reason to stop. The settings read below is
        // what decides — the user may be looking at the prompt this very
        // request put on their screen.
        log.notice(
          "notification authorization request failed: \(error.localizedDescription, privacy: .public)"
        )
      }
      status = await authorizationStatus()
    }
    switch status {
    case .authorized, .provisional, .ephemeral: return true
    case .denied, .notDetermined: return false
    @unknown default: return false
    }
  }

  /// The one field of `UNNotificationSettings` this file needs, fetched without
  /// the object it came on.
  ///
  /// `UNNotificationSettings` is a class and is not `Sendable`, so the `async`
  /// spelling of this cannot hand one back across an isolation boundary under
  /// Swift 6. The callback form can: the settings object stays inside the
  /// closure and only the status — an enum, and a value — comes out.
  ///
  /// `nonisolated`, and that is not a tidiness note. This type is
  /// `@MainActor`, so without it the completion handler inherits main-actor
  /// isolation — and `getNotificationSettings` calls back on a dispatch queue
  /// of its own choosing. Swift checks that at runtime rather than trusting
  /// it, so the app took a `dispatch_assert_queue` trap and died inside the
  /// first notification it ever tried to send. Nothing here touches
  /// main-actor state; the `await` at the call site hops back.
  private nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
    await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        continuation.resume(returning: settings.authorizationStatus)
      }
    }
  }

  /// The completion chime, by file name.
  ///
  /// `UNNotificationSound(named:)` takes a *file* name, which is why the
  /// extension is part of it — "Glass" with no extension is what
  /// `NSSound(named:)` wants, and this is not that. The file is one macOS has
  /// shipped in `/System/Library/Sounds` for decades, so there is no audio in
  /// this repository to license, sign or keep.
  ///
  /// Glass over the rest of that folder: it is a struck note with a short
  /// decay that settles rather than rising, which is what "that finished"
  /// sounds like. Tink and Pop are the size of one keystroke and say nothing
  /// ended; Ping and Bottle are the shape of a message arriving; Hero is a
  /// fanfare, and nobody wants to be congratulated at 3am; Purr and Submarine
  /// are too soft and too low to carry to the next room, which is where the
  /// person this is for has gone; and Sosumi, Basso, Funk and Frog are error
  /// sounds wherever else the user has met them.
  ///
  /// A name rather than a built `UNNotificationSound`, and that is not a
  /// style choice: a sound held on this main-actor type would put the content
  /// it is attached to in the main actor's isolation region, and the request
  /// could then no longer be handed to the notification centre at all. Built
  /// where it is used, it is a value of its own and goes where it is sent.
  private static let completionSoundFile = "Glass.aiff"

  /// The sound arrives already decided, by the same pass of the loop that
  /// decided there was anything to say. Working it out here would mean scoring
  /// one notification against the last one posted, in whatever order the
  /// notification centre got to them, using the only two facts this file has.
  /// Ask for permission while somebody is looking.
  ///
  /// Safe to call on every panel open: `isAllowedToSpeak` only prompts on
  /// `.notDetermined`, and macOS remembers a refusal so a user who said no is
  /// never asked again.
  static func askToSpeakIfNeeded() {
    Task { _ = await isAllowedToSpeak() }
  }

  static func notify(_ event: Event, sound: NotificationPolicy.Sound?) {
    Task { await send(event, sound: sound) }
  }

  private static func send(_ event: Event, sound: NotificationPolicy.Sound?) async {
    let center = UNUserNotificationCenter.current()

    guard await isAllowedToSpeak() else { return }

    let content = UNMutableNotificationContent()

    switch event {
    case .allAgentsFinished(let count):
      content.title = count == 1 ? "Agent finished" : "Agents finished"
      content.body =
        count == 1
        ? "Your agent has stopped working. Your Mac can sleep normally now."
        : "All \(count) agents have stopped working. Your Mac can sleep normally now."
      // `.passive` is not merely "quiet": a passive notification is never
      // presented and never plays a sound, so the chime cannot be had without
      // the banner. With the sound off this is exactly the notification Vigil
      // has always sent — filed in Notification Center, seen when they look.
      // With it on, the banner is the point: they are not at the desk.
      //
      // `.active`, not `.timeSensitive`. Finishing is good news, and good news
      // does not get to break through a Focus at 3am — which is also what
      // keeps this honest about Do Not Disturb, since macOS silences an active
      // notification's sound for us rather than us deciding when to be quiet.
      content.interruptionLevel = sound == nil ? .passive : .active

    case .runEndedBadly(let count):
      // "stopped", never "finished". `StopFailure` and `Interrupt` are the
      // same shape of event as the ones that end a turn properly, and Vigil
      // read them the same way — so an overnight run that died on a context
      // overflow at 2am was announced, with a pleasant chime, as work its
      // owner could come and collect.
      content.title =
        count == 1 ? "Agent stopped without finishing" : "Agents stopped without finishing"
      content.body =
        count == 1
        ? "Your agent stopped before it finished — it may have hit an error, or been "
          + "interrupted. Your Mac can sleep normally now."
        : "All \(count) agents have stopped, and at least one stopped before it finished. "
          + "Your Mac can sleep normally now."
      // `.active`, like the good news beside it, and for the same reason from
      // the other side: this is bad news that has already happened, and
      // nothing done at 3am recovers it. The one alert here that breaks
      // through a Focus is the one about work that can still be saved.
      content.interruptionLevel = sound == nil ? .passive : .active

    case .lostContact(let count):
      // Not "finished", and not "stopped" either. A session that ran out the
      // staleness window still working told us nothing at all: the host may
      // have crashed, the terminal may have closed, the Mac may have slept —
      // or it may be working this second and have gone quiet. That is the
      // whole of what Vigil knows, so it is the whole of what it says.
      content.title =
        count == 1
        ? "Vigil lost contact with your agent" : "Vigil lost contact with your agents"
      content.body =
        count == 1
        ? "It stopped reporting, so Vigil is no longer holding your Mac awake. "
          + "It may not have finished."
        : "They stopped reporting, so Vigil is no longer holding your Mac awake. "
          + "They may not have finished."
      content.interruptionLevel = sound == nil ? .passive : .active

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

    switch sound {
    case .completion:
      content.sound = UNNotificationSound(named: UNNotificationSoundName(completionSoundFile))
    // The system alert sound, for everything that is not a run arriving
    // finished: a guardrail cutting one short, and a run that ended without
    // finishing. The guardrail alarm keeps it whatever the completion switch
    // says — somebody who turned off a chime did not ask to be left unwarned.
    case .warning: content.sound = .default
    case nil: break
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
