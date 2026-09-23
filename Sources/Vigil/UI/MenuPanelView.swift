import SwiftUI
import VigilCore

/// The dropdown.
///
/// Reads as a sequence of answers: what is happening, who is holding your Mac
/// awake, and what you can do about it.
///
/// Two lists, one row. The agents and the assertion ledger used to be built
/// from three row types at three heights, which made them look like three
/// different kinds of information — when in fact both lists answer the same
/// question, "who is holding your Mac awake", and differ only in the subject
/// the semibold header above them already names. One `AwakeRow` at one height is
/// the whole reason this panel is 180pt shorter than the one it replaces.
///
/// Groups separate on a semibold header and whitespace. Exactly one rule
/// survives, above the footer, where the content stops being an answer and
/// starts being an action. A rule per section is the same visual noise as a box
/// per section.
struct MenuPanelView: View {
  @Bindable var model: AppModel
  var onQuit: () -> Void
  var onSettings: () -> Void

  private var pad: CGFloat { Theme.Metrics.panelPadding }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      status
      bridgeNotice
      agents
      ledger
      footer
    }
    .padding(.vertical, Theme.Metrics.panelPaddingVertical)
    .frame(width: Theme.Metrics.panelWidth)
    .animation(Theme.Motion.contentChange, value: model.sessions)
    .animation(Theme.Motion.contentChange, value: model.otherAssertions)
  }

  // MARK: - Status

  /// The headline, the reason under it, and — folded back in from what used to
  /// be a 63pt section of its own — the battery.
  ///
  /// That section stated one number three times (header, bar, caption) and
  /// printed the floor permanently, as a fact about the machine, when it is a
  /// setting. DESIGN.md's own sketch always had the meter on the status line;
  /// the section was the drift. What is genuinely stateful about the battery —
  /// that it has dropped below the number you chose — arrives in `statusDetail`
  /// on the line below, in words, at the moment it matters.
  private var status: some View {
    VStack(alignment: .leading, spacing: 0) {
      // `spacing: 0` with the gap in the spacer, so the minimum between the
      // headline and the meter is the 16 it says and not the 24 a stack
      // spacing either side of a spacer minimum quietly adds up to. The widest
      // pair this line can hold — "Keeping your Mac awake" and "99% charging"
      // behind a 21pt glyph — leaves 19pt over, and would lose 8 of them to
      // that arithmetic.
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(model.statusHeadline)
          .font(Theme.Text.status)
          .foregroundStyle(model.decision.holdIdleAssertion ? Color.vigilAmber : .vigilPrimary)
          .lineLimit(1)
          // The headline is the one line this app exists to show, so it takes
          // its width first and the readout beside it is what gives way if a
          // larger system font ever leaves them short.
          .layoutPriority(1)

        Spacer(minLength: Theme.Metrics.loose)

        // Omitted outright on a desktop. A meter pinned at 100% forever is a
        // decoration, and this is the one line in the app that cannot carry one.
        if model.power.hasBattery {
          BatteryReadout(percent: model.power.batteryPercent, isCharging: model.power.isPluggedIn)
        }
      }
      .frame(height: 20)

      Text(model.statusDetail)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilSecondary)
        .lineLimit(1)
        .frame(height: 17, alignment: .leading)
    }
    .padding(.horizontal, pad)
  }

  // MARK: - Notices

  /// The one global notice there is.
  ///
  /// Everything else that can go wrong belongs to a row, and is answered beside
  /// that row. This one belongs to no row: if the bridge is down, every row in
  /// the panel is quietly stale, and nothing else in the interface would say so.
  @ViewBuilder
  private var bridgeNotice: some View {
    if let error = model.bridgeError {
      Notice(
        title: "Agents can't reach Vigil",
        detail: "Vigil listens on a socket in your home folder, and nothing can reach it "
          + "right now. Your agents will keep working — Vigil just won't know they are.",
        actionTitle: "Try again",
        action: model.retryBridge
      )
      // The raw reason is a socket error: a path, an errno, and a word like
      // "bind". DESIGN.md keeps that vocabulary out of the panel, and throwing
      // it away entirely would leave a bug report with nothing in it — so it
      // lives one hover and one log line away instead.
      .help(error)
    }
  }

  // MARK: - Agents

  private var agents: some View {
    VStack(alignment: .leading, spacing: 0) {
      SectionHeader(
        "Agents",
        actionTitle: model.attentionSummary,
        action: model.fixIntegrationsNeedingAttention
      )
      .padding(.top, Theme.Metrics.snug)

      if model.availableIntegrations.isEmpty {
        nothingToWatch
      } else {
        VStack(alignment: .leading, spacing: 0) {
          // Live sessions first, named by the project each is working in — the
          // thing you actually want to know is *which* run is still going.
          ForEach(shownSessions) { session in
            AwakeRow(
              isActive: session.state == .working,
              primary: AgentIntegration.displayName(for: session.agent),
              secondary: session.cwd.map(Self.shorten),
              // Paths truncate from the head: the last two components say which
              // project this is, and the first two say nothing you don't know.
              secondaryTruncation: .head,
              value: .text(Self.sessionValue(session, now: model.now)),
              spoken: Self.spokenSession(session, now: model.now)
            )
          }
          if hiddenSessionCount > 0 {
            more(hiddenSessionCount)
          }

          // Then the agents with nothing running. Same row: four hollow dots
          // are proof Vigil is watching, which a sentence saying the panel is
          // empty would undo.
          ForEach(model.quietIntegrations) { integration in
            let state = model.setupState(for: integration)
            AwakeRow(
              isActive: false,
              primary: integration.displayName,
              value: Self.quietValue(state) { model.installHooks(for: integration) },
              spoken: "\(integration.displayName), \(Self.spokenSetup(state))"
            )
          }

          if let error = model.setupError {
            // A written sentence, with the installer's own text on the hover.
            // What it says is true of every failure the installer can report:
            // it refuses before writing rather than half-way through.
            Text("That didn't finish. Nothing was changed — open Settings to see why.")
              .font(Theme.Text.footnote)
              .foregroundStyle(.vigilPrimary)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, pad)
              .padding(.top, Theme.Metrics.tight)
              .help(error)
          }
        }
        .padding(.top, Theme.Metrics.tight)
      }
    }
  }

  /// The empty state, in place of the rows rather than instead of the section.
  ///
  /// A headline, one sentence and one thing to do — never a lone grey sentence
  /// where a list should be. Keeping the header above it means the panel still
  /// reads as a working app that has nothing to report, rather than a broken one.
  private var nothingToWatch: some View {
    VStack(alignment: .leading, spacing: Theme.Metrics.tight) {
      Text("Nothing to watch yet")
        .font(Theme.Text.body)
        .foregroundStyle(.vigilPrimary)
      Text(
        "Vigil works with Claude Code, Codex, Gemini CLI and Cursor. "
          + "Install one and its runs will show up here."
      )
      .font(Theme.Text.detail)
      .foregroundStyle(.vigilSecondary)
      .fixedSize(horizontal: false, vertical: true)
      Link("How Vigil works", destination: Self.projectURL)
        .font(Theme.Text.detail)
    }
    .padding(.horizontal, pad)
    .padding(.top, Theme.Metrics.tight)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("No agents installed")
  }

  private static let projectURL = URL(string: "https://github.com/Rupareliaaniket22/vigil")!

  /// Capped, because the panel clamps its height to the screen and does not
  /// scroll: rows past the bottom would be silently cut off, which is worse
  /// than saying how many there are. Sorted by most recent activity, so the
  /// ones shown are the ones worth seeing.
  private var shownSessions: [AgentSession] { Array(model.sessions.prefix(8)) }
  private var hiddenSessionCount: Int { max(0, model.sessions.count - 8) }

  // MARK: - Ledger

  /// Processes other than Vigil holding the Mac awake.
  ///
  /// DESIGN.md: the ledger is the point. It is what turns this from a switch
  /// into an explanation, and it is honest about the times the answer isn't us.
  /// The rows leave the dot's gutter empty rather than borrowing a hollow dot —
  /// that gap is what keeps the dot meaning one thing, "this is an agent Vigil
  /// is watching", instead of drifting into "this is a row".
  @ViewBuilder
  private var ledger: some View {
    if !shownAssertions.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        // `snug`, the same as the gap above "Agents" and above the footer's
        // rule. This one was `loose`, and the only gap in the panel that was:
        // a row's 4pt of slack, 16, and the header's 2 made 22pt of white
        // where every other section break made 11 or 12, and the ledger read
        // as a second panel that had been pushed down rather than the next
        // answer in the same one.
        SectionHeader("Also holding your Mac awake")
          .padding(.top, Theme.Metrics.snug)

        VStack(alignment: .leading, spacing: 0) {
          ForEach(shownAssertions) { assertion in
            let phrase = LedgerPhrase(processName: assertion.processName, reason: assertion.reason)
            AwakeRow(
              isActive: false,
              showsDot: false,
              primary: phrase.primary,
              secondary: phrase.secondary,
              value: .text(Self.held(assertion, until: model.now.wall)),
              spoken: Self.spokenAssertion(assertion, phrase: phrase, until: model.now.wall)
            )
          }
          if hiddenAssertionCount > 0 {
            more(hiddenAssertionCount)
          }
        }
        .padding(.top, Theme.Metrics.tight)
      }
    }
  }

  /// One row per process, keeping its longest-held assertion. The list arrives
  /// sorted longest-first, so the first one seen is the right one.
  private var collapsedAssertions: [SystemAssertion] {
    var seen = Set<String>()
    return model.otherAssertions.filter { seen.insert($0.processName).inserted }
  }

  private var shownAssertions: [SystemAssertion] { Array(collapsedAssertions.prefix(4)) }
  private var hiddenAssertionCount: Int { max(0, collapsedAssertions.count - 4) }

  // MARK: - Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 0) {
      // The one full-bleed rule in the panel. Above it everything answers a
      // question; below it everything does something. That is a change of kind,
      // which is the only thing a rule is allowed to mark.
      Hairline(fullBleed: true)
        .padding(.top, Theme.Metrics.snug)

      VStack(alignment: .leading, spacing: 0) {
        KeepAwakeRow(isOn: $model.manualOverride, blockedBy: guardrailPhrase)

        if model.isPaused {
          // Reads its own state, never the global status detail — a guardrail
          // can be the active reason while a pause is also running.
          VigilMenuRow("Resume — paused until \(pausedUntilText)", action: model.resume)
        } else {
          // Siblings, not a `Menu`. A real menu draws in its own window: it
          // would open on top of the panel, outside it, for two options that
          // cost 48pt to state outright.
          VigilMenuRow("Pause 30 minutes") { model.pause(for: 30 * 60) }
          VigilMenuRow("Pause 1 hour") { model.pause(for: 60 * 60) }
        }

        VigilMenuRow("Settings…", trailing: "⌘,", action: onSettings)
        VigilMenuRow("Quit Vigil", trailing: "⌘Q", action: onQuit)
      }
      .padding(.top, Theme.Metrics.tight)
    }
  }

  /// Why the manual hold is unavailable, in the few words a trailing slot holds.
  ///
  /// Not `statusDetail`: that is a sentence for the status line, and the widest
  /// of them is three times the room there is here. These are fragments of the
  /// row's own grammar — "Always keep awake · on battery" — which is also why
  /// they are not in `StatusCopy`, where every string is a sentence that has
  /// to stand on its own.
  ///
  /// A disabled switch that says nothing is worse than no switch at all: the
  /// user is left to guess whether Vigil is broken or being careful.
  private var guardrailPhrase: String? {
    switch model.decision.reason {
    case .batteryBelowFloor: "battery too low"
    case .onBatteryAndPluggedInRequired: "on battery"
    case .lowPowerMode: "Low Power Mode"
    case .tooHot: "too hot"
    case .agentsWorking, .manualOverride, .paused, .noAgents: nil
    }
  }

  private var pausedUntilText: String {
    model.pausedUntil?.formatted(date: .omitted, time: .shortened) ?? ""
  }

  // MARK: - Row content

  private func more(_ count: Int) -> some View {
    Text("and \(count) more")
      .font(Theme.Text.footnote)
      .foregroundStyle(.vigilTertiary)
      .padding(.horizontal, pad)
      .frame(height: Theme.Metrics.rowHeight, alignment: .leading)
  }

  /// What a live session's value rail says.
  ///
  /// A waiting session reports what it needs rather than how long it has been
  /// needing it: the number is the same either way, and only one of the two
  /// tells you to go and look at it.
  private static func sessionValue(_ session: AgentSession, now: Timestamp) -> String {
    session.state == .waiting ? "needs you" : Elapsed.short(session.quietFor(now: now))
  }

  private static func quietValue(
    _ state: HookSetupState, fix: @escaping () -> Void
  ) -> AwakeRow.Value {
    switch state {
    case .ready: .text("idle")
    case .outOfDate: .action("Update", fix)
    case .notSetUp: .action("Set up", fix)
    // Not an action: re-running the install is exactly what does not help.
    case .untrusted: .text("not trusted")
    }
  }

  private static func held(_ assertion: SystemAssertion, until now: Date) -> String {
    guard let seconds = assertion.held(until: now), seconds >= 0 else { return "" }
    return Elapsed.short(seconds)
  }

  private static func shorten(_ path: String) -> String {
    guard !path.isEmpty else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  // MARK: - What VoiceOver hears

  private static func spokenSession(_ session: AgentSession, now: Timestamp) -> String {
    let name = AgentIntegration.displayName(for: session.agent)
    let value = sessionValue(session, now: now)
    return session.state == .waiting
      ? "\(name), waiting for you"
      : "\(name), \(session.state.rawValue), last active \(value)"
  }

  private static func spokenSetup(_ state: HookSetupState) -> String {
    switch state {
    case .ready: "idle"
    case .outOfDate: "set up by an older version of Vigil"
    case .notSetUp: "not set up"
    case .untrusted: "installed, but the host is not running it"
    }
  }

  private static func spokenAssertion(
    _ assertion: SystemAssertion, phrase: LedgerPhrase, until now: Date
  ) -> String {
    var parts = [phrase.primary]
    // The demoted half is only worth saying when it is not a restatement of
    // the half already spoken.
    if let secondary = phrase.secondary, secondary != phrase.primary { parts.append(secondary) }
    let duration = held(assertion, until: now)
    if !duration.isEmpty { parts.append("held \(duration)") }
    parts.append(assertion.expiresOnItsOwn ? "expires on its own" : "no time limit")
    return parts.joined(separator: ", ")
  }
}

// MARK: - Structure

/// A group's label, and where a group has one thing to fix, the fix.
///
/// Semibold rather than bold: SwiftUI's `.bold` is weight 700 and the macOS
/// Headline style is 600. At 13pt, 700 out-shouts the 15pt status line and the
/// panel ends up with its hierarchy inverted — the smallest text being the
/// loudest. The weight lives in `Theme.Text.section`; this is only where it
/// shows.
private struct SectionHeader: View {
  let title: String
  var actionTitle: String?
  var action: (() -> Void)?

  init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
    self.title = title
    self.actionTitle = actionTitle
    self.action = action
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.snug) {
      Text(title)
        .font(Theme.Text.section)
        .foregroundStyle(.vigilPrimary)
        .lineLimit(1)

      Spacer(minLength: Theme.Metrics.tight)

      if let actionTitle, let action {
        // Where an 83pt banner used to be. The banner explained at length
        // something there is only one thing to do about, and the affected rows
        // were already offering to do it — so what is left is the sentence, in
        // the one place a group's own business belongs.
        //
        // The chevron is in the label rather than a separate image so it
        // travels with the last word instead of pinning itself to the margin.
        Button(action: action) { Text("\(actionTitle) \u{203A}") }
          .buttonStyle(.vigil)
          .fixedSize()
      }
    }
    .padding(.horizontal, Theme.Metrics.panelPadding)
    // The button's capsule is 22pt and overhangs this by a point top and
    // bottom, into a gap that is four. Letting the header grow instead would
    // move every row below it the moment an agent went out of date.
    .frame(height: 20)
  }
}

/// Something the user needs to know, and the one action that resolves it.
/// DESIGN.md: errors say what happened and what to do, and do not apologise.
private struct Notice: View {
  let title: String
  let detail: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(Theme.Text.body)
        .foregroundStyle(.vigilPrimary)
      Text(detail)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.vigilFilled)
          .padding(.top, Theme.Metrics.tight)
      }
    }
    .padding(.horizontal, Theme.Metrics.panelPadding)
    .padding(.top, Theme.Metrics.snug)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

// MARK: - The row

/// One thing holding your Mac awake: an agent Vigil is watching, or a process
/// it merely found.
///
/// Four columns, identical for both lists, because the lists are the same
/// question asked of two subjects. The value rail is what makes them read as
/// one table rather than two: every elapsed time lands on the same x, so the
/// eye can run down the column instead of hunting for the number on each line.
struct AwakeRow: View {

  /// What the rail holds. A time, or the one thing to do about this row —
  /// never both, because a row with two right-hand ends has neither.
  enum Value {
    case text(String)
    case action(String, () -> Void)
  }

  var isActive: Bool
  /// False for the ledger, whose rows are not agents and must not borrow the
  /// dot that says one is being watched.
  var showsDot = true
  let primary: String
  var secondary: String?
  var secondaryTruncation: Text.TruncationMode = .tail
  let value: Value
  /// The whole row in one sentence, so VoiceOver reads it as a row rather than
  /// as four unrelated fragments.
  let spoken: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.snug) {
      dot

      Text(primary)
        .font(Theme.Text.body)
        .foregroundStyle(.vigilPrimary)
        .lineLimit(1)
        // The name is the answer; the path beside it is context. Priority is
        // how that gets said to the layout system — without it a long path
        // shortens the name it is explaining.
        .layoutPriority(2)

      if let secondary, !secondary.isEmpty {
        Text(secondary)
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilSecondary)
          .lineLimit(1)
          .truncationMode(secondaryTruncation)
          .layoutPriority(0)
      }

      Spacer(minLength: Theme.Metrics.tight)

      rail
    }
    .padding(.horizontal, Theme.Metrics.panelPadding)
    .frame(height: Theme.Metrics.rowHeight)
    // The row moves as one piece, or not at all.
    //
    // DESIGN.md asks for a session appearing or disappearing to be animated,
    // and `MenuPanelView` does that on `model.sessions`. Without a group, every
    // leaf in here resolves its own geometry against the ancestor's
    // *interpolating* frame — and these four columns do not resolve at the same
    // rate, because two of them carry `layoutPriority` and the rail is
    // `fixedSize`. So the rail slides to its new x while the path is still the
    // old width, and for two frames the row re-columns itself in mid-air. That
    // is precisely what makes a list look replaced rather than updated, which
    // is the thing the animation was added to prevent.
    //
    // Taken from MacControlCenterUI, which puts a geometry group on every one
    // of its menu items (Menu Abstracts/HighlightingMenuItem.swift and the
    // rest) for the same reason. macOS 14 is our floor, so it needs no gate;
    // theirs is spelled `geometryGroupIfSupportedByPlatform()` because they
    // still support 11.
    .geometryGroup()
    .modifier(RowAccessibility(spoken: spoken, hasAction: hasAction))
  }

  private var hasAction: Bool {
    if case .action = value { return true }
    return false
  }

  /// The dot's column — 6pt of dot plus `snug`, putting every row's first
  /// character at x=30 — is held open even when there is no dot, by the dot
  /// itself. `.hidden()` keeps the layout and the alignment guide and drops
  /// only the drawing, so the two lists share a column to the point rather than
  /// to within a rounding error.
  @ViewBuilder
  private var dot: some View {
    if showsDot {
      StateDot(isActive: isActive)
    } else {
      StateDot(isActive: false).hidden()
    }
  }

  @ViewBuilder
  private var rail: some View {
    switch value {
    case .text(let text):
      Text(text)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilTertiary)
        .monospacedDigit()
        .lineLimit(1)
        // `minWidth`, not `width`. The width pins the elapsed times into a
        // column, which is the whole job; a two-word state like "needs you" is
        // two points wider than that and is allowed to grow leftward rather
        // than truncate, because the rail is its trailing edge.
        .frame(minWidth: Theme.Metrics.valueRail, alignment: .trailing)
        .fixedSize(horizontal: true, vertical: false)
    case .action(let title, let perform):
      Button(title, action: perform)
        .buttonStyle(.vigil)
        .fixedSize()
    }
  }
}

/// Rows with a button cannot be collapsed into one element — that is where the
/// button goes. Rows without one must be, or VoiceOver reads four fragments and
/// leaves the listener to assemble the row themselves.
private struct RowAccessibility: ViewModifier {
  let spoken: String
  let hasAction: Bool

  func body(content: Content) -> some View {
    if hasAction {
      content
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
    } else {
      content
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }
  }
}

/// One way of saying how long ago, used by every row that says it.
enum Elapsed {
  static func short(_ seconds: TimeInterval) -> String {
    let minutes = Int(max(0, seconds)) / 60
    if minutes < 1 { return "now" }
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
  }
}

// MARK: - Footer switch

/// "Always keep awake", with the switch on the right.
///
/// It used to sit beside the status headline with a "Keep awake" label, which
/// cost 101pt of the widest line in the panel to say something the footer says
/// for free — every other row down there is also a thing you do. A switch is
/// the one control that reads correctly in a menu, because it shows its state
/// as well as offering the change.
///
/// "Always", because the row sits under a headline that already says "Keeping
/// your Mac awake" whenever an agent is working, and a switch reading "Keep
/// awake" would look wrong sitting off beneath it. What the switch adds is the
/// *always*: awake whether or not an agent is working, until you turn it off.
/// "Keep awake, agents or not" said the same thing as a fragment with a comma
/// in it, and at 160pt it was two points wider than the room beside "Low Power
/// Mode", so the one time the row had to explain itself it ended in an
/// ellipsis. The guardrail phrase beside it is what keeps "always" honest.
///
/// Not a `VigilMenuRow`: that row *is* a button, and this row *is* a switch.
/// Borrowing the menu row would report a button to accessibility, and a button
/// that says "Always keep awake" with no on or off in it is useless to anyone
/// who cannot see the track.
private struct KeepAwakeRow: View {
  @Binding var isOn: Bool
  /// Why the switch cannot be used, when it cannot. A manual hold never beats a
  /// guardrail, so offering one during a guardrail is a switch that visibly
  /// does nothing.
  var blockedBy: String?

  private let title = "Always keep awake"

  var body: some View {
    if let blockedBy {
      // Two elements rather than one disabled `Toggle` with a longer label:
      // `.disabled()` dims the whole control to 50%, and the one thing the
      // user needs to read here — why it is down — must not be the half that
      // fades. So only the switch is disabled, and the words are not.
      HStack(spacing: Theme.Metrics.snug) {
        Text(title)
          .font(Theme.Text.body)
          .foregroundStyle(.vigilPrimary)
          .lineLimit(1)

        Spacer(minLength: Theme.Metrics.tight)

        Text(blockedBy)
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilSecondary)
          .lineLimit(1)

        // The user's own setting, shown as it is. A guardrail outranks the
        // manual hold, it does not clear it — so drawing the switch off
        // would be telling them they never flipped it, when what they need
        // to know is that they did and it is not being honoured yet.
        Toggle(isOn: .constant(isOn)) { EmptyView() }
          .toggleStyle(.vigil)
          .controlSize(.mini)
          .disabled(true)
          .fixedSize()
      }
      // The panel's own text margin, so the title starts where every row
      // above it does. Nothing here can take focus, so nothing needs the
      // menu-row inset the live switch below carries.
      .padding(.horizontal, Theme.Metrics.panelPadding)
      .frame(height: Theme.Metrics.menuRowHeight)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(title)
      .accessibilityValue("\(isOn ? "on" : "off"), \(blockedBy)")
      .accessibilityAddTraits(.isToggle)
    } else {
      Toggle(isOn: $isOn) {
        Text(title)
          .font(Theme.Text.body)
          .foregroundStyle(.vigilPrimary)
      }
      // Laid out as a footer row by the style itself, margin included, so its
      // focus ring is the menu rows' highlight rectangle — 6pt in, 6pt radius
      // — and not a ring at the text margin that the four rows under it never
      // draw. The style has to own the margin because the ring goes round
      // whatever is inside the style, and padding applied out here would be
      // outside it.
      .toggleStyle(.vigilMenuRow)
      .controlSize(.mini)
      .accessibilityHint("Holds your Mac awake regardless of what agents are doing")
    }
  }
}

// MARK: - Battery

/// The battery glyph and the number, on the status line.
///
/// Monochrome, always. Colour in this app means one thing — that something is
/// holding the Mac awake — and a meter that went amber or green would be a
/// second meaning, after which neither reads at a glance.
///
/// The glyph is the system's own battery symbol at the nearest quarter, set
/// inline so it takes the text's size, colour and baseline. It replaces a
/// hand-drawn 24×5 pill whose track was `separatorColor` — 1.24:1 against the
/// panel, so the empty part vanished and what remained was a grey dash of no
/// fixed meaning floating beside the words, at a width where one percent was
/// under a quarter of a point. The number was always the reading. What the
/// glyph is for is saying, in the quarter-second a glance lasts, that the
/// number is a *battery* — the one thing "67% left" on its own leaves you to
/// infer — and the symbol everyone already reads in their menu bar does that
/// at 12pt without inventing a drawing of our own. Quarters, because that is
/// the resolution a glance has; the digits beside it carry the rest.
///
/// No floor marker, as before: the floor is a setting, not a state, and
/// printing it permanently beside a live reading was always the wrong
/// register. It lives in Settings, and surfaces in the status detail in words
/// on the one day it fires.
private struct BatteryReadout: View {
  let percent: Int
  let isCharging: Bool

  var body: some View {
    // One `Text`, not an `Image` beside one: an inline symbol sits on the
    // digits' baseline and takes their font, where a separate `Image` in a
    // `.firstTextBaseline` row reports its bottom edge as its baseline and
    // hangs below them — the same fault `StateDot` has to correct by hand.
    Text("\(Image(systemName: symbol)) \(label)")
      .monospacedDigit()
      .font(Theme.Text.detail)
      .foregroundStyle(.vigilSecondary)
      .lineLimit(1)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Battery \(percent) percent\(isCharging ? ", charging" : "")")
  }

  /// `battery.0percent` through `battery.100percent`, in quarters.
  ///
  /// Rounded to the nearest, not floored: 67% *is* three-quarters to anyone
  /// glancing at it, and a glyph showing half beside a number saying 67 would
  /// be two readings that disagree. Only one symbol is used, whatever the
  /// charging state: the word beside it already says "charging", and a bolt
  /// on the glyph would be a second way of saying the same thing.
  private var symbol: String {
    let clamped = min(max(percent, 0), 100)
    let quarter = Int((Double(clamped) / 25).rounded()) * 25
    return "battery.\(quarter)percent"
  }

  /// Three states, and the words are load-bearing twice over.
  ///
  /// "left" is wrong while charging — the number is going up — and "Charged"
  /// is what a full battery on mains actually is, which is also the one pair
  /// ("Keeping your Mac awake" beside "100% charging") that would not fit on
  /// this line. No separator between the number and the word: a middle dot and
  /// its two spaces cost 10pt to say something the space already says.
  private var label: String {
    guard isCharging else { return "\(percent)% left" }
    return percent >= 100 ? "Charged" : "\(percent)% charging"
  }
}

// MARK: - Gallery

/// Stands in for `#Preview` — see ControlSupport.swift for why it has to.
///
/// The two pieces of panel chrome no fixture can reach. The bridge notice needs
/// a socket that will not bind, and the blocked switch needs a guardrail that is
/// actually holding — neither of which a layout check is allowed to arrange on
/// the machine running it. Gathered here so they are still built by something
/// before they ship, rather than first drawn on a user's Mac on the worst day
/// they have had with it.
struct MenuPanelDegradedGallery: View {
  @State private var manual = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Notice(
        title: "Agents can't reach Vigil",
        detail: "Vigil listens on a socket in your home folder, and nothing can reach it "
          + "right now. Your agents will keep working — Vigil just won't know they are.",
        actionTitle: "Try again",
        action: {}
      )

      Hairline(fullBleed: true)
        .padding(.top, Theme.Metrics.snug)

      VStack(alignment: .leading, spacing: 0) {
        // Every guardrail phrase there is, at the width it has to fit in.
        KeepAwakeRow(isOn: $manual, blockedBy: "battery too low")
        KeepAwakeRow(isOn: $manual, blockedBy: "on battery")
        KeepAwakeRow(isOn: $manual, blockedBy: "Low Power Mode")
        KeepAwakeRow(isOn: $manual, blockedBy: "too hot")
        KeepAwakeRow(isOn: $manual, blockedBy: nil)
      }
      .padding(.top, Theme.Metrics.tight)
    }
    .padding(.vertical, Theme.Metrics.panelPaddingVertical)
    .frame(width: Theme.Metrics.panelWidth)
  }
}
