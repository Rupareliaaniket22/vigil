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
        Toggle("Keep working with the lid closed", isOn: $model.settings.allowClamshell)
          .disabled(!model.clamshellSupported)

        if model.clamshellSupported {
          Text("Your Mac will keep running with the lid shut while an agent is working.")
            .font(Theme.Text.footnote)
            .foregroundStyle(.vigilSecondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          // Say what to do, not that it is unavailable. Keeping a Mac awake
          // with the lid shut is a privileged change, so it cannot be a switch
          // — but the user can still make it work in one command.
          VStack(alignment: .leading, spacing: 4) {
            Text("Closing the lid still sleeps your Mac. Enabling this needs one command:")
              .font(Theme.Text.footnote)
              .foregroundStyle(.vigilSecondary)
              .fixedSize(horizontal: false, vertical: true)

            Text("sudo ./Scripts/install-clamshell.sh")
              .font(.system(size: 10, design: .monospaced))
              .textSelection(.enabled)
              .foregroundStyle(.vigilPrimary)

            Text(
              "It lets one specific program change the lid-close setting as root. "
                + "Read SECURITY.md before you run it."
            )
            .font(Theme.Text.footnote)
            .foregroundStyle(.vigilTertiary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      Section("Agents") {
        ForEach(model.availableIntegrations) { integration in
          HStack {
            Text(integration.displayName)
              .font(Theme.Text.body)
            Spacer()
            if model.isInstalled(integration) {
              Text("Reporting")
                .font(Theme.Text.detail)
                .foregroundStyle(.vigilSecondary)
              Button("Remove") { model.uninstallHooks(for: integration) }
            } else {
              Button("Set up") { model.installHooks(for: integration) }
            }
          }
        }

        if model.availableIntegrations.isEmpty {
          Text("Vigil works with Claude Code, Codex, Gemini CLI and Cursor. None is installed.")
            .fixedSize(horizontal: false, vertical: true)
            .font(Theme.Text.detail)
            .foregroundStyle(.vigilSecondary)
        }
        if let error = model.setupError {
          Text(error)
            .font(Theme.Text.footnote)
            .foregroundStyle(.vigilAmber)
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
