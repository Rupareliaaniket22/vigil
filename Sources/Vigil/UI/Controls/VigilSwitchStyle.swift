import SwiftUI

/// The geometry of an AppKit switch, per control size.
///
/// Measured off `NSSwitch` rather than invented: `.mini` is 26×15, `.small`
/// 32×18, `.regular` 38×22. Both dimensions are stored because the aspect ratio
/// is not constant across the three — deriving a width from a height using any
/// one of them gets the other two wrong — and a switch a point and a half off
/// the system one is obvious the moment they sit in the same panel.
struct SwitchMetrics: Equatable, Sendable {
  let width: CGFloat
  let height: CGFloat

  /// The knob leaves a point of track visible all the way round.
  var inset: CGFloat { 1 }
  var knob: CGFloat { height - 2 }
  /// How far the knob slides: the track less one knob and two insets, which
  /// reduces to width − height.
  var travel: CGFloat { width - height }

  static let mini = SwitchMetrics(width: 26, height: 15)
  static let small = SwitchMetrics(width: 32, height: 18)
  static let regular = SwitchMetrics(width: 38, height: 22)

  /// `.large` and `.extraLarge` fall back to `.regular`, because `NSSwitch`
  /// does too. Inventing a bigger size would put this control out of step with
  /// every system control standing next to it.
  static func matching(_ size: ControlSize) -> SwitchMetrics {
    switch size {
    case .mini: .mini
    case .small: .small
    default: .regular
    }
  }
}

/// Vigil's switch: a track, a knob, and a press tone.
///
/// Apply with `.toggleStyle(.vigil)`, and size it with `.controlSize(.mini)`
/// the same way a system switch is sized.
struct VigilSwitchStyle: ToggleStyle {
  /// What the focus ring goes round.
  ///
  /// A switch in a row somebody else lays out — a settings row — is `inline`,
  /// and the ring hugs its label and track. A switch that *is* a row of the
  /// panel's footer is a `menuRow`: it carries the same inset and radius as
  /// the `VigilMenuRow`s under it, so the ring drawn round it lands exactly
  /// where those rows' highlight does. Before this existed the footer's first
  /// row rang at the panel's 16pt text margin and the other four at 6pt in,
  /// and the one row that did not match was the one with a control in it.
  enum Placement {
    case inline
    case menuRow
  }

  var placement: Placement = .inline

  func makeBody(configuration: Configuration) -> some View {
    SwitchBody(configuration: configuration, placement: placement)
  }
}

extension ToggleStyle where Self == VigilSwitchStyle {
  static var vigil: VigilSwitchStyle { VigilSwitchStyle() }
  static var vigilMenuRow: VigilSwitchStyle { VigilSwitchStyle(placement: .menuRow) }
}

/// Every environment read lives in here, not in `makeBody`.
///
/// A `ToggleStyle` is not a `View`. An `@Environment` property on the style
/// itself compiles, and even reads the right value the first time, but nothing
/// re-invokes `makeBody` when that value changes — so a switch built that way
/// never notices Reduce Motion being switched on, and stays bright after the
/// thing it controls is disabled. A nested `View` is tracked normally.
private struct SwitchBody: View {
  let configuration: ToggleStyleConfiguration
  let placement: VigilSwitchStyle.Placement

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isFocused: Bool
  @State private var isPressed = false

  private var metrics: SwitchMetrics { .matching(controlSize) }
  private var isMenuRow: Bool { placement == .menuRow }

  /// The whole row is the target — label included, the way a system switch
  /// behaves — so the ring goes round the row rather than round the track. One
  /// shape for the hit area, the focus effect and the drawn ring means they
  /// cannot disagree about where the control is.
  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: Theme.Metrics.menuRowRadius, style: .continuous)
  }

  var body: some View {
    HStack(spacing: Theme.Metrics.snug) {
      configuration.label
      Spacer(minLength: Theme.Metrics.tight)
      track
    }
    // The same two paddings a `VigilMenuRow` splits the text margin into: 10
    // inside the shape and 6 outside it, so the label still starts on the
    // panel's 16pt column while the ring stops 6pt short of the panel's edge,
    // concentric with its corner. Inline, the row around us owns the margin.
    .padding(.horizontal, isMenuRow ? Theme.Metrics.panelPadding - Theme.Metrics.menuRowInset : 0)
    .frame(height: isMenuRow ? Theme.Metrics.menuRowHeight : nil)
    .vigilDimmed(isEnabled)
    .contentShape([.focusEffect, .interaction], shape)
    .vigilPressAction(isPressed: $isPressed) { toggle() }
    // Without this the control is not in the keyboard loop at all: it cannot be
    // tabbed to, so none of the focus handling below would ever run.
    .focusable(isEnabled)
    .focused($isFocused)
    .focusEffectDisabled()
    .vigilFocusRing(isFocused, in: shape)
    .onKeyPress(.space) {
      toggle()
      return .handled
    }
    .padding(.horizontal, isMenuRow ? Theme.Metrics.menuRowInset : 0)
    // `.accessibilityAddTraits(.isToggle)` does nothing here — a custom toggle
    // already reports as AXToggle, and what is missing is AXSwitch. Handing
    // accessibility a real system switch is the only thing that restores it,
    // and it speaks "on"/"off" in the user's language for free. `.switch` is
    // not optional: toggle styles travel through the environment, so without it
    // the represented Toggle picks this style back up and recurses.
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
        .toggleStyle(.switch)
    }
  }

  private func toggle() {
    guard isEnabled else { return }
    configuration.isOn.toggle()
  }

  private var track: some View {
    Capsule()
      .fill(configuration.isOn ? Color.vigilTrackOn : .vigilTrackOff)
      .frame(width: metrics.width, height: metrics.height)
      .overlay(alignment: .leading) { knob }
      .overlay { if isPressed { Capsule().fill(Color.vigilPressOverlay) } }
      .animation(Theme.Motion.state(reduceMotion: reduceMotion), value: configuration.isOn)
  }

  private var knob: some View {
    Circle()
      .fill(Color.vigilKnob)
      .frame(width: metrics.knob, height: metrics.knob)
      // Black in both appearances on purpose. This is occlusion, not a
      // semantic colour — the knob sits above the track in either one.
      .shadow(color: .black.opacity(0.12), radius: 0.75, y: 0.5)
      .offset(x: metrics.inset + (configuration.isOn ? metrics.travel : 0))
  }
}

// MARK: - Gallery

/// Stands in for `#Preview` — see ControlSupport.swift for why it has to.
struct VigilSwitchStyleGallery: View {
  @State private var on = true
  @State private var off = false
  @State private var disabledOn = true

  var body: some View {
    GalleryFrame(title: "VigilSwitchStyle") {
      GallerySpecimen(caption: "mini · on, off") {
        VStack(spacing: Theme.Metrics.snug) {
          Toggle("Keep awake", isOn: $on)
          Toggle("Keep awake", isOn: $off)
        }
        .toggleStyle(.vigil)
        .controlSize(.mini)
        .font(Theme.Text.detail)
      }

      GallerySpecimen(caption: "small · regular") {
        VStack(spacing: Theme.Metrics.snug) {
          Toggle("Only on mains power", isOn: $on).controlSize(.small)
          Toggle("Respect Low Power Mode", isOn: $off).controlSize(.regular)
        }
        .toggleStyle(.vigil)
        .font(Theme.Text.body)
      }

      GallerySpecimen(caption: "disabled · dimmed explicitly, on and off") {
        VStack(spacing: Theme.Metrics.snug) {
          Toggle("Keep awake", isOn: $disabledOn)
          Toggle("Keep awake", isOn: $off)
        }
        .toggleStyle(.vigil)
        .controlSize(.mini)
        .font(Theme.Text.detail)
        .disabled(true)
      }

      GallerySpecimen(caption: "focus · tab in, space toggles; hover and press show the tone") {
        Toggle("Keep working with the lid closed", isOn: $on)
          .toggleStyle(.vigil)
          .controlSize(.small)
          .font(Theme.Text.body)
      }

      GallerySpecimen(caption: "as a footer row · tab across: the ring sits on the highlight") {
        VStack(spacing: 0) {
          Toggle("Always keep awake", isOn: $on)
            .toggleStyle(.vigilMenuRow)
            .controlSize(.mini)
            .font(Theme.Text.body)
          VigilMenuRow("Pause 30 minutes") {}
        }
        // Rows go edge to edge; the ring and the highlight inset themselves.
        .padding(.horizontal, -Theme.Metrics.panelPadding)
      }
    }
  }
}
