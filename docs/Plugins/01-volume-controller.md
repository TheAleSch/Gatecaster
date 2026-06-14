# Gatecaster Volume Controller — Design & Implementation

## Section A — Audio Control System: Requirements & Architecture

### Architecture Overview

A volume controller widget for a deck controller consists of CoreAudio-level volume management exposed through a **backend runtime** that communicates between the deck host application and macOS audio services. The Configuration Panel UI is built with vanilla HTML+JS and communicates over the host's event bridge.

### CoreAudio Integration

On macOS, all audio device control goes through the **CoreAudio framework** via a native Swift/ObjC addon (`.dylib` or compiled CLI helper). There is no separate audio routing daemon — the system manages device enumeration, volume, mute, and default device changes natively through `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData` with property listeners.

### Native Helper Interface (Gatecaster's design)

The helper's surface follows from what device-level CoreAudio control needs — read
the device list and the current defaults, get/set a device's volume and mute, and
get notified when any of that changes. A minimal capability set:

- get the default device for a direction (input/output, with a communications role)
- look a device up by its CoreAudio UID
- list all devices
- set a device's mute
- set a device's volume (0.0–1.0, clamped to range)
- subscribe to per-device property changes
- subscribe to default-device changes

A single coordinator owns the device list, applies changes through the helper, and
re-publishes change events to whatever tiles are visible. Naming and decomposition
inside the coordinator are Gatecaster's own.

### Actions (Gatecaster's set)

Derived from the audio capabilities a touch deck needs, under Gatecaster's own
`com.gatecaster.volume-controller.*` namespace:

| Action | Purpose |
|---|---|
| Output Volume | set / adjust / mute the system (or a chosen) output device |
| Input Gain | set / adjust / mute the system (or a chosen) input device |
| App Volume | pick a specific app, then set / adjust / mute its audio (macOS 14.2+) |
| Audible Apps | a scrollable tile auto-listing apps currently producing sound, each with mute + volume controls |

Output Volume, Input Gain, and App Volume share one device-control behavior
(direction, rendering, key vs. rotary handling) and differ only in which audio
target they address. "Audible Apps" replaces a fixed per-app key grid with a single
scrolling list tile, which suits a touch surface better than discrete keys.

### Two Subsystems: App Audio vs Device Audio

The system handles **two fundamentally different audio domains**:

#### 1. Application Audio (App-Level Volume)

> **Requires macOS 14.2+.** Per-app audio control is only available on macOS 14.2+ via the Audio Tap API.

Controlled via the **Audio Tap API** (`AudioHardwareCreateProcessTap` / `CATapDescription`). Unlike device-level volume, there is no simple property getter for per-process volume. macOS does not expose `kAudioHardwarePropertyRunningApps` or per-process `kAudioDevicePropertyVolume` — these do not exist.

The correct approach uses **private aggregate devices and process taps**:
1. Create a `CATapDescription` targeting the desired audio process
2. Call `AudioHardwareCreateProcessTap` to create a tap on that process's audio stream
3. The tap provides access to the raw audio data, which can be used to derive volume levels
4. Volume adjustment requires muting/attenuating the tap's stream — there is no `setApplicationInstanceMute` or per-process `AudioObjectSetPropertyData`

A per-application audio coordinator (Gatecaster's own) tracks apps producing audio:
- enumerates audio processes via `kAudioHardwarePropertyProcessObjectList` (macOS 14.2+); note `kAudioHardwarePropertyRunningApps` does not exist
- registers CoreAudio property listeners for mute, activity, and volume changes
- keeps a process-ID → per-app state mapping

**Per-app state** each entry needs: process ID, display name, executable path; a
0.0–1.0 volume and a mute flag; an activity state (active / recently-stopped /
dormant); cached app icons (normal plus muted/unavailable variants); and whether the
app is currently active enough to accept a volume change. (Field set follows from
the feature; struct/class shape is Gatecaster's.)

**Hardware-level device volume** (for system output/input) uses the standard CoreAudio pattern with `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData` on `kAudioDevicePropertyVolume` / `kAudioDevicePropertyMute` — this is straightforward and well-documented. `AudioHardwareService` is deprecated since macOS 10.6; use `AudioObjectGetPropertyData` with `kAudioObjectPropertyScopeOutput` / `kAudioObjectPropertyScopeInput` instead.

#### 2. Device Audio (Hardware-Level Volume)

Controlled via the **native CoreAudio addon**, which talks to `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData` directly.

A device coordinator (Gatecaster's own) wraps the native helper:
- tracks default input / output / communication devices
- emits events when the device list changes, the input source changes, the output sink changes, or the system defaults change
- exposes the active input and output device lists as `{id, displayName}` entries

### Audible-apps list (Gatecaster's design)

Rather than paginate per-app controls across a fixed key grid, Gatecaster presents
the currently-audible apps as one **scrolling list tile** — a natural fit for a touch
surface (the deck already drives native momentum scroll inside a tile). Behavior:

1. The per-app coordinator supplies the live set of audio apps; the tile renders one
   row per app: icon, name, a mute toggle, and volume +/− (or a rotary, on a dial).
2. A display-mode setting chooses **all** audio apps vs. only **currently active**
   ones.
3. The list refreshes on the same events the coordinator emits — app attach/detach,
   volume change, mute toggle, activity change, icon update — so it stays live
   without polling.

There is no fixed column/page layout to manage; the list simply grows and scrolls.
App icons come from the app bundle (`NSWorkspace.icon(forFile:)`), falling back to a
rendered glyph when unavailable.

### Picking one app (App Volume action)

When the user assigns the App Volume action to a specific app, the tile stores that
app's executable path. On display it resolves the path to the live app and shows its
icon/state. A tap or rotary turn maps to the configured control mode — toggle mute,
adjust by a step, or set an exact level — and a turn while muted un-mutes first. New
levels are computed as `current + ticks × step%`, clamped to 0–1.

### Shared device-control behavior

Output Volume, Input Gain, and App Volume share one rendering + input behavior,
parameterized by audio target and control mode (mute / adjust / set):

- **Tile rendering** reflects the mode: a mute glyph; an increase/decrease affordance
  with vertical or horizontal styling; or a numeric set-value.
- **Rotary feedback** (on a dial) shows a title, icon, a 0–100% indicator, and the
  value text.
- **Turn** applies `volume + (step/100) × ticks`, auto-unmuting when turning up.
- **Press** toggles mute on the target.
- **Hold-to-repeat**: while a +/− control is held, re-apply the step on a short
  interval so the user can ramp quickly.
- Tile imagery can be generated from SVG rasterized via `CGContext`/`NSImage`, one
  variant per mode/state.

### Settings each action collects

Each action needs a small settings view; how Gatecaster organizes the view code is
its own choice. The inputs follow from the actions:

- **Audible Apps** (widget-wide): display mode (all vs. currently-active) and a
  default step amount. Surfaces "not connected" / "unsupported" states when audio
  isn't available.
- **App Volume**: an app picker (from the live audio-app list), a control mode
  (set / adjust / mute), a display style (plain / vertical / horizontal), a step
  amount, and an initial level. On a rotary, this reduces to a step amount.
- **Output Volume / Input Gain**: a device dropdown — including "Default Device"
  and "Default Device (Communication)" entries — a control mode, step, and level.
  Output labels read "…Output Volume"; input labels read "…Gain / Mute Microphone".

Config views talk to Gatecaster over its internal panel channel; the message names
and any shared helper modules are Gatecaster's own and are not part of a public
interface.

### Settings Persistence

Two levels, with Gatecaster-chosen key names:
1. **Widget-wide settings**: display mode (all / active) and a default step amount,
   used by the Audible Apps list.
2. **Per-tile settings**: vary by action. App Volume stores the app path, control
   mode, step, display style, and level; device control stores the device key,
   display name, control mode, step, level, and style.

### Image Generation Pipeline

The system generates its own key images dynamically:
- SVG string templates are rendered to PNG buffers via a compiled helper using `CGContext` / `NSImage` on macOS, or via a standalone `librsvg` / `cairo` binary
- Multiple image variants per action: normal, disabled, muted, with-text, without-text
- App icons are loaded from the app bundle via `NSWorkspace` (Swift helper)
- Text overlays are composited using `CGContext` draw operations
- Tile images are set from the rendered PNG
- Rotary feedback carries a title, icon, a 0–100% indicator bar, and the value text

### Mute/Unmute Flow

For **app audio**: toggling an app's mute adjusts attenuation on the process tap
created via `AudioHardwareCreateProcessTap`. There is no simple CoreAudio property
setter for per-process mute — the tap's audio stream is muted at the aggregate-device
level. Requires macOS 14.2+.

For **device audio**: the device coordinator flips the device's mute through the
native helper's set-mute call.

The mute state propagates through the system:
1. Native addon detects change via CoreAudio listener
2. A mute-change event fires, notifying all subscribers
3. Event handlers update all visible action images
4. The auto-profile layout manager refreshes the muted app's column

### Step Size Handling

- **Auto detection**: Step size from global settings (default 5, range 1-25), stored per-device ID, applied as percentage points
- **Manual detection**: Per-action step size (-25 to +25 for keys, 1-5 for encoders)
- **Device control**: Per-action step size (-25 to +25 for keys, 1-5 for encoders)
- `computeNewLevel(volume, ticks, stepSize)`: `newVol = Vol + (ticks × stepSize / 100)`, clamped [0, 1]

### Error Handling

- If a CoreAudio device isn't found → log a warning and show an alert on the tile
- Auto-reconnect: re-register property listeners when the device set changes
- Only active apps accept a volume change (the per-app state carries that flag)

---

## Section B — Gatecaster Widget Implementation Plan

### Architecture Context

Gatecaster widgets are **declarative JSON manifests** with fields, buttons, and a refresh/action shell-command system. There is no Node.js runtime — all logic runs as `zsh` commands executed on the broadcaster's machine, with results parsed back into the tile UI.

### What Can Ship as a Declarative Widget (Phases 1-2)

#### Phase 1 — Simple Volume Slider for Default Output

A **"Default Output Volume"** widget with:
- **Tile**: Shows current volume % and mute status, with up/down buttons
- **Refresh command**: Uses `osascript` to query system volume
- **Actions**: Mute toggle, volume up/down via shell

**Manifest** (`volume-controller/manifest.json`):
```json
{
  "kind": "widget",
  "name": "Default Output Volume",
  "description": "Control your Mac's default output volume",
  "author": "Gatecaster",
  "version": "1.0.0",
  "refreshInterval": 2000,
  "tile": {
    "template": "standard",
    "fields": [
      { "key": "volume", "label": "Volume", "type": "text", "size": "large" },
      { "key": "muted", "label": "", "type": "status", "variant": "muted" },
      { "key": "device", "label": "Device", "type": "text", "size": "small" }
    ],
    "layout": [
      ["volume", "muted"],
      ["device"]
    ]
  },
  "refresh": {
    "command": "zsh",
    "args": ["-c", "osascript -e 'output volume of (get volume settings)' 2>/dev/null; printf '|'; osascript -e 'output muted of (get volume settings)' 2>/dev/null; printf '|'; SwitchAudioSource -t output -c 2>/dev/null || echo 'Default'"],
    "parse": {
      "delimiter": "|",
      "fields": ["volume", "muted", "device"],
      "trim": true
    },
    "transform": {
      "muted": { "true": "Muted", "false": "" },
      "volume": "Volume: $value%"
    }
  },
  "actions": {
    "mute-toggle": {
      "label": "Toggle Mute",
      "icon": "speaker",
      "command": "zsh",
      "args": ["-c", "osascript -e 'set volume output muted (not output muted of (get volume settings))'"],
      "then": "refresh"
    },
    "volume-up": {
      "label": "+10%",
      "icon": "plus",
      "command": "zsh",
      "args": ["-c", "osascript -e 'set v to (output volume of (get volume settings)) + 10; if v > 100 then set v to 100; set volume output volume v'"],
      "then": "refresh"
    },
    "volume-down": {
      "label": "-10%",
      "icon": "minus",
      "command": "zsh",
      "args": ["-c", "osascript -e 'set v to (output volume of (get volume settings)) - 10; if v < 0 then set v to 0; set volume output volume v'"],
      "then": "refresh"
    },
    "set-50": {
      "label": "50%",
      "command": "zsh",
      "args": ["-c", "osascript -e 'set volume output volume 50'"],
      "then": "refresh"
    },
    "set-0": {
      "label": "Mute",
      "icon": "mute",
      "command": "zsh",
      "args": ["-c", "osascript -e 'set volume output volume 0'"],
      "then": "refresh"
    }
  }
}
```

#### Phase 2 — Application Volume Control (macOS 14.2+)

A **"Per-App Volume"** widget that shows a list of running audio apps with individual controls.

Uses a **Swift helper tool** (`helpers/volume-helper`) compiled as a CLI binary that accesses per-process audio via the Audio Tap API (macOS 14.2+):

```swift
// helpers/VolumeHelper.swift — compiled as a CLI binary
import CoreAudio
import Foundation

func getRunningAudioApps() -> [[String: Any]] {
    // Enumerate via kAudioHardwarePropertyProcessObjectList (macOS 14.2+)
    // Return pid, name, volume, mute for each
    // Note: volume/mute requires a CATapDescription + AudioHardwareCreateProcessTap
    // on each process's audio stream — there is no simple property getter
}

func setAppVolume(pid: Int32, volume: Float) {
    // Requires Audio Tap API: create a process tap, adjust attenuation
    // on the aggregate device. No simple AudioObjectSetPropertyData exists
    // for per-process volume.
}

func toggleAppMute(pid: Int32) {
    // Mute by adjusting tap gain to 0 on the process's audio stream tap
}
```

**Manifest** (`volume-controller/app-volumes/manifest.json`):
```json
{
  "kind": "widget",
  "name": "App Volumes",
  "version": "1.1.0",
  "refreshInterval": 3000,
  "tile": {
    "template": "list",
    "fields": [
      { "key": "apps", "type": "dynamic_table", "columns": [
        { "key": "name", "label": "App", "width": 2 },
        { "key": "volume", "label": "Vol", "width": 1, "align": "right" },
        { "key": "muted", "label": "", "width": 0.5 }
      ]}
    ]
  },
  "refresh": {
    "command": "zsh",
    "args": ["-c", "helpers/volume-helper list"],
    "parse": "json"
  },
  "actions": {
    "toggle-mute": {
      "params": ["pid"],
      "command": "zsh",
      "args": ["-c", "helpers/volume-helper toggle-mute $PARAM_PID"],
      "then": "refresh"
    },
    "set-volume": {
      "params": ["pid", "volume"],
      "command": "zsh",
      "args": ["-c", "helpers/volume-helper set-app-volume $PARAM_PID $PARAM_VOLUME"],
      "then": "refresh"
    }
  }
}
```

### What Requires Deeper Integration (Phase 3+)

#### Features Needing a New Action Kind in Deck.swift

The current `action` kind in Deck.swift executes a shell command and returns result. The following require real-time streaming events:

- **Live volume meter** (watching CoreAudio level changes at 60fps)
- **Default device change notifications** (headphones plugged in → auto-switch)
- **App launch/terminate detection** for auto-population

These need a **`monitor` action kind** akin to `action` but with:
- A long-lived process that sends events via stdout
- Gatecaster's Deck.swift reads stdin of the monitor process line-by-line
- Each line is a JSON patch to the tile's state

```swift
// Deck.swift — new monitor action kind
case .monitor(let config):
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", config.command]
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    stdout.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if let line = String(data: data, encoding: .utf8), !line.isEmpty {
            DispatchQueue.main.async {
                self.applyPatch(jsonString: line)
            }
        }
    }
```

#### Features Needing a WebView Widget

- **Configuration Panel–style configuration UI** (device picker dropdown, step size slider, "show apps: all vs active" radio)
- **Interactive volume slider** (drag to set exact volume, not just step buttons)
- **App icon rendering** (fetching and displaying per-app audio icons)

WebView widgets need:
- A bundled `.html` file served from the widget's directory
- The `WebKit` bridge to communicate state back to Deck.swift
- Gatecaster would inject `window.Gatecaster = { environment, setField, onRefresh }`

```json
{
  "kind": "webview",
  "name": "Volume Mixer",
  "entry": "mixer.html",
  "width": 300,
  "height": 400,
  "refreshInterval": 0,
  "setup": {
    "command": "zsh",
    "args": ["-c", "helpers/volume-helper list"],
    "parse": "json",
    "inject": ["apps"]
  }
}
```

#### Features Needing Native Helper Tools

**Per-app volume control** on macOS 14.2+ requires the **Audio Tap API**:

1. **Swift** helper using `AudioHardwareCreateProcessTap` / `CATapDescription` to create private aggregate devices and process taps
2. **CoreAudio C** via the same Audio Tap API (`AudioHardwareCreateProcessTap`)
3. **`osascript`** with System Events (limited — can't control arbitrary app volumes)

There is NO simple `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData` pattern for per-process volume or mute. The Audio Tap API is the only mechanism available for per-app audio control, and it requires macOS 14.2 or later.

For device-level control (system output/input volume), the standard CoreAudio property API works:
- `AudioObjectGetPropertyData` with `kAudioDevicePropertyVolume` on the device object (not per-process)
- `kAudioHardwarePropertyProcessObjectList` (macOS 14.2+) for enumerating audio processes (replaces the nonexistent `kAudioHardwarePropertyRunningApps`)
- `AudioHardwareService` is deprecated since macOS 10.6 — use `AudioObjectGetPropertyData` with `kAudioObjectPropertyScopeOutput` / `kAudioObjectPropertyScopeInput`

A minimal Swift helper for the Audio Tap approach:
```swift
import CoreAudio
import Foundation

func getAudioApps() -> [[String: Any]] {
    var propSize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    // AudioObjectGetPropertyData to get list of process objects
    // Each process object can have its audio stream tapped via
    // AudioHardwareCreateProcessTap with a CATapDescription
}

func setAppVolume(pid: Int32, volume: Float) {
    // Requires Audio Tap API: AudioHardwareCreateProcessTap(CATapDescription(...))
    // to create a process tap, then adjust attenuation on the tap's stream.
    // There is no simpler per-process AudioObjectSetPropertyData pattern.
}
```

This compiles to a CLI tool invoked from the widget's commands. For Phase 1, only system volume (via osascript) is achievable without this native helper.

### Phased Roadmap

| Phase | What Ships | Dependencies | Effort |
|---|---|---|---|
| **P1** | Default output volume (osascript) | None | 1-2 days |
| **P2** | App volume list + per-app mute | Swift helper binary | 3-5 days |
| **P3** | Device picker (input/output select) | `SwitchAudioSource` or CoreAudio helper | 2-3 days |
| **P4** | Live audible-apps list (watch app launch/exit) | `monitor` action kind in Deck.swift | 1-2 weeks |
| **P5** | WebView mixer with live VU meter | WebView widget kind + CoreAudio helper | 2-3 weeks |

### Shell Command Reference

All commands for Phase 1:

```zsh
# Get current output volume (0-100)
osascript -e 'output volume of (get volume settings)'

# Get mute status (true/false)
osascript -e 'output muted of (get volume settings)'

# Set volume
osascript -e 'set volume output volume 50'

# Toggle mute
osascript -e 'set volume output muted (not output muted of (get volume settings))'

# Step up/down (clamped to 0-100)
osascript -e 'set v to (output volume of (get volume settings)) + 10; if v > 100 then set v to 100; set volume output volume v'
osascript -e 'set v to (output volume of (get volume settings)) - 10; if v < 0 then set v to 0; set volume output volume v'

# Get default output device name
SwitchAudioSource -t output -c 2>/dev/null || echo "Default"

# Get all audio devices
SwitchAudioSource -a -t output

# List audio input devices
SwitchAudioSource -a -t input

# Set default output device
SwitchAudioSource -s "Device Name"

# Get system volume with more detail
system_profiler SPAudioDataType 2>/dev/null | grep -A5 "Output"
```

### Key Limitations of Declarative Widget Approach

1. **No polling for app audio changes** — The reference system uses persistent CoreAudio property listeners. Shell commands can only poll, which is wasteful. For app-level changes, you'd poll every 1-3 seconds.

2. **No rich encoder support** — Encoder feedback (text, icon, indicator bar) isn't replicable in a basic Gatecaster widget. Sliders must be discrete button-based or use a WebView.

3. **No dynamic key creation** — a per-app key grid isn't expressible. Gatecaster instead renders audible apps as a scrollable list within a single tile.

4. **Image generation** — Dynamic per-app icon generation with text overlays requires its own SVG/icon rendering in Gatecaster, likely using SF Symbols or cached PNGs.
