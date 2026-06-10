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
| `page`      | `2` or `Streaming`       | switch the deck to another page |

The `page` action jumps the deck to another page — give `value` either the
1-based page number (`"2"`) or the page's exact name (`"Streaming"`,
case-insensitive). Handy for a button that opens a sub-page of controls and a
"back" button that returns to page 1. Deck buttons reach this through the action
picker (kind → *Switch Page*); extension buttons can fire it too.

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

## Scrolling content

When a widget has more buttons or fields than fit its tile, the content
scrolls — you don't do anything special. Just declare as many `buttons`/`fields`
as you need; Gatecaster lays them out in a scroll area and drives the scrolling
for you.

How it works (so you can reason about it): the deck is a non-activating panel
that never takes keyboard/mouse focus, so a normal trackpad/SwiftUI scroll
gesture never reaches it. Instead, **the engine drives the scroll** — a
one-finger drag inside a widget is detected by the touch engine, which posts real
scroll-wheel events to the panel under your finger, exactly like a physical
wheel. The result is native momentum scrolling that works even though the panel
can't be focused. The scrollbar stays hidden and only flicks in faintly while you
scroll, iOS-style. As an extension author you never call a scroll API; you just
provide content taller than the tile and it scrolls. (Implementation:
`Engine.deckScrollAt` → `.fscroll` mode → `Pointer.scroll`, documented in
INTERNALS.md.)

## Richer custom UI (e.g. an iOS-style timer dial) — roadmap

Some widgets want a fully custom interaction — the built-in **Timer** widget, for
instance, shows a circular countdown ring with start/pause/reset and preset
chips. That's deliberately a *built-in* widget, not a declarative one: the
manifest format describes "fields + buttons + a refresh command", which can't
express an arbitrary custom canvas like a progress ring or a draggable dial.

If you wanted to build something like the iOS timer as an extension today, you'd
approximate it with the declarative tools: buttons for the presets and
start/stop (`shortcut`/`shell` actions to a script that runs a real timer), and a
`refresh` field that prints the remaining time every second. You get the controls
and a live read-out, but not the custom ring.

For genuinely custom UI (a ring, a dial, a chart you draw yourself), the planned
path is a **WebView widget** — sandboxed HTML/JS/CSS with a tiny `gatecaster.*`
JS bridge (read fields, fire actions, draw whatever you like on a canvas). A web
timer dial would be a few dozen lines of HTML. That tier is also portable: the
same web widget runs on macOS (WKWebView) and Windows (WebView2). Tracked in
DECK_PLAN.md.

Note on dials specifically: the iOS timer sets its duration by *dragging* a knob
around the ring. On the deck, a one-finger drag inside a widget is consumed by
the scroll engine (see "Scrolling content" above), so a drag-to-set knob would
fight scrolling. The built-in Timer therefore uses **tap controls** (preset
chips + ± steppers) instead of a draggable knob — a good pattern to copy for any
future WebView widget too.

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

## Theming & styling (how your widget looks)

The deck has user-selectable **themes** (Deck ⋯ → Deck Settings → Theme):
Midnight, Darkness (pure black), Graphite, Glass, Aurora, Daylight, plus a
transparency slider. A theme sets the panel background **and** flips SwiftUI's
color scheme (light/dark), so your widget should use **adaptive colors** and it
will look right in every theme automatically:

- Use the system roles for text/icons: they adapt to the theme's light/dark
  scheme. In a manifest you don't pick text colors — Gatecaster renders your
  `fields` and `buttons` with theme-aware colors. Just provide `label`,
  `symbol`, and optionally a `colorHex` accent for your header icon.
- `colorHex` is your **brand accent** (the header icon tint), e.g. Spotify
  green `#1DB954`. Pick one that reads on both dark and light backgrounds.
- `symbol` is any SF Symbol; these are vector + monochrome, so they tint
  correctly per theme. Browse names in Apple's SF Symbols app.
- Button chips, fields, and toggles inherit the theme automatically — don't
  hard-code backgrounds. Toggle/multi-state "on" states use the system accent.

Size hints (`minW/minH/defaultW/defaultH`) also shape how your widget reads:
pick a `default` that fits your content without lots of empty space; the user
can resize within your `min`.

Rule of thumb: **describe content + an accent, not absolute colors.** That keeps
your widget consistent with whatever theme the user picks and ready for a future
Windows port.
