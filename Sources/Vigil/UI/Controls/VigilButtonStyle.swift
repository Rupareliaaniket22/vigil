import SwiftUI

/// Vigil's button: a capsule that fills under the pointer, tones down when
/// pressed, and draws its own focus ring.
///
/// Apply with `.buttonStyle(.vigil)` or `.buttonStyle(.vigilFilled)`.
struct VigilButtonStyle: ButtonStyle {
  /// `plain` is the resting weight — a button that only announces itself when
  /// you reach for it, which is what the panel's rows want. `filled` is for the
  /// single action that resolves a notice. There should never be two of them in
  /// view at once; a panel with two loud buttons has no loud button.
  enum Emphasis {
    case plain
    case filled
  }

  var emphasis: Emphasis = .plain

  func makeBody(configuration: Configuration) -> some View {
    ButtonBody(configuration: configuration, emphasis: emphasis)
  }
}

extension ButtonStyle where Self == VigilButtonStyle {
  static var vigil: VigilButtonStyle { VigilButtonStyle() }
  static var vigilFilled: VigilButtonStyle { VigilButtonStyle(emphasis: .filled) }
}

/// The same reason `SwitchBody` exists: a `ButtonStyle` is not a `View`, so an
/// `@Environment` property on the style is read once and never invalidated.
private struct ButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let emphasis: VigilButtonStyle.Emphasis

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false
  @FocusState private var isFocused: Bool

  /// A capsule, not a rounded rectangle. The panel's rounded rectangles are
  /// containers — the panel itself, a menu row's highlight — and keeping one
  /// shape for "this is a region" and another for "this is a control" means
  /// neither has to be labelled.
  private var shape: Capsule { Capsule(style: .continuous) }

  var body: some View {
    configuration.label
      .font(Theme.Text.detail)
      .foregroundStyle(foreground)
      // Named rather than added up here, because a row that shares its trailing
      // rail with non-button content cancels exactly this much again — see
      // `Theme.Metrics.buttonHPadding`.
      .padding(.horizontal, Theme.Metrics.buttonHPadding)
      .padding(.vertical, Theme.Metrics.tight)
      .background { shape.fill(background) }
      .overlay { if configuration.isPressed { shape.fill(Color.vigilPressOverlay) } }
      .vigilDimmed(isEnabled)
      .contentShape([.focusEffect, .interaction], shape)
      // Without this the button is absent from the keyboard loop unless Full
      // Keyboard Access is on. Activation stays with `Button` itself — a
      // `ButtonStyle` cannot fire its own action before macOS 15, when
      // `ButtonStyleConfiguration.trigger()` arrived, and the deployment
      // target here is 14.
      .focusable(isEnabled)
      .focused($isFocused)
      .focusEffectDisabled()
      .vigilFocusRing(isFocused, in: shape)
      // Hover is pointer-only feedback, so it is never the sole carrier of
      // anything; disabled buttons simply do not light up, and one that is
      // disabled while lit goes dark — see `vigilHover`.
      .vigilHover($isHovered)
      // The same rule `VigilMenuRow` states: hover snaps. These buttons sit
      // inside the panel's own `.animation(_:value:)` on the session list, and
      // a row's button is rebuilt whenever that list changes — so a hover that
      // lands in the same pass would otherwise fade in on the panel's timing
      // and read as the app lagging behind the pointer.
      .animation(nil, value: isHovered)
  }

  private var foreground: Color {
    switch emphasis {
    case .plain: .vigilPrimary
    // Not `labelColor`: the fill is the user's accent, which can be any hue
    // they chose. `alternateSelectedControlTextColor` is the colour Apple
    // guarantees against an accent-filled surface.
    case .filled: .vigilSelectedText
    }
  }

  private var background: Color {
    switch emphasis {
    // Nothing at rest, so a row of these reads as text until you go near one.
    case .plain: isHovered ? .vigilControlFill : .clear
    // A filled button already has a fill; brightening it on hover would be a
    // second, weaker version of the same signal, and the press tone still
    // answers "did that click land".
    case .filled: .vigilTrackOn
    }
  }
}

// MARK: - Gallery

/// Stands in for `#Preview` — see ControlSupport.swift for why it has to.
struct VigilButtonStyleGallery: View {
  @State private var count = 0

  var body: some View {
    GalleryFrame(title: "VigilButtonStyle") {
      GallerySpecimen(caption: "plain · hover fills, press tones, tab draws the ring") {
        HStack(spacing: Theme.Metrics.snug) {
          Button("Set up") { count += 1 }
          Button("Update") { count += 1 }
          Button("Remove") { count += 1 }
        }
        .buttonStyle(.vigil)
      }

      GallerySpecimen(caption: "filled · the one action that resolves a notice") {
        Button("Update all") { count += 1 }
          .buttonStyle(.vigilFilled)
      }

      GallerySpecimen(caption: "disabled · both emphases, dimmed explicitly") {
        HStack(spacing: Theme.Metrics.snug) {
          Button("Set up") { count += 1 }
            .buttonStyle(.vigil)
          Button("Update all") { count += 1 }
            .buttonStyle(.vigilFilled)
        }
        .disabled(true)
      }

      Text("activations: \(count)")
        .font(Theme.Text.footnote)
        .foregroundStyle(.vigilTertiary)
        .monospacedDigit()
    }
  }
}
