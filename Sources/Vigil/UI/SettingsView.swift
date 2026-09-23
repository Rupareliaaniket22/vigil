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
/// whitespace say the same things inside `Theme.Metrics.settingsHeight`, which
/// is a size somebody decided on and `make smoke` checks. What the sections
/// actually measure is printed by that check on every build; the numbers are
/// not repeated here, because a number in a comment is a number that drifts.
struct SettingsView: View {
  @Bindable var model: AppModel

  /// Measured rather than drawn.
  ///
  /// A fixed height is only a design decision for as long as the content still
  /// fits inside it; the moment it does not, it is a window with its last row
  /// cut off and nothing saying so. The layout check builds one of these to ask
  /// how tall the sections actually want to be, which turns the fixed size into
  /// something that fails at build time rather than on someone's Mac. It builds
  /// this machine as it is, and then the worst shape the window can honestly be
  /// in — every agent offered, an untrusted host, an installer error long
  /// enough to reach its cap, and each of the two things the lid section can
  /// say — none of which the developer's own Mac is likely to be showing.
  var fitsToContent = false

  /// Bound straight to the one `UserDefaults` key `Notifier` reads, rather
  /// than through the model: the sound is not an input to the wake decision,
  /// so it is not part of `model.settings`, and going through `@AppStorage`
  /// leaves no second copy of it to keep in step. `SoundSettings` names the
  /// key and the default; this states neither.
  @AppStorage(SoundSettings.completionSoundKey)
  var playsCompletionSound = SoundSettings.playsCompletionSoundByDefault

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
          remove: { model.uninstallHooks(for: integration) },
          trust: { model.reviewTrust(for: integration) }
        )
      }

      // Under Agents rather than in a section of its own, and the reason is
      // measured rather than felt: a fifth section costs a 16pt gap, a 20pt
      // header and the row itself, in a window whose height is fixed and whose
      // spare points are already spoken for by the notices below. It is not
      // homeless here: what it announces is these agents finishing, and every
      // row in the section already shares one trailing rail with it.
      //
      // Above the notices, with the rows, rather than below them where it
      // landed when it arrived. Every other section in this window reads
      // controls first and explanation last, and a switch underneath a wrapped
      // installer error is a control that moves down the window by two lines
      // the first time something goes wrong.
      SettingsSwitch("Play a sound when your agents finish") { $playsCompletionSound }

      // Below the rows rather than inside one: each sentence names its own
      // host, and the thing it asks for happens in that host's window, not in
      // this one. A row can only say that something is wrong; this says what to
      // go and do about it.
      ForEach(model.availableIntegrations) { integration in
        if let notice = model.trustNotice(for: integration) {
          Text(notice)
            .font(Theme.Text.footnote)
            .foregroundStyle(.vigilSecondary)
            // Two, which is what it wraps to. Codex is the only host that
            // gates hooks, so this is one of two fixed sentences with one
            // fixed name in it and the cap is never reached — which is the
            // point: the number the layout check measures is the number this
            // can cost, rather than a cap with unmeasured room above it.
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.Metrics.tight)
            .help(notice)
        }
      }

      if let error = model.setupError {
        // Not amber. Amber means one thing in this app — that something is
        // holding the Mac awake — and spending it on an error message is
        // exactly the second meaning DESIGN.md rules out.
        Text(error)
          .font(Theme.Text.footnote)
          .foregroundStyle(.vigilPrimary)
          // The one string in this window that is not ours. `ClamshellInstaller
          // .failed` passes an installer script's own output straight through,
          // so there is no length this can be trusted to stay under — and this
          // window is a fixed size with no scroll view and no resize handle,
          // where overflow is clipped by the window edge with nothing saying
          // so. What gets cut is the bottom: the "Open Vigil at login" switch
          // and the ⌥⌘L note, controls still notionally on screen and out of
          // reach. Three lines is the most it can cost, and the whole of it is
          // one hover away — the same rule `MenuPanelView.RowNote` holds the
          // panel's copy of this string to, one line looser because this is the
          // window the panel sends people to in order to read it.
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, Theme.Metrics.tight)
          .help(error)
      }
    }
    // The consent gate, and the reason the button in the row reads "Trust…"
    // rather than "Trust". The press opens what would be written — the command,
    // the events it runs on, and the file the approval lands in — and writes
    // none of it until a second, separate decision. A button that recorded the
    // approval on the first press is the silent self-approval this whole
    // feature exists to refuse, with a label stuck on it.
    //
    // A system alert rather than something drawn here, and the one place in
    // Vigil where that is the right answer: this is macOS asking whether a
    // program may run a command, and it should look like every other time the
    // user has been asked that — not like a panel Vigil designed for itself.
    .confirmationDialog(
      model.pendingTrustApproval?.title ?? "",
      isPresented: confirmingTrust,
      titleVisibility: .visible,
      presenting: model.pendingTrustApproval
    ) { approval in
      Button("Approve") { model.trustHooks(for: approval) }
      Button("Cancel", role: .cancel) { model.cancelTrustReview() }
    } message: { approval in
      Text(approval.message)
    }
  }

  /// Open for as long as there is something to approve.
  ///
  /// Every way out of the dialog other than Approve — Cancel, Escape, the
  /// window closing — comes back through here as a decline, which is the only
  /// safe default for a control whose other outcome edits somebody's file.
  private var confirmingTrust: Binding<Bool> {
    Binding(
      get: { model.pendingTrustApproval != nil },
      set: { if !$0 { model.cancelTrustReview() } }
    )
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
      } else if let notice = model.helperNotice {
        // Drift in the installed helper, which until now was computed on every
        // tick and rendered by nothing — a root-owned file that no longer
        // matches the one this build drives, and the user was never told.
        //
        // `else`, not a second `if`: the two are only ever both true when the
        // helper is installed and the sudoers rule that makes it usable is
        // not, and in that state turning the switch on runs the installer,
        // which replaces the drifted helper anyway. Saying both would be
        // warning about a file the note above it is already about to fix.
        HelperRow(notice: notice, reinstall: model.reinstallClamshellHelper)
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

/// The privileged helper, when it is not the one this build ships.
///
/// A row rather than a paragraph, and for the same reason the trust notices in
/// Agents *are* paragraphs. Those name something to go and do in another
/// program, so a row cannot carry them — "a row can only say that something is
/// wrong; this says what to go and do about it". This one is resolved by a
/// button in Vigil, so it is the three parts every agent row in this window
/// already has: what it is, what state it is in, and the one press that fixes
/// it. "Out of date" and "Reinstall" rather than a third pair of words for the
/// state `AgentRow` already calls out of date.
///
/// `HelperIntegrity`'s own sentence is what the row is *about* rather than what
/// it says. It names root, which is the whole reason a cosmetic difference in a
/// shell script is worth any interface at all — so it goes on the hover and to
/// VoiceOver, the way the panel puts its longer text one hover away rather than
/// spending a fixed-height window's remaining points on three wrapped lines.
private struct HelperRow: View {
  let notice: String
  let reinstall: () -> Void

  var body: some View {
    SettingsRow("Lid-closed helper") {
      HStack(spacing: Theme.Metrics.snug) {
        Text("Out of date")
          .font(Theme.Text.detail)
          .foregroundStyle(.vigilSecondary)
          .lineLimit(1)
        Button("Reinstall", action: reinstall)
      }
      .buttonStyle(.vigil)
      .fixedSize()
      .vigilOnRail()
    }
    .help(notice)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Lid-closed helper, out of date")
    .accessibilityHint(notice)
  }
}

/// One agent, and the one thing to do about it.
///
/// Four states, not two. An agent can be reporting through hooks from an older
/// version of Vigil, which reads as working while quietly sending less than we
/// now listen for; and it can be wired up perfectly while the host refuses to
/// run any of it. "Set up" would be wrong for the first and "Reporting" a lie,
/// and the second is fixed by the opposite action to either — so each gets its
/// own wording and its own button.
private struct AgentRow: View {
  let integration: AgentIntegration
  let state: HookSetupState
  let setUp: () -> Void
  let remove: () -> Void
  let trust: () -> Void

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
        // Not "Update": the hooks are installed and correct, and re-running
        // the install is exactly what does not help. What is missing is the
        // host's approval of the command, which is the user's to give and
        // nobody else's — so the button opens it to be read, and the press
        // that writes it is the one in the dialog.
        case .untrusted: Button("Trust…", action: trust)
        }
      }
      .buttonStyle(.vigil)
      .fixedSize()
      // The same rail the switch tracks down this window already sit on. A
      // `.vigil` plain button draws no background at rest, so without this the
      // button's invisible capsule takes the rail and the right-hand column
      // alternates between the switches' edge and 12pt short of it, on exactly
      // the rows that are asking to be clicked.
      .vigilOnRail()
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
    case .untrusted: "Not trusted"
    }
  }

  private var spoken: String {
    switch state {
    case .ready: "reporting"
    case .outOfDate: "set up by an older version of Vigil"
    case .notSetUp: "not set up"
    case .untrusted: "installed, but \(integration.displayName) is not running it"
    }
  }
}
