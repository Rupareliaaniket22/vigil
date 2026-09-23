import SwiftUI
import VigilCore

/// Settings, in the order they are opened for rather than the order they group
/// into.
///
/// **Agents** first, because it is the only section containing a *task* — the
/// reason anyone opens this window the first time is to wire an agent up, and
/// it used to be third. Power, lid and startup follow: things you set once and
/// then come back to only when something surprised you.
///
/// No `Form`, no `Section`, no `GroupBox`. `Form(.grouped)` sizes itself: it
/// inherited an inset per section, a background per section and a row metric
/// nobody chose, and the four groups it drew came to 813pt — a window that on a
/// 13" MacBook very nearly touches the top and bottom of the screen. Rows and
/// whitespace come to 580, say the same things, and are a size somebody
/// decided on.
struct SettingsView: View {
  @Bindable var model: AppModel

  /// Measured rather than drawn.
  ///
  /// A fixed height is only a design decision for as long as the content still
  /// fits inside it; the moment it does not, it is a window with its last row
  /// cut off and nothing saying so. The layout check builds one of these to ask
  /// how tall the sections actually want to be, which turns "520 × 580" into
  /// something that fails at build time rather than on someone's Mac.
  var fitsToContent = false

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Metrics.loose) {
      agents
      power
      lidClosed
      startingUp
    }
    .padding(.horizontal, Theme.Metrics.settingsInset)
    // The traffic lights are drawn over the content on a window with no visible
    // title bar, so the content starts below them or the first section header
    // sits under the close button.
    .padding(.top, Theme.Metrics.titleBarZone)
    .padding(.bottom, Theme.Metrics.settingsInset)
    // Top-aligned, so the sections stay packed against the title bar instead of
    // drifting down the window as the content changes underneath them.
    .frame(
      width: Theme.Metrics.settingsWidth,
      height: fitsToContent ? nil : Theme.Metrics.settingsHeight,
      alignment: .topLeading
    )
  }

  // MARK: - Agents

  private var agents: some View {
    SettingsSection("Agents") {
      if model.availableIntegrations.isEmpty {
        Note(
          "Vigil works with Claude Code, Codex, Gemini CLI and Cursor. "
            + "Install one and it will appear here."
        )
      }

      ForEach(model.availableIntegrations) { integration in
        AgentRow(
          integration: integration,
          state: model.setupState(for: integration),
          setUp: { model.installHooks(for: integration) },
          remove: { model.uninstallHooks(for: integration) }
        )
      }

      if let error = model.setupError {
        // Not amber. Amber means one thing in this app — that something is
        // holding the Mac awake — and spending it on an error message is
        // exactly the second meaning DESIGN.md rules out.
        Text(error)
          .font(Theme.Text.footnote)
          .foregroundStyle(.vigilPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, Theme.Metrics.tight)
      }
    }
  }

  // MARK: - Power

  private var power: some View {
    SettingsSection("Power") {
      SettingsSwitch("Only keep your Mac awake on mains power") {
        $model.settings.onlyWhenPluggedIn
      }

      // A `Stepper` over 0–90 in fives is up to eighteen clicks to cross the
      // range, and it never shows you where the range ends. Five values is the
      // whole of what anyone sets this to — and "Never" says what 0% means,
      // which a stepper reading "0%" leaves you to work out.
      SettingsMenu(
        VigilValueMenu(
          "Let your Mac sleep below",
          options: batteryFloorOptions,
          selection: $model.settings.batteryFloorPercent
        )
        // Nothing to choose when the Mac is not allowed to hold on battery in
        // the first place.
        .disabled(model.settings.onlyWhenPluggedIn)
      )

      SettingsSwitch("Respect Low Power Mode") { $model.settings.respectLowPowerMode }

      SettingsMenu(
        VigilValueMenu(
          "Stop when your Mac gets",
          options: [
            .init(ThermalState.fair, "Warm"),
            .init(ThermalState.serious, "Hot"),
            .init(ThermalState.critical, "Very hot"),
          ],
          selection: $model.settings.thermalCeiling
        )
      )

      // Kept, where the battery note was deleted: that one restated the control
      // it sat under. This one says something the control cannot — that heat
      // outranks even a hold you set yourself.
      Note(
        "Heat overrides everything, including a hold you set yourself. "
          + "A Mac kept awake in a closed bag has nowhere to put the heat."
      )
    }
  }

  /// The five values anyone actually sets this to — plus whatever is already
  /// stored, when that is not one of them.
  ///
  /// The control this replaces was a 0–90 stepper in fives, so a Mac upgrading
  /// into this build can perfectly well be sitting on 45%. Offering only the
  /// five would leave the menu with nothing to show for the current value and
  /// the trigger would read blank; snapping it to the nearest offered value
  /// would move a guardrail behind the user's back, which is the one setting in
  /// this window where that is not a trade we get to make. So the old value
  /// keeps its place in the list until they choose another.
  private var batteryFloorOptions: [VigilValueMenu<Int>.Option] {
    let offered = [0, 10, 15, 20, 30]
    let current = model.settings.batteryFloorPercent
    let values = offered.contains(current) ? offered : (offered + [current]).sorted()
    // "Never" rather than "0%": zero is the absence of a floor, and a row of
    // digits is a poor way to say that nothing happens.
    return values.map { .init($0, $0 == 0 ? "Never" : "\($0)%") }
  }

  // MARK: - Lid closed

  private var lidClosed: some View {
    SettingsSection("Lid closed") {
      SettingsSwitch("Keep working with the lid closed") {
        Binding(
          get: { model.settings.allowClamshell },
          set: { model.setLidClosed($0) }
        )
      }

      // Only when it has not been set up. Once it has, the note would say what
      // the switch beside it already says.
      if !model.clamshellSupported {
        Note(
          "Turning this on asks for your password once, so Vigil can install a small "
            + "root-owned helper that changes this one setting and nothing else."
        )
      }
    }
  }

  // MARK: - Starting up

  private var startingUp: some View {
    // "Starting up", not "Startup". Every other label in this window is
    // something the Mac or you does; a bare noun is the odd one out.
    SettingsSection("Starting up") {
      SettingsSwitch("Open Vigil at login") { $model.launchAtLogin }

      Note(
        model.shortcutUnavailable
          ? "Another app already uses ⌥⌘L, so Vigil's shortcut is inactive."
          : "Press ⌥⌘L anywhere to keep your Mac awake."
      )
    }
  }
}

// MARK: - Structure

/// A heading and the rows under it. Nothing is drawn around them.
///
/// DESIGN.md rules out cards, and a `GroupBox` per group is a card per group —
/// the default that makes a utility look generated. Whitespace separates the
/// groups and the heading names them, which is all a group was ever for.
private struct SettingsSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(Theme.Text.section)
        .foregroundStyle(.vigilPrimary)
        .padding(.bottom, Theme.Metrics.tight)
      content
    }
  }
}

/// One setting: what it is on the left, the control on the right.
///
/// The label takes all the space going and yields it first; the control takes
/// what it needs and never gives any back. That one asymmetry is what puts
/// every control's trailing edge on the same rail down the window, however long
/// the sentence beside it — and a long label truncates rather than squeezing
/// the thing it describes into unusability.
///
/// A `.vigil` switch and a `VigilValueMenu` are already this shape: both lay
/// out as label, spacer, control. `SettingsSwitch` and `SettingsMenu` below are
/// that shape held to this row's height, so the three cannot drift apart.
private struct SettingsRow<Control: View>: View {
  let label: String
  @ViewBuilder let control: Control

  init(_ label: String, @ViewBuilder control: () -> Control) {
    self.label = label
    self.control = control()
  }

  var body: some View {
    HStack(spacing: Theme.Metrics.loose) {
      Text(label)
        .font(Theme.Text.body)
        .foregroundStyle(.vigilPrimary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(0)

      control
        .layoutPriority(1)
    }
    .frame(height: Theme.Metrics.settingsRowHeight)
  }
}

/// A switch row. The label belongs to the `Toggle` rather than sitting beside
/// it, so accessibility hears one switch with a name instead of a nameless
/// switch next to some text.
private struct SettingsSwitch: View {
  let label: String
  let binding: () -> Binding<Bool>

  init(_ label: String, binding: @escaping () -> Binding<Bool>) {
    self.label = label
    self.binding = binding
  }

  var body: some View {
    Toggle(isOn: binding()) {
      Text(label)
        .font(Theme.Text.body)
        .foregroundStyle(.vigilPrimary)
        .lineLimit(1)
    }
    .toggleStyle(.vigil)
    .controlSize(.small)
    .frame(height: Theme.Metrics.settingsRowHeight)
  }
}

/// A value-menu row, held to the same height as every other row.
private struct SettingsMenu<Content: View>: View {
  let menu: Content

  init(_ menu: Content) {
    self.menu = menu
  }

  var body: some View {
    menu.frame(height: Theme.Metrics.settingsRowHeight)
  }
}

/// A line of explanation under a control.
///
/// Only where it says something the control cannot. A note that restates its
/// own control — "Below this charge, Vigil lets your Mac sleep" under a row
/// reading "Let your Mac sleep below" — is a line of text asking to be read
/// twice and worth reading none.
private struct Note: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(Theme.Text.footnote)
      .foregroundStyle(.vigilSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, Theme.Metrics.tight)
  }
}

/// One agent, and the one thing to do about it.
///
/// Three states, not two: an agent can be reporting through hooks from an older
/// version of Vigil, which reads as working while quietly sending less than we
/// now listen for. "Set up" would be wrong for it and "Reporting" would be a
/// lie, so it gets its own wording and its own action.
private struct AgentRow: View {
  let integration: AgentIntegration
  let state: HookSetupState
  let setUp: () -> Void
  let remove: () -> Void

  var body: some View {
    SettingsRow(integration.displayName) {
      HStack(spacing: Theme.Metrics.snug) {
        if let status {
          Text(status)
            .font(Theme.Text.detail)
            .foregroundStyle(.vigilSecondary)
            .lineLimit(1)
        }
        switch state {
        case .ready: Button("Remove", action: remove)
        case .outOfDate: Button("Update", action: setUp)
        case .notSetUp: Button("Set up", action: setUp)
        }
      }
      .buttonStyle(.vigil)
      .fixedSize()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(integration.displayName), \(spoken)")
  }

  /// Nothing beside the "Set up" button: the button already says the state, and
  /// "Not set up · Set up" is the same words twice.
  private var status: String? {
    switch state {
    case .ready: "Reporting"
    case .outOfDate: "Out of date"
    case .notSetUp: nil
    }
  }

  private var spoken: String {
    switch state {
    case .ready: "reporting"
    case .outOfDate: "set up by an older version of Vigil"
    case .notSetUp: "not set up"
    }
  }
}
