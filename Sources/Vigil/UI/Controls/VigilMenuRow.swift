import SwiftUI

/// A footer row that highlights the way a real menu item does.
///
/// The trailing slot takes whatever the row's right-hand side would say in a
/// menu — a `⌘,` shortcut, or the current value of the thing the row opens.
struct VigilMenuRow: View {
  let title: String
  var trailing: String?
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false
  @State private var isPressed = false
  @FocusState private var isFocused: Bool

  init(_ title: String, trailing: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.trailing = trailing
    self.action = action
  }

  /// One highlight, not three. Pointer, keyboard focus and press all mean the
  /// same thing in a menu — this is the row you are about to act on — so they
  /// share one appearance. A separate press tone on top would be a second
  /// answer to a question the highlight already answered.
  private var isHighlighted: Bool { isEnabled && (isHovered || isFocused || isPressed) }

  /// Inset and rounded, never full-bleed. The inner radius is the panel's less
  /// the inset, so the highlight's corner runs parallel to the panel's own.
  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: Theme.Metrics.menuRowRadius, style: .continuous)
  }

  var body: some View {
    HStack(spacing: Theme.Metrics.snug) {
      Text(title)
        .font(Theme.Text.body)
        .foregroundStyle(isHighlighted ? Color.vigilSelectedText : .vigilPrimary)
        .lineLimit(1)

      Spacer(minLength: Theme.Metrics.tight)

      if let trailing {
        Text(trailing)
          .font(Theme.Text.detail)
          // On the highlight, the secondary ink would be an unrelated grey over
          // the accent. The same selected text colour held back a little is how
          // AppKit keeps a shortcut subordinate to its command.
          .foregroundStyle(
            isHighlighted ? Color.vigilSelectedText.opacity(0.75) : .vigilSecondary
          )
          .monospacedDigit()
          .lineLimit(1)
      }
    }
    // The text still lands on the panel's 16pt margin: 10 here plus the 6 the
    // whole row is inset by below.
    .padding(.horizontal, Theme.Metrics.panelPadding - Theme.Metrics.menuRowInset)
    .frame(height: Theme.Metrics.menuRowHeight)
    .background { if isHighlighted { shape.fill(Color.vigilSelection) } }
    .vigilDimmed(isEnabled)
    .contentShape([.focusEffect, .interaction], shape)
    .vigilPressAction(isPressed: $isPressed) { activate() }
    .focusable(isEnabled)
    .focused($isFocused)
    .focusEffectDisabled()
    .vigilFocusRing(isFocused, in: shape)
    .onKeyPress(.space) { activate() }
    .onKeyPress(.return) { activate() }
    .onHover { isHovered = isEnabled && $0 }
    .padding(.horizontal, Theme.Metrics.menuRowInset)
    // Real menus snap. Fading the highlight in reads as the app lagging behind
    // the pointer, and `nil` here also protects the row from an ambient
    // `withAnimation` somewhere up the tree.
    .animation(nil, value: isHighlighted)
    // No `Button` underneath, so the traits and the activation are ours to
    // supply. The title is the label and the trailing slot is the value, which
    // is what it is in every case: a shortcut, or the current setting.
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(title)
    .accessibilityValue(trailing ?? "")
    .accessibilityAction(.default, action)
  }

  @discardableResult
  private func activate() -> KeyPress.Result {
    guard isEnabled else { return .ignored }
    action()
    return .handled
  }
}

// MARK: - Gallery

/// Stands in for `#Preview` — see ControlSupport.swift for why it has to.
struct VigilMenuRowGallery: View {
  @State private var log = "—"

  var body: some View {
    GalleryFrame(title: "VigilMenuRow") {
      GallerySpecimen(caption: "plain · hover or tab to highlight, space or return to fire") {
        VStack(spacing: 0) {
          VigilMenuRow("Pause") { log = "Pause" }
          VigilMenuRow("Settings…", trailing: "⌘,") { log = "Settings" }
          VigilMenuRow("Quit Vigil", trailing: "⌘Q") { log = "Quit" }
        }
        // Rows go edge to edge; the highlight insets itself.
        .padding(.horizontal, -Theme.Metrics.panelPadding)
      }

      GallerySpecimen(caption: "trailing as a value, and a disabled row") {
        VStack(spacing: 0) {
          VigilMenuRow("Let the Mac sleep below", trailing: "20%") { log = "Floor" }
          VigilMenuRow("Resume — paused until 14:30") { log = "Resume" }
            .disabled(true)
        }
        .padding(.horizontal, -Theme.Metrics.panelPadding)
      }

      Text("last: \(log)")
        .font(Theme.Text.footnote)
        .foregroundStyle(.vigilTertiary)
    }
  }
}
