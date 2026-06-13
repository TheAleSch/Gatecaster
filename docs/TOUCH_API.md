# Gatecaster — Touch API

A client developer's guide to consuming touches and gestures from Gatecaster,
and to suppressing the driver's own input injection.

Gatecaster is a user-space macOS driver that turns a USB HID touchscreen into a
full Mac input device. By default it *drives* the Mac — moving the pointer,
clicking, scrolling, synthesizing pinch/rotate, popping the on-screen keyboard.
The **Touch API** is the out-of-process door: a local socket your app connects
to in order to read the raw touch stream, react to recognized gestures, and (for
games and kiosks) tell Gatecaster to stop injecting system input while you own
the screen.

> **Protocol-at-a-glance** for someone working *on the driver* lives in
> [DEVELOPER_API.md §3](DEVELOPER_API.md#3-public-multi-touch-api). This document
> is the client-facing companion. The authoritative implementation is
> [TouchAPI.swift](../Sources/Gatecaster/TouchAPI.swift) — if anything here ever
> disagrees with that file, the file wins.

Runnable reference clients live in [`examples/touch-api/`](../examples/touch-api/).

---

## 1. Overview & when to use it

Reach for the Touch API when you want your app to react to the touchscreen
**directly** rather than through the synthetic mouse/trackpad events Gatecaster
posts to the system. Two broad cases:

- **You want the touch data.** A drawing app, a music controller, a multi-touch
  visualization — anything that wants real finger positions (all ten of them,
  with stable ids) instead of a single synthesized cursor. Subscribe to the
  finger and/or gesture channels and read frames.

- **You want the screen to yourself.** A full-screen game or a kiosk app that
  draws its own touch UI does *not* want Gatecaster also moving the pointer,
  firing pinch-zoom into the foreground window, or pulling up the on-screen
  keyboard from a bottom-edge swipe. Use the *suppress* command to mute exactly
  the categories you handle yourself, for exactly as long as you're connected.

You can do both at once on a single connection: subscribe to `fingers`,
suppress `input`, and you have a clean multi-touch surface that no longer fights
with the system pointer.

**When NOT to use it:** if you just want the touchscreen to act like a mouse and
trackpad for ordinary Mac apps, you need nothing here — that's the default
behavior. The Touch API is for apps that consume touch *themselves*.

The transport is a Unix-domain socket, local-only by construction (no network
listener exists). Any language that can open an `AF_UNIX` stream socket and read
lines of JSON can be a client; the examples are dependency-free Python, Node.js,
and Swift.

---

## 2. Connecting

### Socket path

```
~/Library/Application Support/Gatecaster/api.sock
```

It's a `SOCK_STREAM` Unix-domain socket. The Gatecaster app creates it on launch
and removes it on quit. If the file is absent, **Gatecaster isn't running** (or
hasn't finished starting) — see [Troubleshooting](#10-troubleshooting--faq).

Expand `~` to the *invoking user's* home directory. In Python:

```python
import os
SOCK = os.path.expanduser("~/Library/Application Support/Gatecaster/api.sock")
```

### The hello

The instant you connect, the server sends exactly one `hello` line, before you
send anything:

```json
{"v":1,"type":"hello","ready":true,
 "caps":["fingers","rawFingers","gestures","suppress"],
 "screen":{"x":0,"y":0,"w":1920,"h":1080},
 "panel":{"xMin":120,"xMax":3960,"yMin":80,"yMax":2240}}
```

| Field    | Meaning |
|----------|---------|
| `v`      | Protocol version (currently `1`). See [Versioning](#8-versioning--forward-compatibility). |
| `type`   | Always `"hello"` for this message. |
| `ready`  | `true` once Gatecaster has resolved its target display; see below. |
| `caps`   | Capability tokens this server supports. Future servers may add more — match by presence, don't assume the exact set. |
| `screen` | The active display's bounds in CG screen pixels: origin (`x`,`y`) and size (`w`,`h`). |
| `panel`  | The calibrated raw-panel rectangle (`xMin`..`xMax`, `yMin`..`yMax`) that maps onto `screen`. |

Read the hello first, before processing any other line. It's the only place the
geometry is advertised.

### The `ready` flag

`ready` is `false` if you connect *before* Gatecaster has resolved which display
it's driving (right at launch, or mid-display-hotplug). While not ready, the
`screen`/`panel` bounds are still zero and any normalized→screen transform you
compute from them is garbage.

Crucially: **finger `sx`/`sy` (screen-pixel coordinates) are always live**,
because the Engine maps them itself before publishing. So even on a `ready:false`
connection you can use `sx`/`sy` immediately — you just shouldn't trust `screen`,
`panel`, or your own math against them yet.

If you depend on the geometry, the simplest robust pattern is: **on
`ready:false`, close and reconnect after a short delay** until you get a
`ready:true` hello. The server does not send a second hello to upgrade an
existing connection.

### Reconnection

Treat the socket as something that can vanish: Gatecaster may be quit and
relaunched, the display may change. A resilient client loops:

1. Try to connect. If the socket file is missing or `connect()` is refused, wait
   (e.g. 1 s) and retry — Gatecaster may not be up yet.
2. On connect, read and parse the hello. If `ready` is false and you need
   geometry, drop and retry.
3. Read frames until the connection closes (EOF / error), then go back to step 1.

Your suppress and subscription state is **per connection** and does not survive a
reconnect — re-send your `subscribe`/`suppress` commands after each new hello.
This is by design: it's what makes a crashed client unable to leave touch wedged
off (see [§6](#6-suppressing-input--games--kiosks)).

---

## 3. Subscriptions & channels

You receive nothing until you subscribe. Send:

```json
{"subscribe":["fingers","gestures"]}
```

This **replaces** your current subscription set (it is not additive). To
unsubscribe from everything, send `{"subscribe":[]}`. You may re-subscribe at any
time, as often as you like.

Three channels are available:

| Channel      | What you get |
|--------------|--------------|
| `fingers`    | Post-palm-rejection contacts — exactly the touches the Engine treats as real input. `palm` is always `false` here. This is what most apps want. |
| `rawFingers` | *Every* contact the panel reports, each flagged with `palm` (`true` = palm rejection would have filtered it). For apps doing their own rejection. |
| `gestures`   | Recognized gestures (pinch / rotate / scroll / swipe) after the Engine's intent latch decides what a multi-finger motion is. |

You can subscribe to any combination. Subscribing to both `fingers` and
`rawFingers` delivers two frames per panel report (one per channel) — usually you
want one or the other, not both.

A subscription only controls what's *delivered* to you; it does not affect
whether Gatecaster drives the Mac. Reading touches and suppressing input are
independent (see [§6](#6-suppressing-input--games--kiosks)).

---

## 4. Finger frames

A finger frame is sent each panel report while you're subscribed to `fingers`
and/or `rawFingers`, up to roughly the panel's report rate (~120/s — see
[§7](#7-backpressure--performance)).

```json
{"v":1,"type":"fingers","t":1717000000.123,"dropped":0,"fingers":[
  {"id":3,"x":0.412,"y":0.875,"sx":791.0,"sy":945.0,"phase":"moved","palm":false}
]}
```

### Frame fields

| Field     | Type        | Meaning |
|-----------|-------------|---------|
| `v`       | int         | Protocol version. |
| `type`    | string      | `"fingers"`. |
| `t`       | float       | Unix timestamp in seconds (fractional), stamped when the frame was produced. |
| `dropped` | int         | Frames discarded for *this client* since the last delivered frame (slow consumer). Always present; `0` in the normal case. See [§7](#7-backpressure--performance). |
| `fingers` | array       | Zero or more contact objects (below). An all-fingers-lifted frame carries the terminal `ended`/`cancelled` entries, then subsequent frames have an empty array. |

### Contact fields

| Field   | Type   | Meaning |
|---------|--------|---------|
| `id`    | int    | Stable contact id for the lifetime of one touch. Reused by the panel after a finger lifts; correlate motion by id within a touch, not across lifts. |
| `x`     | float  | Normalized horizontal position, `0`–`1`, in **calibrated panel space** (rounded to 6 decimals). |
| `y`     | float  | Normalized vertical position, `0`–`1`, in calibrated panel space. |
| `sx`    | float  | Screen X in CG pixels, already mapped through calibration + the active display (rounded to 2 decimals). |
| `sy`    | float  | Screen Y in CG pixels (rounded to 2 decimals). |
| `phase` | string | Lifecycle: `began` / `moved` / `ended` / `cancelled` (see below). |
| `palm`  | bool   | Only meaningful on `rawFingers`; always `false` on `fingers`. |

### Coordinate spaces

There are two coordinate spaces in every contact, and they answer different
questions:

- **`sx`/`sy` — screen pixels.** Use these to position something on screen, hit-
  test against a window, or drive a cursor. They're already correct for the
  active display; no math needed. Origin is the CG global top-left, matching the
  `screen` rectangle in the hello.

- **`x`/`y` — normalized panel space, 0–1.** Use these when you want a
  resolution-independent position on the touch surface itself (e.g. mapping a
  finger to a position in *your own* canvas), independent of which display
  Gatecaster happens to be driving.

**Worked normalized → screen example.** Given the hello above
(`screen` = origin (0,0), size 1920×1080) and a contact at `x:0.412, y:0.875`:

```
screenX = screen.x + x * screen.w = 0 + 0.412 * 1920 = 791.0
screenY = screen.y + y * screen.h = 0 + 0.875 * 1080 = 945.0
```

…which is exactly the `sx:791.0, sy:945.0` the server already gave you. In other
words you normally **don't** need to do this — `sx`/`sy` are the result of this
mapping. The normalized values are there for when you want panel-relative
positions, and the formula above is how the two relate.

### The phase lifecycle

A contact moves through phases over its life:

```
began ──▶ moved ──▶ moved ──▶ … ──▶ ended        (normal lift)
                                 └─▶ cancelled    (taken away, not lifted)
```

- **`began`** — first frame this id is seen down.
- **`moved`** — any subsequent frame the id is still down (position may or may
  not have changed).
- **`ended`** — the user lifted the finger. This is the contact's last frame; its
  `sx`/`sy`/`x`/`y` carry the last-seen position.
- **`cancelled`** — the contact went away *without* a user lift: palm rejection
  ate it mid-touch, or the Engine reset. Treat it like `ended` for cleanup, but
  know the gesture it was part of should be abandoned, not committed.

Two edge cases worth handling explicitly:

- **Connecting mid-touch.** If a finger is already down when you connect (or when
  you subscribe), its first frame to you may be `moved`, not `began`. Don't assume
  every id's first appearance is `began` — tolerate a leading `moved`.
- **`cancelled` only on the `fingers` channel.** A contact that palm rejection
  removes mid-touch is reported `cancelled` on `fingers`. On `rawFingers` that
  same contact is never *removed* by rejection — it stays present (with
  `palm:true`) until the user actually lifts, at which point it's `ended`.

### The `palm` flag

On `rawFingers`, `palm:true` marks a contact that Gatecaster's behavioral palm
rejection would filter out (it reports no contact area, so rejection is a
heuristic — see [CLAUDE.md](../CLAUDE.md)). If you're building your own rejection
on the raw stream, this is the driver's verdict for reference. A contact's *last*
(`ended`) frame carries its last-seen palm verdict, so a palm that was a palm all
along doesn't suddenly read `palm:false` as it lifts.

On `fingers`, palm-rejected contacts are simply absent, so `palm` is always
`false`.

---

## 5. Gesture events

Sent only while subscribed to `gestures`, after the Engine's two-finger intent
latch (or three-finger detector) has committed to *what* a motion is. One JSON
line per event:

```json
{"v":1,"type":"gesture","t":...,"gesture":"pinch","value":0.034,"phase":"changed"}
{"v":1,"type":"gesture","t":...,"gesture":"rotate","value":-1.2,"phase":"changed"}
{"v":1,"type":"gesture","t":...,"gesture":"scroll","dx":0.0,"dy":-13.5,"phase":"changed"}
{"v":1,"type":"gesture","t":...,"gesture":"swipe","direction":"left","fingers":3}
```

Common fields: `v`, `type` (`"gesture"`), `t` (Unix seconds), and `gesture` (the
kind). The remaining fields depend on the kind:

| `gesture`  | Carries `phase`? | Payload fields | Meaning |
|------------|------------------|----------------|---------|
| `pinch`    | yes (`began`/`changed`/`ended`) | `value` | `value` = pinch ratio delta (positive = spread/zoom-in, negative = pinch-in), per event. |
| `rotate`   | yes | `value` | `value` = rotation in **degrees** for this event (sign = direction). |
| `scroll`   | yes | `dx`, `dy` | Scroll deltas in **pixels** (`dy` negative = content moves up, matching the wheel convention). |
| `swipe`    | **no** (one-shot) | `direction`, `fingers` | A discrete multi-finger swipe; `direction` ∈ `left`/`right`/`up`/`down`, `fingers` = finger count (e.g. `3`). |

**Phase bracketing.** For `pinch`/`rotate`/`scroll`, a continuous motion arrives
as a `began`, a run of `changed`, and a terminal `ended`. Use them to bracket an
animation: start on `began`, accumulate on each `changed`, finalize on `ended`.
Always expect the `ended` — don't leave an animation open if the stream pauses.

**`swipe` is a single event** with no phase: there is no began/ended to bracket,
you just react once when it arrives.

`value` and the deltas are rounded server-side (6 decimals for `value`, 2 for
`dx`/`dy`).

Because `value`/`dx`/`dy` are *per-event* deltas, accumulate them yourself if you
want an absolute total over the gesture.

---

## 6. Suppressing input — games & kiosks

If your app draws its own touch UI, you'll want Gatecaster to stop injecting the
system input you're handling yourself. Send a `suppress` command:

```json
{"suppress":["input","gestures","edges"]}
```

You pick exactly which categories to mute:

| Category   | Mutes |
|------------|-------|
| `input`    | Pointer move / click / drag / scroll / keystroke injection. |
| `gestures` | Synthesized pinch / rotate trackpad events. |
| `edges`    | Edge-pull triggers: the on-screen keyboard (bottom-edge pull) and Notification Center (right-edge pull). |

Shorthand forms:

```json
{"suppress":true}     // all three categories
{"suppress":false}    // clear (mute nothing); same as []
{"suppress":[]}       // clear
```

A `suppress` command **replaces** your previous mask. To change what you mute,
send a new full mask.

### Union semantics

The live suppression state is the **union of every connected client's mask**. If
client A suppresses `input` and client B suppresses `gestures`, then both `input`
and `gestures` are muted system-wide while both are connected. A category stays
muted as long as *at least one* client asks for it.

This means you can't *force* something back on that another client is holding off
— but in practice the consumer count is tiny (a game, a kiosk), and each client
only suppresses what it actually handles.

### Connection-scoped lease, and why there's no TTL

A client's suppress contribution is **leased to its socket connection**. When you
disconnect — cleanly, or because you crashed, or the socket dropped — your
contribution is removed automatically and the union recomputes without you.

That's the safety guarantee: **a crashed or hung client can never leave the Mac
with touch input wedged off.** The OS tears down the socket when your process
dies; the server sees the EOF and drops your mask. There is deliberately **no
TTL and no heartbeat** — you don't have to keep pinging to retain suppression,
and you can't forget to release it. The socket *is* the lease.

The practical consequence: **hold the connection open for exactly as long as you
want to suppress.** To stop suppressing, either send `{"suppress":false}` or just
close the socket. A kiosk app typically suppresses on launch and simply stays
connected for its whole lifetime.

When suppression transitions on or off, Gatecaster logs a one-line notice to
stderr (`input suppression ON (a client owns touch)` / `…cleared`) so an operator
can see that a client owns touch — useful when debugging "the touchscreen stopped
responding."

### A note on subscribing while suppressing

Suppressing `input` does not subscribe you to anything, and subscribing doesn't
suppress anything — they're orthogonal. A game usually wants both: subscribe to
`fingers` (to read touch) *and* suppress `input` (so the pointer doesn't also
move). Send both commands after the hello.

---

## 7. Backpressure & performance

Finger frames can arrive at the panel's full report rate — budget for roughly
**120 frames per second**, each potentially carrying up to ten contacts. Your
reader has to keep up.

The server never blocks on a slow client. Frames are encoded once and written
**non-blocking** to each connection. If your connection's outbound buffer backs
up past the server's cap (~256 KB), the server **drops whole frames** (at frame
boundaries, so the NDJSON stream stays line-valid) and counts them. The next
frame you *do* receive reports the count in its `dropped` field:

```json
{"v":1,"type":"fingers","t":...,"dropped":7,"fingers":[ … ]}
```

`dropped:7` means seven frames were shed for you since your last delivered frame.
A nonzero `dropped` is your signal that **your reader is too slow** — you're
falling behind the panel.

Keep your read path lean:

- **Read in a tight loop** and parse incrementally; don't do heavy work (layout,
  disk, network) on the socket-reading thread between reads.
- **Buffer partial lines correctly.** A single `recv()` may contain several
  frames *and* a partial trailing line; split on `\n`, process complete lines,
  and keep the remainder for the next read. (Both reference clients show this.)
- **Coalesce if you fall behind.** If you only care about the latest finger
  positions, it's fine to drain and keep only the most recent frame; `dropped`
  already tells you the server did some of that for you.

Dropping only ever affects the lagging client — other clients and the driver
itself are unaffected.

---

## 8. Versioning & forward-compatibility

Every message carries a `v` field (currently `1`). The rule:

- **`v` bumps only on a breaking change** — a field removed, or a field's meaning
  changed.
- **Additive changes do not bump `v`.** New fields, new gesture kinds, new
  capability tokens, new phases may appear within the same `v`.

Therefore, to stay forward-compatible, your client **MUST**:

1. **Ignore unknown fields** on any message rather than rejecting the message.
2. **Ignore unknown `gesture` kinds** rather than erroring — a future Gatecaster
   may emit a gesture your code predates.
3. **Match capabilities by presence** in `caps`, not by exact set equality.

If you ever see a `v` higher than you were written for, the safe move is to keep
running on the fields you recognize (they're guaranteed still present unless `v`
bumped for a removal you'd need to handle) — or refuse with a clear message if
you require a feature gated behind that version.

---

## 9. Full worked example

The [`examples/touch-api/`](../examples/touch-api/) directory has runnable,
dependency-free reference clients that exercise everything above:

- **[`client.py`](../examples/touch-api/client.py)** — Python 3, standard library
  only. Connects (reconnecting if the socket isn't there yet), parses the hello,
  subscribes to `fingers` + `gestures`, and prints a live readout: a one-line
  finger summary that updates in place, plus gesture events as they arrive. It
  buffers partial lines across `recv()` boundaries correctly, tolerates junk and
  unknown messages, and shuts down cleanly on Ctrl-C. Pass `--suppress` to
  demonstrate kiosk mode: it suppresses `input` (the pointer stops moving) and
  holds it until you Ctrl-C, releasing on exit.

- **[`client.js`](../examples/touch-api/client.js)** — the same thing in Node.js,
  using only the built-in `net` module.

- **[`client.swift`](../examples/touch-api/client.swift)** — the same thing in
  Swift, using `Network.framework` (`NWConnection`) for the connection and
  `Codable` models for the wire format. Runs as a script (`swift client.swift`),
  but its `LineReader`, `TouchClient`, and model structs drop straight into a
  real macOS app — the canonical example if you're integrating from Swift.

Run any of them and touch the panel; see [the examples README](../examples/touch-api/README.md)
for exact commands and expected output.

The shape every client follows:

```
connect  →  read hello (check ready)  →  send subscribe (+ optional suppress)
         →  loop: recv bytes, split on '\n', parse each line, dispatch by `type`
         →  on EOF/error: clean up, optionally reconnect
```

---

## 10. Troubleshooting / FAQ

**The socket file doesn't exist / connection refused.**
Gatecaster isn't running, or hasn't finished launching. The app creates the
socket on startup and removes it on quit. Launch `Gatecaster.app` (or the bare
binary), confirm it has its required permissions, then retry. A resilient client
should just keep retrying with a short delay.

**`ready` is never `true`.**
Gatecaster hasn't resolved a target display. Make sure the panel is connected and
Gatecaster has actually picked a screen (it may be waiting on display selection
or a hotplug). Remember `sx`/`sy` are usable even while `ready:false`; only the
hello's `screen`/`panel` geometry is untrustworthy until ready.

**I connected but no frames arrive.**
You haven't subscribed. Send `{"subscribe":["fingers"]}` (or whichever channels
you want) — the server sends nothing until you do. Also confirm a finger is
actually touching the panel; an idle panel produces no frames.

**Frames arrive but `dropped` keeps climbing.**
Your reader is too slow and the server is shedding frames for you. See
[§7](#7-backpressure--performance) — lighten the read path, or coalesce to the
latest frame.

**Input still moves the pointer even though I sent `suppress`.**
Check three things: (1) you sent the command *after* the hello on the same
connection; (2) you used a valid form (`{"suppress":["input"]}` or
`{"suppress":true}`) — a malformed line is silently ignored; (3) another client
isn't the issue — suppression is a *union*, so your own missing/incorrect mask is
the only thing that would leave `input` live. Gatecaster logs the on/off
transition to stderr, which is the quickest way to confirm whether *anyone* is
suppressing.

**Touch is wedged off after my app exited.**
This shouldn't be possible — suppression is leased to the socket and released on
disconnect. If you see it, the connection probably didn't actually close (a
lingering child process or a duplicated fd still holds it open). Confirm your
process and all its children have exited; the lease releases on the *last* holder
of the socket.

**My first frame for a finger says `moved`, not `began`.**
You connected (or subscribed) mid-touch, with a finger already down. Expected —
tolerate a leading `moved` (see [§4](#4-finger-frames)).

**I got a `gesture` kind I don't recognize.**
A newer Gatecaster emitted a gesture your client predates. Ignore it (see
[§8](#8-versioning--forward-compatibility)); it's not an error.

**Can two apps both read touch?**
Yes. Up to 16 concurrent clients, each with independent subscription and suppress
state. Frames are broadcast to every subscriber.

---

## Appendix — message reference

All messages are single-line JSON terminated by `\n` (NDJSON), both directions.

### Server → client

**`hello`** (once, on connect)
```json
{"v":1,"type":"hello","ready":true,
 "caps":["fingers","rawFingers","gestures","suppress"],
 "screen":{"x":0,"y":0,"w":1920,"h":1080},
 "panel":{"xMin":120,"xMax":3960,"yMin":80,"yMax":2240}}
```

**`fingers`** (per panel report, while subscribed to `fingers`/`rawFingers`)
```json
{"v":1,"type":"fingers","t":1717000000.123,"dropped":0,"fingers":[
  {"id":3,"x":0.412,"y":0.875,"sx":791.0,"sy":945.0,"phase":"moved","palm":false}
]}
```
`phase` ∈ `began`/`moved`/`ended`/`cancelled`.

**`gesture`** (while subscribed to `gestures`)
```json
{"v":1,"type":"gesture","t":...,"gesture":"pinch","value":0.034,"phase":"changed"}
{"v":1,"type":"gesture","t":...,"gesture":"rotate","value":-1.2,"phase":"changed"}
{"v":1,"type":"gesture","t":...,"gesture":"scroll","dx":0.0,"dy":-13.5,"phase":"changed"}
{"v":1,"type":"gesture","t":...,"gesture":"swipe","direction":"left","fingers":3}
```

### Client → server

```json
{"subscribe":["fingers","gestures"]}     // replaces current subscription set; [] = none
{"suppress":["input","gestures","edges"]} // replaces current mask
{"suppress":true}                         // all categories
{"suppress":false}                        // none (also: [])
```

Channels: `fingers`, `rawFingers`, `gestures`.
Suppress categories: `input`, `gestures`, `edges`.

Send commands any time after the hello, one JSON object per line. Unknown/junk
lines are ignored. Subscription and suppress state are per connection and reset
on reconnect.

---

*Implementation: [TouchAPI.swift](../Sources/Gatecaster/TouchAPI.swift). Driver-side
protocol notes: [DEVELOPER_API.md §3](DEVELOPER_API.md#3-public-multi-touch-api).*
