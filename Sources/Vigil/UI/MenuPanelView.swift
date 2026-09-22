import SwiftUI
import VigilCore

/// The dropdown. One status line, the sessions, the ledger, the controls.
struct MenuPanelView: View {
  @Bindable var model: AppModel
  var onQuit: () -> Void
  var onSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Metrics.loose) {
      header
      setup
      sessions
      ledger
      controls
    }
    .padding(Theme.Metrics.panelPadding)
    .frame(width: Theme.Metrics.panelWidth)
    .animation(Theme.Motion.contentChange, value: model.sessions)
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.snug) {
      Text(model.statusLine)
        .font(Theme.Text.status)
        // Amber appears here only when the Mac is actually being held awake.
        .foregroundStyle(model.decision.holdIdleAssertion ? Color.vigilAmber : .vigilPrimary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: Theme.Metrics.snug)

      BatteryMeter(percent: model.power.batteryPercent, isPluggedIn: model.power.isPluggedIn)
    }
  }

  // MARK: - Setup

  /// Shown until Claude Code is reporting to us. The panel is the onboarding —
  /// there is no separate wizard, and this disappears once it is done.
  @ViewBuilder
  private var setup: some View {
    if !model.hooksInstalled {
      VStack(alignment: .leading, spacing: Theme.Metrics.snug) {
        Text("No agents are reporting to Vigil yet.")
          .font(Theme.Text.body)
          .foregroundStyle(.vigilPrimary)
          .fixedSize(horizontal: false, vertical: true)

        Text(
          "Vigil will add a hook to \(setupTargets), keeping a backup of each file."
        )
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilSecondary)
        .fixedSize(horizontal: false, vertical: true)

        Button("Set up") { model.installAllAvailableHooks() }
          .controlSize(.small)
      }
    }

    if let error = model.setupError {
      Text(error)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilAmber)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Name the agents we found rather than saying "your agents" — people should
  /// know exactly which files are about to be edited.
  private var setupTargets: String {
    let names = model.availableIntegrations.map(\.displayName)
    switch names.count {
    case 0: return "your agent settings"
    case 1: return names[0]
    case 2: return "\(names[0]) and \(names[1])"
    default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }
  }

  // MARK: - Sessions

  @ViewBuilder
  private var sessions: some View {
    if model.sessions.isEmpty {
      // Never a blank panel: say what is true and leave an action in reach.
      if model.hooksInstalled {
        Text("Nothing is running. Vigil is out of the way.")
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilSecondary)
      }
    } else {
      VStack(alignment: .leading, spacing: Theme.Metrics.snug) {
        Text("Sessions")
          .font(Theme.Text.section)
          .foregroundStyle(.vigilPrimary)

        VStack(alignment: .leading, spacing: Theme.Metrics.tight) {
          ForEach(model.sessions) { session in
            SessionRow(session: session, now: model.now)
          }
        }
      }
    }
  }

  // MARK: - Ledger

  @ViewBuilder
  private var ledger: some View {
    if !model.otherAssertions.isEmpty {
      VStack(alignment: .leading, spacing: Theme.Metrics.snug) {
        Divider().overlay(Color.vigilSeparator)

        Text("Also holding your Mac awake")
          .font(Theme.Text.section)
          .foregroundStyle(.vigilPrimary)

        VStack(alignment: .leading, spacing: Theme.Metrics.tight) {
          ForEach(collapsedAssertions) { assertion in
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.snug) {
              Text(assertion.processName)
                .font(Theme.Text.detail)
                .foregroundStyle(.vigilSecondary)
              Text(assertion.reason)
                .font(Theme.Text.detail)
                .foregroundStyle(.vigilTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(assertion.processName): \(assertion.reason)")
          }
        }
      }
    }
  }

  /// One row per process. A process holding several assertions is still one
  /// answer to "what is keeping my Mac awake", and listing it repeatedly would
  /// make a short list look alarming.
  private var collapsedAssertions: [SystemAssertion] {
    var seen = Set<String>()
    return model.otherAssertions.filter { seen.insert($0.processName).inserted }
  }

  // MARK: - Controls

  private var controls: some View {
    VStack(alignment: .leading, spacing: Theme.Metrics.snug) {
      Divider().overlay(Color.vigilSeparator)

      Toggle("Keep awake", isOn: $model.manualOverride)
        .font(Theme.Text.body)
        .toggleStyle(.switch)
        .controlSize(.small)

      HStack {
        if model.isPaused {
          Button("Resume") { model.resume() }
        } else {
          Menu("Pause for…") {
            Button("30 minutes") { model.pause(for: 30 * 60) }
            Button("1 hour") { model.pause(for: 60 * 60) }
            Button("Until tomorrow") { model.pause(for: 12 * 60 * 60) }
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
        }

        Spacer()

        Button("Settings…", action: onSettings)
        Button("Quit", action: onQuit)
      }
      .font(Theme.Text.detail)
      .buttonStyle(.link)
    }
  }
}

// MARK: - Row

private struct SessionRow: View {
  let session: AgentSession
  let now: Date

  var body: some View {
    HStack(spacing: Theme.Metrics.snug) {
      // Filled vs hollow carries the state; amber only ever means "working".
      Circle()
        .fill(session.state == .working ? Color.vigilAmber : .vigilTertiary)
        .frame(width: 6, height: 6)

      Text(session.agent.rawValue)
        .font(Theme.Text.body)
        .foregroundStyle(.vigilPrimary)

      if let cwd = session.cwd {
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
    }
    .frame(height: Theme.Metrics.rowHeight - Theme.Metrics.snug)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(session.agent.rawValue), \(session.state.rawValue), \(elapsed)")
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

// MARK: - Battery

private struct BatteryMeter: View {
  let percent: Int
  let isPluggedIn: Bool

  var body: some View {
    HStack(spacing: Theme.Metrics.tight) {
      if isPluggedIn {
        Image(systemName: "powerplug.fill")
          .font(.system(size: 9))
          .foregroundStyle(.vigilSecondary)
      }
      Text("\(percent)%")
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilSecondary)
        .monospacedDigit()
    }
    .accessibilityLabel(
      "Battery \(percent) percent\(isPluggedIn ? ", plugged in" : ", on battery")")
  }
}
