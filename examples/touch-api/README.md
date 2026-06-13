# Gatecaster Touch API — example clients

Dependency-free reference clients for the Gatecaster Touch API. They connect to
the local socket, subscribe to the finger and gesture channels, print a live
readout, and (with `--suppress`) demonstrate kiosk-style input suppression.

Full protocol guide: [`../../docs/TOUCH_API.md`](../../docs/TOUCH_API.md).

## Requirements

- **Gatecaster must be running.** The clients connect to the socket it creates at
  `~/Library/Application Support/Gatecaster/api.sock` on launch. If Gatecaster
  isn't up, the clients wait and retry until it is.
- A touchscreen Gatecaster supports, connected and resolved to a display.
- Python 3.6+ (for `client.py`) or Node.js 12+ (for `client.js`). No packages to
  install — both use only the standard library.

## Run

Python:

```bash
python3 client.py              # read-only: print fingers + gestures
python3 client.py --suppress   # also suppress system input (kiosk demo)
```

Node.js:

```bash
node client.js                 # read-only
node client.js --suppress      # also suppress system input (kiosk demo)
```

## What you should see

On connect, a line summarizing the hello:

```
connected: v1 caps=["fingers","rawFingers","gestures","suppress"]
ready: screen 1920x1080 @ (0,0)
```

Then, as you touch the panel, a finger summary line that updates **in place**
(one line, rewritten each frame) showing every contact's id, phase, and screen
position:

```
fingers[2]: #3:move (791,945)  #4:move (612,310)
```

Lift all fingers and it reads `fingers: (none)`. Multi-finger gestures print on
their own lines as they're recognized:

```
gesture scroll dx=0.0 dy=-13.5 phase=changed
gesture pinch value=0.034 phase=changed
gesture swipe left fingers=3
```

If your machine is too slow to keep up, you'll see a `(dropped N)` note on the
finger line — that's the server shedding frames for this client (see the
guide's backpressure section).

## Kiosk mode (`--suppress`)

With `--suppress`, the client sends `{"suppress":["input"]}` after connecting:
Gatecaster stops moving the pointer / clicking / scrolling / typing while the
client runs. You'll still see fingers and gestures in the readout, but the Mac's
cursor won't react to touch.

Press **Ctrl-C** to quit. Suppression is leased to the socket connection, so it's
released the instant the client exits — there's nothing to clean up and no way to
leave touch wedged off. (The client also sends an explicit `{"suppress":false}`
on the way out, which is just belt-and-suspenders.)
