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

  /// The pressed tone, laid flat over whatever is underneath.
  ///
  /// Not a scale, not a knob that nudges early. `NSButton`'s push highlight is
  /// a tone and nothing else, and a control that shrinks under the pointer
  /// reads as a toy beside the system controls sharing the panel with it.
  /// These two values reproduce the push highlight exactly.
  static let pressOverlay = NSColor(name: "VigilPressOverlay") { appearance in
    switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
    case .darkAqua:
      NSColor(white: 1, alpha: 0.11)
    default:
      NSColor(white: 0, alpha: 0.06)
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

    /// The ON half of a switch track: the user's accent, deliberately not amber.
    ///
    /// Amber means one thing — the Mac is being held awake — and the headline
    /// beside the switch already says so in amber. A second amber element for
    /// the same fact adds no information, and a switch left on while a
    /// guardrail holds the Mac asleep would be amber for something untrue.
    static let trackOn = NSColor.controlAccentColor

    /// The OFF half. `quaternaryLabelColor` is 10% ink, which over `.popover`
    /// material sits right at the edge of visible — fine normally, gone for
    /// anyone who turned Increase Contrast on. So that appearance steps up to
    /// `tertiaryLabelColor`, where the track still reads as a track.
    static let trackOff = NSColor(name: "VigilSwitchTrackOff") { appearance in
      switch appearance.bestMatch(from: [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
      ]) {
      case .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua:
        NSColor.tertiaryLabelColor
      default:
        NSColor.quaternaryLabelColor
      }
    }

    /// The switch knob. Opaque in light, 75% in dark — a fully opaque white
    /// knob on a dark panel is brighter than any text near it and pulls the eye
    /// off the status line, which is the one thing the panel exists to say.
    static let knob = NSColor(name: "VigilSwitchKnob") { appearance in
      switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
      case .darkAqua:
        NSColor(white: 1, alpha: 0.75)
      default:
        NSColor(white: 1, alpha: 1)
      }
    }

    /// The keyboard focus ring. It already carries 50% alpha of its own;
    /// multiplying it with `.opacity()` is the usual way a hand-drawn focus
    /// ring ends up invisible on the machine of the person who needs it.
    static let focusRing = NSColor.keyboardFocusIndicatorColor
  }

  // MARK: - Typography

  /// The bottom half of the macOS ramp. Large Title, Title 1 and Title 2 are
  /// sized for window headers and are deliberately absent.
  enum Text {
    /// The single status line. Exactly one of these exists in the panel.
    static let status = Font.system(size: 15)

    /// Section labels. Semibold, not bold.
    ///
    /// SwiftUI's `.bold` is weight 700; the macOS Headline style is 600. At
    /// 13pt, 700 out-weighs the 15pt status line above it and the panel ends up
    /// with two headlines, the louder of which is the smaller one. 600 keeps
    /// the section label a label.
    static let section = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    /// Paths and elapsed time.
    static let detail = Font.system(size: 12)
    /// 11, not 10. Ten-point text is below the size macOS sets any of its own
    /// interface text at, and the only thing it bought was a row of captions
    /// nobody could read without leaning in.
    static let footnote = Font.system(size: 11)
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

    /// Vertical breathing room inside the panel's rounded edge.
    ///
    /// Five, against sixteen horizontally, and deliberately not square. The
    /// horizontal margin is a text margin — it sets the column everything
    /// aligns to. The vertical one only has to keep the first and last rows off
    /// the corner curve, and every row already carries its own height, so a
    /// matching 16 here reads as a gap somebody forgot to fill.
    static let panelPaddingVertical: CGFloat = 5

    /// One row in either list: an agent, or a process holding the Mac awake.
    /// The height *is* the rhythm — rows stack at zero spacing, so 24 is both
    /// the row and the pitch.
    static let rowHeight: CGFloat = 24

    /// The right-hand column every row's value lands in.
    ///
    /// Fixed so the elapsed times line up as a column instead of ending
    /// wherever each string happens to. 56 holds the longest time a row can
    /// show ("12h 34m"); a two-word state like "needs you" is allowed to grow
    /// leftward past it rather than truncate, because what makes this a rail is
    /// its trailing edge, not its width.
    static let valueRail: CGFloat = 56
    /// The 8pt grid, as named steps so call sites don't sprinkle magic numbers.
    static let tight: CGFloat = 4
    static let snug: CGFloat = 8
    static let loose: CGFloat = 16
    /// Height of a tappable footer row.
    static let menuRowHeight: CGFloat = 24

    /// A menu row's highlight is inset from the panel edge, never full-bleed,
    /// and its corner is concentric with the panel's own: an inner radius equal
    /// to the outer radius less the inset keeps the two curves parallel.
    /// Full-bleed would run a square corner straight into a rounded one.
    static let menuRowInset: CGFloat = 6
    static var menuRowRadius: CGFloat { cornerRadius - menuRowInset }

    // MARK: Settings

    /// The settings window, fixed rather than fitted.
    ///
    /// A window that sizes itself to its content is at the mercy of the longest
    /// sentence in it: the old one grew to 813pt tall, which on a 13" MacBook
    /// reaches within a few points of both screen edges. Naming the size makes
    /// it something a reviewer can check, and makes content that does not fit a
    /// failure at build time rather than a window nobody can see the bottom of.
    static let settingsWidth: CGFloat = 520
    static let settingsHeight: CGFloat = 580
    static let settingsInset: CGFloat = 24
    /// Taller than a panel row: this one holds controls, not text.
    static let settingsRowHeight: CGFloat = 28

    /// Clearance for the traffic lights on a window with no visible title bar.
    /// The buttons are drawn over the content, so the content has to start
    /// below them or the first row sits underneath the close button.
    static let titleBarZone: CGFloat = 28
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

    /// A control changing state — a switch knob crossing, a segment's underline
    /// sliding under the new choice.
    ///
    /// Not `.default`: on macOS 14 that resolves to a spring with a response of
    /// 0.55, tuned for window-sized movement and far too slow for a panel the
    /// user opened to read in a quarter of a second. Bounce is zero on purpose
    /// — a knob that overshoots and settles reads as a toy, and this one is
    /// reporting whether the Mac will sleep.
    ///
    /// Takes the preference rather than reading it, because the only correct
    /// place to read it is `@Environment(\.accessibilityReduceMotion)` inside a
    /// view. `NSWorkspace` answers once, statically, and never tells SwiftUI to
    /// redraw when the user changes it mid-session.
    static func state(reduceMotion: Bool) -> Animation {
      reduceMotion ? .easeInOut(duration: 0.10) : .spring(duration: 0.18, bounce: 0)
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
  static let vigilPressOverlay = Color(nsColor: Theme.pressOverlay)
  static let vigilTrackOn = Color(nsColor: Theme.Ink.trackOn)
  static let vigilTrackOff = Color(nsColor: Theme.Ink.trackOff)
  static let vigilKnob = Color(nsColor: Theme.Ink.knob)
  static let vigilFocusRing = Color(nsColor: Theme.Ink.focusRing)
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
  static var vigilPressOverlay: Color { .vigilPressOverlay }
  static var vigilTrackOn: Color { .vigilTrackOn }
  static var vigilTrackOff: Color { .vigilTrackOff }
  static var vigilKnob: Color { .vigilKnob }
  static var vigilFocusRing: Color { .vigilFocusRing }
}
