# Gatecaster — Developer API

How to build on Gatecaster, the user-space macOS driver for HID touchscreens
(currently the Visual Beat V17UT / ELAN `04F3:5512`).

> **Status:** the in-process hooks below exist today. The out-of-process
> multi-touch API (§3) is **implemented** — see [TouchAPI.swift](../Sources/Gatecaster/TouchAPI.swift)
> and the standalone guide [TOUCH_API.md](TOUCH_API.md).

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

## 3. Public multi-touch API

Lets external apps consume normalized touches + recognized gestures, and (for
games / kiosks) tell Gatecaster to stop injecting system input. The full
client-facing reference with examples is in [TOUCH_API.md](TOUCH_API.md); this
section is the protocol-at-a-glance for someone working on the driver.

**Transport:** Unix-domain stream socket `~/Library/Application Support/Gatecaster/api.sock`
(local-only by construction; no network). Newline-delimited JSON (NDJSON), one
object per line, both directions. Multiple simultaneous clients are supported;
each gets an independent subscription + suppress state.

**On connect — server `hello`** (advertises protocol version, capabilities, and
the geometry a client needs to map normalized → screen coordinates):
```json
{"v":1,"type":"hello","ready":true,"caps":["fingers","rawFingers","gestures","suppress"],
 "screen":{"x":0,"y":0,"w":1920,"h":1080},
 "panel":{"xMin":120,"xMax":3960,"yMin":80,"yMax":2240}}
```
`ready` is `false` if you connect before Gatecaster has resolved its display (the
`screen`/`panel` bounds are then still zero and not yet trustworthy); reconnect, or
ignore the geometry until you see a `ready:true` — finger `sx`/`sy` are always live
regardless.

**Finger frames** (~panel report rate, only while subscribed):
```json
{"v":1,"type":"fingers","t":1717000000.123,"dropped":0,"fingers":[
  {"id":3,"x":0.412,"y":0.875,"sx":791.0,"sy":945.0,"phase":"moved","palm":false}
]}
```
- `x`/`y` — normalized 0–1 in *calibrated* panel space.
- `sx`/`sy` — screen pixels (already mapped through calibration + active display).
- `phase` ∈ `began` / `moved` / `ended` / `cancelled` (cancelled = the contact was
  dropped by palm rejection or a reset mid-touch, not lifted by the user).
- `palm` — only meaningful on the `rawFingers` channel; `true` for a contact palm
  rejection filtered out. On the `fingers` channel it is always `false`.
- `dropped` — count of frames discarded for this client (slow consumer) since the
  last delivered frame; `0` in the normal case.

Two finger channels: **`fingers`** = post-palm-rejection contacts (what the pointer
sees); **`rawFingers`** = every contact, each flagged with `palm`, for apps doing
their own rejection.

**Gesture events** (after the Engine's intent latch decides), only while subscribed
to `gestures`:
```json
{"v":1,"type":"gesture","t":...,"gesture":"pinch","value":0.034,"phase":"changed"}
{"v":1,"type":"gesture","t":...,"gesture":"rotate","value":-1.2,"phase":"changed"}
{"v":1,"type":"gesture","t":...,"gesture":"scroll","dx":0.0,"dy":-13.5,"phase":"changed"}
{"v":1,"type":"gesture","t":...,"gesture":"swipe","direction":"left","fingers":3}
```
`pinch`, `rotate`, and `scroll` carry a `phase` (`began`/`changed`/`ended`) so you can
bracket an animation; `swipe` is a one-shot (no `phase`). Clients MUST tolerate unknown
`gesture` values and unknown fields (forward-compat).

**Client → server commands** (NDJSON, one per line):
```json
{"subscribe":["fingers","gestures"]}          // replaces the current subscription set
{"suppress":["input","gestures","edges"]}     // the app picks what to mute
{"suppress":true}                             // shorthand for all categories
{"suppress":false}                            // clear (also: [] )
```
Suppress categories — *the app decides* which to mute:
- `input` — pointer move / click / drag / scroll / keystroke injection.
- `gestures` — synthesized pinch / rotate trackpad events.
- `edges` — edge-pull triggers (on-screen keyboard, Notification Center).

**Suppress is connection-scoped and self-healing:** the live suppression is the
union of all connected clients' masks; when a client disconnects (or the socket
drops) its contribution is removed automatically — a crashed client can never
leave the Mac with input wedged off. No TTL/heartbeat needed because the socket
close is the lease.

**Versioning:** every message carries `"v"`. `v` bumps only on a *breaking* change
(field removal or changed semantics); additive fields are backward-compatible and
do NOT bump it, so clients must ignore unknown fields.

**Backpressure:** frames are encoded once and written non-blocking to each client.
A client that can't keep up has frames dropped (never the driver blocking) and is
told how many via the next frame's `dropped`.

A heavier alternative (DriverKit virtual HID trackpad) would give apps native
`NSTouch` events and unlock the animated 3-finger Spaces swipe — that's the
long-term path, documented in `INTERNALS.md` §8.

## 4. Reusing the driver for other panels

The ELAN wake handshake + report layout live in `Hid.swift` / `Engine.onReport`.
To support another HID touchscreen: parse its report descriptor for the
digitizer usage fields (contact count, tip, X/Y + logical maxima) instead of the
hard-coded 11-byte stride, and add its enable quirk if it has one. Everything
downstream of `Contact {id,x,y}` is panel-agnostic.
