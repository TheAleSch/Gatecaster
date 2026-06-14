# Zoom Meeting Controls — macOS Automation Design for Gatecaster

---

## SECTION A — macOS Automation Architecture

### 1. Architecture Overview

Zoom meeting control is achieved through **macOS-native accessibility automation** — specifically AppleScript's System Events to dispatch keyboard shortcuts. No C++ binary, no SDK integration, no IPC proxy.

**High-level architecture:**

```
Gatecaster App  ──→  child_process.exec('osascript ...')  ──→  System Events  ──→  zoom.us (keyboard shortcut)
                                                                                         │
                                                                           Configuration Panel (HTML/JS)
```

The system has **no native binary** — all action logic is inline osascript commands dispatched from Node.js. The Configuration Panel is purely for user preferences (localization, recording type, emoji selection). No JavaScript action code needed on the widget side.

### 2. Actions Exposed

| Action ID | States | Purpose |
|---|---|---|
| `zoom-mute` | 2 (Muted, Unmuted) | Toggle microphone |
| `zoom-video` | 2 (Camera On, Camera Off) | Toggle camera |
| `zoom-screenshare` | 2 (Sharing, Not Sharing) | Screen share toggle |
| `zoom-leave` | 1 | Leave/end meeting |
| `zoom-raise-hand` | 2 (Raised, Lowered) | Raise/lower hand |
| `zoom-react` | 1 | Send emoji reaction (direct shortcuts via Opt+Cmd+4–9) |
| `zoom-record` | 2 (Recording, Not Recording) | Local/cloud recording |

### 3. How It Connects to Zoom

Zoom has **no AppleScript dictionary** (`sdef` returns no output — this was confirmed through macOS research). It does not expose a scripting interface, so traditional AppleScript `tell application "zoom.us" to ...` cannot invoke meeting functions directly.

The solution is **GUI scripting via System Events** — the same mechanism macOS users employ for any app that lacks scriptability. Zoom supports a full set of keyboard shortcuts for meeting control. By dispatching these via `osascript -e 'tell app "System Events" to tell process "zoom.us" to keystroke ...'`, we achieve reliable meeting control without any SDK.

The system **monitors Zoom's process** to detect whether it is running before dispatching commands.

### 4. Data Flow (Command → Zoom Action)

```
User taps widget on deck controller
  → Gatecaster reads widget action config
  → Gatecaster spawns osascript (child_process.exec)
  → osascript sends keystroke via System Events to zoom.us
  → Zoom processes keyboard shortcut
  → Widget toggles its local state optimistically
```

### 5. Key Finding: No AppleScript Dictionary

Zoom does not expose an AppleScript suite. Verified via:

```zsh
sdef /Applications/Zoom.us.app
# Returns no output — no scripting terminology
```

This means:
- No `tell application "zoom.us" to mute audio` style commands
- No property access for current meeting state
- No event handlers for meeting state changes

The only reliable control path is **keyboard shortcut dispatch** via System Events.

---

## SECTION B — Gatecaster Widget Implementation Plan

### 1. macOS-Native Commands (osascript / System Events)

Every command uses the same pattern: target the `zoom.us` process via System Events and dispatch the known keyboard shortcut.

| Action | Shortcut | osascript Command |
|---|---|---|
| Mute/Unmute | `Cmd+Shift+A` | `tell app "System Events" to tell process "zoom.us" to keystroke "a" using {command down, shift down}` |
| Start/Stop Video | `Cmd+Shift+V` | `tell app "System Events" to tell process "zoom.us" to keystroke "v" using {command down, shift down}` |
| Share Screen | `Cmd+Shift+S` | `tell app "System Events" to tell process "zoom.us" to keystroke "s" using {command down, shift down}` |
| Pause/Resume Share | `Cmd+Shift+T` | `tell app "System Events" to tell process "zoom.us" to keystroke "t" using {command down, shift down}` |
| Start Local Recording | `Cmd+Shift+R` | `tell app "System Events" to tell process "zoom.us" to keystroke "r" using {command down, shift down}` |
| Start Cloud Recording | `Cmd+Shift+C` | `tell app "System Events" to tell process "zoom.us" to keystroke "c" using {command down, shift down}` |
| Pause/Resume Recording | `Cmd+Shift+P` | `tell app "System Events" to tell process "zoom.us" to keystroke "p" using {command down, shift down}` |
| Raise/Lower Hand | `Opt+Y` | `tell app "System Events" to tell process "zoom.us" to key code 16 using {option down}` |
| Leave Meeting | `Cmd+W` then Enter | `tell app "zoom.us" to activate\ndelay 0.2\ntell app "System Events" to tell process "zoom.us" to keystroke "w" using {command down}\ndelay 0.5\ntell app "System Events" to tell process "zoom.us" to key code 36` |
| Reactions Picker | `Shift+Cmd+Y` | `tell app "System Events" to tell process "zoom.us" to keystroke "y" using {command down, shift down}` |
| Toggle Participants | `Cmd+U` | `tell app "System Events" to tell process "zoom.us" to keystroke "u" using {command down}` |
| Toggle Full Screen | `Cmd+Shift+F` | `tell app "System Events" to tell process "zoom.us" to keystroke "f" using {command down, shift down}` |

### 2. Reliability Assessment

| Reliability | Actions |
|---|---|
| ★★★★★ (Rock solid) | Mute/Unmute, Video toggle, Raise/Lower hand, Recording start/stop, Full screen |
| ★★★★☆ (Reliable) | Leave meeting (timing-dependent on dialog; focus guard: activate Zoom first to ensure main window), Screen share toggle (opens picker) |
| ★★★★★ (Rock solid) | Emoji reactions (direct shortcuts: Opt+Cmd+4 clap, +5 thumbs up, +6 heart, +7 joy, +8 wow, +9 tada) |
| ★★☆☆☆ (Brittle) | State queries (UI element inspection varies by Zoom version) |

### 3. What Is Possible via osascript Only (No SDK)

| Feature | Approach | Quality |
|---|---|---|
| Mute/Unmute | `Cmd+Shift+A` via System Events | High |
| Video toggle | `Cmd+Shift+V` via System Events | High |
| Raise/Lower hand | `Opt+Y` via System Events | High |
| Leave meeting | `Cmd+W` + Enter via System Events | High (focus guard: activate Zoom first to avoid closing sub-window) |
| Start/Stop recording | `Cmd+Shift+R` or `Cmd+Shift+C` | High |
| Screen share toggle | `Cmd+Shift+S` (opens picker) | Medium |
| Send emoji reaction | `Shift+Cmd+Y` or direct shortcuts (`Opt+Cmd+4`–`9`) | High |
| Query mute/video state | UI element inspection (version-dependent) | Low |

### 4. Limitations (No SDK Workaround)

| Feature | Limitation |
|---|---|
| Bi-directional state sync | Cannot receive push notifications — only optimistic local state |
| Participant roster | No AppleScript access to meeting data |
| Cloud vs local recording choice | Shortcut toggles the last-used mode; configurable via setting |
| Share audio/video options | No keyboard shortcut for these toggles |
| Screen with specific display selection | Opens picker; requires additional navigation |
| Full leave vs end meeting for host | Dialog behavior differs based on role |
| Breakout room controls | No keyboard shortcuts |

### 5. Manifest Structure

Each Zoom control is a separate widget type in Gatecaster:

```json
{
  "manifestVersion": "1.0.0",
  "name": "Zoom Meeting Controls",
  "description": "Control Zoom meetings via Gatecaster overlay",
  "version": "1.0.0",
  "widgets": [
    {
      "type": "zoom-mute",
      "name": "Zoom Mute Toggle",
      "icon": "icons/mute.svg",
      "size": { "width": 120, "height": 120 },
      "states": 2,
      "stateDisplayName": ["Muted", "Unmuted"],
      "supportedPlatforms": ["macos"],
      "requiresAccessibility": true,
      "action": {
        "interpreter": "osascript",
        "script": "tell application \"System Events\" to tell process \"zoom.us\" to keystroke \"a\" using {command down, shift down}"
      }
    },
    {
      "type": "zoom-video",
      "name": "Zoom Camera Toggle",
      "icon": "icons/camera.svg",
      "size": { "width": 120, "height": 120 },
      "states": 2,
      "stateDisplayName": ["Camera On", "Camera Off"],
      "supportedPlatforms": ["macos"],
      "requiresAccessibility": true,
      "action": {
        "interpreter": "osascript",
        "script": "tell application \"System Events\" to tell process \"zoom.us\" to keystroke \"v\" using {command down, shift down}"
      }
    },
    {
      "type": "zoom-raise-hand",
      "name": "Zoom Raise Hand",
      "icon": "icons/hand.svg",
      "size": { "width": 120, "height": 120 },
      "states": 2,
      "stateDisplayName": ["Hand Down", "Hand Raised"],
      "supportedPlatforms": ["macos"],
      "requiresAccessibility": true,
      "action": {
        "interpreter": "osascript",
        "script": "tell application \"System Events\" to tell process \"zoom.us\" to key code 16 using {option down}"
      }
    },
    {
      "type": "zoom-leave",
      "name": "Zoom Leave Meeting",
      "icon": "icons/leave.svg",
      "size": { "width": 120, "height": 120 },
      "states": 1,
      "supportedPlatforms": ["macos"],
      "requiresAccessibility": true,
      "action": {
        "interpreter": "osascript",
        "script": "tell application \"zoom.us\" to activate\ndelay 0.2\ntell application \"System Events\" to tell process \"zoom.us\" to keystroke \"w\" using {command down}\ndelay 0.5\ntell application \"System Events\" to tell process \"zoom.us\" to key code 36"
      },
      "confirmAction": true,
      "focusGuard": "Cmd+W closes the focused window. If a secondary window (chat, participants) is focused, it will close that window instead of triggering the leave dialog. The 'activate' command before the keystroke brings Zoom to front as a guard."
    },
    {
      "type": "zoom-record",
      "name": "Zoom Recording",
      "icon": "icons/record.svg",
      "size": { "width": 120, "height": 120 },
      "states": 2,
      "stateDisplayName": ["Not Recording", "Recording"],
      "supportedPlatforms": ["macos"],
      "requiresAccessibility": true,
      "configuration": [
        {
          "key": "recordingType",
          "type": "select",
          "label": "Recording Type",
          "options": [
            { "value": "local", "label": "Local" },
            { "value": "cloud", "label": "Cloud" }
          ],
          "default": "local"
        }
      ],
      "action": {
        "interpreter": "osascript",
        "script": "tell application \"System Events\" to tell process \"zoom.us\" to keystroke \"{{recordingType}}\" using {command down, shift down}"
      },
      "templateVariables": {
        "recordingType": "Key to send: 'c' for cloud recording, 'r' for local recording (matches config options)"
      }
    },
    {
      "type": "zoom-react",
      "name": "Zoom Emoji Reaction",
      "icon": "icons/react.svg",
      "size": { "width": 120, "height": 120 },
      "states": 1,
      "supportedPlatforms": ["macos"],
      "requiresAccessibility": true,
      "configuration": [
        {
          "key": "emojiKey",
          "type": "select",
          "label": "Emoji",
          "options": [
            { "value": "4", "label": "Clap" },
            { "value": "5", "label": "Thumbs Up" },
            { "value": "6", "label": "Heart" },
            { "value": "7", "label": "Joy" },
            { "value": "8", "label": "Wow" },
            { "value": "9", "label": "Tada" }
          ],
          "default": "4"
        }
      ],
      "action": {
        "interpreter": "osascript",
        "script": "tell application \"System Events\" to tell process \"zoom.us\" to keystroke \"{{emojiKey}}\" using {command down, option down}",
        "notes": "Direct emoji shortcuts: Opt+Cmd+4 (clap), +5 (thumbs up), +6 (heart), +7 (joy), +8 (wow), +9 (tada)"
      }
    },
    {
      "type": "zoom-screenshare",
      "name": "Zoom Screen Share",
      "icon": "icons/share.svg",
      "size": { "width": 120, "height": 120 },
      "states": 2,
      "stateDisplayName": ["Not Sharing", "Sharing"],
      "supportedPlatforms": ["macos"],
      "requiresAccessibility": true,
      "action": {
        "interpreter": "osascript",
        "script": "tell application \"System Events\" to tell process \"zoom.us\" to keystroke \"s\" using {command down, shift down}",
        "notes": "Cmd+Shift+S opens share picker. Full automation requires clicking the desired screen."
      }
    }
  ]
}
```

### 6. Key Technical Considerations

#### Accessibility Permissions

macOS requires **Accessibility access** for `System Events` to control other applications:

- **Settings:** `System Settings → Privacy & Security → Accessibility`
- The process running `osascript` must be granted access (Terminal, Gatecaster.app, or a helper binary)
- Can be checked programmatically:
  ```applescript
  tell application "System Events" to get name of first process whose frontmost is true
  ```
  If this throws, accessibility is not granted.

#### Zoom App Path Variance

Zoom can be installed from two sources, each with a different bundle path:

| Source | App Path | Process Name |
|---|---|---|
| Direct (zoom.us) | `/Applications/Zoom.us.app` | `"zoom.us"` |
| Mac App Store | `/Applications/Zoom.app` | `"Zoom"` |

When targeting the process for System Events, the `process` name must match exactly:
- Direct install: `tell process "zoom.us"`
- App Store: `tell process "Zoom"`

**Detection guard** — check both process names before dispatching and use whichever is running:

```applescript
tell application "System Events"
    if exists process "zoom.us" then
        set zoomProc to "zoom.us"
    else if exists process "Zoom" then
        set zoomProc to "Zoom"
    else
        return "zoom_not_running"
    end if
end tell
-- Then use zoomProc variable in keystroke commands
```

The `sdef` and accessibility inspection paths also differ:
```zsh
sdef /Applications/Zoom.us.app   # Direct install
sdef /Applications/Zoom.app      # App Store install
```

#### Process Detection

Before dispatching commands, check whether Zoom is running. Use the detection guard above to handle both process names, then dispatch through the matched process.

#### State Tracking (Optimistic)

Since Zoom provides no query API, state is tracked **optimistically** in the widget:

- Widget toggles its visual state on each press
- No round-trip confirmation needed
- Icon reflects the presumed state after the command

For improved accuracy, a polling script can inspect Zoom's UI elements:

```applescript
tell application "System Events"
    tell process "zoom.us"
        set muteButton to first button of window 1 whose description contains "mute"
        return description of muteButton
    end tell
end tell
```

**Caveat:** UI element structure varies by Zoom version. This approach requires version-specific handling and is inherently more brittle than the shortcut-dispatch approach.

#### Sandboxing & Gatekeeper

The osascript approach avoids any binary distribution concerns — it uses only built-in macOS scripting subsystems. No notarization needed, no helper binary to distribute, no library dependencies.

#### Image Resources

Each widget needs SVG icons for all states:
- Muted / Unmuted (microphone)
- Camera On / Off
- Hand Raised / Lowered
- Recording / Not Recording
- Sharing / Not Sharing
- Leave Meeting
- Emoji reaction

### 7. Phased Approach

#### Phase 1: Core Toggles (MVP) — 1-2 days

Four most reliable widgets:

| Widget | Shortcut | Notes |
|---|---|---|
| `zoom-mute` | `Cmd+Shift+A` | Most used, most reliable |
| `zoom-video` | `Cmd+Shift+V` | Same reliability as mute |
| `zoom-raise-hand` | `Opt+Y` | Instant toggle |
| `zoom-leave` | `Cmd+W` + Enter | With confirmation dialog |

**Implementation:**
- Gatecaster backend spawns `osascript -e '...'` via Node.js `child_process.exec()`
- Widget UI shows two states with state-indicator icons
- Leave widget shows confirmation before executing
- **State tracking:** local only — optimistic toggle on each press
- No polling, no IPC — simplest possible implementation

**⚠️ Focus guard for leave meeting:** `Cmd+W` closes whichever window is focused. If a secondary Zoom window (chat, participants, settings) has focus instead of the main meeting window, `Cmd+W` will close that secondary window rather than triggering the leave dialog. The `activate` command before the keystroke (which brings Zoom to front) mitigates this, but does not guarantee the meeting window receives focus. An additional guard is to click the meeting window first via UI scripting, or send a second `Cmd+W` in sequence.

#### Phase 2: Recording & State Awareness — 2-3 days

| Widget | Shortcut | Notes |
|---|---|---|
| `zoom-record` | `Cmd+Shift+R` / `Cmd+Shift+C` | Configurable local vs cloud |
| `zoom-screenshare` | `Cmd+Shift+S` | Basic toggle, no screen selection |

**State tracking:**
- Add polling every 2-3 seconds via an AppleScript UI element inspection script
- Sync widget icon with actual Zoom state
- Configuration Panel allows recording type selection

#### Phase 3: Reactions & Screen Picker — 1-2 weeks

| Widget | Notes |
|---|---|
| `zoom-react` | Sends emoji via direct shortcuts (`Opt+Cmd+4`–`9`) |
| `zoom-screenshare` with screen picker | Tab/arrow navigation through share dialog |

**Emoji reactions:**
- Direct keyboard shortcuts available: `Opt+Cmd+4` (clap), `Opt+Cmd+5` (thumbs up), `Opt+Cmd+6` (heart), `Opt+Cmd+7` (joy), `Opt+Cmd+8` (wow), `Opt+Cmd+9` (tada)
- The `zoom-react` widget maps the user's emoji selection to the corresponding key and dispatches it directly
- No mouse interaction or navigation needed

### 8. Summary

| Feature | osascript | Reliability | SDK Needed | Priority |
|---|---|---|---|---|
| Mute/Unmute | ✅ Yes | High | No | P0 |
| Video on/off | ✅ Yes | High | No | P0 |
| Raise/Lower Hand | ✅ Yes | High | No | P0 |
| Leave Meeting | ✅ Yes | High | No | P0 |
| Start/Stop Recording | ✅ Yes | High | No | P1 |
| Screen Share (basic) | ✅ Yes | Medium | No | P1 |
| Emoji Reactions | ✅ Yes | High | No | P2 |
| State Sync (polling) | ⚠️ Partial | Low | No | P2 |
| Screen share picker | ⚠️ Partial | Low | No | P2 |
| Bi-directional state | ❌ No | — | Yes | P3 |
| Share audio options | ❌ No | — | Yes | P3 |
| Participant controls | ❌ No | — | Yes | P3 |
