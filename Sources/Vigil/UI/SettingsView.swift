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
          Text("Stop below")
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
        Text("Vigil releases the wake lock below this charge, whatever agents are doing.")
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

        Text(
          model.clamshellSupported
            ? "Your Mac will keep running with the lid shut while an agent is working."
            : "Needs a one-time setup step that isn't available in this build. "
              + "Without it, closing the lid still sleeps your Mac."
        )
        .font(Theme.Text.footnote)
        .foregroundStyle(.vigilSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Section("Agents") {
        HStack {
          Text(model.hooksInstalled ? "Claude Code is reporting to Vigil." : "Not set up yet.")
            .font(Theme.Text.body)
          Spacer()
          if model.hooksInstalled {
            Button("Remove") { model.uninstallHooks() }
          } else {
            Button("Set up") { model.installHooks() }
          }
        }
        if let error = model.setupError {
          Text(error)
            .font(Theme.Text.footnote)
            .foregroundStyle(.vigilAmber)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Section("General") {
        Toggle("Open Vigil at login", isOn: $model.launchAtLogin)
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
  }
}
