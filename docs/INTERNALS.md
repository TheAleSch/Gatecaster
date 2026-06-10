# Gatecaster — making a cheap 4K touchscreen work like a Mac trackpad

*Reverse-engineering touch and gestures for the Visual Beat V17UT (ELAN
controller) on macOS — from "touch does nothing" to pointer, momentum scroll,
and native pinch-to-zoom. The app/project is named **Gatecaster**; the developer
integration surface is described in `DEVELOPER_API.md`.*

> Status: working notes / field reference. Everything here was learned by
> observation on the author's own hardware. The gesture-synthesis parts rely on
> **private, undocumented** macOS event fields and can change between OS
> releases. Use at your own risk.

---

## 0. Plain-English summary (read this first)

**The situation.** You can buy a cheap 4K touchscreen that works perfectly on
Windows. Plug it into a Mac and nothing happens — no cursor, no taps, no
pinch-to-zoom. This project makes it work like a Mac trackpad, and figures out
*why* macOS ignored it.

**Two separate problems had to be solved:**

1. **Getting the touches at all.** The screen's chip (made by ELAN) ships with
   its multi-finger mode *asleep*. On Windows, the driver whispers a secret
   "wake up" message to the screen at startup; macOS never does, so the screen
   only ever sends a basic single-finger "mouse" signal that macOS half-ignores.
   The fix is one line: ask the screen for a specific info report (`feature
   report 0x44`), which is the wake-up handshake. After that, the screen streams
   all 10 fingers.

2. **Turning finger movements into Mac actions.** macOS doesn't automatically
   turn "two fingers on a screen" into "scroll" or "zoom." We read the raw
   finger positions and *create* the matching Mac events ourselves:
   - Move/tap/drag and scroll: easy — macOS has official ways to fake those.
   - **Pinch-to-zoom and rotate: very hard.** macOS has *no official way* to fake
     a gesture. Apple's own docs, the authors of every reference tool, and our
     own crashes all suggested it was impossible on modern macOS. It isn't — we
     found the trick (see below) and **pinch-zoom now works with real fingers.**

**The one trick that unlocked zoom/rotate.** To fake a gesture you must:
(a) start from a *real* fake mouse event and then change its "type" to gesture —
starting from a blank event doesn't work; (b) set a few specific hidden fields;
and (c) **never send a scroll event at the same time** — if you do, macOS decides
"oh, this is a scroll" and throws the zoom away. We were doing all three wrong
for a long time (see the journey doc, `JOURNEY.md`).

**What works vs. what's still blocked:**

| Feature | Status |
|---|---|
| Cursor, tap, drag, right-click (press-hold) | ✅ works |
| One-/two-finger scroll with momentum | ✅ works |
| **Pinch-to-zoom (animated, continuous)** | ✅ **works with fingers** |
| Rotate | ✅ same mechanism as zoom |
| 3-finger swipe → Mission Control / Spaces | ✅ works (via keyboard shortcuts) |
| 3-finger swipe *with the finger-following animation* | ❌ blocked (needs finger-count data macOS won't let us fake) |

---

## 1. The problem

The Visual Beat V17UT is a 17.3" 4K portable touchscreen built around an **ELAN**
USB touch controller (USB `VID 0x04F3`, `PID 0x5512`). On Windows it's a normal
10-point touchscreen. On macOS, touch appears to do *nothing*: no cursor, no
taps, no gestures.

The reason isn't that macOS can't see it — it's that macOS reads the panel's USB
HID reports but never translates "digitizer" contacts into pointer/gesture
events the way Windows does. The whole project is about bridging that gap in
user space (no kernel extension).

---

## 2. Talking to the panel (USB HID)

### 2.1 Enumerate

The panel shows up as a standard USB HID device. In Python with `hidapi`:

```python
import hid
for d in hid.enumerate():
    print(hex(d['vendor_id']), hex(d['product_id']),
          hex(d.get('usage_page', 0)), d.get('product_string'))
```

For the V17UT this is a single HID interface (`0x04F3` / `0x5512`) whose report
descriptor contains *several* top-level collections:

| Report ID | Collection                | Purpose                                   |
|-----------|---------------------------|-------------------------------------------|
| 1         | Digitizer / Touch Screen  | the real 10-finger multi-touch report     |
| 7         | Mouse (absolute pointer)  | single-touch compatibility                |
| 9         | Keyboard                  | firmware "gesture → keystroke" fallback   |
| 10 (0x0A) | Feature: Contact Count Max| reports max contacts (= 10)               |
| 68 (0x44) | Feature: vendor 256-byte  | MS "certification" blob (`usagePage 0xFF00`, `usage 0xC5`) |
| 2 / 3     | Vendor in/out             | ELAN private channel                      |

Logical ranges from the descriptor: **X 0..2624, Y 0..1856** (physical ~194mm ×
~344mm — the panel's native axes).

### 2.2 The key discovery: the panel hides multi-touch until you ask

Out of the box, touching the panel only emits **Report ID 7** (an absolute-mouse
report) and, for two-finger gestures, **Report ID 9** (canned keyboard shortcuts
like ⌘+/⌘−). The 10-finger **Report ID 1** digitizer never fires.

It turns out the firmware gates the digitizer behind a feature-report handshake
that Windows performs at enumeration. Replaying it on macOS flips the panel into
multi-touch:

```python
d = hid.Device(0x04f3, 0x5512)
d.get_feature_report(0x0a, 4)     # Contact Count Maximum
d.get_feature_report(0x44, 257)   # 256-byte MS certification blob -> enables digitizer
# Report ID 1 packets now stream on every touch.
```

That single `GET_FEATURE 0x44` is the whole trick. No vendor command, no Windows
capture needed.

### 2.3 Report ID 1 format

Each report is `0x01` followed by up to 10 contact slots of **11 bytes** each,
then scan-time + contact-count at the tail:

```
byte 0        report id (0x01)
per finger k (base = 1 + k*11):
  base+0      bit0 = tip switch (finger down); bits2..7 = contact id
  base+1      width   (unused)
  base+2      height  (unused)
  base+3..4   X  uint16 LE   (0..2624)   <- used
  base+5..6   X  uint16 LE   (duplicate, firmware quirk)
  base+7..8   Y  uint16 LE   (0..1856)   <- used
  base+9..10  Y  uint16 LE   (duplicate)
```

Decode in Python:

```python
def contacts(data):
    out = []
    if not data or data[0] != 0x01:
        return out
    for k in range(10):
        b = 1 + k*11
        if b+9 > len(data): break
        if not (data[b] & 1): continue            # finger up
        cid = (data[b] >> 2) & 0x3f
        x = data[b+3] | (data[b+4] << 8)
        y = data[b+7] | (data[b+8] << 8)
        out.append((cid, x, y))
    return out
```

---

## 3. Turning touches into macOS input (the easy, public part)

These use documented Quartz APIs and never crash.

**Pointer / click / drag** — map panel (x,y) to the target display rectangle and
post mouse events:

```python
# fx = x/2624, fy = y/1856 ; screen = bounds.origin + (fx,fy)*bounds.size
CGEventCreateMouseEvent(None, kCGEventMouseMoved, (sx, sy), kCGMouseButtonLeft)
```

Quick tap → `LeftMouseDown`+`Up`. Move past a small slop → drag. Hold still ~0.5s
→ right click.

**Momentum scroll** — the native trackpad feel comes from tagging scroll events
with *phase* fields:

```
kCGScrollWheelEventScrollPhase   (field 99)  : 1 began / 2 changed / 4 ended
kCGScrollWheelEventMomentumPhase (field 123) : 1 begin / 2 continue / 3 end
```

During the drag emit `Began…Changed…Ended`; on release, measure the finger's
**peak** velocity over the last ~60 ms and replay decaying `Momentum begin…
continue…end` events with friction. Accumulate sub-pixel deltas so fast polling
doesn't truncate small moves to zero.

---

## 4. Gestures: the hard, private part

macOS reserves smooth pinch/rotate for **gesture events**, which have no public
construction API. To learn the format we tapped real trackpad events read-only
(`CGEvent.tapCreate(..., .listenOnly, ...)`) for the gesture event types and
dumped every CGEvent field with `CGEventGetIntegerValueField` /
`...DoubleValueField` over ids 0..255.

### 4.1 Two events per gesture

A single trackpad pinch produces a continuous stream of:

- **`type = 29`** — *NSEventTypeGesture*, the gesture "container" / phase track.
- **`type = 30`** — *NSEventTypeMagnify*, what apps receive in `-magnifyWithEvent:`.

(Other gesture types observed in the family: `18` rotate, `31` swipe, `32` smart
magnify, `19/20` begin/end gesture.)

Constant device/window noise fields seen on every event (ignore them):
`39, 40, 45, 50, 53, 55, 58, 85, 87, 101, 107, 169`.

### 4.2 Magnify field map

On the **type = 30** magnify event:

| Field | Meaning                                            |
|-------|----------------------------------------------------|
| `int[110]` = 23 | event subkind (magnify)                  |
| `int[123]` = 2  | constant                                 |
| `int[132]`, `int[134]` | phase: 1 began / 2 changed / 4 ended |
| `int[135]` | magnification delta as **float32 bit-pattern**  |
| `dbl[124]` | magnification delta as **double**               |
| `dbl[126]` | \|magnification\|                               |
| `int[136]`=1, `int[138]`=3, `int[165]`=2 | constants          |

On the **type = 29** gesture container during a magnify, the same value shows up
differently:

| Field | Meaning                                            |
|-------|----------------------------------------------------|
| `int[110]` = 32 | gesture kind = magnify                   |
| `int[132]` | phase 1 / 2 / 4                                 |
| `int[144]` | 5 at begin, 1 thereafter                        |
| `int[123]`, `int[165]` | magnification delta as float32 bits |
| `dbl[119]`, `dbl[139]`, `dbl[148]` | magnification delta as double |

**Worked example.** A "changed" frame had `int[123] = 1013678080`. In hex that's
`0x3C6C0000`; as IEEE-754 float32 that's `+0.01440`, matching the observed
`dbl[119] = 0.014374`. So the integer field is literally the float bits of the
per-frame magnification delta. The decode of `0xBC2E0000 → −0.0106` similarly
matched a pinch-in frame on the type-30 event.

### 4.3 Begin / end framing

- **begin**: `int[132]=1`, `int[144]=5`, no value yet.
- **changed**: `int[132]=2`, value present, streamed per frame.
- **end**: `int[132]=4`, `int[144]=1`, no value. The lift frame also carries a
  small negative double across `dbl[113..118]` — the release/inertia velocity.

### 4.4 Synthesizing it

The naïve historical approach (circa 2010, Calftrail's `TouchEvents`) builds a
`type=29` event by serializing a CGEvent, stripping its trailing gesture-field
bytes, and grafting a hand-built IOHID payload (queue element + digitizer "hand"
collection + vendor token + tagged fields) via `CGEventCreateFromData`. On modern
macOS this **crashes WindowServer** (logs you out) because the base event's
serialized layout has changed and the graft lands misaligned.

The modern approach is far simpler and safer: a magnify is just a *normal*
`type=30` CGEvent (~316 bytes). Create one, set the fields above, and post it —
no byte surgery:

```c
CGEventRef e = CGEventCreate(NULL);
CGEventSetType(e, (CGEventType)30);          // NSEventTypeMagnify
CGEventSetIntegerValueField(e, 110, 23);
CGEventSetIntegerValueField(e, 123, 2);
CGEventSetIntegerValueField(e, 132, phase);  // 1/2/4
CGEventSetIntegerValueField(e, 134, phase);
CGEventSetIntegerValueField(e, 136, 1);
CGEventSetIntegerValueField(e, 138, 3);
CGEventSetIntegerValueField(e, 165, 2);
float f = (float)delta; uint32_t bits; memcpy(&bits, &f, 4);
CGEventSetIntegerValueField(e, 135, (int64_t)bits);
CGEventSetDoubleValueField(e, 124, delta);
CGEventSetDoubleValueField(e, 126, fabs(delta));
CGEventPost(kCGHIDEventTap, e);
CFRelease(e);
```

Drive it from the panel's two-finger stream: per frame, `delta = (dist −
lastDist) / lastDist`, sending `phase=1` on the first frame, `2` thereafter, and
a final `phase=4` with `delta=0` on release. Rotate (`type=18`) and swipe
(`type=31`) follow the same pattern with their own value fields, still to be
fully mapped.

**Important negative result.** Posting a lone, well-formed `type=30` magnify
event does **not** make apps zoom (it's accepted but ignored — no crash). In
captures, every real `type=30` is accompanied by the `type=29` gesture-phase
container stream (`int[110]=32`, phase in `int[132]`, value in `dbl[119]`).
AppKit's `-magnifyWithEvent:` appears to fire only when that gesture phase track
is present to "arm" it. So a working synth must emit the **pair**: a `type=29`
begin → changed… → end sequence *interleaved with* the `type=30` magnify events,
not the magnify events alone. This remains the open item.

---

## 4.6 Why synthesized magnify/swipe never animate (the wall)

Capturing many gestures reveals that the `type=29` events carry a gesture-kind in
`int[110]`:

| `int[110]` | meaning (observed)                          |
|------------|---------------------------------------------|
| 6          | gesture begin (`int[132]=128` = may-begin)  |
| 8          | scale/progress sample                        |
| 4          | translation: `dbl[119]=x, dbl[120]=y`        |
| 32         | magnify gesture container                    |
| 23         | (on the `type=30` magnify event) subkind     |
| 59         | idle / between gestures                       |

The decisive observation: these `type=29` events are the **output of macOS's
gesture recognizer**, produced *after* it has already classified the raw finger
motion (begin → deltas → end). The recognizer reads the **multitouch hardware
directly**; there is no input path from synthesized CGEvents back into it.

That is why posting a correct `type=30` magnify (verified fields, correct sign
flag) — even paired with a `type=29` envelope — does nothing in apps: we are
replaying the recognizer's *results*, not feeding its *input*. AppKit's
`-magnifyWithEvent:` only fires from recognizer state that the real touch device
updates.

### Verified gesture map (AppKit-labeled capture)

Bridging each tapped CGEvent back through `NSEvent(cgEvent:)` makes AppKit name it,
which removes all guesswork. Result: **every gesture is `type=29`
(NSEventTypeGesture)**, distinguished by a subtype in field **`110`**, with the
gesture value AppKit actually reads in the noted field:

| `110` | gesture        | value fields                         | AppKit read |
|-------|----------------|--------------------------------------|-------------|
| 4     | pan/translation| x=`119`, y=`120` (mirror 139/140), float-bits 123/165 | — |
| 5     | **rotate**     | degrees in `113` (mirror 114/116/118), float-bits 115/117/164 | `rotation=-0.71` |
| 6     | gesture container (begin/end/momentum) | phase in `132` | — |
| 8     | **magnify**    | magnification in `113` (mirror 114/116/118), float-bits 115/117/164 | `magnification=0.015` |

Phase lives in field `132` for all of them. Crucially, AppKit's
`NSEvent.magnification` / `.rotation` **successfully read field `113`** off these
`type=29` subtype-8/5 events — whereas the `type=30` "magnify" events return
`magnification=0.0000` through the bridge. So the earlier `type=30`/field-`124`
encoding was a secondary echo AppKit ignores; **the real, honored event is
`type=29` with the value in field `113`.** Real gestures are also bracketed by
`110=6` container events (`132` = mayBegin `128` → … → ended), which likely arm
the recognizer.

### Correction, after researching the original authors

It is **not** simply impossible — it was possible on older macOS. The reference
implementation (Calftrail `TouchEvents.c`, `tl_CGEventCreateFromGesture`) builds
a **`type=29` (NSEventTypeGesture, flags=256)** event and grafts an IOHID payload
via `CGEventCreateFromData`, with these gesture fields:

| field | meaning                                   |
|-------|-------------------------------------------|
| `0x6E` (110) | subtype: **8 magnify, 6 scroll, 5 rotate, 0x10 swipe**, 0x0B gesture, 0x3D/0x3E begin/end |
| `0x84` (132) | gesture phase                       |
| `0x71` (113) | magnification (float)               |
| `0x72` (114) | rotation (float)                    |
| `0x73` (115) | swipe direction (int)               |

Our live captures confirm these codes exactly (`110=6` scroll with the delta in
`119`; `110=8` magnify with value near `113`).

The author, Nathan Vander Wilt, states the high-level gesture injection still
works, **but** that "trying to inject [the touch structures] seemed not to work
anymore on recent releases" — and the appended IOHID touch structures are
undocumented and change per OS version. The Hammerspoon maintainer (asmagill)
similarly could not get it working on 10.12.

That `type=29` + touch-graft is exactly what crashed WindowServer for us on
current macOS. So the honest conclusion is **historical, not absolute**:

- It worked through ~Sierra via the `type=29` gesture graft.
- On **current** macOS the required touch-structure graft destabilizes
  WindowServer (matching the author's "doesn't work on recent releases").
- A bare `type=30`/`type=29` event *without* the graft is accepted but ignored,
  because AppKit's recognizer is driven by the real multitouch hardware, not by
  field-only events.

So: animated gestures are reachable only through the touch-structure graft, which
is no longer stable on current macOS — a moving, undocumented target rather than
a permanent wall. Sources: Hammerspoon issue #1434; calftrail/Touch
`TouchSynthesis/TouchEvents.c`.

## 4.7 The working recipe (no graft) — the Touch-Up technique

The breakthrough came from reading **Touch-Up** (`shueber/Touch-Up`,
`TUCCursorUtilities.m`). Its magnify works on supported screens, and it does
**not** use the IOHID graft at all. The trick we'd missed:

1. **Start from a real mouse event, then retype it to gesture 29.** A bare
   `CGEventCreate(NULL)` produces an event AppKit ignores; a mouse event carries
   a valid location/timestamp/internal state that makes the retyped gesture
   honored.
2. **Set "magic" integer fields** `50=248`, `101=4`, plus subtype `110` (8 =
   magnify, 5 = rotate), value in doubles `113/114/116/118`, phase in `132`
   (NSTouchPhase: `1` began, `2` moved, `8` ended). `flags=0`.

```c
CGEventRef probe = CGEventCreate(NULL);
CGPoint loc = CGEventGetLocation(probe); CFRelease(probe);
CGEventRef e = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, loc, kCGMouseButtonLeft);
CGEventSetType(e, (CGEventType)29);     // NSEventTypeGesture
CGEventSetFlags(e, 0);
CGEventSetIntegerValueField(e, 50, 248);
CGEventSetIntegerValueField(e, 101, 4);
CGEventSetIntegerValueField(e, 110, 8); // 8 magnify, 5 rotate
CGEventSetDoubleValueField(e, 113, mag);
CGEventSetDoubleValueField(e, 114, mag);
CGEventSetDoubleValueField(e, 116, mag);
CGEventSetDoubleValueField(e, 118, mag);
CGEventSetIntegerValueField(e, 132, phase); // 1 began / 2 moved / 8 ended
CGEventPost(kCGHIDEventTap, e);
```

Critical caveat learned the hard way: **do not emit scroll-wheel events during
the pinch.** A real trackpad fires a single gesture; interleaving `NSScrollWheel`
events makes macOS classify the sequence as a scroll and drop the magnify. The
synth must move the cursor to the pinch midpoint on `began`, then emit *only*
magnify/rotate events.

This supersedes section 4.6's pessimism: animated gestures **are** synthesizable
on current macOS without the crashing graft — the earlier failures were from
(a) a bare base event, (b) the wrong field/echo (`type=30`/`124` instead of
`type=29`/`113`), and (c) concurrent scroll events.

### Critical pitfalls (each one cost us hours)

1. **Base from a mouse event, not `CGEventCreate(NULL)`.** A blank event is
   ignored; a retyped mouse event is honored.
2. **Use `type=29` + value in `113`**, not the `type=30`/`124` echo.
3. **No scroll events during the gesture** — they make macOS reclassify it as a
   scroll and silently drop the magnify/rotate.
4. **You MUST send the `ended` phase for every gesture you begin** — including
   when a two-finger gesture drops to *one* finger, not just zero. If you leave a
   gesture open (a `began`/`changed` with no `ended`), macOS's recognizer gets
   stuck mid-gesture and **freezes ALL gestures system-wide — on the touchscreen
   *and* the built-in trackpad — until your process exits.** This is the most
   dangerous failure mode; guard every state transition out of a gesture.
5. **Latch the two-finger intent in ONE unit.** A two-finger move changes finger
   distance, angle, *and* centroid position all at once. Decide scroll vs pinch
   vs rotate by measuring each candidate in the **same unit — accumulated screen
   points since touchdown**: spread `|dist−startDist|` (pinch), centroid travel
   `hypot(dx,dy)` (scroll/swipe), arc length `angle·radius` (rotate). Whichever
   passes a ~12-point commit first wins for the rest of the sequence. Compare in
   one unit or a tiny spread ratio will out-vote a real scroll. Bias toward
   scroll (pinch must beat travel by 1.6×) since scroll is the common case.
   **When one-finger (iPad) scroll is on, the two-finger latch drops scroll
   entirely** — two fingers are reserved for pinch/rotate/swipe, which removes the
   scroll-vs-pinch competition and makes those gestures much more stable. (A
   horizontal two-finger swipe still navigates back/forward via the release-commit.)
6. **Own the gesture lifecycle, including dropped fingers.** Always send the
   matching `ended`, or macOS's recognizer wedges *all* gestures system-wide. And
   when a two-finger gesture loses a finger (you lift one mid-pinch), close the
   gesture and **swallow the leftover finger until a full lift** — otherwise the
   straggler becomes a stray click / press-and-hold, which makes zoom feel flaky.
7. **The config must not go stale.** While iterating the field recipe, an old
   on-disk settings file silently fed the wrong encoding for a long time — make
   the config versioned/auto-migrating so you're never testing a stale format.

> **Codebase note.** The abandoned 2010-style IOHID **graft** (the path that
> crashed WindowServer) has been **removed from the source** — `GestureKit` now
> contains only the working `gk_post_fields` recipe plus the capture helper. The
> graft story is kept in this doc and in `JOURNEY.md` as history, not as code.
> Default settings: multi-touch gestures **on**, **natural** scroll direction.

> ✅ **CONFIRMED WORKING** on the Visual Beat V17UT (ELAN `04F3:5512`), current
> macOS, Apple Silicon: live two-finger pinch zooms in and out in real apps
> (Preview, Safari), continuous and animated. Verified both via a synthetic
> hotkey pulse and real finger input. The panel reports a clean 2 contacts during
> a pinch (no phantom finger). The single hardest-won lesson: post **only** the
> magnify gesture during a pinch — any concurrent `NSScrollWheel` event makes
> macOS reclassify the sequence as a scroll and silently drop the magnify.

## 5. What works, what doesn't

Works reliably (public APIs): cursor, tap/drag, hold-to-right-click, one- and
two-finger **momentum scroll**, 3/4-finger swipe via Ctrl+arrows.

**Touch robustness (staggered fingers).** Real fingers never land or leave a
multi-finger gesture at the same instant, which caused two artifacts, both fixed:
*(a)* a first finger landing a hair before the second would start a one-finger
drag, leaving a mouse button **held down through the gesture** ("click and hold
mixed with zoom"). Fix: a `touchSettleMS` (~25 ms) delay before a single finger
commits to a drag, plus a `leftUp` release when a second finger arrives. *(b)*
A scroll that drops to one finger (you lift one mid-scroll) now **keeps scrolling
with the remaining finger** — the two-finger scroll hands off to the one-finger
scroll path on the same scroll phase, so it's seamless and still coasts on the
final lift. Pinch/rotate can't continue on one finger, so a dropped finger there
enters a brief `liftGraceMS` (~70 ms) grace: a still two-finger tap becomes a
right-click, a flicker back to two fingers resumes, otherwise the straggler is
swallowed (never a stray click).

**Cursor restore ("debounce").** Optional (menu toggle, default on): the pointer
position is captured before a touch begins and **warped back** a configurable
quiet period after the last action (`restoreDelayMS`, default 20 ms). It applies
only to **discrete actions** — taps/clicks, pinch, rotate — and is **cancelled by
scroll and drag**, because those are delivered to the window under the cursor:
restoring mid-scroll would send the next stroke (or the momentum tail) to the
wrong window. So a tap returns the cursor, but scrolling leaves it over what you
scrolled. The menu uses a larger font so its rows are finger-sized hit targets.

**Inertia robustness vs. panel dropouts.** The ELAN panel occasionally drops a
report or emits a phantom contact, which made flick-to-coast flaky. Three guards:
the lift "silence" timeout is 70 ms (tolerates brief mid-scroll dropouts), the
release-velocity peak window is widened (80 ms) with a 200 ms staleness allowance
(so a flick whose last fast frames were dropped still launches momentum), and a
single stray contact during a coast is ignored — only **two consecutive** touch
frames stop the momentum (a lone phantom no longer "gets it stuck").

Continuous **pinch-zoom and rotate**: the **Touch-Up recipe in §4.7** (type-29 +
magic fields, value in `113`, no scroll during gesture). Validated on current
macOS with real fingers. (The old stepped ⌘± keystroke zoom has been removed now
that real magnify works.)

**Two-finger page-swipe (Safari back/forward).** We first tried synthesizing the
captured `type=29` **subtype `110=6`** pan event directly — it never navigated
Safari. The reason: that gesture event is *derived by AppKit* from a stream of
horizontal scroll events; injecting the derived conclusion doesn't reproduce the
context Safari needs to commit a navigation. **What actually works** is the same
thing a real trackpad sends: plain **horizontal scroll-wheel events** (the exact
`emitScroll` path used for vertical scroll). Safari turns continued horizontal
scroll at the page edge into back/forward on its own. Two details make it
reliable: the scroll phase must be **closed** on every release path (including a
2→1 finger drop), and a Safari swipe is a **small, fast horizontal flick** — it's
recognized from the **momentum**, not the distance — so a horizontal-dominant
flick always emits a momentum tail even if inertial scrolling is toggled off.
(The synthetic subtype-6 swipe is retained in the config only for the 3-finger
experiment; two-finger navigation no longer uses it.)

**3-finger Spaces/Mission-Control swipe** remains the one blocked gesture (needs
finger-count in the touch data) — handled via Ctrl+arrow keystrokes instead.

### Why the 3-finger Spaces swipe can't be animated

It comes down to *who recognizes the gesture* and *what information they need*:

- **Pinch / rotate / two-finger page-swipe** are recognized by **AppKit, inside
  the focused app**. The app only needs one derived number (magnification,
  rotation degrees, swipe offset). A synthesized CGEvent can carry that number,
  so apps honor it. ✅
- **The 3-finger Mission Control / Spaces swipe** is recognized by
  **WindowServer / the Dock** — the system compositor, below the app layer and
  more privileged. It doesn't want a scalar; it needs to know *"three distinct
  fingers are present, at these positions, moving together,"* read directly from
  the **multitouch hardware**, and it renders the desktops sliding *as the fingers
  move*.

The wall: a CGEvent is a **scalar** — there is **no CGEvent field for "N fingers
at these coordinates."** That per-finger data lives only in the raw IOHID
multitouch frames. So we can't tell WindowServer "this is 3 fingers" via any
event we may post, and the only channel that *does* carry finger count — raw
multitouch injection (the 2010 graft) — is undocumented, no longer accepted, and
**crashes WindowServer** on current macOS. The live **animation** makes it worse:
it's drawn by WindowServer while continuously reading the moving fingers, so it
needs a real-time stream of 3-finger positions into exactly that blocked channel.

In short: we can **fake the conclusion** (a scalar gesture event), but we cannot
**fake the hardware** (a stream of individual finger touches) through public APIs.

### The only real way to get it: a virtual HID multitouch device

The legitimate path is a **DriverKit system extension** that registers a
**virtual HID device pretending to be a real Multi-Touch trackpad** (e.g. a Magic
Trackpad 2). Then:

1. Your driver reads the V17UT touches (as now).
2. It re-encodes them into **Magic-Trackpad-2 HID multitouch reports** (the format
   reverse-engineered by the `MagicTrackpad2ForWindows` project).
3. It feeds those reports to the virtual HID device.
4. macOS's **own** `AppleMultitouchDevice` driver reads them *as if from real
   hardware*, runs the real gesture recognizer, and **animates Spaces / Mission
   Control natively** — with finger count, momentum, everything — and **without
   crashing**, because it's the sanctioned hardware path.

Cost/trade-offs: it's a signed **System Extension** (heavier than this user-space
app), needs the DriverKit entitlement, and you must implement the MT2 report
descriptor + report format. Reference: `pqrs-org/Karabiner-DriverKit-
VirtualHIDDevice` (virtual HID on modern macOS) + `vitoplantamura/
MagicTrackpad2ForWindows` (the MT2 report format). This is the difference between
*faking the conclusion* (CGEvents — what this project does) and *faking the
hardware* (virtual HID — the only way to reach the system-level gestures).

Hardware limits: the panel is an **absolute** touchscreen, so there's no
pressure/Force-Touch, and ergonomically it's a screen you reach up to touch — the
gesture *vocabulary* can match a trackpad, the feel can't fully.

---

## 6. Settings, calibration & tuning UI

All user-facing behavior now lives in one persisted object, `AppSettings`
(`~/v17ut-settings.json`), which the Engine reads live every frame and a SwiftUI
window binds to. Open it from the menu-bar 👆 → **Settings…**. The window is
built for touch: large switches, a segmented control, and big sliders, each with
a tappable ⓘ that pops an explanation (hover tooltips are useless on a touch
panel). The status menu is now minimal — Settings, Calibrate, the display picker,
the capture tool, Quit — because everything else moved into the window.

**Gesture engine** is one mutually-exclusive choice (`GestureMode`), surfaced as a
3-way segmented control with a live caption and a read-only "what each gesture
does" map so the model is discoverable:

- **Off** — two-finger scrolling only.
- **Smooth** (default) — synthesized trackpad events: animated pinch-zoom and
  rotate; two-finger horizontal becomes edge-scroll that Safari turns into
  back/forward.
- **Legacy** (stored as `shortcuts`) — gestures fire **keyboard shortcuts**
  instead, with no trackpad-event synthesis at all: pinch → ⌘+/⌘–, rotate →
  ⌘L/⌘R (app-dependent, e.g. Preview), two-finger swipe → ⌘[ / ⌘]
  (back/forward). Reliable everywhere, no animation.

A separate **Three-finger gestures** toggle (default on, active in Smooth and
Shortcuts) maps three fingers to Mission Control (up), App Exposé (down), and
switch-desktops (left/right) via Ctrl+arrow keystrokes — the one gesture neither
engine can animate, so it's always keystroke-driven. This replaced the old
`gesturesEnabled` boolean: one enum prevents invalid Smooth+Legacy combinations.

**Right-click mode** is selectable: *Touch & hold*, *Two-finger tap*, or *Either*
(default: two-finger tap, because press-and-hold fires by accident when you mean
to drag). `RightClickMode.usesHold` / `usesTwoFingerTap` gate the two code paths.
**One-finger scroll (iPad mode) is on by default.**

**Natural scroll** is now a single sign applied identically to one- and
two-finger scrolling (`AppSettings.scrollSign`); previously the two had opposite
mappings, so the toggle appeared to do nothing for one-finger scroll.

**One-finger inertia** has its own gain (`oneFingerInertiaGain`, default higher
than the two-finger `momentumGain`) so a one-finger flick coasts faster.

**Advanced timing** (a disclosure in the window) exposes every feel constant —
tap/hold thresholds, drag settle, inertia gains, friction, flick thresholds,
gesture commit/bias, dropout-robustness windows, cursor-return delay — all
live-editable and debounce-saved to disk.

**Choosing the display** happens two ways, both persisted (`displayID` +
`hasPickedDisplay`): a **dropdown in Settings → Display** (lists every connected
screen by name + resolution), and the numbered overlay below. The old menu-bar
"Touch maps to" list is gone.

**Persistence is by stable UUID.** A raw `CGDirectDisplayID` is *not* stable across
reboots/reconnects, so the saved monitor is keyed by `CGDisplayCreateUUIDFromDisplayID`
(`displayUUID`) and resolved back to the live id on launch. So the chosen monitor
and the calibration (which is panel-raw, already display-independent) survive
relaunch with no re-prompt. On first launch the saved uuid resolves silently; only
if it was set before but is genuinely absent **and** there's more than one screen
to choose from does the picker reappear.

**Hotplug recovery.** The app observes `NSApplication.didChangeScreenParameters`
and re-resolves the saved **uuid** on every change: if the touchscreen is unplugged
it **falls back to the main display** (keeping the preference), and when it's
plugged back in it **rebinds automatically**. The Settings dropdown live-refreshes
on hotplug, and a Combine subscription on `settings.$displayID` applies any dropdown
change to the engine immediately (and records its uuid).

**First-run display picker** (menu → Choose Touchscreen Display…, or shown
automatically on first launch) overlays a big number on every screen, macOS
"Identify"-style. Because the panel reports only raw X/Y and can't tell macOS
which display it is, you choose by **tapping the number** shown on the
touchscreen **or pressing that number key** (the overlay uses a `KeyableWindow`
so a borderless window can still receive key events — important when no cursor is
available). The choice persists (`hasPickedDisplay` / `displayID`) and flows
straight into calibration; it only re-asks if the saved display is gone.

**Calibration** (menu → Calibrate, or the window button) drops a full-screen
overlay on the touch-mapped display showing four corner targets. While it's up,
the Engine is in `calibrating` mode: taps are captured raw (no cursor movement)
and routed to `CalibrationController`, which solves an independent per-axis linear
map (`calXMin/Max`, `calYMin/Max`) from the corner samples and writes it back to
`AppSettings`. `toScreen` then uses those ranges instead of the panel's nominal
0–2624 / 0–1856, correcting any offset/scale skew. The overlay window is placed
by matching `NSScreen` (AppKit bottom-left coords), not the CG display bounds.

## 7. On-screen keyboard & edge gestures

**On-screen keyboard.** An iOS-style `KeyboardView` (rounded keys, light/dark
adaptive via `Color(nsColor:)` semantic colors, with a letters page and a
numbers/symbols page) hosted in a **non-activating, draggable `NSPanel`**
(`.nonactivatingPanel`, floating level, `isMovableByWindowBackground`). The panel
never takes focus, so tapping a key — which works through the normal
touch→cursor→click pipeline — posts a real `CGEvent` keystroke
(`Pointer.keyFlagged`) to whatever app *is* focused (symbol keys carry the right
shift flag). Drag it by the top bar. Transparency is the `keyboardOpacity` setting
(0.3–1.0). Toggle it from the menu, the Settings button, the floating control, or
the bottom-edge gesture. All floating UI (keyboard, launcher) uses semantic
colors so it follows the system light/dark appearance.

**Edge gestures** (`edgeGestures` setting), with a **dwell** for precision. Rather
than a fragile separate pre-check (fingers land staggered, so a clean N-finger
touchdown rarely happens on one frame), detection is *folded into the existing
handlers* which already debounce finger arrival:

- **Keyboard:** inside `handleSwipe` — a 3-finger group that **started at the
  bottom edge**, **dwelled `edgeDwellMS`** (default 250 ms), then pulled up,
  toggles the keyboard. A quick 3-finger up elsewhere is still Mission Control.
- **Notification Center:** inside `handleTwoFinger` — two fingers that **started
  at the right edge**, dwelled, then pulled left by `edgePull` points. It's opened
  best-effort by clicking the menu-bar clock **on the touch display** (so it opens
  there, not wherever the cursor is); NC has no public trigger.

Both timings (`edgeDwellMS`, `edgePull`) are user-tunable in Settings.

**Edge zones are precise, visible bands.** Detection originally used
%-of-panel-span margins (the right zone was ~10% of the width ≈ 190 pt — wide
and invisible, hence flaky). Zones are now **fixed screen-point bands** (bottom
48 pt for the keyboard pull, right 40 pt for Notification Center) and each is
marked by a subtle **accent strip** — a pass-through panel
(`ignoresMouseEvents = true`) that's pure affordance, shown when edge gestures
are on and repositioned when the touch display changes. Rest your fingers on the
strip, dwell, pull.

**Floating control** (`showFloatingControl`). A 160×160 semi-transparent,
draggable launcher in a non-activating panel (`isMovableByWindowBackground`, joins
all Spaces). Tap to open the keyboard, **cycle the gesture engine**, or open
Settings. Its chevron **collapses it to a thin tab pinned to the screen edge**;
tap the tab to expand. Toggle from the menu or Settings; the state persists.

**How touch-dragging the panels works** (keyboard + launcher, even in iPad mode):
the panels are `NSPanel`s with `isMovableByWindowBackground = true`, and at every
one-finger touchdown the Engine queries `isOverPanel(point)` — the app converts
each panel's AppKit frame to CG coordinates (`cgY = primaryHeight − appKitMaxY`)
and hit-tests. If the touch starts over a panel, the Engine emits a real
`leftMouseDown` + `leftMouseDragged` stream instead of iPad-mode scroll, and the
window server moves the panel. This is also a reusable pattern for third-party
floating UI — see `DEVELOPER_API.md` §2.

**Keyboard visibility note.** The keyboard/launcher panels use a **fixed content
size** (NSHostingView `fittingSize` is 0 before layout) and
`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` so they appear on
the active Space and over full-screen apps even though the app is an accessory
(menu-bar-only) process.

**Virtual trackpad** (`showTrackpad`, default off). A floating, draggable,
resizable panel whose surface the Engine intercepts (`trackpadRect`): touches
that *start* inside it run in **relative** trackpad semantics — one finger moves
the cursor by deltas × `trackpadGain` (clicks land at the **cursor**, never at
the touch point), tap = click, two-finger = scroll with inertia, two-finger tap =
right click. This makes the Mac fully drivable with no mouse/trackpad attached.
The header strip is excluded from the active surface so drag/resize/close work.

**Resizable panels.** The keyboard and trackpad have a corner "bean"
(`ResizeBean`/`ResizeHandle`): an AppKit view whose mouseDown/Dragged/Up resize
the window, keeping the top edge fixed. Deliberately **event-driven, not a
`nextEvent` tracking loop** — a tracking loop switches the run loop into
event-tracking mode, which would pause the HID callbacks that generate our
synthetic drags and deadlock touch input. Keyboard keys use flexible frames so
they stretch to fill whatever size the panel is.

**Extended keys** (`keyboardExtendedKeys`, default on). Adds esc + F1–F12 and
**sticky ⌘ ⌥ ⌃ fn modifiers**: tap a modifier (it highlights), tap a key, and the
combo is sent with the right `CGEventFlags`, then the modifiers clear — so ⌘C,
⌘⌥-esc, F-keys etc. all work from the touchscreen.

**Full Mac layout + keycap layouts** (`keyboardLayout`, default `us`). The
keyboard is the full Mac arrangement (number row with shifted symbols, tab, caps
lock as a UI shift-lock, full punctuation, arrows), data-driven from `KeyDef`
rows with width weights. Selectable keycap sets: **US, Français (AZERTY),
Español, Português, 中文 (Pinyin), 日本語 (Romaji)**. Crucial mechanic: we post
*positional virtual keycodes* and **macOS maps them through the active input
source**, so the layout option changes the keycaps to mirror that source — the
user picks the one matching System Settings → Keyboard → Input Sources. Chinese
and Japanese type through their IMEs over QWERTY, so they share US keycaps.

**Keyboard dock & pull tab.** The keyboard opens **snapped to the bottom** of the
touch display; its ⌄ button collapses it to a small **pull tab** pinned
bottom-center (keyboard icon + chevron) — tap the tab and the keyboard slides
back up. The menu/Settings toggle still fully shows/hides it. An optional
**numeric keypad** column (`keyboardNumpad`, real keypad keycodes) widens the
panel when enabled.

**Settings IA.** The Settings window is organized like macOS System Settings: an
icon **sidebar** (Pointer & Scroll / Gestures / Right-click / Keyboard / Trackpad
/ Edges & Launcher / Display / Advanced) with a detail pane per section, replacing
the earlier single scrolling column.

**Panels are confined to the touch display.** Every move/resize of the keyboard,
trackpad, or launcher is clamped into the touch display's frame
(`NSWindow.didMove/didResizeNotification` → `clampToTouchDisplay`), and they
re-clamp when the chosen display changes. Dragging a panel **hard past a side
edge (>40 px)** collapses it to its **pull tab** instead of clamping — the
launcher and trackpad pin a thin tab to the right edge, the keyboard to its
bottom-center tab. The trackpad's active surface becomes empty while collapsed,
so the tab never intercepts touches.

**Trackpad gestures on the virtual pad.** The pad's two-finger handling runs the
same intent latch as the touchscreen (scroll / pinch / rotate in one comparable
unit), so **OS-level pinch-zoom and rotate work from the virtual trackpad** —
synthesized trackpad events in Smooth, ⌘±/⌘L/R in Legacy — plus two-finger
scroll with inertia. Right-click is MacBook-style: a quick, still **tap of a
second finger** (2→1 transition) right-clicks at the cursor and the first finger
keeps tracking; a plain two-finger tap right-clicks too. A `padClicked` flag
prevents the final lift from double-firing a left click.

**Polish round.** Right-click on the touchscreen now fires **the moment a second
finger taps** while the first holds (MacBook-style, at the held finger's
position; `rcFired` prevents double-firing on the later lift) — this is the
default since `rightClickMode = .twoFingerTap`. Tap-to-click was flaky because a
quick tap's few-px movement computed a huge instantaneous velocity and became a
micro-flick — a flick now also requires real travel (`> tapMaxMove`). The virtual
trackpad gained a **pointer-acceleration curve** (0.5×–3× by finger speed, like a
real trackpad). Panels animate open/collapsed (`setFrame(animate:)`), pull tabs
and header controls were enlarged for finger-sized targets, settings switches
went back to regular size, and Settings gained an **About** tab.

## 8. Roadmap (planned, not yet built)

**Generic HID-compliant touchscreens — detect the CONTROLLER, not the display.**
The USB device is the touch controller (ours: ELAN `04F3:5512`); the display
brand never matters. Generalize in layers: (1) match by HID **usage** — Digitizer
page 0x0D / TouchScreen 0x04 — catching any vendor's controller; (2) enable
multitouch the standard way: set the HID **Device Mode** feature (Windows
precision-touch spec) → fall back to the MS-certification feature read → a small
per-vendor quirk table (ELAN's 0x44/0x0a read is entry #1); (3) parse the
**report descriptor** for contact-count / X / Y / tip offsets and logical maxima
instead of the hard-coded 11-byte stride. Everything downstream of
`Contact {id,x,y}` is already controller-agnostic.

**iPad as a touch surface.** Sidecar is a dead end: Apple exposes only Apple
Pencil as a pointer and never surfaces finger touches as a HID device macOS can
read. The viable route is a **companion iPad app** streaming normalized touches
over the network into the engine — the input-side twin of the planned developer
API (same `Contact` stream, network transport instead of USB HID).

**Distribution & licensing.**
- **Mac App Store: not viable.** The app depends on Accessibility event posting
  (`CGEventPost`), raw HID access (`IOHIDManager`), synthesized private gesture
  events, and clicking the menu bar — all of which the App Store sandbox forbids.
- **Direct (own website): yes.** Ship a **Developer ID-signed, notarized,
  stapled `.app`** (hardened runtime). Users grant Accessibility + Input
  Monitoring on first launch. This is the only realistic channel. Requires an
  Apple Developer account (confirm current cost/terms with Apple).
- **Auto-update (TODO — Apple Developer account in hand):** integrate **Sparkle 2**
  — add the SPM dependency, generate an EdDSA key pair (`generate_keys`), host an
  `appcast.xml` + the signed `.zip`/DMG on the website, set `SUFeedURL` and the
  public key in Info.plist, and sign each release with `sign_update`. Pairs with
  Developer ID signing + notarization in the release build script.
- **Licensing (low-price, "good enough"):** offload payments + license issuance to
  Paddle / Lemon Squeezy / Gumroad, or self-host. Verify a **public-key-signed
  license file** offline (ship the public key, sign with a private key you keep).
  Accept that nothing is uncrackable; for a cheap app a signed-license check with
  an offline grace period deters casual sharing without punishing real users.
  Keep the check away from the input pipeline so a bypass can't degrade behavior.

**Keyboard: emoji picker & autocomplete (TODO).** An emoji key opening a
searchable emoji grid (insert via pasteboard + ⌘V, or Unicode key events), and an
autocomplete/suggestion bar above the keys (word completion from a local
dictionary; would need a text-context source — start with a simple
frequency-based completer fed by what was typed in-session).

**Public multi-touch API for other apps.** Expose the normalized touch stream
(per-finger id, x, y, phase) plus recognized gestures so third-party apps can
react. Options, lightest→heaviest: a local **Unix-domain socket / Bonjour**
publishing JSON touch frames; a **Distributed Notifications / XPC** service; or a
small **framework** (à la TouchUpCore) apps link against. A DriverKit **virtual
HID multitouch device** would be the most native (it'd also unlock the animated
3-finger Spaces swipe) but is the biggest lift — a system extension with its own
signing/notarization. Recommended first step: the socket + a tiny client sample.

## 9. Method notes (how to reproduce the capture)

1. `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
   options: .listenOnly, eventsOfInterest: mask, ...)` with `mask` covering
   types 18,19,20,29,30,31,32.
2. In the callback, dump non-zero `CGEventGetIntegerValueField` and
   `...DoubleValueField` for field ids 0..255, plus `CGEventGetType` and the
   `CGEventCreateData` length.
3. Perform one clean gesture at a time (pinch, then twist, then 3-finger swipe)
   and diff the field sets. Integer fields that hold float bit-patterns are the
   tell: cross-check by reinterpreting them as float32 and comparing to the
   matching `dbl[...]` field.

Requires **Accessibility** + **Input Monitoring** permission for the binary.

---

*Hardware: Visual Beat V17UT, ELAN `04F3:5512`. Field ids are from the author's
macOS version and may differ on yours — re-run the capture to confirm.*

## Palm rejection

The ELAN panel reports no contact size/area, so palms are classified
behaviorally in `Engine.filterPalms` — a pre-filter that runs before the
state machine sees any contact. Rejection is sticky per contact id: once an
id is classified as a palm it stays ignored until that contact lifts.

Two heuristics (Settings → Pointer & Scroll → Palm rejection):

1. **Cluster** — a contact with 2+ neighbors inside `palmClusterPts`
   (default 56 pt) is a palm heel; no finger spread is that tight.
   Tunable: lower if 3-finger gestures get eaten, raise if palms still click.
2. **Panel guard** (`palmPanelGuard`) — while an accepted touch is on the
   on-screen keyboard or virtual trackpad, new touches landing *off-panel*
   are a resting hand and are rejected. The guard only catches touches that
   land *after* the panel touch, since landing order is the only signal
   available without contact area.

## Floating panels: run-loop, focus, and backdrop

All touch panels (keyboard, trackpad, deck, floating launcher) are
non-activating `NSPanel`s — they must never steal key focus from the app the
user is typing into. Three consequences, each handled:

- **Run-loop modes**: the HID manager and the engine's 120 Hz tick are
  scheduled in `.commonModes`, not `.defaultMode`. Otherwise opening the
  status menu or dragging a window (which switch the main run loop out of
  default mode) freezes touch until the interaction ends.
- **Live backdrop**: a non-activating window is treated as permanently
  inactive, so a glass/blur backdrop freezes a stale snapshot. `GlassHostingView`
  walks its subviews after every layout pass and forces any
  `NSVisualEffectView` to `state = .active`. On macOS 26, Liquid Glass
  (`glassEffect`) froze a ghost snapshot with no public override, so panels
  use `gcActiveBlur` (an always-active `NSVisualEffectView` + sheen) instead.
  Settings → General → "Blur panel backgrounds" turns this off for a flat
  translucent fill (no compositing cost).
- **Single instance**: on launch the app terminates any other running
  instance with the same bundle id — two engines fighting over one HID device
  put the cursor on the wrong display and double-post events.

## On-screen keyboard press feedback

iOS-style feedback in `KeyCapStyle` (a `ButtonStyle`): touch-down applies a
brightness highlight + a 0.94 scale dip, spring-released. Letter keys also get
a magnified key-pop callout (`KeyPopCallout`) floating above the held key.
Both toggle independently in Settings → Keyboard (`keyPressFeedback`,
`keyPopup`).

## General settings tab

Settings → General gathers: start-at-login (`SMAppService`), a live permission
checklist (Accessibility + Input Monitoring, polled every 2 s, with Grant /
Open-Settings deep-links / Relaunch), the blur toggle, and touch-controller
status with a Reconnect button.

## Touch routing inside our own panels

Panels speak "mouse" to the OS so standard SwiftUI controls and third-party
widgets work without a bespoke API. Two fixes encode this:

- **Interior drag = real mouse drag.** A one-finger drag that starts over one
  of our panels but NOT on its top bar used to fall through to iPad-scroll, so
  the deck volume slider (and scroll views) didn't respond to dragging. The
  engine now posts `leftDown`+`leftDrag` for interior panel drags, so SwiftUI
  controls track the finger. (Top-bar drags still use the `onPanelDragBegan`
  window-frame path; synthetic mouse there caused the input wedge.)
- **Tap holds briefly.** A touch tap fired `leftDown`+`leftUp` in one frame, so
  a SwiftUI `ButtonStyle`'s pressed state lasted ~0 frames — key highlight/pop
  only showed under a real mouse. Taps over our panels now hold the button down
  ~80 ms (async `leftUp`) so press feedback renders.

Only window-frame *moves* use the custom panel-drag callback; everything inside
a panel is standard SwiftUI driven by synthetic mouse events. This is also the
cross-platform seam (see DECK_PLAN.md): a Windows host swaps event synthesis,
the widgets/extensions stay unchanged.

## Deck widgets & extensions

`DeckPage.widgets` holds spanning live tiles rendered in a horizontal rail
above the button grid. Built-ins: Clock, Media. Third-party widgets are
declarative `manifest.json` packs under
`~/Library/Application Support/Gatecaster/Extensions/` — `WidgetRegistry`
discovers them, `WidgetDataSource` polls each one's `refresh` command (JSON
stdout → fields), `ExtensionWidget` renders generically, `MissingWidget`
badges an uninstalled reference. No third-party native code runs; only the
declared actions + refresh command. Full author guide: docs/EXTENSIONS.md.

## Panel dragging: title bar only

Panels set `isMovableByWindowBackground = false`. Whole-background drag both
let a mouse move a panel from anywhere AND made the engine's synthetic
mouse-drag over a slider move the window instead of the control. Now:
- **Mouse**: a `TitleBarDrag` NSView sits behind each header and calls
  `window.performDrag` on mouseDown — only the title bar moves the panel;
  header buttons consume their own clicks.
- **Touch**: the engine's top-bar `onPanelDragBegan` path (full panels drag
  only from the 46pt header) moves the frame; interior touches are real mouse
  drags for the controls.

## Built-in deck widgets

`clock` (time/date), `media` (transport via media keys), and `claude` —
Claude usage. The Claude widget (`ClaudeUsage`) scans
`~/.claude/projects/**/*.jsonl` off-thread every 60s and sums token usage
(input/output/cache). It mirrors ccusage: de-dups entries by message-id +
request-id, then groups them into 5-hour **session blocks** (a block starts at
the first message floored to the UTC hour and ends 5h later or after a >5h
gap) — so the "5-hour" figure is the active block, not a naive last-5-hours.
It also reports the rolling 7-day total and the largest historical block,
which is used as an auto limit (ccusage's "-t max") so the bar shows a
percentage even without an explicit cap. Optional `limit5h`/`limitWeek` config
override it; `display` = tokens|percent|both. Percent needs a limit because
local logs can't know the plan cap. Purely local; no network. For maximum
fidelity a future option could shell out to `ccusage --json` when installed.

## Deck layout: unified spanning grid + per-widget editing

Buttons (1×1) and widgets (W×H) share one grid. `DeckView.packLayout` is a
first-fit packer over `DeckPage.resolvedOrder`: it places each item at the
first free slot (top-to-bottom, left-to-right) in a `columns`-wide grid,
returning absolute (row,col) positions rendered in a `ZStack` with offsets.
In **manual** mode (`autoArrange == false`) an item with an explicit
`gridCol`/`gridRow` is honored when that cell range is free and in-bounds, and
everything else first-fits around it; in **Auto-Arrange** mode (default) the
stored cells are ignored entirely → pure first-fit ("tidy"). Buttons default
to the neutral keycap color (empty `colorHex`); color is opt-in.

In edit mode each widget tile shows three controls: a **gear**
(`WidgetConfigEditor` popover — per-kind settings), a **trash** (delete), and
a bottom-right **resize handle** that drags the span in whole cells
(`widget.spanW/spanH`, via a `Binding<DeckWidget>`). Resize works on touch
because interior panel drags post real mouse drags.

The Claude usage widget reads its display mode + token limits from
`widget.config` (`display` = tokens|percent|both, `limit5h`, `limitWeek`);
percent requires a limit since local logs can't know the plan cap.

## Deck: tile drag (two modes), min size, more built-in widgets

- **Whole-tile drag.** In edit mode the entire tile body is draggable (a
  `DragGesture` in the named `deckGrid` coordinate space; gated on `editing` so a
  non-edit touch leaves the volume slider's own gesture free). The bottom-right
  resize handle keeps `highPriorityGesture`, so grabbing the corner resizes and
  beats the body drag; a tap still opens the editor. The drop is interpreted by
  mode in `DeckView.handleDrop`:
  - **Auto-Arrange ON** (default) → **reorder**: the drop snaps to the nearest
    other tile's center and the dragged item takes its place in
    `DeckPage.order`; the packer re-flows ("tidy"). `resolvedOrder` falls back
    to widgets-then-buttons for old layouts.
  - **Auto-Arrange OFF** → **absolute placement**: the drop snaps to the nearest
    cell and is stored as the item's `gridCol`/`gridRow` (integers, so positions
    survive a Block-Size change — the cell pitch can grow/shrink and the item
    keeps the same logical cell).
- **Menu**: deck ⋯ → `Auto-Arrange` toggle and `Tidy Up Now` (`DeckView.tidyUp`
  clears every item's `gridCol`/`gridRow` on the page → instant reflow).
- **Min size**: `widgetMinSpan` / `widgetDefaultSpan` give each kind a floor and
  a drop size; extensions declare `minW/minH/defaultW/defaultH` in the manifest.
  The resize handle clamps to the minimum.
- **Edit grid**: in edit mode the grid fills the viewport with `AddCell` "+"
  cells (dashed outline, plus spare rows) so there's visible empty space — and
  an add affordance — to resize/drag into.
- **Built-in widgets**: clock, volume, media, claude, **battery** (`pmset`),
  **cpu** (`host_statistics`). Media now uses real NX media keys, not F-keys.
  Most other widgets (OBS, Spotify, timers, multi-tz, GPU…) are intended as
  registry extensions, not built-ins — see docs/WIDGET_IDEAS.md.

## Deck: capture, persistence, full-screen, background, emoji

- **Shortcut capture** (`KeyRecorder` in DeckView): the keystroke action editor
  has a Record button. Because the deck is a non-activating panel (NSEvent
  monitors are unreliable), capture uses a CGEvent keyDown tap that reads
  keycode+flags, formats to our token syntax, and SWALLOWS the combo so
  recording `cmd+shift+4` doesn't trigger it. Needs Accessibility.
- **Panel persistence**: keyboard/trackpad/deck/floating frames are saved to
  `settings.panelFrames[key]` (NSStringFromRect) when a drag/resize settles,
  and restored in each `show*` via `savedFrame(key)`.
- **Full screen**: deck ⋯ → Toggle Full Screen posts `.gcDeckFullScreen`;
  `AppController.toggleDeckFullScreen` fills the touch display and toggles back
  to the saved windowed frame.
- **Background**: deck ⋯ → Background = blur | opaque | clear, stored in
  `settings.deckBackground` (+ `deckOpacity` for opaque). Applied by DeckView's
  `deckBackground` view.
- **Block size**: `settings.deckCellSize` (Small/Medium/Large); columns derive
  from panel width ÷ block size so resizing the panel adds cells, not size. No
  inner scroll — the grid fills the panel.
- **Add flow**: every empty cell renders an `AddCell` "+" → one popover with
  Button + all widget kinds + installed extensions (replaces the old separate
  add tiles / Menu which didn't open from touch).
- **Built-in widgets** now also include **Emoji** (`EmojiWidget`): category
  tabs + scrollable grid + recents; taps insert the emoji via
  `DeckRunner.typeText` (synthesized Unicode keystroke). `typeText` and
  `mediaKey` live in DeckRunner.

## Deck Settings, themes, transparency, extension manager

`DeckSettingsView` (sheet from deck ⋯ → Deck Settings) provides:
- **Themes** (`DeckTheme`): Midnight, Darkness (pure black, forced opaque),
  Graphite, Glass (live blur), Aurora (gradient), Daylight (light). A theme sets
  the panel background AND `\.environment(\.colorScheme)`, so built-in widgets +
  neutral keycaps (system colors) adapt automatically. Stored in
  `settings.deckTheme`.
- **Transparency**: `settings.deckOpacity` modulates solid/gradient themes
  (ignored by forced-opaque themes like Darkness).
- **Extension manager**: lists installed packs (folders under the Extensions
  dir), with add (open folder) / reload / delete (removes the folder).

Authoring guidance (declare accent + content, not absolute colors) is in
docs/EXTENSIONS.md → "Theming & styling". Roadmap: in-app extension downloads
(#46), per-page import/export + cloud backup (#47).

## Deck widget scrolling (engine-driven)

SwiftUI `DragGesture` doesn't reliably receive the engine's synthesized drags
on a non-key panel, and a native `ScrollView` only scrolls on scroll-wheel
events — so neither worked alone. The fix: the engine drives it.

When a one-finger drag starts over a scrollable deck region (`Engine.deckScrollAt`
→ `AppController.deckScrollRegion`: inside the deck panel, below the ~50pt
header, and NOT in edit mode), the engine enters `.fscroll` and emits real
scroll-wheel events (with phase + momentum) at the cursor. macOS delivers those
to the `ScrollView` under the cursor — which scrolls natively, even though the
panel isn't key. Widgets (emoji grid, extension chip grid) just use a plain
`ScrollView`. Taps still go through the click path, so buttons keep working;
edit-mode interior drags stay mouse-drags for tile drag / resize.

**Volume bars opt out.** A vertical volume bar needs a real *drag*, not a
scroll. Each on-screen `VolumeWidget` publishes its panel-local frame to
`DeckDragRegions.volumeRects` (keyed by widget id, cleared on disappear);
`deckScrollRegion` maps those into screen space and returns `false` for a touch
inside one. The engine then takes the interior `.dragging` path
(`leftDown`+`leftDrag`), so the bar's `DragGesture` tracks the finger and sets
the volume. Without this the whole content area scrolled and the bar never moved
— `highPriorityGesture` on the bar couldn't help, because the engine never
delivered a drag to begin with.
