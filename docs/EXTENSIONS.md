# Gatecaster widget extensions

Third-party widgets for the Deck are **declarative** — a folder with a
`manifest.json`. No Swift, no compiling, no linked code. A widget author
describes a tile and the actions it can fire; Gatecaster renders it. This keeps
authoring simple and keeps the format portable across operating systems (see
"Cross-platform" below).

## Install location

```
~/Library/Application Support/Gatecaster/Extensions/<your-id>/manifest.json
```

In the Deck: enter edit mode → the widget rail's **＋** menu →
*Open Extensions Folder…* / *Reload Extensions*. Installed extensions then
appear in the same menu to drop onto the rail.

## Manifest schema

```json
{
  "id": "com.example.nowplaying",      // reverse-DNS, unique
  "name": "Now Playing",
  "symbol": "music.note",              // SF Symbol for the header
  "colorHex": "#32D74B",
  "minW": 2, "minH": 1, "defaultW": 3, "defaultH": 2,  // optional size hints (cells)

  "fields": [                          // live read-outs (optional)
    { "label": "Track",  "refreshKey": "title" },
    { "label": "Artist", "refreshKey": "artist" },
    { "label": "Status", "value": "Static text if no refreshKey" }
  ],

  "buttons": [                         // tap targets (optional)
    { "symbol": "playpause.fill", "action": { "kind": "media", "value": "playpause" } },
    { "label": "Open", "action": { "kind": "app", "value": "Spotify" } },
    { "label": "Dev Mode", "symbol": "chevron.left.forwardslash.chevron.right",
      "toggle": true, "altLabel": "Design", "altSymbol": "paintbrush.pointed",
      "action": { "kind": "keystroke", "value": "shift+d" } }
  ],

  "refresh": {                         // optional polling (optional)
    "command": "…prints a flat JSON object to stdout…",
    "everySeconds": 5
  }
}
```

### Actions (`kind` + `value`)

The same safe set the Deck buttons use:

| kind        | value example            | does |
|-------------|--------------------------|------|
| `app`       | `Spotify`                | open an app (name or .app path) |
| `url`       | `https://open.spotify.com` | open a URL |
| `keystroke` | `cmd+shift+m`            | post a shortcut (`fn+f8` = play/pause) |
| `shortcut`  | `My Shortcut`            | run an Apple Shortcut |
| `shell`     | `open ~/Music`           | run a zsh command |
| `volume`    | `40`                     | set output volume 0–100 |
| `media`     | `playpause` / `next` / `previous` | media transport key |

### Live fields (`refresh`)

`refresh.command` runs on `everySeconds` (min 2s). Its **stdout must be a flat
JSON object**; each key becomes available to any field's `refreshKey`. Example
that exposes `title` and `artist`:

```bash
osascript -e 'tell application "Music" to set t to name of current track & "|" & artist of current track' \
  | awk -F'|' '{printf "{\"title\":\"%s\",\"artist\":\"%s\"}", $1, $2}'
```

A complete working example ships in
[`examples/extensions/com.example.nowplaying/`](../examples/extensions/com.example.nowplaying/manifest.json).
Copy that folder into the Extensions location to try it.

## Security model

Extensions run with **your** privileges: a `shell`/`refresh` command can do
anything you can. Today that means **only install extensions you trust**, the
same as any script. Gatecaster never executes linked native third-party code —
only the declared actions and the refresh command you installed. The planned
marketplace (v1) will review submitted packs and warn on shell/refresh use;
a future sandbox tier will run refresh commands with reduced privileges.

## Cross-platform note

The manifest format, the deck layout file (`.gatedeck`), and the marketplace
are OS-neutral data. Only the *execution* is platform-specific — `shell`
commands and `refresh` use zsh on macOS and would use PowerShell on Windows. A
future schema revision will allow per-OS commands:

```json
"refresh": { "command": { "macos": "...", "windows": "..." }, "everySeconds": 5 }
```

so a single extension can target both. This is why widgets are declarative
rather than Swift: a Windows port of Gatecaster reuses the entire extension
ecosystem unchanged and only swaps the host runtime.

## Richer custom UI (roadmap)

Declarative tiles cover most cases (status + buttons). For fully custom widget
UIs, the planned path is a **WebView widget** — sandboxed HTML/JS with a tiny
`gatecaster.*` JS bridge (read fields, fire actions). That is also portable:
the same web widget runs on macOS (WKWebView) and Windows (WebView2). Tracked
in DECK_PLAN.md.

## Examples

Two runnable packs ship in `examples/extensions/`:
- `com.example.nowplaying` — live fields via a refresh command + media buttons.
- `com.figma.shortcuts` — ~18 Figma shortcut buttons (no refresh).

Install one by copying its folder into the Extensions location:
```bash
cp -R examples/extensions/com.figma.shortcuts \
  ~/Library/Application\ Support/Gatecaster/Extensions/
```
Then Deck → tap a "+" → Reload Extensions.

## Toggle buttons

Add `"toggle": true` to a button to make it an on/off control: it highlights
when on and can swap to `altLabel` / `altSymbol`. By default it fires `action`
both ways (good for a shortcut that itself toggles, like Figma's Shift+D for
Dev Mode). For separate on/off commands, add `actionAlt` — it fires when
turning the button off.

## Multi-state buttons

For more than two states, give a button a `states` array — it cycles through
them on each tap, showing the current state's `label`/`symbol` and firing its
`action`. (Supersedes `toggle`, which is just the two-state case.)

```json
{ "label": "Quality",
  "states": [
    { "label": "Low",  "symbol": "1.circle",  "action": { "kind": "shortcut", "value": "Quality Low" } },
    { "label": "Med",  "symbol": "2.circle",  "action": { "kind": "shortcut", "value": "Quality Med" } },
    { "label": "High", "symbol": "3.circle",  "action": { "kind": "shortcut", "value": "Quality High" } }
  ]
}
```

Each tap fires the shown state's action, then advances to the next. The button
highlights for any state past the first.
