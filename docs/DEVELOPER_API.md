# Gatecaster — Developer API

How to build on Gatecaster, the user-space macOS driver for HID touchscreens
(currently the Visual Beat V17UT / ELAN `04F3:5512`).

> **Status:** the in-process hooks below exist today. The out-of-process
> multi-touch API (§3) is a **draft spec** — designed, not yet implemented.
> See `INTERNALS.md` §8 (Roadmap).

---

## 1. Architecture (what you're tapping into)

```
HID panel ──▶ HidTouch (IOHIDManager, ELAN wake handshake)
                 │  raw Report-ID-1 packets
                 ▼
              Engine (state machine: tap/drag/scroll/pinch/rotate/swipe,
                 │    calibration-aware coordinate mapping, edge gestures)
                 ▼
   ┌─────────────┼──────────────────┐
 Pointer       GestureSynth      callbacks → app layer
 (CGEvent      (synth trackpad   (keyboard, Notification Center,
  mouse/scroll/ magnify/rotate,   calibration taps, panel hit-test)
  keystrokes)   type-29 recipe)
```

Everything runs on the main run loop; the Engine is not thread-safe by design.

## 2. In-process integration points (exist today)

### Engine callbacks
| Hook | Signature | Fired when |
|---|---|---|
| `onShowKeyboard` | `(() -> Void)?` | 3-finger dwell + pull up from the bottom edge |
| `onNotificationCenter` | `(() -> Void)?` | 2-finger dwell + pull in from the right edge |
| `onCalibrationTap` | `((Int, Int) -> Void)?` | a raw tap while `calibrating == true` |
| `isOverPanel` | `((CGPoint) -> Bool)?` | queried at every one-finger touchdown |

`isOverPanel` is how floating UI participates in the input pipeline: return
`true` for a CG screen point and the Engine produces a **real left-drag** there
(even in iPad/one-finger-scroll mode) instead of scroll — which is what makes a
non-activating `NSPanel` with `isMovableByWindowBackground = true` draggable by
touch. To make your own touch-draggable panel: create the panel, add its frame to
the host app's `pointIsOverPanel` check (AppKit→CG flip:
`cgY = primaryScreenHeight − appKitMaxY`), done.

### Settings file (read/write, hot-reloaded on relaunch)
`~/v17ut-settings.json` — flat JSON of every tunable. Notable keys:
`gestureMode` (`off`/`smooth`/`shortcuts` — the last is shown as **Legacy** in
the UI), `threeFingerEnabled`, `ipadMode`, `naturalScroll`, `rightClickMode`,
`calXMin/calXMax/calYMin/calYMax` (raw panel → screen mapping), `displayUUID`
(stable display identity), `pageSwipePts`, `edgeDwellMS`, `edgePull`,
`keyboardOpacity`, `showFloatingControl`, plus all timing constants. Edits apply
on next launch; the app autosaves (400 ms debounce).

### Gesture synthesis (GestureKit)
`gk_post_fields(type, intFields, intValues, n, dblFields, dblValues, m)` posts a
CGEvent with arbitrary private fields. The proven trackpad recipe (magnify /
rotate) is hardcoded in `GestureSynth`: type 29, ints `50=248`, `101=4`,
subtype `110` (8 = magnify, 5 = rotate), value in doubles `113/114/116/118`,
phase in `132` (1 began / 2 changed / 4 ended). **Always send the `ended` phase**
— an unbalanced gesture wedges macOS's recognizer system-wide.

## 3. Planned public multi-touch API (draft spec)

Goal: let external apps consume normalized touches + recognized gestures.

**Transport:** Unix-domain socket `~/Library/Application Support/Gatecaster/api.sock`
(local-only by construction; no network). Newline-delimited JSON (NDJSON).

**Stream frames** (~panel report rate):
```json
{"v":1,"t":1717000000.123,"fingers":[
  {"id":3,"x":0.412,"y":0.875,"phase":"moved"}
],"n":1}
```
`x`/`y` normalized 0–1 in *calibrated* panel space; `phase` ∈ began/moved/ended.

**Gesture events** (after the Engine's latch decides):
```json
{"v":1,"t":...,"gesture":"pinch","value":0.034,"phase":"changed"}
{"v":1,"t":...,"gesture":"swipe3","direction":"left"}
```

**Client → server commands:**
```json
{"subscribe":["fingers","gestures"]}
{"suppress":true}        // ask Gatecaster not to inject system input while
                         // the client consumes touches (game/kiosk mode)
```

**Versioning:** every message carries `"v"`; breaking changes bump it.
**Implementation sketch:** a `FileHandle`/`NWListener` socket server fed from
`Engine.handle()` (one JSON encode per report), `suppress` checked at the top of
the state machine. Estimated at ~150 lines; see roadmap.

A heavier alternative (DriverKit virtual HID trackpad) would give apps native
`NSTouch` events and unlock the animated 3-finger Spaces swipe — that's the
long-term path, documented in `INTERNALS.md` §8.

## 4. Reusing the driver for other panels

The ELAN wake handshake + report layout live in `Hid.swift` / `Engine.onReport`.
To support another HID touchscreen: parse its report descriptor for the
digitizer usage fields (contact count, tip, X/Y + logical maxima) instead of the
hard-coded 11-byte stride, and add its enable quirk if it has one. Everything
downstream of `Contact {id,x,y}` is panel-agnostic.
