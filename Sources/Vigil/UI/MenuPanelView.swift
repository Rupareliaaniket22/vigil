import SwiftUI
import VigilCore

/// The dropdown.
///
/// Reads as a sequence of answers: what is happening, how much power is left,
/// which agents are running, what else is keeping the Mac awake, and what you
/// can do about it. Each of those is a titled section with a rule above it, so
/// the structure carries the hierarchy and no row needs a box of its own.
struct MenuPanelView: View {
  @Bindable var model: AppModel
  var onQuit: () -> Void
  var onSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      notices
      battery
      agents
      ledger
      pause
      footer
    }
    .padding(.vertical, Theme.Metrics.loose)
    .frame(width: Theme.Metrics.panelWidth)
    .animation(Theme.Motion.contentChange, value: model.sessions)
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(model.statusHeadline)
          .font(Theme.Text.status)
          .foregroundStyle(
            model.decision.holdIdleAssertion ? Color.vigilAmber : .vigilPrimary
          )
          .lineLimit(1)

        Spacer()

        Toggle("", isOn: $model.manualOverride)
          .toggleStyle(.switch)
          .controlSize(.small)
          .labelsHidden()
          .help("Keep awake regardless of what agents are doing")
      }

      Text(model.statusDetail)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilSecondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, Theme.Metrics.panelPadding)
  }

  // MARK: - Notices

  @ViewBuilder
  private var notices: some View {
    if let error = model.bridgeError {
      Notice(title: "Vigil isn't receiving agent events", detail: error, isProblem: true)
    }
    if let error = model.setupError {
      Notice(title: "Setup didn't finish", detail: error, isProblem: true)
    }
  }

  // MARK: - Battery

  private var battery: some View {
    PanelSection(title: "Battery") {
      BatteryBar(
        percent: model.power.batteryPercent,
        floor: model.settings.batteryFloorPercent,
        isBelowFloor: model.decision.reason.isGuardrail && !model.power.isPluggedIn
      )

      HStack {
        Text(
          model.power.isPluggedIn
            ? "\(model.power.batteryPercent)% · charging"
            : "\(model.power.batteryPercent)% left"
        )
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilSecondary)
        .monospacedDigit()

        Spacer()

        // Showing the threshold makes the guardrail visible rather than a
        // surprise the first time it fires.
        Text("stops below \(model.settings.batteryFloorPercent)%")
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilTertiary)
      }
    }
  }

  // MARK: - Agents

  private var agents: some View {
    PanelSection(
      title: "Agents", trailing: model.workingCount > 0 ? "\(model.workingCount) working" : nil
    ) {
      if model.availableIntegrations.isEmpty {
        Text("No supported agents found on this Mac.")
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilSecondary)
      } else {
        ForEach(model.availableIntegrations) { integration in
          AgentRow(
            name: integration.displayName,
            summary: model.summary(for: integration),
            isWorking: model.isWorking(integration),
            isSetUp: model.isInstalled(integration)
          )
        }
      }

      if !model.hooksInstalled {
        Button("Set up") { model.installAllAvailableHooks() }
          .controlSize(.small)
          .padding(.top, Theme.Metrics.tight)
      }
    }
  }

  // MARK: - Ledger

  @ViewBuilder
  private var ledger: some View {
    if !collapsedAssertions.isEmpty {
      PanelSection(title: "Also keeping it awake") {
        ForEach(collapsedAssertions) { assertion in
          AssertionRow(assertion: assertion, now: model.now)
        }
      }
    }
  }

  /// One row per process, keeping its longest-held assertion. The list arrives
  /// sorted longest-first, so the first one seen is the right one.
  private var collapsedAssertions: [SystemAssertion] {
    var seen = Set<String>()
    return model.otherAssertions.filter { seen.insert($0.processName).inserted }
  }

  // MARK: - Pause

  private var pause: some View {
    PanelSection(title: "Pause") {
      if model.isPaused {
        HStack {
          Text(model.statusDetail)
            .font(Theme.Text.detail)
            .foregroundStyle(.vigilSecondary)
          Spacer()
          PillButton("Resume") { model.resume() }
        }
      } else {
        HStack(spacing: Theme.Metrics.snug) {
          Spacer()
          PillButton("30 min") { model.pause(for: 30 * 60) }
          PillButton("1 hour") { model.pause(for: 60 * 60) }
        }
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 0) {
      Rule().padding(.top, Theme.Metrics.loose)
      MenuRow(title: "Settings…", shortcut: "⌘,", action: onSettings)
      MenuRow(title: "Quit Vigil", shortcut: "⌘Q", action: onQuit)
    }
  }
}

// MARK: - Structure

/// A titled group with a rule above it.
private struct PanelSection<Content: View>: View {
  let title: String
  var trailing: String?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Metrics.snug) {
      Rule().padding(.top, Theme.Metrics.loose)

      HStack {
        Text(title)
          .font(Theme.Text.section)
          .foregroundStyle(.vigilPrimary)
        Spacer()
        if let trailing {
          Text(trailing)
            .font(Theme.Text.detail)
            .foregroundStyle(.vigilSecondary)
        }
      }

      VStack(alignment: .leading, spacing: Theme.Metrics.tight) { content }
    }
    .padding(.horizontal, Theme.Metrics.panelPadding)
  }
}

/// A full-bleed hairline. Runs edge to edge so sections read as bands rather
/// than as floating cards.
private struct Rule: View {
  var body: some View {
    Rectangle()
      .fill(Color.vigilSeparator)
      .frame(height: 1)
      .padding(.horizontal, -Theme.Metrics.panelPadding)
      .padding(.bottom, Theme.Metrics.snug)
  }
}

private struct Notice: View {
  let title: String
  let detail: String
  let isProblem: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(Theme.Text.body)
        .foregroundStyle(isProblem ? Color.vigilAmber : .vigilPrimary)
      Text(detail)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, Theme.Metrics.panelPadding)
    .padding(.top, Theme.Metrics.loose)
  }
}

// MARK: - Controls

private struct PillButton: View {
  let title: String
  let action: () -> Void

  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilPrimary)
        .padding(.horizontal, Theme.Metrics.snug + 2)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.vigilSeparator.opacity(0.6))
        )
    }
    .buttonStyle(.plain)
  }
}

/// A full-width row that highlights on hover, the way a real menu item does.
private struct MenuRow: View {
  let title: String
  let shortcut: String
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title)
          .font(Theme.Text.body)
          .foregroundStyle(.vigilPrimary)
        Spacer()
        Text(shortcut)
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilTertiary)
      }
      .padding(.horizontal, Theme.Metrics.panelPadding)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
      .background(isHovered ? Color.vigilSeparator.opacity(0.5) : .clear)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}

// MARK: - Rows

private struct AgentRow: View {
  let name: String
  let summary: String
  let isWorking: Bool
  let isSetUp: Bool

  var body: some View {
    HStack(spacing: Theme.Metrics.snug) {
      Text(name)
        .font(Theme.Text.body)
        // Idle agents recede so a working one is the thing you see.
        .foregroundStyle(isWorking ? Color.vigilPrimary : .vigilSecondary)
        .lineLimit(1)

      Spacer(minLength: Theme.Metrics.tight)

      Text(summary)
        .font(Theme.Text.detail)
        .foregroundStyle(isWorking ? Color.vigilSecondary : .vigilTertiary)

      Circle()
        .fill(isWorking ? Color.vigilAmber : .clear)
        .frame(width: 6, height: 6)
    }
    .frame(height: 20)
    .opacity(isSetUp ? 1 : 0.55)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(name), \(summary)")
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
        .layoutPriority(1)

      if let reason = distinctReason {
        Text(reason)
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilTertiary)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      Spacer(minLength: Theme.Metrics.tight)

      Text(duration)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilTertiary)
        .monospacedDigit()
        .layoutPriority(1)
    }
    .frame(height: 18)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibleDescription)
  }

  /// Drop the reason when it only restates the process name. "caffeinate,
  /// caffeinate command-line tool" spends a row saying nothing, then truncates
  /// the part that might have said something.
  private var distinctReason: String? {
    let reason = assertion.reason
    guard !reason.localizedCaseInsensitiveContains(assertion.processName) else { return nil }
    return reason
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
    var parts = ["\(assertion.processName): \(assertion.reason)"]
    if !duration.isEmpty { parts.append("held \(duration)") }
    parts.append(assertion.expiresOnItsOwn ? "expires on its own" : "no time limit")
    return parts.joined(separator: ", ")
  }
}

// MARK: - Battery

/// A level bar that stays monochrome until the charge is actually a problem.
///
/// Hold My Lid paints its bar green; colour here means one thing — that
/// something is holding the Mac awake or stopping it from being held — so the
/// bar only takes amber when the floor has cut in.
private struct BatteryBar: View {
  let percent: Int
  let floor: Int
  let isBelowFloor: Bool

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.vigilSeparator)

        Capsule()
          .fill(isBelowFloor ? Color.vigilAmber : .vigilSecondary)
          .frame(width: max(2, geometry.size.width * CGFloat(percent) / 100))

        // Where the guardrail sits, so the number below has somewhere to point.
        if floor > 0, floor < 100 {
          Rectangle()
            .fill(Color.vigilPrimary.opacity(0.35))
            .frame(width: 1)
            .offset(x: geometry.size.width * CGFloat(floor) / 100)
        }
      }
    }
    .frame(height: 6)
    .accessibilityHidden(true)
  }
}
