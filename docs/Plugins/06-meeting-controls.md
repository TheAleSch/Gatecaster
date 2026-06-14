# macOS Meeting Control Widget — Architecture & Implementation Guide

---

## 1. Design Philosophy

Meeting control widgets for deck controllers face a fundamental challenge: desktop meeting applications (Zoom, Teams, Google Meet) do not expose formal automation interfaces. A clean, macOS-native solution uses **macOS Accessibility via System Events** to simulate keyboard shortcuts, which works universally across both browser-based and native desktop meeting apps — no browser extensions, no WebSocket servers, no bundled backend services.

This document describes the original Gatecaster meeting controls design using macOS-native automation patterns.

## 2. Architecture Overview

```
Gatecaster Widget
       │
       │ (osascript subprocess)
       │
       ▼
tell application "System Events"
       │
       ├── keystroke (keyboard shortcut injection)
       ├── tell process "zoom.us" to click (Accessibility button targeting)
       └── tell application "Google Chrome" to execute javascript (in-browser DOM clicks)
```

The widget itself handles all control logic locally — no background service, no companion browser extension, no WebSocket bridge. Each button press spawns an `osascript -e '...'` call that sends keystrokes or accessibility events directly to the target app.

### Why This Approach

- **No external dependencies** — only what macOS ships with
- **Universal** — keyboard shortcuts work on any meeting platform
- **Zero install friction** — no companion browser extension, no bundled Node server
- **Desktop app support** — works with Zoom, Teams, Slack, not just Google Meet

## 3. Meeting Platform Keyboard Shortcuts (macOS)

### Google Meet — keyboard shortcuts (works in any browser)

```applescript
-- Toggle microphone (Cmd + D)
tell application "System Events"
    keystroke "d" using command down
end tell

-- Toggle camera (Cmd + E)
tell application "System Events"
    keystroke "e" using command down
end tell

-- Raise/lower hand (Cmd + Ctrl + H)
tell application "System Events"
    key code 4 using {command down, control down}
end tell

-- Leave call (Cmd + Option + L)
tell application "System Events"
    keystroke "l" using {command down, option down}
end tell

-- Toggle captions (C)
tell application "System Events"
    keystroke "c"
end tell
```

**Screen share** in Google Meet can use the keyboard shortcut `Ctrl + Cmd + P` (`key code 35 using {control down, command down}`), or JavaScript injection via the browser's AppleScript dictionary:

```applescript
tell application "Google Chrome"
    tell window 1
        tell tab 1
            execute javascript "document.querySelector('[aria-label=\"Present now\"]')?.click()"
        end tell
    end tell
end tell
```

### Zoom Desktop App — keyboard shortcuts

Zoom for macOS has **no AppleScript dictionary** (confirmed by `sdef /Applications/Zoom.us.app` returning no output). All control must be done via keyboard shortcuts through System Events:

```applescript
-- Toggle mute (Cmd + Shift + A)
tell application "System Events"
    keystroke "a" using {command down, shift down}
end tell

-- Toggle video (Cmd + Shift + V)
tell application "System Events"
    keystroke "v" using {command down, shift down}
end tell

-- Leave meeting (Cmd + W)
tell application "System Events"
    keystroke "w" using command down
end tell

-- Raise hand (Option + Y)
tell application "System Events"
    key code 16 using {option down}
end tell

-- Start/stop screen share (Cmd + Shift + S)
tell application "System Events"
    keystroke "s" using {command down, shift down}
end tell
```

### Microsoft Teams (Desktop)

```applescript
-- Toggle mute (Cmd + Shift + M)
tell application "System Events"
    keystroke "m" using {command down, shift down}
end tell

-- Toggle video (Cmd + Shift + O)
tell application "System Events"
    keystroke "o" using {command down, shift down}
end tell

-- Raise hand (Cmd + Shift + K)
tell application "System Events"
    keystroke "k" using {command down, shift down}
end tell

-- Leave meeting (Cmd + Shift + B)
tell application "System Events"
    keystroke "b" using {command down, shift down}
end tell
```

### Slack Huddles

```applescript
-- Toggle mute (M)
tell application "System Events"
    keystroke "m"
end tell

-- Toggle video (V)
tell application "System Events"
    keystroke "v"
end tell
```

## 4. Widget Action Definitions

| Widget ID | Label | Behavior | macOS Implementation |
|---|---|---|---|
| `microphone` | Microphone | Toggle mic mute/unmute | `osascript` + keystroke |
| `camera` | Camera | Toggle camera on/off | `osascript` + keystroke |
| `hand` | Hand | Raise/lower hand | `osascript` + keystroke |
| `leave` | Leave | Leave current meeting | `osascript` + keystroke |
| `screenshare` | Share Screen | Start/stop screen sharing | `osascript` + Accessibility or JS injection |
| `reaction` | Reaction | Send emoji reaction | `osascript` + Accessibility button click |

## 5. Command Lookup Table

```js
const MEETING_COMMANDS = {
  microphone: {
    'google-meet': `osascript -e 'tell app "System Events" to keystroke "d" using command down'`,
    zoom: `osascript -e 'tell app "System Events" to keystroke "a" using {command down, shift down}'`,
    teams: `osascript -e 'tell app "System Events" to keystroke "m" using {command down, shift down}'`,
    'slack-huddles': `osascript -e 'tell app "System Events" to keystroke "m"'`
  },
  camera: {
    'google-meet': `osascript -e 'tell app "System Events" to keystroke "e" using command down'`,
    zoom: `osascript -e 'tell app "System Events" to keystroke "v" using {command down, shift down}'`,
    teams: `osascript -e 'tell app "System Events" to keystroke "o" using {command down, shift down}'`
  },
  hand: {
    'google-meet': `osascript -e 'tell app "System Events" to key code 4 using {command down, control down}'`,
    zoom: `osascript -e 'tell app "System Events" to key code 16 using {option down}'`,
    teams: `osascript -e 'tell app "System Events" to keystroke "k" using {command down, shift down}'`
  },
  leave: {
    'google-meet': `osascript -e 'tell app "System Events" to keystroke "l" using {command down, option down}'`,
    zoom: `osascript -e 'tell app "System Events" to keystroke "w" using command down'`,
    teams: `osascript -e 'tell app "System Events" to keystroke "b" using {command down, shift down}'`
  },
  screenshare: {
    'google-meet': `osascript -e 'tell app "System Events" to key code 35 using {control down, command down}'`,
    zoom: `osascript -e 'tell app "System Events" to keystroke "s" using {command down, shift down}'`,
    teams: `osascript -e 'tell app "System Events" to keystroke "e" using {command down, shift down}'`
  },
  reaction: {
    zoom: `osascript -e 'tell app "System Events" to key code 22 using {option down, command down}'`
  }
};
```

## 6. Manifest Structure

```json
{
  "id": "com.gatecaster.meeting-controls",
  "version": "1.0.0",
  "name": "Meeting Controls",
  "description": "Control video calls directly from your deck controller with quick access to essential meeting controls",
  "author": "Gatecaster",
  "license": "MIT",
  "platforms": ["macos"],
  "widgets": [
    {
      "id": "microphone",
      "name": "Microphone",
      "description": "Toggle microphone mute/unmute",
      "icon": "assets/microphone/default.svg",
      "states": {
        "default": "assets/microphone/default.svg",
        "on": "assets/microphone/on.svg",
        "off": "assets/microphone/off.svg",
        "disabled": "assets/microphone/disabled.svg"
      },
      "settings": [
        {
          "key": "platform",
          "label": "Meeting Platform",
          "type": "select",
          "options": ["google-meet", "zoom", "teams", "slack-huddles"],
          "default": "google-meet"
        }
      ]
    },
    {
      "id": "camera",
      "name": "Camera",
      "description": "Toggle camera on/off",
      "icon": "assets/camera/default.svg",
      "states": {
        "default": "assets/camera/default.svg",
        "on": "assets/camera/on.svg",
        "off": "assets/camera/off.svg",
        "disabled": "assets/camera/disabled.svg"
      },
      "settings": [
        {
          "key": "platform",
          "label": "Meeting Platform",
          "type": "select",
          "options": ["google-meet", "zoom", "teams"],
          "default": "google-meet"
        }
      ]
    },
    {
      "id": "hand",
      "name": "Hand",
      "description": "Raise/lower hand",
      "icon": "assets/hand/default.svg",
      "settings": [
        {
          "key": "platform",
          "label": "Meeting Platform",
          "type": "select",
          "options": ["google-meet", "zoom", "teams"],
          "default": "google-meet"
        }
      ]
    },
    {
      "id": "leave",
      "name": "Leave Meeting",
      "description": "Leave current meeting",
      "icon": "assets/leave/default.svg",
      "settings": [
        {
          "key": "platform",
          "label": "Meeting Platform",
          "type": "select",
          "options": ["google-meet", "zoom", "teams"],
          "default": "google-meet"
        },
        {
          "key": "confirm",
          "label": "Require confirmation",
          "type": "checkbox",
          "default": true
        }
      ]
    },
    {
      "id": "screenshare",
      "name": "Share Screen",
      "description": "Start or stop screen sharing",
      "icon": "assets/screenshare/default.svg",
      "settings": [
        {
          "key": "platform",
          "label": "Meeting Platform",
          "type": "select",
          "options": ["google-meet", "zoom", "teams"],
          "default": "google-meet"
        }
      ]
    },
    {
      "id": "reaction",
      "name": "Reaction",
      "description": "Send a reaction/emoji",
      "icon": "assets/reaction/default.svg",
      "settings": [
        {
          "key": "platform",
          "label": "Meeting Platform",
          "type": "select",
          "options": ["google-meet", "zoom"],
          "default": "google-meet"
        },
        {
          "key": "emoji",
          "label": "Emoji",
          "type": "select",
          "options": [
            "thumbs-up", "thumbs-down", "clapping", "heart", "laughter",
            "sad", "surprised", "thinking", "celebrate"
          ],
          "default": "thumbs-up"
        }
      ]
    }
  ]
}
```

## 7. Phased Implementation

### Phase 1 — AppleScript MVP (Week 1-2)

Goal: Working meeting controls via `osascript`, no external dependencies.

- Build command lookup table with AppleScript strings for each platform/action pair
- Support Google Meet, Zoom, Teams
- 4 core widgets: microphone, camera, hand, leave
- Execute commands via `exec()` or equivalent
- Optimistic toggle state tracking (no real-time feedback)
- Configuration Panel: platform selector dropdown

**Execution sketch:**

```js
import { execSync } from 'child_process';

function runMeetingCommand(action, platform) {
  const script = MEETING_COMMANDS[action]?.[platform];
  if (!script) return { success: false, error: `No command for ${action}/${platform}` };

  try {
    const result = execSync(script, { timeout: 5000 });
    return { success: true, output: result.toString() };
  } catch (err) {
    return { success: false, error: err.message };
  }
}
```

**Known issues:**
- Meeting app or browser tab must have focus
- Leave action should check if meeting window still exists
- No state feedback — widget assumes toggle behavior

### Phase 2 — State Tracking & Expanded Widgets (Week 3-4)

Goal: Optimistic local state tracking with lifecycle management.

- Add `screenshare` widget (hardest — no keyboard shortcut on browser platforms)
- Add `reaction` widget (emoji selection in Configuration Panel)
- Local state machine per widget:

```
UNKNOWN → TOGGLED_ON → TOGGLED_OFF → TOGGLED_ON ...
(Reset to UNKNOWN after N minutes or on error)
```

- Retry logic and window focus activation

### Phase 3 — macOS Accessibility API (Week 5-6)

Goal: Target native elements directly instead of relying on keyboard shortcuts.

- Use `tell process "zoom.us"` for Zoom menu bar interactions
- Use `tell process "Microsoft Teams"` for Teams UI element targeting
- Accessibility button click as fallback when keyboard shortcuts fail

```applescript
tell application "System Events"
    tell process "zoom.us"
        set targetButton to first button of window 1 whose description contains "mute"
        click targetButton
    end tell
end tell
```

- Configurable shortcut overrides in Configuration Panel
- Process-level window focus activation

## 8. Configuration Panel Design

Each widget has a Configuration Panel (opened from the deck controller's settings UI) with:

- **Platform selector** — dropdown matching the platform option in the manifest
- **Emoji picker** (reaction widget only) — radio button grid of 9 emoji options
- **Confirmation checkbox** (leave widget only) — require a two-tap confirm before leaving
- **"How to Use"** section — collapsible instructions explaining focus requirements
- **"Troubleshooting"** section — known issues and resolution steps

## 9. Technical Risks & Mitigations

| Risk | Mitigation |
|---|---|
| **Keyboard shortcuts change** | Define shortcuts in the command table; add Configuration Panel fields for user override |
| **Window focus issues** | Activate target process before sending keystrokes: `tell process "zoom.us" to set frontmost to true` |
| **No real-time state feedback** | Use optimistic local toggle state; reset to UNKNOWN on error or timeout |
| **Reactions limited by keyboard shortcuts** | Zoom requires clicking the Reactions button followed by a specific emoji — use AppleScript Accessibility to click UI coordinates or menu items |
| **Zoom menu bar changes** | Fall back to keyboard shortcut method; provide user-configurable shortcuts |
| **Google Meet screen share (no shortcut)** | Use JavaScript injection via browser's AppleScript dictionary as only viable path |

## 10. Asset Organization

```
assets/
  microphone/
    default.svg
    on.svg
    off.svg
    disabled.svg
  camera/
    default.svg
    on.svg
    off.svg
    disabled.svg
  hand/
    default.svg
  leave/
    default.svg
  screenshare/
    default.svg
  reaction/
    default.svg
    thumbs-up.svg
    thumbs-down.svg
    clapping.svg
    heart.svg
    laughter.svg
    sad.svg
    surprised.svg
    thinking.svg
    celebrate.svg
```

State icons follow a simple convention: `default.svg` for idle, `on.svg` for active state, `off.svg` for inactive state, `disabled.svg` when the action is unavailable. Reaction emoji SVGs are single-purpose icons.

## 11. Comparison: Automation Approaches

| Aspect | Browser Extension Approach | macOS Native (Gatecaster) |
|---|---|---|
| **Meeting Platform** | Google Meet only | Google Meet, Zoom, Teams, Slack |
| **Control Mechanism** | Chrome Extension content script | AppleScript / Accessibility API |
| **Companion App** | Required browser extension | None |
| **State Feedback** | Via browser extension | Optimistic local toggle |
| **Desktop App Support** | No | Yes |
| **Installation** | Extension + service | Single widget |
| **Dependencies** | Browser WebSocket library | macOS System Events |
