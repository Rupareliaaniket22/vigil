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
| **Vigil Amber** | `#8A5600` | `#FFB340` |

Amber is the instrumentation convention for *active watch* — aviation and
control-room panels use it for "something is running, stay aware", distinct from
red's "something is wrong". It also inverts Night Shift's association: macOS
turns warm to wind you down, Vigil goes warm to say the desk lamp is still on.

Two values, not one, because perceived contrast differs by appearance. The light
value is darkened well past the dark-mode value so it reads on a white panel:
`#A66A00` measured 3.76:1 against the panel, below AA, and the `.popover`
material lets the desktop through — so a mid-tone wallpaper washed it out
entirely. `#8A5600` measures 5.3:1. Dark mode never had this failure, which is
why it went unnoticed. High-contrast variants of both are in `DesignSystem.swift`.

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
| Section label | Headline (semibold) | 13 / 16 |
| Session name | Body | 13 / 16 |
| Path, elapsed time | Callout | 12 / 15 |
| Footnotes | Footnote | 11 / 14 |

Semibold, not bold. SwiftUI's `.bold` is weight 700 and the macOS Headline
style is 600; at 13pt, 700 out-weighs the 15pt status line, and the panel ends
up with the smallest text as its loudest — the hierarchy exactly inverted.

Footnotes are 11, not 10. Ten-point text is below the size macOS sets any of
its own interface text at, and it only ever bought captions nobody read.

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
| Panel width | 340pt | *(chosen — 320 truncated the assertion reasons)* |
| Corner radius | 12pt, `cornerCurve = .continuous` | *(chosen)* |
| Grid | 8pt multiples | *(chosen convention)* |
| Panel padding | 16pt across, 5pt top and bottom | *(chosen)* |
| Row height | 24pt | *(chosen)* |
| Value rail | 56pt, trailing | *(chosen)* |
| Settings window | 520 × 680pt | *(chosen)* |
| Menu bar height | 24pt | Apple |
| Status item icon | 16×16pt in a 22pt slot | Apple |
| Minimum hit target | 44×44pt | Apple |

macOS 26 pushed corner radii dramatically larger; macOS 27 pulled them back.
Don't chase it — 12pt is a deliberate choice, not a guess at the current trend.

The padding is deliberately not square. The horizontal margin is a *text*
margin: it sets the column every row aligns to. The vertical one only has to
keep the first and last rows off the corner curve, and every row carries its own
height, so matching 16 there reads as a gap somebody forgot to fill.

**One row, one height.** Both lists in the panel — the agents, and the processes
holding the Mac awake — answer the same question, so they are the same 24pt row
with the same four columns, stacked at zero spacing so the row *is* the rhythm.
The last column is a fixed rail rather than whatever each value happens to
measure, which is what lets the eye run down the elapsed times as a column.

A rail is a trailing *edge*, so a button sitting on one hangs its capsule over
the margin and puts its text where the text above it is. Our plain button draws
no background at rest, so left alone its 12pt of capsule padding is invisible
and stops the column 12pt short on exactly the rows that are asking to be
clicked — in the panel and in the settings window both, where the switch tracks
set the same edge.

**The settings window is a fixed size, not a fitted one.** A window that sizes
itself is at the mercy of its longest sentence: the grouped `Form` it replaced
came to 813pt, which on a 13" MacBook very nearly touches the top and bottom of
the screen. Naming the size makes it something a reviewer can check.

The number has moved twice, and both times for the same reason: the window has
no scroll view and no resize handle, so content that does not fit is cut off by
the window edge with nothing saying so, and what gets cut is the bottom — the
last switch in the last section. 580 became 620 when the agent rows grew a line
explaining a host that refuses to run Vigil's hooks. 620 became 680 when the
layout check stopped measuring only the machine it ran on, where nothing is
ever wrong, and started building the worst shape the window can honestly be in:
every agent offered, every host that gates hooks refusing at once, an installer
error long enough to reach its line cap, and each of the two things the lid
section can say. That measures 648, and 680 carries it with two wrapped footnote
lines to spare.

Which is the other half of the rule. **Every block of text in that window that
Vigil did not write is capped**, with the whole of it on `.help()` — an
installer's output has no length, and one paragraph is enough to push a control
off the bottom of a window that cannot scroll. `make smoke` measures the capped
worst case on every build and fails it if the number goes over, so the height
is a claim the build can falsify rather than a hope.

And the claim is only as good as the worst case it is checked against. Which
hosts refuse in that shape is read off the integrations rather than written
down. It was written down — Codex, the only one that gates hooks today — and a
guard that names the only case that exists cannot fire on the case it guards
against, because the build that gives a second host a trust gate is the build
that adds a second notice. Each notice costs 32pt, so the margin above 648 is
exactly one more of them: two gating hosts measure 680 of 680, and three fail
the build.

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
┌────────────────────────────────────────────────────┐
│  Keeping your Mac awake         ▓▓▓▓▓▓▓░ 95% left  │  Title 3 + meter
│  2 agents working                                  │  Callout
│                                                    │
│  Agents                         2 need updating ›  │  Headline + action
│  ●  Claude Code    ~/code/vigil               4m   │  Body + Callout
│  ◐  Codex          ~/code/linkzy       needs you   │
│  ○  Gemini CLI                              idle   │
│                                                    │
│  Also holding your Mac awake                       │  Headline
│     Your display is on   powerd           1h 38m   │
│     Audio is playing     coreaudiod       2h 04m   │
│                                                    │
│────────────────────────────────────────────────────│  separatorColor
│   Always keep awake                         ( •)   │
│   Pause 30 minutes                                 │
│   Pause 1 hour                                     │
│   Settings…                                  ⌘,    │
│   Quit Vigil                                 ⌘Q    │
└────────────────────────────────────────────────────┘
```

Amber appears only where state is: the headline while the Mac is held awake,
and the dot beside a working agent. Nothing else, the meter included — a green
or amber battery bar would be a second colour with a second meaning, and the
whole design rests on there being one.

**The meter lives on the status line**, not in a section of its own. A section
stated one number three times and printed the battery floor permanently, as
though it were a fact about the machine rather than a setting. What is genuinely
stateful — that the charge has fallen below the number you chose — arrives in
the reason line underneath, in words, on the one day it matters. On a Mac with
no battery the meter is absent rather than pinned at full.

The meter is the system battery symbol at the nearest quarter, inline with the
number and in the same grey. The number is the reading; the glyph is what says
the number is a battery, and it is the drawing everyone already reads in their
menu bar at exactly this size. A bar of our own at 24pt had no room to mean
anything — one percent was a quarter of a point — and its empty track was
invisible against the panel, so it read as a stray dash rather than a level.

**Exactly one rule**, above the footer, where the content stops being an answer
and starts being an action. Once both lists are the same row, the rule that used
to sit above the ledger marked no change of kind — only a change of subject, and
the header states that.

**The panel opens with nothing focused.** A menu highlights nothing until the
keyboard asks for something, and this panel is a menu in all but class. The
first Tab or arrow key lands on the first row (up-arrow on the last), Space or
Return fires it, Escape closes. So does ⌘W, by the same exit — and getting it
there took two things rather than one. The panel has no close button, so
`performClose` has nothing to press and is routed to the same dismissal Escape
uses; and AppKit disables Window ▸ Close for a window with no close button,
while a disabled menu item still swallows the keystroke rather than passing it
on. The panel had the first half without the second, and for that whole time ⌘W
did nothing at all while three places said it dismissed the panel. A window that
meets the reflex gesture for dismissing a focused surface with silence is
telling the user they did something wrong when they did not. A focus ring drawn
on open is the loudest thing on screen, for a keyboard nobody has touched.

**The footer's rows highlight as one shape**: an inset rounded rectangle, 6pt
in from the panel's edge with a 6pt radius so its corner runs parallel to the
panel's own. The four action rows fill it in the selection colour under the
pointer or keyboard focus, with the text flipped to match, the way a menu item
does. The switch row is a real switch — it has to report on and off to
VoiceOver, and its accent-coloured track would vanish on an accent fill — so
it takes the keyboard focus ring on that same rectangle and no fill; its
affordance is the switch itself.

**The ledger leaves the dot's gutter empty.** That gap is what keeps the dot
meaning one thing — *this is an agent Vigil is watching* — rather than drifting
into *this is a row*.

**The ledger is the point.** That second section — assertions held by *other*
processes — is what turns this from a switch into an explanation. It is also
honest: it shows when the reason your Mac is awake isn't Vigil at all. Don't
hide it to save space.

Each row names the process and the reason it gave, because "Music" alone still
leaves you guessing. One row per process: something holding several assertions
is still one answer to the question, and repeating it would make a short list
look alarming.

**The empty state is never blank**, and it is never a grey sentence where a
list should be. Each one is a headline in `labelColor`, one sentence, and one
thing to do:

- **Nothing running.** Keep the idle rows. Four hollow dots are proof Vigil is
  watching; replacing them with a sentence makes a working app look empty.
- **No agents installed.** The Agents section *becomes* the empty state, in
  place, under its own header — what Vigil supports, and a link.
- **The bridge is down.** The one global notice there is, because every row in
  the panel is quietly stale and nothing else would say so.

Raw error text never appears in the panel. A socket error is a path, an errno
and the word "bind"; it goes on `.help()` and into the log, and the panel shows
a written sentence and the one action that resolves it. A sentence with nothing
longer behind it carries no hover at all, rather than an empty one. And where
the sentence asks for something a button in the panel already does, both say it
with the same word.

**The panel's bad day is measured too.** Under the agent rows sit three notes
the panel only writes when something is wrong — a host that will not run the
hooks, a host that has stopped saying its work is over, and a setup that failed
— and two of them are one per host rather than one apiece. `make smoke` builds
the panel with every note a fixture can reach showing at once, and the degraded
gallery holds the one it cannot arrange, so the shape nobody sees until their
worst day is still drawn by every build.

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
