# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Gatecaster is a user-space macOS driver (no kernel extension) that turns a USB
HID touchscreen into a full Mac input device: pointer, tap, drag, right-click,
momentum scroll, native pinch-zoom & rotate, an on-screen keyboard, a virtual
trackpad, edge gestures, and (on the `v3-deck-poc` branch) a Stream Deck-style
control surface. It ships as a menu-bar accessory app.

Currently hardware-locked to the ELAN controller in the Visual Beat V17UT
(USB `04F3:5512`); generic HID support is roadmap.

## Build / run

```bash
swift build -c release            # bare binary → .build/release/Gatecaster
.build/release/Gatecaster         # run it
scripts/make-app.sh               # full app bundle → dist/Gatecaster.app (signed if a cert exists)
scripts/release.sh                # signed + notarized + stapled DMG (needs IDENTITY + NOTARY_PROFILE env)
```

Or open `Package.swift` in Xcode (scheme: **Gatecaster**). There is no test suite.

**Permissions are mandatory** and gate everything. Grant the *binary* (or
Terminal, if launched from there) both **Accessibility** (to post events) and
**Input Monitoring** (to read the HID) in System Settings → Privacy & Security,
then relaunch. TCC keys grants to the signing identity — `make-app.sh` prefers a
real cert (Developer ID / Apple Development) over ad-hoc so grants survive
rebuilds; ad-hoc signing forces re-granting every build.

**"Start at login"** uses `SMAppService` and only works from `Gatecaster.app`
(the bare binary has no bundle identity to register).

## Architecture

Two SPM targets in [Package.swift](Package.swift):

- **GestureKit** (C, [Sources/GestureKit/](Sources/GestureKit/)) — the
  gesture synth. `gk_post_fields` posts a magnify/rotate gesture event
  plus the capture-dump helper. The old IOHID graft (which crashed WindowServer)
  has been deleted; only the working recipe remains.
- **Gatecaster** (Swift, [Sources/Gatecaster/](Sources/Gatecaster/)) — the app.

Data flow: **HID report → Contact stream → Engine state machine → synthesized
CGEvents.**

- [Hid.swift](Sources/Gatecaster/Hid.swift) — `IOHIDManager`: opens the panel and
  performs the one-line wake-up handshake (`GET_FEATURE 0x44`) that unlocks the
  10-finger digitizer (Report ID 1), then decodes the 11-byte-per-contact format
  into `Contact {id, x, y}`. Everything downstream is controller-agnostic from
  this struct onward.
- [Engine.swift](Sources/Gatecaster/Engine.swift) — the heart (~900 lines). The
  gesture state machine: palm rejection, tap/drag/right-click, the two-finger
  *intent latch* (scroll vs pinch vs rotate, decided in one comparable unit),
  momentum, edge-zone dwell detection, panel hit-testing, calibration capture
  mode. Reads `AppSettings.shared` live every frame.
- [Pointer.swift](Sources/Gatecaster/Pointer.swift) — Quartz output: cursor
  move/click/drag, phase-tagged scroll, keystrokes, cursor warp-back.
- [GestureSynth.swift](Sources/Gatecaster/GestureSynth.swift) — config-driven
  magnify/rotate/swipe wrapper over GestureKit.
- [AppSettings.swift](Sources/Gatecaster/AppSettings.swift) — **the single source
  of truth** for all tunables, modes, and calibration. Persisted to
  `~/v17ut-settings.json` (the gesture field recipe lives in `~/v17ut-gesture.json`;
  both versioned/auto-migrating). Engine reads it live; SwiftUI binds to it.
- [main.swift](Sources/Gatecaster/main.swift) — `NSApplication` accessory app:
  menu-bar item, wires the Engine's callbacks (`onShowKeyboard`,
  `onNotificationCenter`, `onCalibrationTap`, `isOverPanel`, …) to the UI, owns
  display selection + hotplug recovery.

UI / supporting files: [SettingsView.swift](Sources/Gatecaster/SettingsView.swift)
(System-Settings-style sidebar), [Keyboard.swift](Sources/Gatecaster/Keyboard.swift)
(on-screen keyboard, 6 keycap layouts + numpad), [Trackpad.swift](Sources/Gatecaster/Trackpad.swift)
(virtual trackpad), [Calibration.swift](Sources/Gatecaster/Calibration.swift)
(corner-tap mapping), [DisplayPicker.swift](Sources/Gatecaster/DisplayPicker.swift)
(numbered "which screen?" overlay), [FloatingControl.swift](Sources/Gatecaster/FloatingControl.swift)
(draggable launcher), [Capture.swift](Sources/Gatecaster/Capture.swift) (read-only
event-tap learning tool, toggled from the menu). Deck (v3 branch):
[Deck.swift](Sources/Gatecaster/Deck.swift) (model + actions, persisted to
`~/gatecaster-deck.json`), [DeckView.swift](Sources/Gatecaster/DeckView.swift).

## Non-obvious constraints (read before touching the Engine or GestureKit)

These are hard-won; see [docs/INTERNALS.md](docs/INTERNALS.md) §4.7 for the full story.

- **Animated pinch/rotate recipe:** build the gesture from a *real mouse event*
  retyped to `type=29` (NOT `CGEventCreate(NULL)`, which AppKit ignores); set the
  magic fields (`50=248`, `101=4`, subtype `110`, value in doubles `113/114/116/118`,
  phase in `132`); value lives in field `113` (the `type=30`/`124` form is an echo
  AppKit ignores).
- **Never emit scroll-wheel events during a pinch/rotate** — macOS reclassifies
  the whole sequence as a scroll and silently drops the gesture. This is why the
  two-finger intent latch commits to ONE gesture for the whole sequence.
- **Always send the `ended` phase for every gesture you begin**, including when a
  two-finger gesture drops to *one* finger. A dangling open gesture **wedges the
  macOS recognizer system-wide** (touchscreen *and* built-in trackpad) until the
  process exits. Guard every transition out of a gesture state.
- **3-finger Spaces/Mission-Control swipe cannot be animated** via CGEvents (no
  event field carries per-finger count — that needs a virtual HID device). It's
  done with Ctrl+arrow keystrokes instead. Same for Notification Center (clicks
  the menu-bar clock) — no public trigger exists.
- **No `nextEvent` tracking loops** (e.g. for panel resize) — they switch the run
  loop into event-tracking mode, pausing the HID callbacks that generate our
  synthetic drags, deadlocking touch input. Use event-driven (mouseDown/Dragged/Up)
  handlers instead.
- **Palm rejection is behavioral** (`Engine.filterPalms`) because the panel
  reports no contact area — sticky per contact id, cluster + panel-guard heuristics.
- **Display persistence is by UUID**, not `CGDirectDisplayID` (which isn't stable
  across reboots/reconnects). Calibration is panel-raw, so it's display-independent.

## Docs

[docs/INTERNALS.md](docs/INTERNALS.md) is the deep technical reference (HID protocol,
the full gesture-synthesis saga, field maps). [docs/JOURNEY.md](docs/JOURNEY.md) is
the reverse-engineering narrative. [docs/DECK_PLAN.md](docs/DECK_PLAN.md) is the
phased plan for the Deck (current `v3-deck-poc` work).

## Conventions

- Comment density is high and explanatory — match it; comments explain *why*
  (which hard-won constraint a line guards against), not *what*.
- All behavior changes flow through `AppSettings` so the Engine, UI, and disk stay
  in sync; don't add ad-hoc state outside it.
- Settings/config files are versioned and auto-migrating — bump and migrate rather
  than break an on-disk format (a stale config silently fed the wrong gesture
  recipe for a long time during development).
- Commit messages: no `Co-Authored-By` lines.
