# How we figured it out — the journey, and what we got wrong

A plain-language log of the steps that took this from "Mac ignores my
touchscreen" to "pinch-to-zoom works with my fingers," including the dead ends.
Read `INTERNALS.md` for the technical reference; this is the story and the method.

---

## The two questions we had to answer

1. Why does the screen do **nothing** on macOS when it works on Windows?
2. Can we make macOS treat our faked input as **real gestures** (pinch/rotate)?

---

## Part 1 — Getting the touches (this went smoothly)

1. **Identify the hardware.** macOS System Information showed the panel as an
   **ELAN** USB device, `VID 0x04F3 / PID 0x5512`.
2. **List the HID interfaces** with a small Python script (`hidapi`). The panel
   is one USB device exposing several "reports": a mouse report, a keyboard
   report, and — importantly — a dormant 10-finger digitizer.
3. **Dump the report descriptor + watch raw bytes.** Touching the screen only
   produced the *mouse* report (single finger). The 10-finger report never fired.
4. **The first real discovery:** the ELAN chip keeps multitouch **asleep** until
   the host reads a specific vendor "certification" report. One line woke it:
   ```python
   d.get_feature_report(0x44, 257)   # + 0x0a
   ```
   After that, the full 10-finger stream (Report ID 1) started flowing.
5. **Decode the finger format.** Each finger is 11 bytes: a tip/id byte, width,
   height, then X and Y as 16-bit values — and X/Y are *duplicated* (a firmware
   quirk; we read the first copy). Range: X 0–2624, Y 0–1856.

> **Why Touch-Up and other "universal" drivers fail on this screen:** they wait
> for touch data that never comes, because they don't send that wake-up read.
> That single handshake is the most reusable thing we learned. (See
> `ELAN_TOUCHUP_NOTES.md`.)

---

## Part 2 — Basic input (also straightforward)

6. Mapped finger position → screen coordinates (with a 3-tap calibration, later
   simplified since the panel reports clean 0–2624 / 0–1856).
7. Built the pointer behaviors with macOS's **official** event APIs:
   move, tap-to-click, drag, press-and-hold = right-click.
8. Added **scroll with momentum** using phase-tagged scroll-wheel events. This
   felt native immediately — because scroll is technically a *mouse* event, and
   macOS *does* provide an official way to fake those.
9. Ported the working prototype from Python to a native **Swift menu-bar app**.

---

## Part 3 — Gestures (the long, hard part — and our mistakes)

This is where we spent most of the effort. Pinch-to-zoom and rotate are
*gesture* events, and macOS provides **no official way to create them**. Here's
the sequence of attempts and what was wrong with each:

### Mistake 1 — the 2010 "graft" → crashed the Mac
We used the classic reverse-engineered method (Calftrail/Sesamouse): build a
gesture event and staple a chunk of raw touch-hardware data onto it. On modern
macOS this **crashed WindowServer** (logged the user out). The original author
later confirmed: that touch-data injection "doesn't work anymore on recent
releases." → **Dead end, and dangerous.**

### Mistake 2 — believing it was impossible
After the crash, Apple's docs (no public API to create gestures), the
Hammerspoon maintainer's failed attempts, and our own crash all pointed to "it
can't be done on modern macOS." We nearly shipped with that conclusion. **It was
wrong** — but understandably so; four sources agreed.

### Method that broke the deadlock — let the OS label the events
Instead of guessing, we tapped the **real trackpad** (read-only) and bridged each
event back through `NSEvent(cgEvent:)` so **AppKit itself named it**. This removed
all argument: we could see exactly which event type and which numeric "field"
held the magnification value on *this* macOS.

### Mistake 3 — chasing the wrong event (the "echo")
The capture showed a `type=30` "magnify" event with the value in field `124`. We
faithfully reproduced it... and apps ignored it. Turned out `type=30` is a
*secondary echo* AppKit doesn't read. The event apps actually honor is
**`type=29`** with the value in field **`113`**. (We confirmed: AppKit read
`magnification=0.0150` off the real one, and `0.0000` off the echo.)

### Mistake 4 — confusing different gestures
Several captures mixed a pinch and a swipe in one recording, so we kept
mislabeling pinches as swipes (and vice-versa). The fix was disciplined
**one-gesture-at-a-time captures**, plus filtering out constant "noise" fields so
the real ones stood out.

### The breakthrough — reading a tool that actually works (Touch-Up)
Touch-Up's source revealed the three things we were doing wrong:
1. **Start from a real (fake) mouse event, then change its type to gesture 29.**
   A blank `CGEventCreate(NULL)` produces an event macOS ignores; a mouse event
   carries the internal state that makes it honored. *This was the missing piece.*
2. **Set the right hidden fields:** `50=248`, `101=4`, subtype `110` (8=magnify,
   5=rotate), value in `113`, phase in `132`. No raw-hardware graft at all → no
   crash.
3. **Never emit a scroll event during the pinch.** If you do, macOS reclassifies
   the whole thing as a scroll and silently drops the zoom.

### Mistake 5 — testing with a stale config
After implementing the correct recipe, it *still* didn't work — because the app
loaded an old settings file (`~/v17ut-gesture.json`) with the previous, broken
encoding. We'd been testing the old format the whole time. Fix: the config now
**auto-migrates** (versioned), so it can't silently use a stale recipe again.

### The proof
We split the problem with two isolation tests:
- A **keyboard shortcut** that fires a pure synthetic zoom (no touchscreen). It
  zoomed an image → **synthesis works.**
- A **finger-count log**: a pinch reported a clean **2 fingers** → the touch side
  was fine too (no phantom contacts, which we'd briefly suspected).

With both halves proven and the config fixed: **two-finger pinch zoomed in and
out with real fingers.** Rotate uses the identical recipe (subtype 5).

### Mistake 6 — leaving a gesture "open" → froze ALL gestures system-wide
After pinch worked, a scarier bug appeared: sometimes gestures stopped working
**everywhere — touchscreen *and* the built-in trackpad — until the app was
quit.** Cause: we sent a gesture `began`/`changed` but not always the matching
`ended`. Specifically, when a two-finger pinch dropped to **one** finger (not
zero), we jumped to the one-finger handler without closing the open gesture. A
half-finished gesture leaves macOS's recognizer stuck mid-gesture, and it
swallows every subsequent gesture until our process dies and the OS resets.
Fix: a `closeSmoothGestures()` that always emits `ended`, called on *every* exit
from a two-finger gesture (lift to zero **and** drop to one finger). Lesson:
synthesizing gestures means you now own the gesture *lifecycle* — a missing
`ended` doesn't just drop your event, it wedges the whole system.

### Mistake 7 — magnify/rotate cross-talk
A twist slightly changes finger distance too, so emitting both gestures per frame
made a rotate also zoom. Fix: latch — whichever (pinch or rotate) crosses its
deadband first locks out the other until the fingers lift.

### Mistake 8 — comparing gestures in different units (broke scroll + swipe)
The first latch compared a **pinch ratio** (≈0.004, dimensionless) against
**scroll/swipe travel** (≈18, in points). Those aren't comparable numbers, and
the pinch threshold was so tiny that the normal jitter in finger spread during a
plain scroll crossed it instantly — so pinch *always* won. Result: two-finger
scroll did nothing and a horizontal swipe got hijacked as a zoom. Fix: measure
all four candidates in **one unit — accumulated screen points since touchdown**:
spread = `|dist - startDist|` (pinch), centroid travel = `hypot(dx,dy)`
(scroll/swipe), arc length = `angleΔ·radius` (rotate). Whichever passes a single
~12-point commit threshold first wins. Now they compete fairly: scrolling moves
the centroid far while spread barely changes → scroll; pinching changes spread
while the centroid stays put → pinch. Touch-Up emits the same plain scroll-wheel
CGEvents we do; the bug was never the emission, only the discrimination.

### Mistake 9 — synthesizing the *derived* swipe instead of replaying the cause
For Safari back/forward we tried posting the exact event a real two-finger swipe
shows in a capture (a `type=29` subtype-6 pan). It never navigated. The insight:
that event is something **AppKit derives** from a stream of horizontal scroll
events — injecting the conclusion doesn't recreate the context Safari needs to
commit. The fix was to send what the trackpad actually sends: plain **horizontal
scroll** events, and let Safari turn edge-scroll into navigation itself. Two
things mattered: (a) a Safari swipe is a *small, fast flick* recognized from
**momentum**, not distance — so a horizontal flick must always emit a momentum
tail; and (b) the scroll phase must be **closed on every release path**, which
exposed the next bug.

### Mistake 10 — a dropped finger became a stray click
When a two-finger pinch/scroll briefly fell to **one** finger (you lift one
slightly), the code jumped straight into one-finger handling — which after a
moment fires a click or press-and-hold. That's what made zoom feel flaky and
"mixed with click-and-hold." Fix: treat a multi-finger gesture that loses a
finger as *over* — close it and **swallow the leftover finger until a full
lift**, exactly like a real trackpad. A straggler never becomes a click.

### Mistake 11 — fingers don't land or lift in unison
Two late bugs both traced to the same wrong assumption — that a multi-finger
gesture starts and ends cleanly. Real fingers are staggered. A first finger
landing slightly early started a one-finger drag whose mouse-button was never
released when the second finger arrived → a click held down through the whole
zoom ("mixed with click and hold"). And a scroll whose fingers lifted staggered
(2→1→0) hit the "swallow the straggler" path and **lost its inertia**, sometimes
firing a stray click instead of coasting. Fixes: a small settle delay before a
finger commits to a drag (so a second finger can still claim it as a gesture), a
button release on the 1→2 transition, and a short grace state on the 2→1 drop
that decides between *coast* (other finger also lifts → flick) and *swallow*
(finger lingers → no click). Lesson: never assume simultaneity from hardware that
reports one finger at a time.

### Two-finger scroll that continues on one finger
A natural ask: start scrolling with two fingers, lift one, keep scrolling with
the one that's left. Since a one-finger scroll path already existed (iPad mode),
the fix was to *hand off* — when a two-finger scroll drops to one finger, switch
to the one-finger scroll mode on the same scroll phase instead of swallowing the
straggler. Seamless, and it still coasts on the final lift. (Pinch/rotate can't
continue on one finger, so those still end on a dropped finger.)

### A small quality-of-life feature — returning the cursor
With the touchscreen used next to a mouse, every touch dragged the cursor away
from where the mouse pointer had been. We added a "debounce": capture the pointer
before a touch, and warp it back a configurable quiet period (default 20 ms,
counted from the end of any inertia coast) after the last action. Toggleable, and
the menu got a larger font so it's tappable by finger.

### Mistake 12 — restoring the cursor broke scrolling onto the wrong window
The cursor-restore feature snapped the pointer back ~20 ms after each touch — but
scroll events go to the window *under the cursor*, so between scroll strokes the
pointer would jump back over a different window and the next stroke scrolled the
wrong thing. Fix: restore is for **discrete actions only** (tap/click/pinch/
rotate); any scroll or drag cancels it so the pointer stays over the target.

### Mistake 13 — trusting the panel to report cleanly
Inertia was "great sometimes, stuck other times." The ELAN panel intermittently
drops a report or fires a phantom contact. Two consequences: a flick whose final
fast frames were dropped was detected as a lift too late, with a stale (≈0)
velocity → no coast; and a phantom contact mid-coast was treated as a finger
landing → momentum killed instantly ("starts then gets stuck"). Fixes: tolerate
brief dropouts (longer silence timeout), use a wider peak-velocity window with a
more generous staleness allowance, and require **two consecutive** touch frames
to cancel a coast so one stray contact is ignored. Lesson: hardware that reports
one finger at a time will lie to you occasionally — debounce both edges.

### Growing up — a real UI, calibration, and one tunable source of truth
Once the behavior was right, the app needed to be usable *on the touchscreen
itself*. Three moves: (1) every constant that used to be a `private let` in the
Engine moved into one persisted `AppSettings` object that the Engine reads live
and a SwiftUI window binds to — one source of truth, debounce-saved to disk.
(2) A touch-friendly settings window: big switches, a segmented right-click
picker, and large sliders, each with a tappable ⓘ (hover tooltips are useless on
a panel you touch). (3) Corner-tap **calibration** — a full-screen overlay puts
the Engine into a capture mode where taps are recorded raw and solved into a
per-axis linear map, so taps land where you touch even if the panel is offset.

Bugs fixed in the same pass: natural-scroll had *opposite* signs for one- vs
two-finger scrolling (so the toggle seemed dead for one finger) — unified to a
single sign; one-finger inertia got its own (faster) gain; and right-click became
selectable (touch-and-hold vs two-finger tap) because hold kept firing when the
user meant to drag.

### One engine choice, an on-screen keyboard, and edge gestures
The gesture controls had grown into overlapping booleans, so they collapsed into
one **GestureMode** (Off / Smooth / Shortcuts) with a live "what each gesture
does" map — a single mutually-exclusive choice the UI can explain. Smooth keeps
the synthesized animated zoom/rotate; **Shortcuts** is the legacy path: pinch →
⌘±, rotate → ⌘L/R, two-finger swipe → ⌘[ / ⌘], and a Three-finger toggle for
Mission Control / Exposé / desktop-switching via Ctrl+arrows (the one gesture
neither engine can animate).

Then a **non-activating on-screen keyboard** (so taps type into the focused app
without stealing focus), and **edge gestures** that reuse the calibrated extents:
3-finger pull up from the bottom opens the keyboard; 2-finger pull in from the
right opens Notification Center (best-effort via a menu-bar-clock click, since it
has no public trigger).

### Edge gestures, take two — dwell, and folding into the handlers
The first edge-gesture attempt used a separate pre-check on the first frame of a
multi-finger touch. It was flaky because fingers land *staggered* — a clean
3-finger frame rarely happens at once, so the normal scroll/swipe latch claimed
the gesture first. The fix was twofold: (1) **fold detection into the existing
handlers** (`handleSwipe` / `handleTwoFinger`) that already debounce finger
arrival, and (2) add a **dwell** — rest the fingers at the edge for a tunable time
before the pull counts, which both adds precision and guarantees all fingers are
down by the time it matters. Also fixed: Notification Center was opening on
whatever display had the cursor; now it clicks the clock on the *touch* display.

### A floating launcher (and why the keyboard wouldn't show)
Added a draggable 160×160 semi-transparent control to make the keyboard and
gesture-mode switch discoverable without memorizing edge pulls, collapsible to an
edge tab. Building it surfaced why the keyboard panel hadn't been appearing: an
accessory (menu-bar-only) app's non-activating panel needs
`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` to show on the
active Space, and `NSHostingView.fittingSize` is 0 before layout so the window was
being sized to nothing — fixed with an explicit content size.

### Code-review hardening pass
A full review surfaced four real issues, now fixed: (1) the HID input-report buffer
was a Swift `Array` whose pointer was handed to a long-lived callback via
`withUnsafeMutableBufferPointer` — undefined behavior once the closure returns;
replaced with a stable heap allocation. (2) The on-screen keyboard / floating
launcher couldn't be dragged in iPad mode, because one finger scrolls there — added
an `isOverPanel` hit-test so a one-finger drag over a floating panel drags it
instead. (3) Calibration could stall if the panel went silent instead of sending a
finger-up report — added a silence-based tap flush. (4) Two-finger contacts were
used in raw report order, so a frame-to-frame swap flipped the angle 180° and
jittered pinch/rotate — now sorted by contact id for a stable pair.

### Becoming Gatecaster
The project got a name — **Gatecaster** — and grew up accordingly: the package
and binary renamed, the "Shortcuts" engine relabeled **Legacy** (it's the
no-trackpad-synthesis path), the gesture recipe hardcoded (the
`~/v17ut-gesture.json` tuning file is no longer read), permission prompts added
for Accessibility and Input Monitoring at first launch, and a `DEVELOPER_API.md`
written so other developers can hook in — covering today's in-process hooks
(`isOverPanel`, the edge-gesture callbacks, the settings file) and the draft
spec for the planned local-socket multi-touch API.

### The virtual trackpad — closing the no-peripherals loop
With a keyboard on screen, the missing piece was pointing at *other* displays
without a mouse: a **virtual trackpad** panel whose surface the Engine claims and
runs in *relative* mode (deltas × sensitivity, clicks at the cursor — never at
the finger). Both it and the keyboard became resizable via a corner bean, which
taught one more lesson: the resize handler must be **event-driven**, because a
classic `nextEvent` tracking loop puts the run loop in event-tracking mode,
pausing the very HID callbacks that produce our synthetic drag — a self-deadlock.
The keyboard also grew an esc/F-row and sticky ⌘ ⌥ ⌃ fn modifiers (tap modifier,
tap key → combo), on by default.

### The input wedge — own both sides, skip the middleman
Dragging the keyboard's pull tab froze ALL touch input. Two fixes failed:
removing the blocking `setFrame(animate:)` nested run loop, and deferring frame
clamps so they never fought the window server's live drag. The real lesson was
architectural: panel dragging was the only place a touch became synthetic mouse
events that fed **window-server drag sessions and SwiftUI button tracking** —
machinery we don't control and that can wedge while holding the event stream.
Since we own both the input (engine) and the windows (our panels), the fix was to
**cut the middleman**: a dedicated `panelDrag` mode moves the window frame
directly — no mouse events, no drag session, nothing to get stuck. It also made
the tabs draggable and gave us clean engine-side resize (bean zone) for free. A
watchdog now force-releases any unmatched left-button-down as a last resort,
because a silently held button is exactly what "touch stopped working" feels like.

### Cleanup pass — deleting the code that taught us
Once everything worked, we removed the scaffolding: the entire crashing IOHID
**graft** (`gk_build` / `gk_post` / the struct ABI / the self-test), the unused
gesture-envelope no-ops, the dead config fields, and the developer test-pulse.
`GestureKit` shrank from ~330 lines to ~75 — just the working recipe and the
capture logger. The history lives in this file and `INTERNALS.md`, not in the source.

---

## What's still blocked, and why

The **3-finger Mission-Control swipe with its finger-following animation** is the
one thing we couldn't fake. Reason: that gesture is gated on the **number of
fingers**, and finger count lives in the raw touch-hardware data — exactly the
data macOS won't let us inject (and whose injection crashes WindowServer).
Magnify/rotate don't need finger count, which is why they *can* be faked. We
trigger Mission Control / Spaces via keyboard shortcuts instead — same result,
minus the animation.

In-app two-finger page-swipe (Safari back/forward) **is now working** — we
captured it, found it's a `type=29` subtype-6 pan (offset in field 113), and
wired it as a two-finger horizontal pan, latched against pinch/rotate.

**Why the 3-finger one is fundamentally different:** pinch/rotate/page-swipe are
recognized *inside the focused app* and only need one scalar number, which a
CGEvent can carry. The 3-finger Spaces swipe is recognized by *WindowServer*,
which needs the actual count and positions of the fingers, read from the
hardware — and CGEvents have no field for "3 fingers here." The only way to
supply that is to *fake the hardware*: a DriverKit **virtual HID multitouch
device** masquerading as a Magic Trackpad, fed Magic-Trackpad-2-format reports.
Then macOS's own driver animates Spaces natively. That's a system extension —
much bigger than this app — and the genuine (if heavy) path if the animated
3-finger gestures are ever a must-have. See `INTERNALS.md` §5.

---

## The part that actually unblocked this: being told to keep going

It's worth being honest about how the breakthrough happened, because it wasn't
the model's idea to keep trying.

After the WindowServer crash, I (Claude) concluded — more than once, and with
confidence — that animating real gestures was **impossible** on modern macOS. I
had what looked like airtight evidence: Apple publishes no API to create gesture
events, the graft method crashed the machine, the Hammerspoon maintainer had
tried and failed, and the original Calftrail author had said the old trick no
longer works. Four independent sources, all agreeing. I was ready to ship "use
keyboard shortcuts instead" as the final answer.

The user didn't accept that. The pushback was specific, not just "try harder":

- *"we did trigger the three-finger up before, so I believe it's possible"* —
  pointing at concrete evidence that contradicted my conclusion.
- *"ok but are we capturing the wrong thing then? shouldn't you research? to
  learn from someone else?"* — redirecting from *arguing about feasibility* to
  *measuring what actually happens* and *reading code that already works*.
- Then they handed me the exact thing to learn from:
  *"https://github.com/shueber/Touch-Up — this didn't work for my display, but
  how do they manage the multitouch?"*

That reframing is the whole reason this works today. The moment I stopped
treating "impossible" as a conclusion and started treating it as "I haven't
measured it yet," the path opened: tap the real trackpad, let AppKit label the
events, read Touch-Up's recipe, find the type-29 / mouse-event-base trick. Every
later fix (the stale config, the freeze, the cross-talk) came from that same
measure-don't-argue mode the user insisted on.

The lesson for me is uncomfortable but useful: **a confident "it can't be done"
backed by authoritative sources is still just a hypothesis until you've tried to
falsify it yourself.** The user's persistence was not stubbornness — it was the
correct epistemics, and I needed to be pushed into them.

## The meta-lesson

Every time we were stuck, the unblock came from **measuring instead of
arguing** — tapping real events and letting the OS label them — and from
**reading code that already worked** rather than trusting documentation or
authority that said "impossible." The hardest bugs (wrong event, stale config,
concurrent scroll) were invisible until we built tests that isolated one variable
at a time.
