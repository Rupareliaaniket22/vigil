import SwiftUI

/// A one-pixel rule.
///
/// One *pixel*, not one point. A `frame(height: 1)` is two physical pixels on
/// every Mac display shipped this decade, which is twice the weight of every
/// system separator it sits near and reads as a deliberate divider rather than
/// a seam. `1 / displayScale` is the actual hairline, and it has to come from
/// the environment because a panel can be dragged onto a second screen at a
/// different scale while it is open.
struct Hairline: View {
  /// Edge to edge. The default stops at the panel's margins, lining the rule
  /// up with the text above and below it; full-bleed is for where the rule
  /// separates two *kinds* of content rather than two groups of the same kind.
  var fullBleed = false

  @Environment(\.displayScale) private var displayScale

  init(fullBleed: Bool = false) {
    self.fullBleed = fullBleed
  }

  var body: some View {
    Rectangle()
      .fill(Color.vigilSeparator)
      .frame(height: 1 / displayScale)
      .padding(.horizontal, fullBleed ? 0 : Theme.Metrics.panelPadding)
      // Carries no vertical margin of its own, so callers control the spacing
      // and one component cannot produce different gaps in different parents.
      .accessibilityHidden(true)
  }
}

// MARK: - Gallery

/// Stands in for `#Preview` — see ControlSupport.swift for why it has to.
struct HairlineGallery: View {
  var body: some View {
    GalleryFrame(title: "Hairline") {
      GallerySpecimen(caption: "inset · aligned with the panel's text margin") {
        VStack(alignment: .leading, spacing: Theme.Metrics.snug) {
          Text("Agents").font(Theme.Text.section)
          Hairline()
          Text("Also holding your Mac awake").font(Theme.Text.section)
        }
        .padding(.horizontal, -Theme.Metrics.panelPadding)
      }

      GallerySpecimen(caption: "full bleed · for a change of kind, not of group") {
        Hairline(fullBleed: true)
          .padding(.horizontal, -Theme.Metrics.panelPadding)
      }

      GallerySpecimen(caption: "beside a literal 1pt rule — the lower one is twice the weight") {
        VStack(spacing: Theme.Metrics.snug) {
          Hairline(fullBleed: true)
          Rectangle()
            .fill(Color.vigilSeparator)
            .frame(height: 1)
        }
      }
    }
  }
}
