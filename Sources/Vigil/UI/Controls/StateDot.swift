import AppKit
import SwiftUI

/// The dot beside a session: filled amber while the agent is working, an empty
/// ring while it is not.
///
/// Filled versus hollow carries the state on its own, so the amber is
/// reinforcement rather than the message — which is what keeps the row readable
/// under Differentiate Without Color and in greyscale.
struct StateDot: View {
  let isActive: Bool
  /// Supplied only when the dot is the sole indicator. Beside a row that
  /// already says "working", it is noise: the row combines its children into
  /// one spoken sentence and a second voice for the same fact interrupts it.
  var accessibilityLabel: String?

  @Environment(\.displayScale) private var displayScale

  init(isActive: Bool, accessibilityLabel: String? = nil) {
    self.isActive = isActive
    self.accessibilityLabel = accessibilityLabel
  }

  /// Half the x-height of the body font: `NSFont.systemFont(ofSize: 13)`
  /// measures 6.8428, so 3.4214.
  ///
  /// Written out rather than measured at runtime — conforming to `View` makes
  /// the whole type main-actor isolated, and an alignment guide's closure is
  /// not, so reading the font here would trade a number for a hop. `nonisolated`
  /// for the same reason: it is a constant, and the closure needs to see it.
  private nonisolated static let xHeightHalf: CGFloat = 3.4214

  var body: some View {
    dot
      .frame(width: 6, height: 6)
      // Aligned to the x-height, not the baseline. In a `.firstTextBaseline`
      // row a 6pt circle reports its own baseline at its bottom edge, which
      // drops it onto the text's baseline and leaves it hanging below the
      // lowercase letters it is meant to sit beside. Reporting a baseline of
      // "my centre, plus half an x-height" puts the dot's middle on the middle
      // of the text instead.
      .alignmentGuide(.firstTextBaseline) { d in
        d[VerticalAlignment.center] + Self.xHeightHalf
      }
      // A `Shape` is not an accessibility element on its own, so a label alone
      // would have nothing to attach to.
      .accessibilityElement()
      .accessibilityHidden(accessibilityLabel == nil)
      .accessibilityLabel(accessibilityLabel ?? "")
  }

  @ViewBuilder
  private var dot: some View {
    if isActive {
      Circle().fill(Color.vigilAmber)
    } else {
      // A full point, not a hairline. At 6pt across, a ring drawn at
      // `1 / displayScale` is a quarter of the dot's visual weight and reads as
      // a smudge rather than as the other half of a two-state indicator.
      Circle().strokeBorder(Color.vigilTertiary, lineWidth: 1)
    }
  }
}

// MARK: - Gallery

/// Stands in for `#Preview` — see ControlSupport.swift for why it has to.
struct StateDotGallery: View {
  var body: some View {
    GalleryFrame(title: "StateDot") {
      GallerySpecimen(caption: "active and idle, beside 13pt body text") {
        VStack(alignment: .leading, spacing: Theme.Metrics.tight) {
          row(isActive: true, name: "claude-code", state: "working")
          row(isActive: false, name: "cursor", state: "idle")
        }
      }

      GallerySpecimen(caption: "against the baseline it is deliberately not on") {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.snug) {
          StateDot(isActive: true)
          Text("xxxxx — the dot's centre sits on the x-height, not the baseline")
            .font(Theme.Text.body)
            .foregroundStyle(.vigilSecondary)
        }
      }
    }
  }

  private func row(isActive: Bool, name: String, state: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.snug) {
      StateDot(isActive: isActive)
      Text(name)
        .font(Theme.Text.body)
        .foregroundStyle(.vigilPrimary)
      Text(state)
        .font(Theme.Text.detail)
        .foregroundStyle(.vigilSecondary)
    }
  }
}
