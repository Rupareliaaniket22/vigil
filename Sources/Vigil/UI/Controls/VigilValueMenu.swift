import SwiftUI

/// A labelled row whose right-hand side opens the list of choices.
///
/// This is the panel's replacement for both `Stepper` and `Picker`. A stepper
/// makes you click eighteen times to cross a range and never shows you where
/// the range ends; a `Picker` in a transient panel is a system control we
/// cannot style to match the rows around it.
///
/// The trigger is ours, the menu is a real `Menu`. That matters: an NSMenu is
/// its own window, so it can extend past the panel's edge and it arrives as a
/// genuine `AXMenu` with keyboard navigation and type-select already working. A
/// hand-drawn list would be trapped inside a 340pt panel and would have to
/// reimplement all of that, badly.
struct VigilValueMenu<Value: Hashable>: View {
  struct Option: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }

    init(_ value: Value, _ title: String) {
      self.value = value
      self.title = title
    }
  }

  let title: String
  let options: [Option]
  @Binding var selection: Value

  init(_ title: String, options: [Option], selection: Binding<Value>) {
    self.title = title
    self.options = options
    self._selection = selection
  }

  var body: some View {
    HStack(spacing: Theme.Metrics.snug) {
      Text(title)
        .font(Theme.Text.body)
        .foregroundStyle(.vigilPrimary)
        .lineLimit(1)
        // The label belongs to the menu, not beside it: left visible to
        // accessibility it would be read as a separate static-text element and
        // the menu would announce only its value, with nothing saying of what.
        .accessibilityHidden(true)

      Spacer(minLength: Theme.Metrics.tight)

      menu
    }
    .frame(minHeight: Theme.Metrics.menuRowHeight)
  }

  private var menu: some View {
    Menu {
      // An inline `Picker` inside a `Menu` becomes real menu items with a
      // checkmark against the current one — the thing a user expects to see
      // when they open a value menu, and something a stack of `Button`s cannot
      // produce without drawing the checkmark by hand.
      Picker(title, selection: $selection) {
        ForEach(options) { option in
          Text(option.title).tag(option.value)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      HStack(spacing: Theme.Metrics.tight) {
        Text(selectedTitle)
          .monospacedDigit()
          .lineLimit(1)
        Image(systemName: "chevron.up.chevron.down")
          .imageScale(.small)
      }
    }
    // `.button` hands the trigger to whatever `ButtonStyle` is in the
    // environment, so the hover fill, the press tone, the focus ring and the
    // disabled dimming are the same code every other button here uses. The
    // system indicator is hidden because the label draws its own.
    .menuStyle(.button)
    .buttonStyle(.vigil)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(title)
    .accessibilityValue(selectedTitle)
  }

  private var selectedTitle: String {
    options.first { $0.value == selection }?.title ?? ""
  }
}

extension VigilValueMenu where Value == Int {
  /// The `Stepper` replacement.
  ///
  /// Turns a range into the list it always was. `format` exists because the
  /// number alone is rarely the whole answer — "20%" and "20 minutes" want
  /// different words and the same control.
  init(
    _ title: String,
    range: ClosedRange<Int>,
    step: Int = 1,
    format: (Int) -> String,
    selection: Binding<Int>
  ) {
    self.init(
      title,
      options: stride(from: range.lowerBound, through: range.upperBound, by: step)
        .map { Option($0, format($0)) },
      selection: selection
    )
  }
}

// MARK: - Gallery

/// Stands in for `#Preview` — see ControlSupport.swift for why it has to.
struct VigilValueMenuGallery: View {
  @State private var floor = 20
  @State private var pause = 60

  var body: some View {
    GalleryFrame(title: "VigilValueMenu") {
      GallerySpecimen(caption: "from a range · replaces Stepper") {
        VigilValueMenu(
          "Let the Mac sleep below",
          range: 0...90,
          step: 5,
          format: { "\($0)%" },
          selection: $floor
        )
      }

      GallerySpecimen(caption: "from explicit options · replaces Picker") {
        VigilValueMenu(
          "Pause for",
          options: [.init(30, "30 minutes"), .init(60, "1 hour"), .init(720, "Until tomorrow")],
          selection: $pause
        )
      }

      GallerySpecimen(caption: "disabled · the trigger dims with the button style") {
        VigilValueMenu(
          "Let the Mac sleep below",
          range: 0...90,
          step: 5,
          format: { "\($0)%" },
          selection: $floor
        )
        .disabled(true)
      }
    }
  }
}
