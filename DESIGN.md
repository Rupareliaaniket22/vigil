# Design

The visual contract for Vigil's interface — the values, and why they are what
they are. Read this before changing a colour, a radius, or an animation.

(Not an engineering design doc. Architecture lives in
[README.md](README.md); conventions in [AGENTS.md](AGENTS.md).)

---

## The idea

**Colour means one thing: whether your Mac is being held awake.**

Everything else — labels, separators, controls — uses Apple's semantic system
colours and stays monochrome. One chromatic element, used for one purpose, so
the state is legible in the quarter-second someone glances at the panel.

This is the whole design. Every rule below follows from it.

---

## Colour

### The accent

| | Light | Dark |
| --- | --- | --- |
| **Vigil Amber** | `#A66A00` | `#FFB340` |

Amber is the instrumentation convention for *active watch* — aviation and
control-room panels use it for "something is running, stay aware", distinct from
red's "something is wrong". It also inverts Night Shift's association: macOS
turns warm to wind you down, Vigil goes warm to say the desk lamp is still on.

Two values, not one, because perceived contrast differs by appearance. The light
value is darkened well past the dark-mode value so it reads on a white panel.

**Used only for:** the status glyph when awake, the awake status line, and the
dot beside a session that is actively working. Nothing else.

### Everything else

Use semantic colours, never hex:

| Role | Token |
| --- | --- |
| Primary text | `labelColor` |
| Secondary text — paths, elapsed time | `secondaryLabelColor` |
| Disabled, idle session dots | `tertiaryLabelColor` |
| Hairlines | `separatorColor` |

Apple hand-tunes these per appearance — `secondaryLabelColor` is 49.8% black in
light but 54.9% white in dark, deliberately not a mirror. They also respond to
Increase Contrast for free. Hardcoding hex throws all of that away.

**Do** leave `AccentColor` undefined in the asset catalog, so system controls
inherit the user's chosen accent.
**Don't** repaint system controls amber. Vigil's amber is for state, not chrome.

---

## Typography

System font throughout. macOS interpolates optical sizing continuously now, so
there is no Text/Display choice to make, and tracking is automatic — don't set
it manually.

The macOS ramp is tighter than iOS's. Use only the bottom half of it:

| Role | Style | Size / line |
| --- | --- | --- |
| Status line | Title 3 | 15 / 20 |
| Section label | Headline (bold) | 13 / 16 |
| Session name | Body | 13 / 16 |
| Path, elapsed time | Callout | 12 / 15 |
| Footnotes | Footnote | 10 / 13 |

**Don't** use Large Title, Title 1 or Title 2 (26/22/17). They are sized for
window headers and will look absurd in a 320pt panel.

Exactly one Title 3 line exists — the status. A second one would mean two things
competing to be the headline, and the whole design rests on there being one.

---

## Layout

Numbers below marked *(chosen)* are our conventions, not Apple specifications.
Apple publishes no popover width, no corner radius, and no point grid.

| | Value | |
| --- | --- | --- |
| Panel width | 320pt | *(chosen — fits a path plus elapsed time without truncating)* |
| Corner radius | 12pt, `cornerCurve = .continuous` | *(chosen)* |
| Grid | 8pt multiples | *(chosen convention)* |
| Panel padding | 16pt | *(chosen)* |
| Row height | 32pt | *(chosen)* |
| Menu bar height | 24pt | Apple |
| Status item icon | 16×16pt in a 22pt slot | Apple |
| Minimum hit target | 44×44pt | Apple |

macOS 26 pushed corner radii dramatically larger; macOS 27 pulled them back.
Don't chase it — 12pt is a deliberate choice, not a guess at the current trend.

---

## Material and depth

The panel uses `NSVisualEffectView` with **`.popover`** material.

Apple's rule is to pick a material by intended use rather than appearance. Ours
is semantically a popover — transient, anchored to the status item, dismissed by
clicking away — even though it is a custom `NSPanel`. `.hudWindow` carries
pro-tool baggage that fights the brief; `.sidebar` is tuned for large adjacent
panes; `.menu` is reserved for a real `NSMenu`.

### On Liquid Glass

A hand-placed `NSVisualEffectView` in a custom panel does **not** get Liquid
Glass by rebuilding against a newer SDK. That only happens for standard system
components. Real glass means adopting `NSGlassEffectView` explicitly.

We don't, for now. The API is about a year old and Apple has already revised its
look once between macOS 26 and 27. `.popover` is correct and stable on every
version we support. If we adopt glass later it goes behind
`if #available(macOS 26, *)` with `.popover` as the fallback — which never
forces the deployment target up from macOS 14.

### A deliberate deviation

Apple's menu bar guidance says to show a menu, not a popover, "unless the app
functionality is too complex for a menu." Ours is: a menu cannot render a battery
meter, per-session rows with state dots, or the assertion ledger. Ice, Maccy and
Rectangle all reached the same conclusion. Named here so it reads as a decision
rather than an oversight.

---

## Motion

Opening a menu bar panel is among the most frequent interactions in macOS, and
Apple's guidance is to avoid animating frequent interactions. So:

**Don't** animate the panel open or closed. It should feel instant. No spring,
no bounce, no fade-in flourish.
**Do** animate changes *within* an open panel — a session appearing or
disappearing. Without it, the panel looks like it was replaced rather than
updated.
**Don't** animate the status item on a timer. Reassigning its image repeatedly
triggers a full redraw and burns CPU, which is self-defeating for a power
utility.

Reduce Motion means swap movement for a cross-fade, not strip animation
entirely. Check `accessibilityDisplayShouldReduceMotion`.

---

## Iconography

SF Symbols, always `isTemplate = true`. The menu bar requires a flat black
silhouette it can tint; Palette and Multicolor rendering collapse to unreadable
contrast there.

| State | Symbol |
| --- | --- |
| Awake | `eye.fill` |
| Asleep | `eye` |
| Paused | `eye` + `appearsDisabled` |

Fill versus outline carries the state, never colour — which keeps it correct
under Differentiate Without Color automatically.

Transition with `.contentTransition(.symbolEffect(.replace))`. It exists for
exactly this and needs no availability gate at macOS 14.

When more than one agent is working, put the count in the status item's title
text beside the glyph. A number cannot be encoded in a 16pt silhouette, and this
is the established convention for countdowns and counts.

---

## The panel

```
┌────────────────────────────────────────────┐
│  Awake · 2 agents working      ▓▓▓▓▓▓▓░ 78%│   Title 3 + meter
│                                            │
│  Sessions                                  │   Headline
│  ● claude-code   ~/vigil     working   4m  │   Body + Callout
│  ● codex         ~/linkzy    working   1m  │
│  ○ cursor        ~/cosmic    idle     12m  │
│                                            │
│  ─────────────────────────────────────     │   separatorColor
│  Also holding your Mac awake               │   Headline
│  Music · caffeinate                        │   Callout
│                                            │
│  Keep awake                          ( •)  │
│  Pause for…                                │
└────────────────────────────────────────────┘
```

Amber appears exactly three times: the status word, and the two working dots.

**The ledger is the point.** That second section — assertions held by *other*
processes — is what turns this from a switch into an explanation. It is also
honest: it shows when the reason your Mac is awake isn't Vigil at all. Don't
hide it to save space.

**The empty state is never blank.** Zero sessions reads "No agents running —
your Mac can sleep normally", with the manual toggle still present, so there is
always something to act on.

---

## Writing

Sentence case. Plain verbs. No exclamation marks.

Say what is true from the user's side — "Your Mac will stay awake while agents
work", not "Wake assertion held". Internal vocabulary like *assertion*,
*clamshell* and *IOPMrootDomain* belongs in code and logs, not the panel.

State the reason, always. "Sleeping — battery 12% is below the 20% floor" beats
"Inactive". Someone who cannot tell why their Mac slept during a long run will
not trust the app again.

Errors explain what happened and what to do. They do not apologise.

---

## What we deliberately don't do

- **No onboarding carousel.** The panel explains itself.
- **No colour beyond amber.** No green/red status pairs — they fail for the
  most common form of colour blindness and this design doesn't need them.
- **No cards.** Rows separated by whitespace and one hairline. Boxing every
  group is the default that makes utilities look generated.
- **No all-caps labels, no monospace for small text.** Both read as decoration
  pretending to be information.
- **No logo in the panel.** The user knows which app they opened.
