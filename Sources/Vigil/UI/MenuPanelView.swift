import SwiftUI
import VigilCore

/// The dropdown.
///
/// Reads as a sequence of answers: what is happening, how much power is left,
/// which agents are running, what else is keeping the Mac awake, and what you
/// can do about it.
///
/// Groups separate on a bold header and whitespace. Rules appear only where the
/// *kind* of content changes — before the ledger, which is about other apps,
/// and before the footer, which is actions. A rule per section is the same
/// visual noise as a box per section.
struct MenuPanelView: View {
  @Bindable var model: AppModel
  var onQuit: () -> Void
  var onSettings: () -> Void

  private var pad: CGFloat { Theme.Metrics.panelPadding }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      notices
      battery
      agents
      ledger
      footer
    }
    .padding(.vertical, Theme.Metrics.loose)
    .frame(width: Theme.Metrics.panelWidth)
    .animation(Theme.Motion.contentChange, value: model.sessions)
    .animation(Theme.Motion.contentChange, value: model.otherAssertions)
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline) {
        Text(model.statusHeadline)
          .font(Theme.Text.status)
          .foregroundStyle(model.decision.holdIdleAssertion ? Color.vigilAmber : .vigilPrimary)
          .lineLimit(1)

        Spacer(minLength: Theme.Metrics.snug)

        Toggle(isOn: $model.manualOverride) {
          Text("Keep awake").font(Theme.Text.detail)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        // A manual hold cannot beat a guardrail, so offering it during one
        // would be a switch that visibly does nothing.
        .disabled(model.decision.reason.isGuardrail)
        .accessibilityLabel("Keep awake")
        .accessibilityHint("Holds your Mac awake regardless of what agents are doing")
      }

      Text(model.statusDetail)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilSecondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, pad)
  }

  // MARK: - Notices

  @ViewBuilder
  private var notices: some View {
    if let error = model.bridgeError {
      Notice(title: "Vigil isn't receiving agent events", detail: error)
    }
    if let error = model.setupError {
      Notice(title: "Setup didn't finish", detail: error)
    }
  }

  // MARK: - Battery

  private var battery: some View {
    Group {
      SectionHeader(
        "Battery",
        trailing: model.power.isPluggedIn
          ? "\(model.power.batteryPercent)% · charging"
          : "\(model.power.batteryPercent)% left"
      )

      VStack(alignment: .leading, spacing: 4) {
        BatteryBar(percent: model.power.batteryPercent, floor: floorShown)

        // Naming the threshold makes the guardrail visible rather than a
        // surprise the first time it fires.
        Text(guardrailSummary)
          .font(Theme.Text.footnote)
          .foregroundStyle(.vigilTertiary)
      }
      .padding(.horizontal, pad)
      .padding(.top, 2)
    }
  }

  /// Zero means "no floor", which a marker at the far left would misrepresent.
  private var floorShown: Int? {
    let floor = model.settings.batteryFloorPercent
    return (floor > 0 && floor < 100) ? floor : nil
  }

  private var guardrailSummary: String {
    if model.settings.onlyWhenPluggedIn { return "Stops when you unplug" }
    guard let floor = floorShown else { return "No battery limit set" }
    return "Stops below \(floor)%"
  }

  // MARK: - Agents

  private var agents: some View {
    Group {
      SectionHeader("Agents")

      VStack(alignment: .leading, spacing: 2) {
        if model.availableIntegrations.isEmpty {
          Text("Vigil works with Claude Code, Codex, Gemini CLI and Cursor. None is installed.")
            .font(Theme.Text.detail)
            .foregroundStyle(.vigilSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        // Live sessions first, with the project each is working in — the thing
        // you actually want to know is *which* run is still going.
        ForEach(model.sessions) { session in
          SessionRow(session: session, now: model.now)
        }

        ForEach(model.quietIntegrations) { integration in
          QuietAgentRow(
            name: integration.displayName,
            isSetUp: model.isInstalled(integration),
            setUp: { model.installHooks(for: integration) }
          )
        }
      }
      .padding(.horizontal, pad)
      .padding(.top, 2)
    }
  }

  // MARK: - Ledger

  @ViewBuilder
  private var ledger: some View {
    if !shownAssertions.isEmpty {
      Rule().padding(.top, Theme.Metrics.loose)
      SectionHeader("Also keeping it awake")

      VStack(alignment: .leading, spacing: 2) {
        ForEach(shownAssertions) { assertion in
          AssertionRow(assertion: assertion, now: model.now)
        }
        if hiddenAssertionCount > 0 {
          Text("and \(hiddenAssertionCount) more")
            .font(Theme.Text.footnote)
            .foregroundStyle(.vigilTertiary)
        }
      }
      .padding(.horizontal, pad)
      .padding(.top, 2)
    }
  }

  /// One row per process, keeping its longest-held assertion. The list arrives
  /// sorted longest-first, so the first one seen is the right one.
  private var collapsedAssertions: [SystemAssertion] {
    var seen = Set<String>()
    return model.otherAssertions.filter { seen.insert($0.processName).inserted }
  }

  /// Capped, so a busy machine cannot grow the panel past the screen.
  private var shownAssertions: [SystemAssertion] { Array(collapsedAssertions.prefix(4)) }
  private var hiddenAssertionCount: Int { max(0, collapsedAssertions.count - 4) }

  // MARK: - Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 0) {
      Rule().padding(.top, Theme.Metrics.loose)

      if model.isPaused {
        // Reads its own state, never the global status detail — a guardrail
        // can be the active reason while a pause is also running.
        MenuRow(title: "Resume — paused until \(pausedUntilText)", action: model.resume)
      } else {
        MenuSubmenuRow(title: "Pause") {
          Button("30 minutes") { model.pause(for: 30 * 60) }
          Button("1 hour") { model.pause(for: 60 * 60) }
          Button("Until tomorrow") { model.pause(for: 12 * 60 * 60) }
        }
      }

      MenuRow(title: "Settings…", action: onSettings)
      MenuRow(title: "Quit Vigil", action: onQuit)
    }
  }

  private var pausedUntilText: String {
    model.pausedUntil?.formatted(date: .omitted, time: .shortened) ?? ""
  }
}

// MARK: - Structure

private struct SectionHeader: View {
  let title: String
  var trailing: String?

  init(_ title: String, trailing: String? = nil) {
    self.title = title
    self.trailing = trailing
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(Theme.Text.section)
        .foregroundStyle(.vigilPrimary)
      Spacer()
      if let trailing {
        Text(trailing)
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilSecondary)
          .monospacedDigit()
      }
    }
    .padding(.horizontal, Theme.Metrics.panelPadding)
    .padding(.top, Theme.Metrics.loose)
  }
}

/// A full-bleed hairline. Carries no margin of its own, so callers control
/// spacing and one component does not produce different gaps in different
/// parents.
private struct Rule: View {
  var body: some View {
    Rectangle()
      .fill(Color.vigilSeparator)
      .frame(height: 1)
  }
}

private struct Notice: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(Theme.Text.body)
        .foregroundStyle(.vigilPrimary)
      Text(detail)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, Theme.Metrics.panelPadding)
    .padding(.top, Theme.Metrics.loose)
  }
}

// MARK: - Footer rows

/// A full-width row that highlights the way a real menu item does — selection
/// background, text flipping to the selected colour.
private struct MenuRow: View {
  let title: String
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title)
          .font(Theme.Text.body)
          .foregroundStyle(isHovered ? Color.vigilSelectedText : .vigilPrimary)
          .lineLimit(1)
        Spacer()
      }
      .padding(.horizontal, Theme.Metrics.panelPadding)
      .frame(height: Theme.Metrics.menuRowHeight)
      .contentShape(Rectangle())
      .background(isHovered ? Color.vigilSelection : .clear)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}

private struct MenuSubmenuRow<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    Menu(title) { content }
      .menuStyle(.borderlessButton)
      .font(Theme.Text.body)
      .padding(.horizontal, Theme.Metrics.panelPadding)
      .frame(height: Theme.Metrics.menuRowHeight)
  }
}

// MARK: - Rows

/// One live session, named by the project it is working in.
private struct SessionRow: View {
  let session: AgentSession
  let now: Date

  var body: some View {
    HStack(spacing: Theme.Metrics.snug) {
      Circle()
        .fill(session.state == .working ? Color.vigilAmber : .vigilTertiary)
        .frame(width: 6, height: 6)

      Text(session.agent.rawValue)
        .font(Theme.Text.body)
        .foregroundStyle(.vigilPrimary)
        .lineLimit(1)
        .layoutPriority(2)

      if let cwd = session.cwd, !cwd.isEmpty {
        Text(shorten(cwd))
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilSecondary)
          .lineLimit(1)
          .truncationMode(.head)
      }

      Spacer(minLength: Theme.Metrics.tight)

      Text(elapsed)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilTertiary)
        .monospacedDigit()
        .fixedSize()
    }
    .frame(height: Theme.Metrics.rowHeight)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(session.agent.rawValue), \(session.state.rawValue), last active \(elapsed)")
  }

  private func shorten(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  private var elapsed: String {
    let seconds = Int(now.timeIntervalSince(session.lastSeen))
    if seconds < 60 { return "now" }
    let minutes = seconds / 60
    return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
  }
}

/// An agent with nothing running: either idle, or not wired up yet.
///
/// Distinguished by colour and wording, never by opacity. Dimming a semantic
/// colour multiplies its alpha after it resolves, which took the unconfigured
/// row — the one you most need to act on — down to 1.4:1.
private struct QuietAgentRow: View {
  let name: String
  let isSetUp: Bool
  let setUp: () -> Void

  var body: some View {
    HStack(spacing: Theme.Metrics.snug) {
      Circle().fill(Color.clear).frame(width: 6, height: 6)

      Text(name)
        .font(Theme.Text.body)
        .foregroundStyle(.vigilSecondary)
        .lineLimit(1)

      Spacer(minLength: Theme.Metrics.tight)

      if isSetUp {
        Text("idle")
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilTertiary)
      } else {
        Button("Set up", action: setUp)
          .buttonStyle(.borderless)
          .controlSize(.small)
          .font(Theme.Text.detail)
      }
    }
    .frame(height: Theme.Metrics.rowHeight)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(name), \(isSetUp ? "idle" : "not set up")")
  }
}

/// One process holding the Mac awake, with how long it has been at it.
private struct AssertionRow: View {
  let assertion: SystemAssertion
  let now: Date

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.snug) {
      Text(assertion.processName)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: 120, alignment: .leading)

      if let reason = assertion.reason {
        Text(reason)
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilTertiary)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      Spacer(minLength: Theme.Metrics.tight)

      if !duration.isEmpty {
        Text(duration)
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilTertiary)
          .monospacedDigit()
          .fixedSize()
      }
    }
    .frame(height: 18)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibleDescription)
  }

  private var duration: String {
    guard let seconds = assertion.held(until: now), seconds >= 0 else { return "" }
    let minutes = Int(seconds) / 60
    if minutes < 1 { return "now" }
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
  }

  private var accessibleDescription: String {
    var parts = [assertion.processName]
    if let reason = assertion.reason { parts.append(reason) }
    if !duration.isEmpty { parts.append("held \(duration)") }
    parts.append(assertion.expiresOnItsOwn ? "expires on its own" : "no time limit")
    return parts.joined(separator: ", ")
  }
}

// MARK: - Battery

/// A level bar. Monochrome always.
///
/// Colour in this app means one thing — that something is holding the Mac
/// awake. A battery bar that goes amber would be a second meaning, and then
/// neither reads at a glance. The floor is drawn as a gap punched through the
/// fill rather than a tinted line, because a 1pt line at any tint measured
/// below 2:1 in both appearances.
private struct BatteryBar: View {
  let percent: Int
  let floor: Int?

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let filled = max(2, width * CGFloat(percent) / 100)

      ZStack(alignment: .leading) {
        Capsule().fill(Color.vigilSeparator)
        Capsule().fill(Color.vigilSecondary).frame(width: filled)

        if let floor {
          Rectangle()
            .fill(Color.vigilControlFill)
            .blendMode(.destinationOut)
            .frame(width: 2)
            .offset(x: width * CGFloat(floor) / 100)
        }
      }
      .compositingGroup()
    }
    .frame(height: 5)
    .accessibilityHidden(true)
  }
}
