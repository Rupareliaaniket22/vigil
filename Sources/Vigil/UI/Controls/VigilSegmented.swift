import SwiftUI

/// A one-of-several choice, drawn as an underline and a weight change.
///
/// Not a pill and not a box: DESIGN.md rules out cards, and a boxed segmented
/// control is a card with dividers in it. The selected option is set in
/// semibold with a rule under it, which means the choice survives Differentiate
/// Without Color without any special handling — there was never a colour
/// carrying it.
struct VigilSegmented<Value: Hashable>: View {
  /// One choice. `id` is the value itself, so two options cannot claim the same
  /// slot without the compiler's `Hashable` doing the complaining.
  struct Option: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }

    init(_ value: Value, _ title: String) {
      self.value = value
      self.title = title
    }
  }

  let label: String
  let options: [Option]
  @Binding var selection: Value

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isFocused: Bool
  @Namespace private var underline

  init(_ label: String, options: [Option], selection: Binding<Value>) {
    self.label = label
    self.options = options
    self._selection = selection
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: Theme.Metrics.menuRowRadius, style: .continuous)
  }

  var body: some View {
    // No trailing `Spacer` in here: the control is as wide as its segments and
    // no wider, so the focus ring hugs them instead of reaching to the panel's
    // far edge. A caller that wants it spread does that at the call site.
    HStack(alignment: .bottom, spacing: Theme.Metrics.loose) {
      ForEach(options) { option in segment(option) }
    }
    // Keeps the drawn ring off the first and last words.
    .padding(.horizontal, Theme.Metrics.tight)
    .vigilDimmed(isEnabled)
    .contentShape([.focusEffect, .interaction], shape)
    // The control takes one focus stop, like an AppKit segmented control —
    // not one per segment. Arrow keys then move the *selection*, which is why
    // `.onMoveCommand` is the right hook: it only fires while this view holds
    // focus, and it does not move focus itself.
    .focusable(isEnabled)
    .focused($isFocused)
    .focusEffectDisabled()
    .vigilFocusRing(isFocused, in: shape)
    .onMoveCommand { direction in
      switch direction {
      case .left: move(by: -1)
      case .right: move(by: 1)
      default: break
      }
    }
    .animation(Theme.Motion.state(reduceMotion: reduceMotion), value: selection)
    // A real segmented picker, so VoiceOver gets the tab list, the index out of
    // the total and the localised "selected" — none of which a row of Texts
    // with traits bolted on would report correctly.
    .accessibilityRepresentation {
      Picker(label, selection: $selection) {
        ForEach(options) { option in
          Text(option.title).tag(option.value)
        }
      }
      .pickerStyle(.segmented)
    }
  }

  private func segment(_ option: Option) -> some View {
    let isSelected = option.value == selection
    return VStack(spacing: Theme.Metrics.tight) {
      // The hidden semibold copy is what sets the width, so the row does not
      // reflow as the selection moves. A segment that shoves its neighbours
      // sideways when you arrow across reads as broken rather than responsive.
      Text(option.title)
        .font(Theme.Text.body)
        .fontWeight(.semibold)
        .hidden()
        .overlay {
          Text(option.title)
            .font(Theme.Text.body)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(isSelected ? Color.vigilPrimary : .vigilSecondary)
            .lineLimit(1)
        }

      ZStack {
        // Always present, so the row's height does not change with selection.
        Color.clear.frame(height: 2)
        if isSelected {
          // Monochrome. The underline is structure, not state, and amber in
          // this app means exactly one thing.
          Capsule()
            .fill(Color.vigilPrimary)
            .frame(height: 2)
            .matchedGeometryEffect(id: "vigil.segmented.underline", in: underline)
        }
      }
    }
    // Without this the segment is as wide as the space it is offered, because
    // `Color.clear` holding the underline's height open is infinitely
    // flexible: the rule would run on past the end of its own word. Fixing the
    // horizontal axis makes the ideal width — the text's — the segment's, and
    // the underline then matches the word it belongs to.
    .fixedSize(horizontal: true, vertical: false)
    .contentShape(Rectangle())
    .onTapGesture { select(option.value) }
  }

  private func select(_ value: Value) {
    guard isEnabled, value != selection else { return }
    selection = value
  }

  /// No wrapping. An arrow key that jumps from the last segment back to the
  /// first loses the user's place, and AppKit's segmented control stops at the
  /// ends too.
  private func move(by step: Int) {
    guard let index = options.firstIndex(where: { $0.value == selection }) else { return }
    let next = index + step
    guard options.indices.contains(next) else { return }
    select(options[next].value)
  }
}

// MARK: - Gallery

/// Stands in for `#Preview` — see ControlSupport.swift for why it has to.
struct VigilSegmentedGallery: View {
  @State private var heat = 1
  @State private var locked = 0

  private var options: [VigilSegmented<Int>.Option] {
    [.init(0, "Warm"), .init(1, "Hot"), .init(2, "Very hot")]
  }

  var body: some View {
    GalleryFrame(title: "VigilSegmented") {
      GallerySpecimen(caption: "tab in, then ← → move the selection, not the focus") {
        VigilSegmented("Stop when the Mac gets", options: options, selection: $heat)
      }

      GallerySpecimen(caption: "selection carried by weight, so it survives greyscale") {
        VigilSegmented("Stop when the Mac gets", options: options, selection: $locked)
      }

      GallerySpecimen(caption: "disabled · dimmed explicitly") {
        VigilSegmented("Stop when the Mac gets", options: options, selection: $heat)
          .disabled(true)
      }
    }
  }
}
