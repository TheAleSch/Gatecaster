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
  Sources/
    GestureKit/            # our clean-room trackpad-gesture synth (C)
      include/GestureKit.h
      GestureKit.c         # gk_post_fields + capture dump
    v17ut/                 # the app (Swift)
      Hid.swift            # IOHIDManager: open + enable digitizer + read
      Pointer.swift        # Quartz cursor / click / phase-tagged scroll / warp
      Engine.swift         # gesture state machine (reads AppSettings live)
      GestureSynth.swift   # config-driven magnify/rotate/swipe synthesis
      Capture.swift        # read-only event-tap learning tool
      AppSettings.swift    # persisted tunables / modes / calibration (source of truth)
      SettingsView.swift   # touch-friendly SwiftUI settings window
      Calibration.swift    # full-screen corner-tap calibration
      DisplayPicker.swift  # numbered "which screen?" overlay + KeyableWindow
      Keyboard.swift       # on-screen touch keyboard (non-activating panel)
      FloatingControl.swift# draggable touch launcher + collapsed edge tab
      main.swift           # menu-bar app; hosts settings / picker / calibration / keyboard / launcher
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
.build/release/v17ut
```

A 👆 icon appears in the menu bar. Open it and pick which display the
touchscreen maps to (so the cursor lands on the V17UT, not your main screen).

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

- **Pointer & scroll:** one-finger (iPad) scroll *(default on)*, natural scroll,
  inertia, return-cursor-after-touch, verbose logging.
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
  **resizable** via the corner bean; the keyboard has an optional (default-on)
  esc/F1–F12 row with sticky ⌘ ⌥ ⌃ fn modifiers.
- **Display:** **Choose Touchscreen Display…** shows a big number on each screen
  — tap the number on your touchscreen or press that number key. Then
  **Calibrate Touchscreen…** — tap the four corner targets to map the panel.
- **Advanced — fine-tune timing:** every feel constant (tap/hold, drag settle,
  one- and two-finger inertia, friction, flick thresholds, gesture commit/bias,
  dropout-robustness windows, cursor-return delay), each with an ⓘ explanation.

Settings persist to `~/v17ut-settings.json`; the gesture field recipe lives in
`~/v17ut-gesture.json` (auto-migrates on version change).

## Auto-start on login (optional)

Once it works, add it as a Login Item: System Settings → General → Login Items →
+ → select the `v17ut` binary (or wrap it in a small .app bundle).
