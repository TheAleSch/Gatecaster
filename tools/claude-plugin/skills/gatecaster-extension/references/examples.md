# Complete example manifests

Copy-ready, each validated. Start from the one nearest your goal.

## 1. Static button board (no data)

A keyboard/launcher tile. `interpreter`/`shell` actions need `capabilities:["shell"]`.

```json
{
  "v": 2,
  "id": "com.you.shortcuts",
  "name": "Shortcuts",
  "symbol": "square.grid.2x2",
  "colorHex": "#5E5CE6",
  "minW": 2, "minH": 2, "defaultW": 2, "defaultH": 2,
  "buttons": [
    { "symbol": "terminal", "label": "Build", "run": "build" },
    { "symbol": "safari", "label": "Docs", "action": { "kind": "url", "value": "https://example.com/docs" } },
    { "symbol": "moon.fill", "label": "DND", "action": { "kind": "shortcut", "value": "Toggle Do Not Disturb" } }
  ],
  "actions": {
    "build": { "interpreter": "zsh", "script": "cd ~/proj && make build" }
  },
  "capabilities": ["shell"]
}
```

Toggle (multi-state) button:

```json
{ "states": [
  { "symbol": "play.fill",  "label": "Play",  "action": { "kind": "media", "value": "play" } },
  { "symbol": "pause.fill", "label": "Pause", "action": { "kind": "media", "value": "pause" } }
] }
```

## 2. Poll, JSON parse (the 90% path)

`refresh.command` prints one JSON object; keys match field `refreshKey`s. No
capability needed for the poll command itself.

```json
{
  "v": 2,
  "id": "com.you.weather",
  "name": "Weather",
  "symbol": "cloud.sun.fill",
  "colorHex": "#30B0C7",
  "fields": [
    { "label": "Now",  "refreshKey": "temp", "size": "large" },
    { "label": "Wind", "refreshKey": "wind" }
  ],
  "refresh": {
    "command": "scripts/weather.sh",
    "everySeconds": 600,
    "parse": { "kind": "json" }
  }
}
```

`scripts/weather.sh`:

```sh
#!/bin/zsh
print -r -- '{"temp":"18°","wind":"12 km/h"}'
```

## 3. Poll, delimited parse

When the command emits columns, not JSON.

```json
{
  "v": 2,
  "id": "com.you.sys",
  "name": "System",
  "fields": [
    { "label": "CPU", "refreshKey": "cpu" },
    { "label": "Mem", "refreshKey": "mem" }
  ],
  "refresh": {
    "command": "echo \"$(cpu)|$(mem)\"",
    "everySeconds": 5,
    "parse": { "kind": "delimited", "delimiter": "|", "fields": ["cpu", "mem"] }
  }
}
```

## 4. Push provider with a button command

Real-time. Needs `capabilities:["process"]`. The button's `run:"ping"` resolves to
the `ping` action whose `kind:"provider"` value is sent to the provider's stdin; the
provider answers with a `patch`. Ships `gatecaster-provider.js` (the shim) alongside.

```json
{
  "v": 2,
  "id": "com.you.pulse",
  "name": "Pulse",
  "symbol": "waveform.path.ecg",
  "colorHex": "#FF2D55",
  "fields": [
    { "label": "Status",    "refreshKey": "status", "value": "…" },
    { "label": "Last ping", "refreshKey": "pong",   "value": "—" }
  ],
  "buttons": [
    { "symbol": "bolt.fill", "label": "Ping", "run": "ping" }
  ],
  "actions": {
    "ping": { "kind": "provider", "value": "ping", "then": "refresh" }
  },
  "provider": { "command": "node provider.js", "caps": ["state"] },
  "capabilities": ["process"]
}
```

`provider.js` (see `provider-protocol.md` for the full protocol):

```js
import { provider } from "./gatecaster-provider.js";
let timer = null;
provider({
  start({ patch }) {
    patch({ status: "up" });
    timer = setInterval(() => patch({ status: "up @ " + new Date().toLocaleTimeString() }), 2000);
  },
  command(name, _msg, { patch }) {
    if (name === "ping") patch({ pong: new Date().toLocaleTimeString() });
  },
  stop() { if (timer) clearInterval(timer); }
});
```

## 5. Config + secret (token-backed poll)

```json
{
  "v": 2,
  "id": "com.you.tickets",
  "name": "Tickets",
  "fields": [{ "label": "Open", "refreshKey": "open" }],
  "refresh": { "command": "scripts/tickets.sh", "everySeconds": 120 },
  "configSchema": [
    { "key": "project", "label": "Project key", "type": "text" }
  ],
  "secrets": [
    { "key": "API_TOKEN", "label": "API token" }
  ],
  "capabilities": ["secrets", "network"]
}
```

`scripts/tickets.sh` reads `$GATECASTER_SECRET_API_TOKEN` and
`$GATECASTER_CONFIG_PROJECT` from the env — never hardcode the token.

## 6. Interactive slider + dial (drag-to-set, §5.9)

A drag-to-set **slider** (output volume) and **dial** (mic volume). The dragged
int lands as `$value`; the slider uses the ungated `volume` kind, the dial uses a
`shell` osascript (so the pack declares `capabilities:["shell"]`). A `delimited`
refresh seeds both controls' start positions. Full pack:
`examples/extensions/com.gatecaster.audio/`.

```json
{
  "v": 2,
  "id": "com.you.audio",
  "name": "Audio",
  "symbol": "speaker.wave.3.fill",
  "minW": 2, "minH": 2, "defaultW": 2, "defaultH": 3,
  "fields": [
    { "label": "Output", "type": "slider", "orientation": "vertical",
      "refreshKey": "out", "min": 0, "max": 100,
      "action": { "kind": "volume", "value": "$value" } },
    { "label": "Mic", "type": "dial",
      "refreshKey": "mic", "min": 0, "max": 100, "run": "setMic" }
  ],
  "actions": {
    "setMic": { "kind": "shell",
      "value": "osascript -e 'set volume input volume $value'", "then": "refresh" }
  },
  "refresh": {
    "command": "osascript -e 'set v to (get volume settings)' -e 'return ((output volume of v) as text) & \"|\" & ((input volume of v) as text)'",
    "everySeconds": 3,
    "parse": { "kind": "delimited", "delimiter": "|", "fields": ["out", "mic"] }
  },
  "capabilities": ["shell"]
}
```

The slider needs no capability (`volume` is ungated); the dial does, because it
shells out. Drop the `setMic` dial and you have a one-control volume slider with
zero capabilities.
