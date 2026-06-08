# Gatecaster — native macOS touchscreen driver (Swift)

*(formerly "V17UT Touch"; the hardware it drives is the Visual Beat V17UT)*

A menu-bar app that enables the Visual Beat V17UT's 10-finger digitizer and maps
it to native macOS input — pointer, click, drag, right-click, two-finger
**momentum scroll**, and **continuous pinch-zoom + rotate** via our own
clean-room gesture synthesis. Includes a touch-friendly settings
window, corner-tap calibration, and fully tunable timing.

## Layout

```
v17ut-touch/
  Package.swift
  Resources/               # Info.plist + app icon (bundle assets)
  scripts/                 # make-app.sh (bundle), release.sh (sign+notarize)
  Sources/
    GestureKit/            # our clean-room trackpad-gesture synth (C)
      include/GestureKit.h
      GestureKit.c         # gk_post_fields + capture dump
    Gatecaster/            # the app (Swift)
      Hid.swift            # IOHIDManager: open + enable digitizer + read (.commonModes)
      Pointer.swift        # Quartz cursor / click / phase-tagged scroll / warp
      Engine.swift         # gesture state machine + palm rejection (reads AppSettings live)
      GestureSynth.swift   # config-driven magnify/rotate/swipe synthesis
      Capture.swift        # read-only event-tap learning tool
      AppSettings.swift    # persisted tunables / modes / calibration (source of truth)
      SettingsView.swift   # touch-friendly SwiftUI settings (General/Pointer/…)
      GlassStyle.swift     # GlassHostingView + gcActiveBlur (always-live panel backdrop)
      Calibration.swift    # full-screen corner-tap calibration
      DisplayPicker.swift  # numbered "which screen?" overlay + KeyableWindow
      Keyboard.swift       # on-screen touch keyboard + iOS-style key feedback
      Trackpad.swift       # virtual trackpad panel + edge-zone hints
      Deck.swift           # deck model + JSON store + action runner (v3 PoC)
      DeckView.swift       # Stream Deck-style control surface (v3 PoC)
      FloatingControl.swift# draggable touch launcher + collapsed edge tab
      main.swift           # menu-bar app; hosts all panels & windows (single-instance)
```

## Requirements

macOS 13+ (the settings UI uses recent SwiftUI). Build with Xcode 15+ or a
matching Swift toolchain.

## Build

```bash
swift build -c release            # bare binary at .build/release/Gatecaster
scripts/make-app.sh               # proper app bundle at dist/Gatecaster.app
```

Or open `Package.swift` in Xcode and Run (scheme: Gatecaster).

> **Start at login** (Settings -> Pointer & Scroll -> General) uses
> `SMAppService` and only works when running as `Gatecaster.app` --
> the bare swift-build binary has no bundle identity to register.

## Release (signed + notarized DMG)

One-time: store notary credentials —
`xcrun notarytool store-credentials gatecaster --apple-id YOU --team-id TEAMID`

```bash
IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=gatecaster \
scripts/release.sh                # → dist/Gatecaster.dmg, notarized + stapled
```

## Permissions

The app synthesizes input and reads HID, so grant the **binary** (or Terminal,
if you launch it from there) these in System Settings → Privacy & Security:

- **Accessibility** — required to post mouse/scroll/gesture events.
- **Input Monitoring** — required to read the touchscreen HID reports.

After granting, relaunch.

## Run

```
.build/release/Gatecaster      # or: open dist/Gatecaster.app
```

A 👆 icon appears in the menu bar. Open it and pick which display the
touchscreen maps to (so the cursor lands on the V17UT, not your main screen).

> Signed builds keep TCC permissions across rebuilds; ad-hoc builds change
> identity each time and re-prompt. `make-app.sh` auto-selects a Developer ID /
> Apple Development certificate by hash (override with `SIGN_IDENTITY`). A
> *revoked* certificate makes macOS flag the app as malware — delete it from
> Keychain Access.

## Gestures & defaults

- 1 finger: move; quick tap = left click; drag = drag.
- 2 fingers: momentum scroll (continues if you drop to one finger), pinch-zoom,
  rotate, horizontal flick = Safari back/forward; two-finger tap = right click.
- 3 fingers: Mission Control / Spaces (Ctrl+arrow).

Default right-click is **two-finger tap** (changeable). Pinch/rotate use the
clean-room `GestureKit` synth (the working, no-crash recipe — the old IOHID graft
is gone).

## Settings & calibration

Open the 👆 menu → **Settings…** for a touch-friendly window:

- **General:** start-at-login (`SMAppService`), a live **Permissions** checklist
  (Accessibility + Input Monitoring, with Grant / Open-Settings / Relaunch),
  **Blur panel backgrounds** toggle (off = flat translucent, cheaper), and
  touch-controller status + Reconnect.
- **Pointer & scroll:** one-finger (iPad) scroll *(default on)*, natural scroll,
  inertia, return-cursor-after-touch, verbose logging, plus **palm rejection**
  (cluster + typing-guard heuristics, with a palm-size slider).
- **Gestures:** engine = **Off / Smooth / Legacy**. Smooth = animated pinch &
  rotate via synthesized trackpad events; Legacy = keyboard shortcuts (⌘±, ⌘L/R,
  ⌘[ ]) that work everywhere, no trackpad-event code involved.
  Plus a **Three-finger gestures** toggle (Mission Control / App Exposé / switch
  desktops). A live gesture map shows what each gesture does in the chosen mode.
- **Right-click:** Touch & hold / Two-finger tap / Either.
- **Keyboard & edge gestures:** on-screen keyboard (transparency configurable);
  rest three fingers at the bottom then pull up to open it; rest two fingers at
  the right edge then pull in for Notification Center. The dwell time and pull
  distance are tunable. Also a **floating control** — a draggable 160×160 launcher
  (Keys / Pad / engine / Settings; collapses to an edge tab) — and a **virtual
  trackpad** panel: relative cursor movement, tap-to-click, two-finger scroll
  with inertia (sensitivity tunable). Keyboard and trackpad are draggable and
  **resizable** via the corner bean (full panels drag from the top bar only);
  the keyboard has an optional (default-on) esc/F1–F12 row with sticky ⌘ ⌥ ⌃ fn
  modifiers, plus iOS-style **key press feedback** (highlight + dip) and a
  **key-pop callout** above letter keys. There's also a **Deck** — a Stream
  Deck-style control surface (v3 PoC; see DECK_PLAN.md).
- **Display:** **Choose Touchscreen Display…** shows a big number on each screen
  — tap the number on your touchscreen or press that number key. Then
  **Calibrate Touchscreen…** — tap the four corner targets to map the panel.
- **Advanced — fine-tune timing:** every feel constant (tap/hold, drag settle,
  one- and two-finger inertia, friction, flick thresholds, gesture commit/bias,
  dropout-robustness windows, cursor-return delay), each with an ⓘ explanation.

Settings persist to `~/v17ut-settings.json`; the deck layout lives in
`~/gatecaster-deck.json` (exportable as a portable `.gatedeck` file).

## Auto-start on login

Settings → General → **Start at login** (uses `SMAppService`; requires the
`.app` bundle, not the bare binary).
