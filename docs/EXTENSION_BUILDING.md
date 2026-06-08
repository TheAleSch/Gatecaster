# Building a Gatecaster widget — a step-by-step tutorial

*Build a live widget for the Gatecaster Deck in about 15 minutes. No Swift, no
compiler, no developer account. If you can edit a text file, you can ship a
widget.*

> The Deck is Gatecaster's Stream Deck-style control surface that lives right
> on your touchscreen. Widgets are the live tiles on it — a clock, your now-
> playing track, a meeting's "join" button. This guide builds one from scratch.

---

## What you'll build

A **"Now Playing"** widget that shows the current track and artist and has
play/pause and skip buttons. Along the way you'll learn every piece of the
format, so you can build a widget for anything — Discord status, a Zoom "join
next meeting" button, a build-server light, your smart-home scene.

---

## 1. The mental model

A widget is just a **folder with one file**: `manifest.json`. That file
describes a tile:

- **how it looks** — a name, an icon, a color;
- **what it shows** — "fields" of live text;
- **what it does** — "buttons" that fire actions;
- **how it stays live** — an optional "refresh" command that feeds the fields.

Gatecaster reads the manifest and draws the tile. You never write UI code —
you *describe* the tile and Gatecaster renders it. That's also why the same
widget will keep working if Gatecaster comes to Windows later: you wrote data,
not platform code.

---

## 2. Create the folder

Widgets live here:

```
~/Library/Application Support/Gatecaster/Extensions/<your-id>/manifest.json
```

Pick a unique reverse-DNS id (like a domain you own, backwards). Make the
folder:

```bash
mkdir -p ~/Library/Application\ Support/Gatecaster/Extensions/com.yourname.nowplaying
```

> Shortcut: in the Deck, tap **Edit** (pencil), then the **＋** on the widget
> rail → **Open Extensions Folder…**. It opens this exact location.

---

## 3. The smallest possible widget

Create `manifest.json` in that folder with just the essentials:

```json
{
  "id": "com.yourname.nowplaying",
  "name": "Now Playing",
  "symbol": "music.note",
  "colorHex": "#32D74B"
}
```

- `id` — must match nothing else installed; reverse-DNS is the convention.
- `name` — shown in the tile header and the "add widget" menu.
- `symbol` — any [SF Symbol](https://developer.apple.com/sf-symbols/) name.
- `colorHex` — the header icon tint.

In the Deck: **Edit → ＋ on the widget rail → Reload Extensions**, then pick
**Now Playing**. You'll see an (empty) tile. That's a working widget already.

---

## 4. Add buttons

Buttons fire **actions**. Gatecaster gives you a small, safe set — the same one
the Deck's own buttons use:

| `kind`      | `value` example              | what it does |
|-------------|------------------------------|--------------|
| `app`       | `"Spotify"`                  | open an app by name or `.app` path |
| `url`       | `"https://open.spotify.com"` | open a link |
| `keystroke` | `"cmd+shift+m"`              | press a shortcut (`fn+f8` = play/pause) |
| `shortcut`  | `"My Shortcut"`              | run an Apple Shortcut by name |
| `shell`     | `"open ~/Music"`             | run a shell command |
| `volume`    | `"40"`                       | set output volume (0–100) |

Add three media buttons:

```json
{
  "id": "com.yourname.nowplaying",
  "name": "Now Playing",
  "symbol": "music.note",
  "colorHex": "#32D74B",
  "buttons": [
    { "symbol": "backward.fill",  "action": { "kind": "keystroke", "value": "fn+f7" } },
    { "symbol": "playpause.fill", "action": { "kind": "keystroke", "value": "fn+f8" } },
    { "symbol": "forward.fill",   "action": { "kind": "keystroke", "value": "fn+f9" } }
  ]
}
```

Each button can have a `symbol`, a `label`, or both. Reload — your tile now has
working transport controls.

---

## 5. Show live information (fields + refresh)

Fields are rows of text. A field's value can be **static** (`value`) or
**live** (`refreshKey`, pulled from a refresh command).

The `refresh` command runs on a timer; **its standard output must be one flat
JSON object**. Every key in that object becomes available to fields via
`refreshKey`.

Here's a refresh command that reads the current track from Apple Music and
prints `{"title": "...", "artist": "..."}`:

```bash
osascript -e 'tell application "Music" to set t to name of current track & "|" & artist of current track' \
  | awk -F'|' '{printf "{\"title\":\"%s\",\"artist\":\"%s\"}", $1, $2}'
```

Wire it in:

```json
{
  "id": "com.yourname.nowplaying",
  "name": "Now Playing",
  "symbol": "music.note",
  "colorHex": "#32D74B",

  "fields": [
    { "label": "Track",  "refreshKey": "title" },
    { "label": "Artist", "refreshKey": "artist" }
  ],

  "buttons": [
    { "symbol": "backward.fill",  "action": { "kind": "keystroke", "value": "fn+f7" } },
    { "symbol": "playpause.fill", "action": { "kind": "keystroke", "value": "fn+f8" } },
    { "symbol": "forward.fill",   "action": { "kind": "keystroke", "value": "fn+f9" } }
  ],

  "refresh": {
    "command": "osascript -e 'tell application \"Music\" to set t to name of current track & \"|\" & artist of current track' | awk -F'|' '{printf \"{\\\"title\\\":\\\"%s\\\",\\\"artist\\\":\\\"%s\\\"}\", $1, $2}'",
    "everySeconds": 5
  }
}
```

> **Watch the escaping.** The command is a JSON string, so every `"` inside it
> becomes `\"`, and a `\"` you want literally in the output becomes `\\\"`.
> When in doubt, write the command in a `.sh` file and have the manifest call
> that file instead — far easier to read.

`everySeconds` is the poll interval (minimum 2). Reload, play a song, and the
tile updates every few seconds.

That's a complete, useful widget. 🎉

---

## 6. More example ideas (copy the pattern)

**Join my next Zoom meeting** — a single big button:

```json
{
  "id": "com.yourname.zoomnext",
  "name": "Next Meeting",
  "symbol": "video.fill",
  "colorHex": "#3478F6",
  "fields": [ { "label": "At", "refreshKey": "time" } ],
  "buttons": [ { "label": "Join", "symbol": "video.fill",
                 "action": { "kind": "shell", "value": "open \"$(cat ~/.next_zoom_url)\"" } } ],
  "refresh": { "command": "…print {\"time\":\"…\"} from your calendar…", "everySeconds": 60 }
}
```

**Discord mute toggle** — `keystroke` to Discord's push-to-mute hotkey.
**Build status light** — `refresh` curls your CI and prints `{"status":"green"}`.
**Smart-home scene** — a `shell` button that runs your home CLI.

The shape is always the same: *describe the tile, list the actions, optionally
feed it live data.*

---

## 7. Publishing

Right now, sharing a widget means sharing its folder — zip it and the
recipient drops it in their Extensions folder. A built-in **marketplace** for
one-tap install is on the roadmap (free packs first, no account required).

When you publish, please:

- Use a real reverse-DNS `id` you control, to avoid collisions.
- Document any `shell`/`refresh` commands in your README so users can see
  exactly what runs on their machine.
- Keep refresh intervals reasonable (5–60s) to be kind to battery.

---

## 8. A word on safety (please read)

Extensions run with **your** privileges. A `shell` or `refresh` command can do
anything you can do at a terminal. Gatecaster never runs hidden native code —
only the actions and refresh command written in the manifest — but a malicious
command is still a malicious command. **Only install widgets you trust, and
read the commands before you do.** The future marketplace will review packs and
flag shell/refresh usage; a sandboxed tier is planned.

---

## Cheat sheet

```
Folder:  ~/Library/Application Support/Gatecaster/Extensions/<id>/manifest.json

manifest.json:
  id         (required)  unique reverse-DNS
  name       (required)  tile title
  symbol                 SF Symbol for the header
  colorHex               header icon tint, e.g. "#32D74B"
  fields[]               { label, refreshKey | value }
  buttons[]              { label?, symbol?, action: { kind, value } }
  refresh                { command (prints flat JSON), everySeconds (≥2) }

action.kind ∈ app | url | keystroke | shortcut | shell | volume
```

A ready-to-run example lives in
[`examples/extensions/com.example.nowplaying/`](../examples/extensions/com.example.nowplaying/manifest.json).
Copy it, rename the `id`, and start tweaking.

Happy building. 🛠️
