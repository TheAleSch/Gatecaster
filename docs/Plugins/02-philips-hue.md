# Philips Hue Smart Lighting Control for Gatecaster — macOS Design Document

---

## Core Architecture

A Philips Hue smart lighting control system that lets users control Philips Hue lights from Gatecaster tiles, dials, and touch panels. The system uses a Node.js application backend that communicates with Gatecaster via WebSocket, with a separate configuration panel rendered as a local HTML page served from the Node.js process.

**Why Node.js as the backend runtime:**

While the Philips Hue REST API v1 is straightforward HTTP/JSON — and much of the control surface could be expressed as `curl` commands in declarative tiles — a persistent Node.js process provides capabilities that shell scripts alone cannot:

- **Bridge pairing wizard** — a multi-step setup flow (discover → link-button press → capture API key) with real-time feedback
- **Dynamic light/group/scene enumeration** — the bridge's inventory changes as users add lights; a static manifest cannot adapt
- **Real-time state via Hue v2 EventStream** — server-sent events push state changes instead of polling
- **Dynamic tile image rendering** — SVG templates composited with live color, brightness, and archetype data
- **In-memory state cache** — avoids hammering the bridge with redundant requests across many tiles
- **Multiple bridge support** — users may have bridges in different zones, each with its own API key

The Hue REST API (v1 and v2) is a public, documented interface. The backend design here is an original architecture for macOS that happens to target that universal API.

**Three-tier architecture:**

1. **Widget Backend (Node.js)** — `index.js`: A long-lived Node.js process that handles all Hue API communication (HTTP and EventStream), state management, settings persistence, and WebSocket message routing to Gatecaster.

2. **Configuration Panel (Browser/HTML)** — `config/index.html` + JS: Rendered by Gatecaster when a tile's settings are opened. Communicates with the backend via WebSocket through Gatecaster's message forwarding.

3. **Setup Window** — `setup/index.html` + JS: A browser popup (`window.open()`) used for bridge discovery and pairing. Communicates with the configuration panel via `window.postMessage()`.

### Actions

Gatecaster's tile actions are derived from what the public Hue API can do — toggle
power, set/adjust brightness, set/adjust color temperature, set color, activate a
scene, read a sensor. Action IDs live under Gatecaster's own `com.gatecaster.hue.*`
namespace (not an original vendor prefix). The set below maps one tile to one Hue
capability; richer compositions are layout choices, not new primitives.

| Action ID | Name | Hue capability used |
|---|---|---|
| `com.gatecaster.hue.power` | On / Off | `PUT .../state {"on": …}` on a light or group |
| `com.gatecaster.hue.brightness` | Brightness | set `bri` (absolute, 1–100% → 1–254) |
| `com.gatecaster.hue.brightness-adjust` | Adjust Brightness | `bri_inc` relative step |
| `com.gatecaster.hue.color` | Color | set `xy` from a hex pick (CIE conversion below) |
| `com.gatecaster.hue.temperature` | Temperature | set `ct` (absolute, mapped to mired) |
| `com.gatecaster.hue.temperature-adjust` | Adjust Temperature | `ct_inc` relative step |
| `com.gatecaster.hue.color-cycle` | Color Cycle | step through a user list of saved colors/temps |
| `com.gatecaster.hue.scene` | Scene | `PUT .../groups/<id>/action {"scene": …}` |
| `com.gatecaster.hue.sensor` | Sensor Read-out | read temperature from a Hue sensor resource |

---

## Bridge Discovery

Two methods, both based on the public Hue discovery protocols:

### 1. Cloud Discovery (Primary)

`GET https://discovery.meethue.com` returns a JSON array of bridges on the LAN, each with `internalipaddress` and `id`. This is the standard discovery endpoint published by Signify. Used in the configuration panel and setup window via `XMLHttpRequest`.

```bash
curl -sf "https://discovery.meethue.com" | jq -c '.[] | {ip: .internalipaddress, id: .id}'
```

### 2. DNS-SD (Bonjour/mDNS)

The Node.js backend uses an mDNS/Bonjour library to browse for `_hue._tcp.local` services on the local network. This is more robust when the cloud endpoint is unreachable (air-gapped networks, firewall restrictions).

```
browse _hue._tcp.local → SRV records → bridge hostnames + IPs
```

---

## Authentication (Bridge Pairing)

The Hue bridge pairing protocol requires physical button interaction — there is no programmatic way to obtain an API key without it. The flow:

1. **Discover** — User triggers discovery (cloud or mDNS). Bridge IPs and IDs are gathered.

2. **Link Button** — User is prompted to press the physical link button on the Hue Bridge.

3. **POST /api** — The backend sends a `POST` to each discovered bridge:
   ```bash
curl -sk -X POST -H "Content-Type: application/json" \
      -d '{"devicetype": "gatecaster#macbook-pro"}' \
      "https://<bridge-ip>/api"
   ```
   The `devicetype` string identifies the client to the bridge.

4. **Response** — If the link button was pressed within 30 seconds, the bridge responds:
   ```json
   [{"success": {"username": "aabbccddee0011223344"}}]
   ```
   This username is the API key for all subsequent calls. If the button was not pressed, the bridge returns a `"link button not pressed"` error.

5. **Storage** — The configuration panel receives the bridge IP, ID, and username via a custom event and saves it to the backend's global settings.

The `devicetype` should be unique per device so users can identify clients in the Hue app's "Linked Apps" list.

---

## Configuration Panel Architecture

### Layout

The configuration panel (`config/index.html`) is the per-action settings UI. Its structure:

- **Bridge selector** — dropdown listing paired bridges, with "Add Bridge" and "Remove Bridge" options
- **Light/group selector** — organized optgroups for rooms, zones, lights, and groups
- **Unit selector** — Celsius/Fahrenheit toggle for motion sensor actions
- **Common display settings** — checkboxes for Mini-Icon, Color swatch, Mini-Slider, Color-Tags
- **Debug menu** — Lights Info, Discovery Info, Export Icon, Restart
- **Action placeholder** — `<div id="placeholder">` where action-specific configuration UI is injected
- **Dialog** — native `<dialog>` element for tooltips and help

### Per-action settings (what each config view collects)

When the user opens a tile's settings, Gatecaster shows the config view for that
action. Each view is responsible only for collecting the inputs the action needs;
how Gatecaster routes to a view and structures its config code is Gatecaster's own
implementation choice. The required inputs follow from the Hue capability, not from
any original UI:

| Action | Inputs the config view collects |
|---|---|
| Power | bridge + target (light or group); optional name filter / sort over the list |
| Brightness | bridge + target; absolute level slider (1–100%) |
| Adjust Brightness | bridge + target; relative step amount |
| Color | bridge + target; hex color picker (HTML `<input type="color">`) |
| Temperature | bridge + target; mired slider (153–500) |
| Adjust Temperature | bridge + target; relative step amount |
| Color Cycle | bridge + target; an ordered list of up to N colors/temps to cycle |
| Scene | bridge + group; scene dropdown populated from that group's scenes |
| Sensor Read-out | bridge + sensor; unit toggle (°C / °F) |

Common to every view: a **bridge selector** (paired bridges, with add/remove), a
**target selector** (rooms, zones, lights, and groups, grouped for readability), and
the standard save-on-change behavior. The list contents come from the backend's
cached bridge inventory (below).

### Communication channel

The config view talks to the backend over a loopback WebSocket
(`ws://127.0.0.1:<port>`; loopback avoids name-resolution overhead and keeps traffic
off the network). Over it the view loads the widget-wide settings, receives the
bridge/light/scene inventory, pushes setting changes back, and forwards control or
discovery commands to the backend. The exact message shapes are an internal
Gatecaster protocol, not part of any public interface.

---

## Widget Backend (Node.js)

### Dependencies

The bundled `index.js` requires the following categories of packages — choose independently from the npm registry:

| Capability | Purpose |
|---|---|
| mDNS/Bonjour browser | Discover Hue bridges on the local network (service type `_hue._tcp`) |
| Color space conversion | Convert hex ↔ RGB ↔ CIE xy chromaticity |
| WebSocket server | Communicate with Gatecaster over loopback WebSocket |
| HTTP SSE client | Subscribe to Hue v2 EventStream (`text/event-stream`) |
| SVG parser/composer | Parse and modify SVG templates for tile image generation |
| JSON streaming | Handle large bridge inventory responses without loading all into memory |

### Hue API Communication

The backend uses two Hue API versions in parallel:

- **Hue API v1 (REST)** — Pairing (`POST /api`), reading state (`GET /api/<username>/lights|groups|scenes`), writing state (`PUT /api/<username>/lights/<id>/state`)
- **Hue API v2 (EventStream)** — Server-Sent Events (SSE) over plain HTTP at `https://<bridge-ip>/eventstream/clip/v2` for real-time state updates. SSE is an HTTP streaming protocol, not WebSocket — use an HTTP streaming client (`eventsource` or built-in `http`/`https` module), not `ws`. Monitor during development:
  ```bash
  curl --insecure -N -H 'hue-application-key: <key>' -H 'Accept: text/event-stream' https://<bridge-ip>/eventstream/clip/v2
  ```

### State Cache

A polling cache refreshes every 60 seconds:

1. Discover all paired bridges (from stored credentials)
2. For each bridge, fetch lights, groups, rooms, zones, scenes, sensors
3. Store in a bridge-keyed object with sub-caches for `light`, `room`, `zone`, `grouped_light`, `scene`, `temperature`, `motion`
4. Transmit cache to all connected configuration panels via update events

Real-time updates from the v2 EventStream augment the polling cache — when a state change event arrives, the relevant cache entry is updated immediately and pushed to panels.

---

## Color / Temperature / Brightness Control

### Color Pipeline

The Hue API v1 represents color in CIE xy chromaticity coordinates. Conversion pipeline:

```
Hex → RGB (8-bit) → linear RGB → XYZ → CIE xy
```

All conversion math is from the public CIE 1931 color space standard and can be implemented in JavaScript, Python, or any language:

**Python (inline in shell scripts):**
```python
h = '#FF6600'.lstrip('#')
r, g, b = [int(h[i:i+2], 16) / 255 for i in (0, 2, 4)]
# Linearize (gamma correction)
r = pow((r + 0.055) / 1.055, 2.4) if r > 0.04045 else r / 12.92
g = pow((g + 0.055) / 1.055, 2.4) if g > 0.04045 else g / 12.92
b = pow((b + 0.055) / 1.055, 2.4) if b > 0.04045 else b / 12.92
# RGB → XYZ (sRGB matrix)
x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041
# XYZ → xy
cx = x / (x + y + z)
cy = y / (x + y + z)
print(f'{cx},{cy}')
```

### Temperature Pipeline

Color temperature uses the mired scale (micro reciprocal degree):

```
mired = 1,000,000 / Kelvin
```

Hue API range: 153 mired (≈ 6500K cool) to 500 mired (≈ 2000K warm).

Conversion from mired to displayable hex uses Tanner Helland's algorithm:
1. mired → Kelvin
2. Kelvin → RGB via lookup/interpolation
3. RGB → hex

### Brightness

Hue API v1 uses `bri` (0–254, where 0 = off, 254 = max). The UI presents 1–100%.

**Conversion:** `bri = Math.round((percentage / 100) * 254)`

### Hue API Control Calls

All control operations use `PUT` against the Hue Bridge REST API:

| Operation | Endpoint | Body |
|---|---|---|
| Power | `/api/<username>/lights/<id>/state` | `{"on": true}` or `{"on": false}` |
| Brightness | `/api/<username>/lights/<id>/state` | `{"on": true, "bri": <1-254>}` |
| Color | `/api/<username>/lights/<id>/state` | `{"on": true, "xy": [<x>, <y>]}` |
| Temperature | `/api/<username>/lights/<id>/state` | `{"on": true, "ct": <153-500>}` |
| Scene | `/api/<username>/groups/<group-id>/action` | `{"scene": "<scene-id>"}` |

### Debouncing

Slider-driven controls (brightness, temperature) debounce HTTP requests at 80ms to avoid flooding the bridge during drag operations. Implemented via a standard leading-edge debounce:

```js
const debounce = (fn, ms) => {
  let timer;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
};
```

---

## Request/response over the two channels

Both hops — config-view ↔ backend (WebSocket) and setup-window ↔ config-view
(`postMessage`) — need a request that waits for its matching reply. A small
promise-based helper that tags each outbound request and resolves when the tagged
response returns covers both transports. Give it per-call timeouts: a few seconds for
normal reads, ~30 seconds for bridge pairing (which blocks on a physical button
press). This is an ordinary async request/response pattern; nothing here is specific
to Hue or to any original implementation.

---

## Settings Persistence

### Instance Settings (per-action)

Gatecaster persists these per tile. Structure:

```json
{
    "bridge": "<bridge-ip>",
    "id": "<light-or-group-id>",
  "name": "Living Room Ceiling",
  "type": "light",
  "brightness": 75,
  "color": "#FF6600",
  "colors": ["#FF0000", "#00FF00", "#0000FF"],
  "scene": "<scene-id>",
  "steps": 10,
  "lights": ["<id1>", "<id2>"],
  "unit": "celsius"
}
```

### Global Settings (widget-wide)

Stored once for the whole widget (not per tile). Structure:

```json
{
  "bridges": {
    "<bridge-ip>": {
      "ip": "192.168.1.100",
      "id": "001788fffe123456",
      "username": "aabbccddee0011223344"
    }
  },
  "recentSelection": {
    "bridge": "<bridge-ip>",
    "id": "<light-id>",
    "name": "Kitchen"
  },
  "debug": {
    "installDebugExtensions": false
  }
}
```

---

## Tile Image Generation

The Node.js backend generates tile images as SVG, rasterized and sent to Gatecaster. Components:

- **Archetype mini-icons** — SVG path data for 70+ bulb types (A19, BR30, GU10, Hue Go, etc.) stored in `assets/bulb-icons.js`
- **Color overlays** — the light's current color applied as a fill/stroke on the icon
- **Brightness mini-slider** — a bar in the corner showing 0–100% level
- **Color tags** — small colored squares for multi-color configurations
- **Text overlays** — light name, brightness percentage, temperature value
- **State indicators** — on/off visual state, connected/disconnected badge

---

## Declarative (Shell-Based) Alternative

While the Node.js widget provides the richest experience, many operations can be expressed as `curl` commands for use in Gatecaster's declarative tile model. This is useful for quick setup or for users who prefer not to run a Node.js backend.

### Data Flow

```
[Tile Press] → [Widget Action] → [curl to Hue Bridge] → [JSON Response]
                                                               ↓
[Tile Display] ← [Periodic Refresh] ← [curl to Hue Bridge] ← [JSON Parsed]
```

### Hue Helper Script

A single `hue-helper.sh` wraps `curl` for all Hue API v1 operations:

```bash
#!/bin/bash
# hue-helper.sh — macOS Hue API wrapper (bash/zsh + curl + jq + python3)

BRIDGE="$1"; USERNAME="$2"; shift 2
COMMAND="$1"; shift

case "$COMMAND" in
  discover-bridges)
    curl -sf "https://discovery.meethue.com" | \
      jq -c '.[] | {ip: .internalipaddress, id: .id}'
    ;;

  pair-bridge)
    curl -sfk -X POST -H "Content-Type: application/json" \
      -d '{"devicetype": "gatecaster"}' \
      "https://$BRIDGE/api"
    ;;

  get-lights)
    curl -sfk "https://$BRIDGE/api/$USERNAME/lights" | \
      jq -c 'to_entries[] | {id: .key, name: .value.name, type: .value.type, on: .value.state.on, bri: .value.state.bri}'
    ;;

  get-groups)
    curl -sfk "https://$BRIDGE/api/$USERNAME/groups" | \
      jq -c 'to_entries[] | {id: .key, name: .value.name, type: .value.type}'
    ;;

  get-scenes)
    curl -sfk "https://$BRIDGE/api/$USERNAME/scenes" | \
      jq -c 'to_entries[] | select(.value.type == "GroupScene") | {id: .key, name: .value.name, group: .value.group}'
    ;;

  get-light-state)
    LIGHT_ID="$1"
    curl -sfk "https://$BRIDGE/api/$USERNAME/lights/$LIGHT_ID" | \
      jq -c '{on: .state.on, bri: .state.bri, xy: .state.xy, ct: .state.ct, name: .name}'
    ;;

  toggle-light)
    LIGHT_ID="$1"
    STATE=$(curl -sfk "https://$BRIDGE/api/$USERNAME/lights/$LIGHT_ID" | jq '.state.on')
    if [ "$STATE" = "true" ]; then
      curl -sfk -X PUT -H "Content-Type: application/json" \
        -d '{"on":false}' \
        "https://$BRIDGE/api/$USERNAME/lights/$LIGHT_ID/state"
    else
      curl -sfk -X PUT -H "Content-Type: application/json" \
        -d '{"on":true}' \
        "https://$BRIDGE/api/$USERNAME/lights/$LIGHT_ID/state"
    fi
    ;;

  set-brightness)
    LIGHT_ID="$1"; VALUE="$2"
    # Convert percentage (0-100) to Hue bri range (0-254)
    BRI=$(( (VALUE * 254 + 50) / 100 ))
    curl -sfk -X PUT -H "Content-Type: application/json" \
      -d "{\"on\":true, \"bri\":$BRI}" \
      "https://$BRIDGE/api/$USERNAME/lights/$LIGHT_ID/state"
    ;;

  set-color)
    LIGHT_ID="$1"; HEX="$2"
    # Convert hex → CIE xy using Python
    XY=$(python3 -c "
h = '$HEX'.lstrip('#')
r,g,b = [int(h[i:i+2],16)/255 for i in (0,2,4)]
r = pow((r+0.055)/1.055,2.4) if r>0.04045 else r/12.92
g = pow((g+0.055)/1.055,2.4) if g>0.04045 else g/12.92
b = pow((b+0.055)/1.055,2.4) if b>0.04045 else b/12.92
x = r*0.4124564 + g*0.3575761 + b*0.1804375
y = r*0.2126729 + g*0.7151522 + b*0.0721750
z = r*0.0193339 + g*0.1191920 + b*0.9503041
print(f'{x/(x+y+z)},{y/(x+y+z)}')
")
    curl -sfk -X PUT -H "Content-Type: application/json" \
      -d "{\"on\":true, \"xy\":[$XY]}" \
      "https://$BRIDGE/api/$USERNAME/lights/$LIGHT_ID/state"
    ;;

  set-temperature)
    LIGHT_ID="$1"; MIRED="$2"
    curl -sfk -X PUT -H "Content-Type: application/json" \
      -d "{\"on\":true, \"ct\":$MIRED}" \
      "https://$BRIDGE/api/$USERNAME/lights/$LIGHT_ID/state"
    ;;

  activate-scene)
    GROUP_ID="$1"; SCENE_ID="$2"
    curl -sfk -X PUT -H "Content-Type: application/json" \
      -d "{\"scene\":\"$SCENE_ID\"}" \
      "https://$BRIDGE/api/$USERNAME/groups/$GROUP_ID/action"
    ;;

  check-bridge)
    curl -sfk "https://$BRIDGE/api/$USERNAME/config" | \
      jq -c '{name: .name, bridgeid: .bridgeid, ip: .ipaddress}'
    ;;
esac
```

### Setup & Pairing Script (macOS)

For the declarative path, pairing is done via a one-time terminal script:

```bash
#!/bin/bash
# setup-hue.sh — macOS Hue Bridge pairing script

echo "=== Hue Bridge Setup for Gatecaster ==="

# Discover bridges
echo "Discovering bridges..."
curl -sf "https://discovery.meethue.com" | jq '.'
read -p "Enter bridge IP: " BRIDGE_IP

# Pair
echo "Press the link button on your Hue Bridge, then press Enter"
read -r

RESULT=$(curl -sfk -X POST -H "Content-Type: application/json" \
  -d '{"devicetype": "gatecaster"}' \
  "https://$BRIDGE_IP/api")

USERNAME=$(echo "$RESULT" | jq -r '.[0].success.username // empty')

if [ -z "$USERNAME" ]; then
  echo "Pairing failed: $RESULT"
  exit 1
fi

echo "Bridge paired successfully!"
echo "IP: $BRIDGE_IP"
echo "Username: $USERNAME"

# Save to config
mkdir -p ~/.config/gatecaster-hue
cat > ~/.config/gatecaster-hue/config.json << EOF
{
  "bridges": {
    "$BRIDGE_IP": {
      "ip": "$BRIDGE_IP",
      "username": "$USERNAME"
    }
  }
}
EOF

echo "Saved to ~/.config/gatecaster-hue/config.json"
```

### Config File Path (macOS)

Bridge credentials are stored at `~/.config/gatecaster-hue/config.json`:

```json
{
  "bridges": {
    "192.168.1.100": {
      "ip": "192.168.1.100",
      "username": "aabbccddee0011223344",
      "name": "Living Room Bridge"
    }
  }
}
```

---

## manifest.json Widget Definitions

The following declarative widget definitions use the helper script above. Each assumes a bridge config file or inline settings.

### On/Off Toggle

```json
{
  "id": "com.gatecaster.hue.onoff",
  "label": "Hue On/Off",
  "tile": {
    "refresh": {
      "period": 5,
      "command": "~/hue-helper.sh 192.168.1.100 aabbccddee0011223344 get-light-state 3"
    },
    "actions": {
      "press": {
        "command": "~/hue-helper.sh 192.168.1.100 aabbccddee0011223344 toggle-light 3",
        "feedback": "refresh"
      }
    }
  }
}
```

### Brightness (Encoder)

```json
{
  "id": "com.gatecaster.hue.brightness",
  "label": "Hue Brightness",
  "tile": {
    "refresh": {
      "period": 5,
      "command": "~/hue-helper.sh 192.168.1.100 aabbccddee0011223344 get-light-state 3"
    },
    "actions": {
      "rotate": {
        "command": "~/hue-helper.sh 192.168.1.100 aabbccddee0011223344 set-brightness 3 {value}",
        "feedback": "refresh"
      },
      "press": {
        "command": "~/hue-helper.sh 192.168.1.100 aabbccddee0011223344 toggle-light 3",
        "feedback": "refresh"
      }
    }
  }
}
```

### Scene Activation

```json
{
  "id": "com.gatecaster.hue.scene",
  "label": "Hue Scene",
  "tile": {
    "refresh": {
      "period": 10,
      "command": "~/hue-helper.sh 192.168.1.100 aabbccddee0011223344 get-scenes"
    },
    "actions": {
      "press": {
        "command": "~/hue-helper.sh 192.168.1.100 aabbccddee0011223344 activate-scene 1 H2plACE1abcde",
        "feedback": "refresh"
      }
    }
  }
}
```

### Set Color

```json
{
  "id": "com.gatecaster.hue.color",
  "label": "Hue Color",
  "tile": {
    "actions": {
      "press": {
        "command": "~/hue-helper.sh 192.168.1.100 aabbccddee0011223344 set-color 3 {color}",
        "feedback": "refresh"
      }
    }
  }
}
```

---

## Declarative vs. Node.js Comparison

| Feature | Node.js Widget (recommended) | Declarative Widget |
|---|---|---|
| Runtime | Node.js (persistent process) | Shell commands (ephemeral) |
| State | In-memory cache + polling | Refresh commands only |
| Real-time updates | Hue v2 EventStream (SSE) | Polling via periodic refresh |
| Configuration UI | Custom HTML panel | Tile field inputs |
| Color conversion | CIE xy conversion library | Inline `python3` script |
| Bridge discovery | mDNS (Bonjour) + cloud API | Cloud API + manual IP entry |
| Image generation | Dynamic SVG rendering | Static SVG + CSS |
| Pairing | Full multi-step wizard | Terminal script + manual setup |
| Multi-device | Full (lights/rooms/zones) | Per-tile hardcoded IDs |
| Error feedback | Tile icons + toast alerts | Refresh-state based |

---

## Config Tunables

The backend's `config.json` exposes tunable parameters:

| Key | Purpose | Default |
|---|---|---|
| `hue.autoOn` | Auto-turn device on when changing brightness/color while off | `true` |
| `discovery.timeoutMs` | Bridge discovery timeout (ms) | `5000` |
| `network.allowExternal` | Allow non-LAN bridge IPs | `false` |
| `keepalive.pingInterval` | WebSocket ping interval (s) | `60` |
| `keepalive.connectionTimeout` | WebSocket idle timeout (s) | `300` |
| `reconnect.retryLimit` | Max exponential backoff retries | `10` |
| `log.level` | Log verbosity (`debug`, `info`, `warn`) | `'info'` |

---

## Phased Implementation Plan

### Phase 1 — Core (Node.js backend + basic tiles)
- On/Off tile for single light
- Scene activation tile
- Brightness set tile (encoder)
- Bridge pairing wizard
- Helper script with curl wrappers
- Bridge config file management

### Phase 2 — Enhanced Controls
- Color picker tile (hex input + temperature slider)
- Temperature tile
- Relative brightness/temperature adjustment
- Refresh polling for state display
- Bridge discovery (cloud + mDNS)

### Phase 3 — Rich Experience
- Multiple bridge support
- Color cycle tile
- Dynamic light list via cache enumeration
- Motion sensor temperature display
- Tile image generation with live state (color swatch, brightness bar)
- Error handling, reconnection, and toast feedback
