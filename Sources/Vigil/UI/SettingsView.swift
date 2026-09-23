import SwiftUI
import VigilCore

/// Settings, in four groups matching the questions people actually ask:
/// when should it engage, when should it stand down, how do agents reach it.
struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section("Power") {
        Toggle("Only keep awake on mains power", isOn: $model.settings.onlyWhenPluggedIn)

        HStack {
          Text("Let the Mac sleep below")
          Stepper(
            value: $model.settings.batteryFloorPercent,
            in: 0...90,
            step: 5
          ) {
            Text("\(model.settings.batteryFloorPercent)%")
              .monospacedDigit()
          }
          .disabled(model.settings.onlyWhenPluggedIn)
        }
        Text("Below this charge, Vigil lets your Mac sleep even while agents are working.")
          .font(Theme.Text.footnote)
          .foregroundStyle(.vigilSecondary)

        Toggle("Respect Low Power Mode", isOn: $model.settings.respectLowPowerMode)

        Picker("Stop when the Mac gets", selection: $model.settings.thermalCeiling) {
          Text("Warm").tag(ThermalState.fair)
          Text("Hot").tag(ThermalState.serious)
          Text("Very hot").tag(ThermalState.critical)
        }
        Text(
          "Heat overrides everything, including a manual hold. A Mac held awake "
            + "inside a closed bag has nowhere to put the heat."
        )
        .font(Theme.Text.footnote)
        .foregroundStyle(.vigilSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Section("Lid closed") {
        Toggle(
          "Keep working with the lid closed",
          isOn: Binding(
            get: { model.settings.allowClamshell },
            set: { model.setLidClosed($0) }
          )
        )

        if model.clamshellSupported {
          Text("Your Mac will keep running with the lid shut while an agent is working.")
            .font(Theme.Text.footnote)
            .foregroundStyle(.vigilSecondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          // Say what to do, not that it is unavailable. Keeping a Mac awake
          // with the lid shut is a privileged change, so it cannot be a switch
          // — but the user can still make it work in one command.
          Text(
            "Turning this on asks for your password once. Keeping a Mac awake with "
              + "the lid shut is a privileged setting, so Vigil installs a small "
              + "root-owned helper that can change it and nothing else."
          )
          .font(Theme.Text.footnote)
          .foregroundStyle(.vigilSecondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      Section("Agents") {
        ForEach(model.availableIntegrations) { integration in
          AgentSettingsRow(
            integration: integration,
            state: model.setupState(for: integration),
            setUp: { model.installHooks(for: integration) },
            remove: { model.uninstallHooks(for: integration) }
          )
        }

        if model.availableIntegrations.isEmpty {
          Text(
            "Vigil works with Claude Code, Codex, Gemini CLI and Cursor. "
              + "None of them is installed here."
          )
          .fixedSize(horizontal: false, vertical: true)
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilSecondary)
        }
        if let error = model.setupError {
          // Not amber. Amber means one thing in this app — that something is
          // holding the Mac awake — and spending it on an error message is
          // exactly the second meaning DESIGN.md rules out.
          Text(error)
            .font(Theme.Text.footnote)
            .foregroundStyle(.vigilPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Section("Startup") {
        Toggle("Open Vigil at login", isOn: $model.launchAtLogin)

        if model.shortcutUnavailable {
          Text("Another app already uses ⌥⌘L, so Vigil's shortcut is inactive.")
            .font(Theme.Text.footnote)
            .foregroundStyle(.vigilSecondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("Press ⌥⌘L anywhere to hold your Mac awake.")
            .font(Theme.Text.footnote)
            .foregroundStyle(.vigilSecondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// One agent, and the one thing to do about it.
///
/// Three states, not two: an agent can be reporting through hooks from an older
/// version of Vigil, which reads as working while quietly sending less than we
/// now listen for. "Set up" would be wrong for it and "Reporting" would be a
/// lie, so it gets its own wording and its own action.
private struct AgentSettingsRow: View {
  let integration: AgentIntegration
  let state: HookSetupState
  let setUp: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack {
      Text(integration.displayName)
        .font(Theme.Text.body)
      Spacer()
      switch state {
      case .ready:
        Text("Reporting")
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilSecondary)
        Button("Remove", action: remove)
      case .outOfDate:
        Text("Out of date")
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilSecondary)
        Button("Update", action: setUp)
      case .notSetUp:
        Button("Set up", action: setUp)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(integration.displayName), \(description)")
  }

  private var description: String {
    switch state {
    case .ready: "reporting"
    case .outOfDate: "set up by an older version of Vigil"
    case .notSetUp: "not set up"
    }
  }
}
