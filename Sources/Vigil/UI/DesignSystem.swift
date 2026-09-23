import AppKit
import SwiftUI

/// The design tokens from DESIGN.md, in code.
///
/// DESIGN.md holds the same values with the reasoning; this is the source of
/// truth the UI actually reads. If you change a value here, change it there too
/// — a token that disagrees with its rationale is worse than no token.
enum Theme {

  // MARK: - Colour

  /// The one chromatic element in the app: it means the Mac is being held awake.
  ///
  /// Two values because perceived contrast differs by appearance — the light
  /// variant is darkened well past the dark one so it reads on a white panel.
  /// Amber is the instrumentation convention for active watch, as distinct from
  /// red's alarm.
  static let amber = NSColor(name: "VigilAmber") { appearance in
    switch appearance.bestMatch(from: [
      .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]) {
    case .darkAqua:
      NSColor(srgbRed: 1.00, green: 0.70, blue: 0.25, alpha: 1)  // #FFB340 — 7.2:1
    case .accessibilityHighContrastDarkAqua:
      NSColor(srgbRed: 1.00, green: 0.78, blue: 0.45, alpha: 1)  // #FFC773
    case .accessibilityHighContrastAqua:
      NSColor(srgbRed: 0.42, green: 0.26, blue: 0.00, alpha: 1)  // #6B4200
    default:
      // #8A5600, not #A66A00. The lighter value measured 3.76:1 against the
      // panel — below AA — and the panel's material lets the desktop through,
      // so a mid-tone wallpaper washed it out entirely. Dark mode never had
      // this failure, which is why it went unnoticed.
      NSColor(srgbRed: 0.54, green: 0.34, blue: 0.00, alpha: 1)  // #8A5600 — 5.3:1
    }
  }

  /// Everything that is not state. Apple tunes these per appearance and adapts
  /// them to Increase Contrast; hardcoding hex throws that away.
  enum Ink {
    static let primary = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    static let tertiary = NSColor.tertiaryLabelColor
    static let separator = NSColor.separatorColor
    /// For control backgrounds. `separatorColor` is 9.8% alpha in *both*
    /// appearances — Apple did not hand-tune that one — so multiplying it was
    /// never going to produce a visible button.
    static let controlFill = NSColor.quaternaryLabelColor
    /// Menu-row highlight, the way a real menu item does it.
    static let selection = NSColor.selectedContentBackgroundColor
    static let selectedText = NSColor.alternateSelectedControlTextColor
  }

  // MARK: - Typography

  /// The bottom half of the macOS ramp. Large Title, Title 1 and Title 2 are
  /// sized for window headers and are deliberately absent.
  enum Text {
    /// The single status line. Exactly one of these exists in the panel.
    static let status = Font.system(size: 15)
    static let section = Font.system(size: 13, weight: .bold)
    static let body = Font.system(size: 13)
    /// Paths and elapsed time.
    static let detail = Font.system(size: 12)
    static let footnote = Font.system(size: 10)
  }

  // MARK: - Layout

  /// Values marked "chosen" in DESIGN.md are our conventions. Apple publishes
  /// no popover width, no corner radius and no point grid.
  enum Metrics {
    /// Chosen: fits an agent name, its status and a project path without
    /// truncating. 320 was too tight — the assertion reasons all ellipsised.
    static let panelWidth: CGFloat = 340
    static let panelPadding: CGFloat = 16
    static let cornerRadius: CGFloat = 12
    static let rowHeight: CGFloat = 22
    /// The 8pt grid, as named steps so call sites don't sprinkle magic numbers.
    static let tight: CGFloat = 4
    static let snug: CGFloat = 8
    static let loose: CGFloat = 16
    /// Height of a tappable footer row.
    static let menuRowHeight: CGFloat = 24
  }

  // MARK: - Motion

  enum Motion {
    /// Whether to move things, or merely cross-fade them.
    static var prefersReduced: Bool {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// For changes *within* an open panel — a session appearing or leaving.
    /// The panel's own open and close are deliberately not animated: it is one
    /// of the most frequent interactions in macOS and should feel instant.
    static var contentChange: Animation {
      prefersReduced ? .easeInOut(duration: 0.12) : .easeOut(duration: 0.18)
    }
  }
}

extension Color {
  /// SwiftUI views read tokens through here rather than reaching for NSColor.
  static let vigilAmber = Color(nsColor: Theme.amber)
  static let vigilPrimary = Color(nsColor: Theme.Ink.primary)
  static let vigilSecondary = Color(nsColor: Theme.Ink.secondary)
  static let vigilTertiary = Color(nsColor: Theme.Ink.tertiary)
  static let vigilSeparator = Color(nsColor: Theme.Ink.separator)
  static let vigilControlFill = Color(nsColor: Theme.Ink.controlFill)
  static let vigilSelection = Color(nsColor: Theme.Ink.selection)
  static let vigilSelectedText = Color(nsColor: Theme.Ink.selectedText)
}

/// So call sites can write `.foregroundStyle(.vigilSecondary)` — the leading-dot
/// form resolves against ShapeStyle, not Color.
extension ShapeStyle where Self == Color {
  static var vigilAmber: Color { .vigilAmber }
  static var vigilPrimary: Color { .vigilPrimary }
  static var vigilSecondary: Color { .vigilSecondary }
  static var vigilTertiary: Color { .vigilTertiary }
  static var vigilSeparator: Color { .vigilSeparator }
  static var vigilControlFill: Color { .vigilControlFill }
  static var vigilSelection: Color { .vigilSelection }
  static var vigilSelectedText: Color { .vigilSelectedText }
}
