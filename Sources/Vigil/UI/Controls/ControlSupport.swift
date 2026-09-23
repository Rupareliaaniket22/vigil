import SwiftUI

// The plumbing every hand-drawn control in this folder needs, and none of it
// comes free. AppKit's press highlight and focus ring belong to `NSButton`; a
// `Shape` we drew ourselves is invisible to both, and to `.disabled()` as well.
//
// On previews: these controls carry `…Gallery` views rather than `#Preview`.
// The macro expands to `#externalMacro(module: "PreviewsMacros", …)`, and that
// plugin ships inside Xcode — Command Line Tools has Observation, Swift and
// Testing macros and nothing else. AGENTS.md makes building without Xcode a
// contributor guarantee, so a `#Preview` here would break `make build` for
// exactly the contributors that guarantee exists for. A plain `View` compiles
// everywhere and can still be dropped into a window to look at.

// MARK: - Disabled

extension View {
  /// The dimming `.disabled()` does not do.
  ///
  /// `.disabled()` stops hit testing and sets `isEnabled` in the environment,
  /// and system controls read that and grey themselves out. A `Capsule` we
  /// filled ourselves reads nothing and stays at full strength, so a disabled
  /// custom control looks live until you click it and nothing happens. Every
  /// control here says so explicitly.
  func vigilDimmed(_ isEnabled: Bool) -> some View {
    opacity(isEnabled ? 1 : 0.5)
  }
}

// MARK: - Press

/// Tracks the press phase and fires on release inside the control.
///
/// `.onTapGesture` cannot report the phase at all, and a bare `DragGesture`
/// never cancels — drag the pointer off a pressed control and it stays lit.
/// Measuring the bounds and testing the release point against them is what
/// gives `NSButton`'s actual behaviour: the tone follows the pointer in and out
/// of the control, and letting go outside it does nothing.
private struct PressAction: ViewModifier {
  @Binding var isPressed: Bool
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled
  @State private var size: CGSize = .zero

  func body(content: Content) -> some View {
    content
      .background {
        GeometryReader { proxy in
          Color.clear
            .onChange(of: proxy.size, initial: true) { _, new in size = new }
        }
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard isEnabled else { return }
            let inside = bounds.contains(value.location)
            if isPressed != inside { isPressed = inside }
          }
          .onEnded { value in
            isPressed = false
            guard isEnabled, bounds.contains(value.location) else { return }
            action()
          }
      )
      // A control disabled mid-press stays lit for good. `.disabled()` stops
      // hit testing, which tears the gesture down without ever calling
      // `onEnded`, so the release that would have cleared this never arrives
      // and a half-dimmed control sits there looking pressed. Nothing in the
      // panel redraws it, because nothing changed.
      //
      // Taken from MacControlCenterUI's MenuCircleToggle.swift, which clears
      // its own `isMouseDown` on this signal. Done here rather than in each
      // control so a control added later cannot forget it — which is the whole
      // reason this file exists.
      .onChange(of: isEnabled) { _, enabled in
        if !enabled { isPressed = false }
      }
  }

  /// `DragGesture` reports in the local coordinate space, so the control's own
  /// bounds start at the origin.
  private var bounds: CGRect { CGRect(origin: .zero, size: size) }
}

// MARK: - Hover

/// Pointer feedback that goes out when the control does.
///
/// `.onHover` reports *crossings*, not where the pointer is. A control that is
/// disabled while the pointer is resting on it gets no second callback, so a
/// plain `isHovered = $0` leaves the flag reading true and the fill lit on a
/// control that no longer does anything — dimmed to 50%, which makes it look
/// broken rather than off. Reading `isEnabled` at both ends is what makes the
/// flag mean "lit" instead of "was last entered".
///
/// Taken from MacControlCenterUI's HighlightingMenuItem.swift, which drops its
/// highlight on the same signal.
///
/// The converse — re-enabled while the pointer is already inside — stays unlit
/// until the pointer moves. That is `.onHover`'s own limit and an `NSButton`
/// does the same thing; it also resolves itself on the next twitch of the
/// mouse, which is not true of the stuck case above.
private struct HoverState: ViewModifier {
  @Binding var isHovered: Bool

  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    content
      .onHover { isHovered = isEnabled && $0 }
      .onChange(of: isEnabled) { _, enabled in
        if !enabled { isHovered = false }
      }
  }
}

// MARK: - Focus

/// Draws the focus ring, just outside the control's own shape.
///
/// The ring sits on `keyboardFocusIndicatorColor`, which already carries 50%
/// alpha. Nothing here multiplies it — the presence of the ring is the state,
/// so it is drawn or it is absent, never faded.
private struct FocusRing<S: Shape>: ViewModifier {
  let shape: S
  let isFocused: Bool

  /// AppKit's ring hugs the control and bleeds outward. Stroking a shape
  /// grown by half the line width puts the stroke's inner edge on the
  /// control's boundary and the rest of it outside, which is the same look.
  private let width: CGFloat = 3
  private let bleed: CGFloat = 1.5

  func body(content: Content) -> some View {
    content.overlay {
      if isFocused {
        shape
          .stroke(Color.vigilFocusRing, lineWidth: width)
          .padding(-bleed)
      }
    }
  }
}

extension View {
  /// Press-and-release handling with the phase reported back.
  func vigilPressAction(
    isPressed: Binding<Bool>,
    perform action: @escaping () -> Void
  ) -> some View {
    modifier(PressAction(isPressed: isPressed, action: action))
  }

  /// Pointer feedback that cannot outlive the control being usable.
  func vigilHover(_ isHovered: Binding<Bool>) -> some View {
    modifier(HoverState(isHovered: isHovered))
  }

  /// A drawn focus ring. Pair it with `.focusEffectDisabled()`, or the system
  /// draws a second rectangular one around the view's bounds.
  func vigilFocusRing(_ isFocused: Bool, in shape: some Shape) -> some View {
    modifier(FocusRing(shape: shape, isFocused: isFocused))
  }

  /// Put a trailing `.vigil` plain button's *text* on the rail, not its capsule.
  ///
  /// DESIGN.md's last column is a fixed rail — "rather than whatever each value
  /// happens to measure, which is what lets the eye run down the elapsed times
  /// as a column". A plain button draws nothing at rest, so its capsule padding
  /// is invisible and the column simply stops 12pt short on exactly the rows
  /// that are asking to be clicked. Cancelling the padding lets the capsule
  /// overhang the margin — it has 16pt in the panel and 24 in Settings to
  /// overhang into, against 12 of padding and 1.5 of focus ring — while the
  /// glyphs land where every text value lands.
  ///
  /// Only for `.plain`. A `.vigilFilled` button has a visible capsule, and its
  /// edge is the thing that would then hang off the margin.
  func vigilOnRail() -> some View {
    padding(.trailing, -Theme.Metrics.buttonHPadding)
  }
}

// MARK: - Gallery scaffolding

/// One labelled specimen in a control gallery.
struct GallerySpecimen<Content: View>: View {
  let caption: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Metrics.tight) {
      Text(caption)
        .font(Theme.Text.footnote)
        .foregroundStyle(.vigilTertiary)
      content
    }
  }
}

/// The frame a gallery sits in: panel width, panel padding, and nothing else,
/// so a specimen is seen at the size it will actually be used at.
struct GalleryFrame<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Metrics.loose) {
      Text(title)
        .font(Theme.Text.section)
        .foregroundStyle(.vigilPrimary)
      content
    }
    .padding(Theme.Metrics.panelPadding)
    .frame(width: Theme.Metrics.panelWidth, alignment: .leading)
  }
}
