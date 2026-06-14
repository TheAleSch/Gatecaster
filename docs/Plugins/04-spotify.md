# Spotify Playback Control — macOS Architecture & Protocol Design

---

## SECTION A — AppleScript Control Layer

### Component Overview

| Property | Value |
|---|---|
| **Bundle ID** | `com.gatecaster.spotify` |
| **Version** | `2.0.2` |
| **Category** | Spotify |

### Control Operations (5 operations)

The system exposes five operations through the AppleScript bridge and Spotify's public AppleScript dictionary:

| Operation UUID | Display Name | Type | UI File | Notes |
|---|---|---|---|---|
| `com.gatecaster.spotify.player-control` | Playback Control | Key | `playback.html` | Pickable: Play/Pause, Previous, Next |
| `com.gatecaster.spotify.multimedia` | Multimedia | Encoder + Key | `multimedia.html` | Encoder: Push=Play/Pause, Rotate=Prev/Next or Volume; Key configurable |
| `com.gatecaster.spotify.shuffle` | Shuffle | Key (2-state) | — | Toggle on/off, states matched to icon set |
| `com.gatecaster.spotify.repeat` | Repeat | Key (2-state) | — | macOS Spotify exposes repeat as a boolean on/off via the `repeating` AppleScript property |
| `com.gatecaster.spotify.volume` | Volume | Key / Encoder | `volume.html` | Configurable step (-25 to +25) |

### Architecture

The system uses **JXA (JavaScript for Automation) AppleScripts** as the sole control backend — a native macOS automation pattern that leverages Spotify's public AppleScript dictionary. No native Node.js addons, no Windows-specific transports, no cross-platform abstraction layer.

Three `.scpt` files in `scripts/` — each compiled from JXA source (`-l JavaScript`) using:

```bash
osascript -l JavaScript -o compile spotify-control.scpt
```

**Note:** The `.scpt` extension is used throughout. The `-l JavaScript` flag tells `osascript` to interpret the source as JXA regardless of extension. Compiled `.scpt` files can also be run without the `-l` flag, but the examples here use `-l JavaScript` for explicitness.

---

#### 1. `spotify-control.scpt` — Command-and-control dispatcher

- Usage: `osascript -l JavaScript spotify-control.scpt <command> [args]`
- Commands: `play`, `pause`, `playpause`, `next`, `previous`, `stop`, `getstate`, `getvolume`, `setvolume <n>`, `changevolume <delta>`, `getshuffling`, `setshuffling <true|false|toggle>`, `getrepeating`, `setrepeating <true|false|toggle>`, `seek <seconds>`, `skipbyseconds <delta>`, `playuri <uri>`, `playtrack <uri>`
- Communicates with Spotify via AppleScript bridge (`Application('Spotify')`)
- Returns JSON or simple string to stdout

The dispatcher script accepts a command name and optional arguments, then uses the JXA Application('Spotify') bridge to execute the corresponding method. It supports: play, pause, playpause, next, previous, stop, getstate, getvolume, setvolume, changevolume, getshuffling, setshuffling, getrepeating, setrepeating, seek, skipbyseconds, playuri/playtrack. All numeric values are clamped to valid ranges. Volume changes use a 50ms delay before readback. State fetches return a JSON object with track metadata and player properties.

---

#### 2. `spotify-state.scpt` — One-shot state poll

- Usage: `osascript -l JavaScript spotify-state.scpt`
- Returns full player state JSON payload to stdout and exits
- Used for initial state fetch when a control is first added

A one-shot state fetcher that queries Spotify's current track and player state, returning the same JSON payload as getstate. Exits immediately after output.

---

#### 3. `spotify-monitor.scpt` — Continuous state watcher

- Runs in an infinite `while (true)` loop with `delay(1)` (1s polling)
- Uses the macOS `NSWorkspace` API to detect Spotify process without sending AppleEvents (avoids auto-launching Spotify)
- Emits JSON change events to **stderr** (not stdout)
- Detects changes in: track ID, play state, position (second granularity), volume, shuffle, repeat mode
- Implements a 2-second cooldown circuit breaker after a quit/failure to avoid sending AppleEvents to a terminating process
- Subprocess is spawned and kept alive; stderr is piped for real-time events

A continuous watcher that polls Spotify state every 1 second. Before sending AppleEvents, it checks whether Spotify is running via NSWorkspace.runningApplications to avoid auto-launching. If Spotify is not running, it emits a 'stopped' event and waits 2 seconds. On state changes (track, play state, position, volume, shuffle, repeat), it emits a JSON change event to stderr with the full state payload. Designed to run as a persistent subprocess with stderr piped for real-time events.

---

### AppleScript Property Reference (Spotify's Public AppleScript Dictionary)

These are the relevant properties of the `Spotify` application object:

| Property | Type | Access | Notes |
|---|---|---|---|
| `playerState` | text (playing/paused/stopped) | read | Current playback state |
| `playerPosition` | real | get/set | Track position in seconds |
| `soundVolume` | integer (0–100) | get/set | Works as expected. Known edge cases: (a) value may wrap at 100 back to 0 (clamp to 0–100), (b) read may lag briefly after write (insert short `delay(0.05)` after setting) |
| `shuffling` | boolean | get/set | Toggle via `spotify.shuffling = !spotify.shuffling()` |
| `repeating` | boolean | get/set | Boolean on/off. macOS Spotify does not expose single-track vs playlist repeat modes through its AppleScript dictionary. |
| `currentTrack` | track object | read | See below |

**`currentTrack` object properties:**

| Property | Return Type | Example |
|---|---|---|
| `id()` | text | `"4cOdK2wGLETKBDo3s2zZ3t"` |
| `name()` | text | `"Bohemian Rhapsody"` |
| `artist()` | text | `"Queen"` |
| `album()` | text | `"A Night at the Opera"` |
| `albumArtist()` | text | `"Queen"` |
| `duration()` | integer | `355000` (milliseconds) |
| `trackNumber()` | integer | `11` |
| `spotifyUrl()` | text | `"https://open.spotify.com/track/4cOdK2wGLETKBDo3s2zZ3t"` |
| `artworkUrl()` | text | `"https://i.scdn.co/image/..."` |

### Data Flow

```
┌──────────────────────────┐
│   Gatecaster Widget       │  (button press / slider change)
└──────┬───────────────────┘
       │ Shell Command
       ▼
┌──────────────────────────┐
│   Gatecaster Runtime      │  (runs locally on macOS)
└──────┬───────────────────┘
       │
       ▼
┌──────────────────────────────────────┐
│  Command Execution                    │
│  ┌────────────┐ ┌─────────────────┐  │
│  │ Manifest   │ │ Shell Exec      │  │
│  │ Templates  │ │ (osascript)     │  │
│  └────────────┘ └──────┬──────────┘  │
└────────────────────────┼─────────────┘
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
    ┌──────────┐   ┌──────────┐   ┌──────────────┐
    │osascript │   │osascript │   │ Gatecaster   │
    │dispatcher│   │  watcher │   │ Plugin JS    │
    │ (one-off)│   │ (persist)│   │ (event bus)  │
    └────┬─────┘   └────┬─────┘   └──────┬───────┘
         │              │                │
         ▼              ▼                │
    ┌──────────┐   ┌──────────┐          │
    │  Spotify │   │  stderr  │          │
    │  Apple   │   │  JSON    │          │
    │  Events  │   │  stream  │          │
    └──────────┘   └──────────┘          │
                              ┌──────────▼────────┐
                              │ Widget State       │
                              │ (UI updates)       │
                              └───────────────────┘
```

**macOS flow:**
- `getstate` → spawns `spotify-state.scpt` → reads stdout JSON → updates control state
- `play`, `pause`, `next`, `previous` → spawns `spotify-control.scpt <cmd>` → no output processing needed
- Real-time updates → spawns `spotify-monitor.scpt` as persistent subprocess, pipes stderr → JSON lines parsed → UI updates pushed

### Configuration Panel

Three HTML files in `ui/` provide configuration interfaces:

#### `playback.html` (for `player-control` action)
- Dropdown (`select element`) with setting key `playbackAction`
- Options: `togglePlayPause`, `previousTrack`, `nextTrack`
- When used in a multi-step action sequence, dynamically adds "Play" and "Pause" as additional options

#### `multimedia.html` (for `multimedia` action)
- `checkbox` with setting `encoderBehavior` (boolean) — controls encoder rotate behavior
- `range slider` (id `step-slider`, setting `stepSize`, min 1, max 10) — volume step size
- Dynamic note that changes based on checkbox state

#### `volume.html` (for `volume` action)
- `range slider` (id `step-slider`, setting `stepSize`, min -25, max 25) — step size with negative for decrease

### Asset Organization

Icons live in `imgs/` organized by action:
- `imgs/playback/` — play, pause, next, previous icons (key + @16 + @24 variants), error, noartwork, notrunning
- `imgs/volume/` — volume0/33/66/100 (key + @16 + @24), up/down arrows
- `imgs/shuffle/` — on/off/disabled (key + player/ variants + @24)
- `imgs/repeat/` — off/on/disabled (key + player/ variants + @24)
- `imgs/plugin/` — icon, category (PNG and SVG)

### Configuration

The Gatecaster widget backend supports the following runtime tunables:

| Key | Purpose | Default |
|---|---|---|
| `spotify.enableStateCache` | Cache state to reduce AppleScript call frequency | `false` |
| `spotify.volumeTarget` | Which volume to adjust: `app` (Spotify app volume) or `system` (system output) | `'app'` |
| `spotify.progressOverlay` | Show playback progress overlay on tile | `false` |
| `log.level` | Log verbosity (`debug`, `info`, `warn`) | `'info'` |

---

## SECTION B — Gatecaster Widget Implementation Plan

### Declarative Widget Support

All Spotify actions can be implemented using shell commands via `osascript`, with some features optionally using a WebView for richer UI.

#### Declarative-Friendly

| Feature | Widget Type | How |
|---|---|---|
| Play/Pause toggle | Button (stateful) | `osascript` call, refresh to show state |
| Next Track | Button | One-shot `osascript` |
| Previous Track | Button | One-shot `osascript` |
| Volume Up/Down | Button (+ increment/decrement) | `osascript changevolume +5` / `-5` |
| Volume Slider | Range/Number field | Read via `osascript getvolume`, write via `osascript setvolume <n>` |
| Shuffle On/Off | Button (toggle) | `osascript setshuffling toggle` |
| Repeat On/Off | Button (toggle) | `osascript setrepeating toggle` |
| Now Playing (Title/Artist) | Text fields (refresh) | Parsed from `osascript getstate` JSON |
| Album Art | Image field (refresh) | Parsed URL from state JSON; Spotify artwork URLs are `https://i.scdn.co/image/<hash>` |

#### WebView-Needed (Phase 2+)

| Feature | Widget Type | Why |
|---|---|---|
| Album art with waveform progress | WebView | Canvas-based progress bar overlay on art |
| Playlist browser / search | WebView | Requires Web API (OAuth) for playlist listing |
| Track position scrubber | WebView | `skipbyseconds` via AppleScript, but drag UX needs canvas |
| Full now-playing with duration bar | WebView | Timeline scrub, smooth animation |

### AppleScript Commands for osascript

All via JXA dispatcher script (`spotify-control.scpt`):

```bash
# --- Playback Control ---
osascript -l JavaScript spotify-control.scpt play
osascript -l JavaScript spotify-control.scpt pause
osascript -l JavaScript spotify-control.scpt playpause     # toggle
osascript -l JavaScript spotify-control.scpt next
osascript -l JavaScript spotify-control.scpt previous

# --- Volume ---
osascript -l JavaScript spotify-control.scpt getvolume
osascript -l JavaScript spotify-control.scpt setvolume 50
osascript -l JavaScript spotify-control.scpt changevolume 10    # +10
osascript -l JavaScript spotify-control.scpt changevolume -5    # -5

# --- Shuffle & Repeat (toggle via dispatcher) ---
osascript -l JavaScript spotify-control.scpt setshuffling toggle
osascript -l JavaScript spotify-control.scpt setrepeating toggle

# --- Seeking & Playback of Specific Tracks ---
osascript -l JavaScript spotify-control.scpt skipbyseconds 30
osascript -l JavaScript spotify-control.scpt skipbyseconds -15
osascript -l JavaScript spotify-control.scpt playtrack "spotify:track:4cOdK2wGLETKBDo3s2zZ3t"

# --- State Polling ---
osascript -l JavaScript spotify-control.scpt getstate
```

### Getting Now-Playing Info

**One-shot (polling):**
```bash
osascript -l JavaScript spotify-control.scpt getstate
```
Returns JSON like:
```json
{
  "id": "4cOdK2wGLETKBDo3s2zZ3t",
  "name": "Bohemian Rhapsody",
  "artist": "Queen",
  "album": "A Night at the Opera",
  "duration": 355000,
  "position": 42.5,
  "state": "playing",
  "volume": 75,
  "shuffling": false,
  "repeating": false,
  "artworkUrl": "https://i.scdn.co/image/...",
  "spotifyUrl": "https://open.spotify.com/track/4cOdK2wGLETKBDo3s2zZ3t"
}
```

**Continuous watcher (for real-time position updates):**
The `spotify-monitor.scpt` script spawns as a subprocess and emits JSON to stderr on any state change. For a widget, the simpler one-shot polling every 2-5 seconds is typically sufficient.

### What Works via Shell (No WebView)

These are all one-liner `osascript` calls with no UI framework needed:

- Play/Pause toggle
- Skip next/previous
- Volume get/set/change (0-100 integer)
- Shuffle toggle (boolean)
- Repeat toggle (boolean)
- Track info display (title, artist, album)
- Album art URL (displayed via `<img>`)
- Position percent (text readout)

### What Needs a WebView Widget

- Album art with a Canvas progress waveform overlay
- Track position scrubber (drag to seek)
- Playlist browser (Web API + OAuth needed)
- Search/browse playlists (Web API)
- Login screen if using Web API

### Manifest.json Structure for Gatecaster

```json
{
  "manifest_version": "1.0.0",
  "id": "com.gatecaster.spotify",
  "name": "Spotify Controller",
  "version": "1.0.0",
  "widgets": [
    {
      "id": "now-playing",
      "type": "refresh",
      "title": "Now Playing",
      "refresh_interval": 3,
      "fields": [
        { "key": "title", "label": "Title", "type": "text" },
        { "key": "artist", "label": "Artist", "type": "text" },
        { "key": "album", "label": "Album", "type": "text" },
        { "key": "position", "label": "Position", "type": "text" },
        { "key": "artwork", "label": "Album Art", "type": "image" }
      ],
      "buttons": [
        { "label": "Prev", "action": "previous", "type": "command" },
        { "label": "Play", "action": "playpause", "type": "command" },
        { "label": "Next", "action": "next", "type": "command" },
        { "label": "Shuffle", "action": "shuffle", "type": "command" },
        { "label": "Repeat", "action": "repeat", "type": "command" }
      ],
      "fetch_command": "osascript -l JavaScript scripts/spotify-control.scpt getstate",
      "parse": {
        "title": ".name",
        "artist": ".artist",
        "album": ".album",
        "position": ".position + 's'",
        "artwork": ".artworkUrl"
      }
    },
    {
      "id": "volume-control",
      "type": "refresh",
      "title": "Volume",
      "refresh_interval": 5,
      "fields": [
        { "key": "volume", "label": "Volume", "type": "range", "min": 0, "max": 100 }
      ],
      "buttons": [
        { "label": "+5", "action": "volume_up", "type": "command" },
        { "label": "-5", "action": "volume_down", "type": "command" }
      ],
      "fetch_command": "osascript -l JavaScript scripts/spotify-control.scpt getvolume",
      "write_command": "osascript -l JavaScript scripts/spotify-control.scpt setvolume %value%"
    },
    {
      "id": "full-player",
      "type": "webview",
      "title": "Spotify Player",
      "url": "ui/player.html",
      "width": 400,
      "height": 600
    }
  ],
  "commands": {
    "playpause": "osascript -l JavaScript scripts/spotify-control.scpt playpause",
    "next": "osascript -l JavaScript scripts/spotify-control.scpt next",
    "previous": "osascript -l JavaScript scripts/spotify-control.scpt previous",
    "shuffle": "osascript -l JavaScript scripts/spotify-control.scpt setshuffling toggle",
    "repeat": "osascript -l JavaScript scripts/spotify-control.scpt setrepeating toggle",
    "volume_up": "osascript -l JavaScript scripts/spotify-control.scpt changevolume 5",
    "volume_down": "osascript -l JavaScript scripts/spotify-control.scpt changevolume -5"
  },
  "requirements": {
    "macOS": true,
    "dependencies": ["osascript", "Spotify.app"],
    "permissions": [
      "System Events (accessibility)"
    ]
  }
}
```

### Phased Approach

#### Phase 1 — Declarative Widgets (MVP)

**Effort:** ~2-3 days

**What ships:**
- `now-playing` refresh widget showing track info, album art, play/pause/next/prev buttons
- `volume-control` refresh widget with range slider and +/- buttons
- Simple AppleScript dispatcher bundled in `scripts/`
- Manifest with commands and fetch-based refresh at 2-3s interval

**Files to create:**
```
com.gatecaster.spotify/
├── manifest.json
└── scripts/
    ├── spotify-control.scpt    (JXA AppleScript dispatcher)
    └── spotify-state.scpt    (one-shot state poll)
```

**Capabilities:**
- See currently playing track, artist, album
- See album art as image
- Play/Pause/Next/Previous buttons
- Volume slider (read+write)
- Volume increment/decrement buttons
- Shuffle and Repeat toggle buttons

**Limitations:**
- Track position is text readout, not scrubbable
- No progress bar animation
- 3-second polling — not truly real-time
- No playlist browsing
- No search

#### Phase 2 — Enhanced Refresh Widget

**Effort:** ~1 week

**Upgrades:**
- Add position progress bar via pure CSS/HTML in a `refresh` widget with a `<div style="width: X%">` technique
- `spotify-monitor.scpt` integration as a background process for push-based state (no polling delay)
- Track seek buttons (forward/back 10s, 30s) via `skipbyseconds`
- Multiple play/pause state-responsive icons
- Handle "Spotify not running" state gracefully

#### Phase 3 — WebView Widget (Rich Player)

**Effort:** ~2 weeks

**What ships:**
- `full-player` WebView widget at `ui/player.html`
- Album art with Canvas waveform/animated progress bar
- Draggable position scrubber
- Play queue display
- Currently playing indicator with smooth updates via websocket or EventSource to a small companion Node.js backend that wraps the AppleScript watcher
- Optional Spotify Web API integration for:
  - Playlist listing
  - Search
  - Liked/saved tracks

**Architecture for Phase 3:**
```
┌─────────────────────────┐
│   Gatecaster Widget      │
│   (WebView)              │
└────────┬────────────────┘
         │ postMessage / HTTP
         ▼
┌─────────────────────────┐
│   spotify-bridge.js      │  (small Node.js helper)
│   - spawns watcher.scpt  │
│   - pipes stderr JSON    │
│   - wraps dispatcher     │
│   - optional Web API     │
└────────┬────────────────┘
         │
         ▼
   osascript dispatcher / watcher
```

### AppleScript Commands Cheat Sheet (Quick Reference)

```bash
# Create a proper shell-friendly wrapper:
SPOTIFY="osascript -l JavaScript /path/to/spotify-control.scpt"

# State (full JSON)
$SPOTIFY getstate

# Transport
$SPOTIFY play
$SPOTIFY pause
$SPOTIFY playpause
$SPOTIFY next
$SPOTIFY previous

# Volume (0-100)
$SPOTIFY getvolume           # → "75"
$SPOTIFY setvolume 50         # → "50"
$SPOTIFY changevolume 10      # → "85"
$SPOTIFY changevolume -10     # → "75"

# Shuffle & Repeat (toggle variant shown; true/false also accepted)
$SPOTIFY setshuffling toggle
$SPOTIFY setrepeating toggle

# Seeking
$SPOTIFY skipbyseconds 30
$SPOTIFY skipbyseconds -15

# Play specific track
$SPOTIFY playtrack "spotify:track:4cOdK2wGLETKBDo3s2zZ3t"
```

### Key Integration Notes

1. **macOS-Native**: This design uses AppleScript/JXA, which is only available on macOS. Spotify exposes a public AppleScript dictionary, making this the canonical local control path on macOS. No cross-platform abstraction is needed.

2. **Spotify Must Be Running**: AppleScript implicitly launches Spotify if you send it commands. The watcher script guards against this by checking `NSRunningApplication` before sending AppleEvents.

3. **Permission**: macOS will prompt for Accessibility permissions for `osascript` to control Spotify. The user must grant this in System Settings > Privacy & Security > Accessibility.

4. **Volume Behavior**: `soundVolume` in Spotify's AppleScript dictionary is 0–100 and works as expected. Two real edge cases worth noting:
   - (a) **Wrap-around**: At value 100, setting `soundVolume = 100` may wrap back to 0 in some Spotify versions. Simple clamping (`Math.min(100, Math.max(0, v))`) prevents this.
   - (b) **Read lag**: After setting `soundVolume`, a subsequent read may return the previous value. A short `delay(0.05)` after writes ensures the read-back is accurate.
   No "n–1" bug exists; any such behavior would be a version-specific quirk and is handled generically by clamping.

5. **Working Directory**: All shell examples in this document use relative paths (e.g., `spotify-control.scpt`). When integrating with the Gatecaster runtime, ensure one of:
   - The runtime's configured working directory points to the `scripts/` folder (or the bundle root).
   - Use absolute paths in the manifest: `/path/to/com.gatecaster.spotify/scripts/spotify-control.scpt`.
   - Set the working directory via Gatecaster's process configuration if supported.

6. **Polling vs Push**: For Phase 1, `getstate` polling every 3 seconds is fine. For Phase 2+, the continuous watcher subprocess provides true push-based updates with sub-second latency via the JXA pipe approach.

7. **Position Tracking**: The watcher emits position changes at 1-second resolution. For a progress bar in Phase 3, synthesize smooth animation on the client side between watcher updates.

8. **Shuffle/Repeat Toggle Design**: The dispatcher's `setshuffling` and `setrepeating` commands accept `true`, `false`, or `toggle`. The Gatecaster manifest uses `toggle` for the button commands, which toggles the current state via `spotify.shuffling = !spotify.shuffling()`. This avoids needing separate "on" and "off" commands.
