# Slack Integration Reference

## Architecture Overview

Gatecaster's Slack integration uses two independent paths:

1. **`slack://` URL scheme** — platform-native on macOS. Opens channels via `slack://channel`, DMs via `slack://user`, group messages via `slack://channel`, and canvases via HTTPS URL — all directly in the Slack desktop app. No credentials required. Executed via the `open` command from a shell script or widget action.

2. **Slack Web API** — for actions that modify state: setting a status emoji/text, pausing notifications (DND/snooze), and posting messages. Requires an OAuth token scoped to the relevant endpoints.

The URL-scheme path is zero-config. The Web API path requires registering a Slack App at `https://api.slack.com/apps` and configuring OAuth in Gatecaster's authentication system.

## Widget Inventory

| ID | Name | Auth Required | Mechanism |
|----|------|:---:|----------|
| `open-channel` | Open Channel | No | `slack://` URL scheme |
| `open-direct-message` | Open Direct Message | No | `slack://` URL scheme |
| `open-group-message` | Open Group Message | No | `slack://` URL scheme |
| `open-canvas` | Open Canvas | No | HTTPS URL (open in browser) |
| `set-status` | Set Status | Yes | Slack Web API `users.profile.set` |
| `pause-notifications` | Pause Notifications | Yes | Slack Web API `dnd.setSnooze` |
| `send-message` | Send Message | Yes | Slack Web API `chat.postMessage` |

### Widget Lifecycle

Each widget follows a standard lifecycle:
- **onActivate**: Fires when the user presses the key. Executes the shell command or HTTP request defined in the manifest.
- **onSettingsUpdate**: Refreshes internal state when configuration changes.
- **onTick** (optional): For polling — used in Phase 3 for presence indicators.

All shell-based widgets use `open(1)` on macOS. Gatecaster's runtime resolves `${variable}` placeholders from the widget's settings dictionary before executing.

## Authentication (Slack Web API)

### OAuth 2.0 Flow

Widgets that modify Slack state (status, DND, messages) require an OAuth 2.0 access token with the following scopes:

- `channels:read`, `channels:manage`, `channels:history`
- `users:read`, `users:read.email`
- `users.profile:write`
- `emoji:read`
- `dnd:read`, `dnd:write`
- `team:read`
- `mpim:read`, `mpim:history`
- `chat:write`
- `usergroups:read`

**OAuth Flow:**

1. User initiates "Connect Slack" from Gatecaster's settings.
2. Gatecaster opens `https://slack.com/oauth/v2/authorize?client_id={CLIENT_ID}&scope={SCOPES}&redirect_uri={GATECASTER_REDIRECT}&state={STATE}`.
3. User authorizes in the browser.
4. Slack redirects to Gatecaster's configured redirect URI with an authorization code.
5. Gatecaster exchanges the code for a token via `POST https://slack.com/api/oauth.v2.access`.
6. The access token is stored securely in Gatecaster's keychain (macOS Keychain or encrypted settings store).
7. Subsequent API calls include `Authorization: Bearer {token}`.

**Desktop app note:** Since Gatecaster is a desktop application, the OAuth redirect URI cannot be a typical web server URL. Use one of these strategies:
- **Custom URL scheme** (recommended): Register a protocol handler (e.g., `slack-gatecaster://`) with the OS. Slack redirects to `slack-gatecaster://callback?code=...&state=...` which Gatecaster handles.
- **Loopback HTTP server**: Start a temporary HTTP server on `http://127.0.0.1:{PORT}` and have Slack redirect there. The local server captures the authorization code and shuts down.

Each workspace is stored as a record containing:
- `teamId`, `teamName`, `domain`
- `accessToken`
- `userId`, `scopes`

### Alternative: User Token (Simpler Setup)

The workspace owner creates a Slack App, generates a token at `api.slack.com/apps`, and pastes it into a settings field. Less automated but faster to prototype.

**Warning:** This token is tied to the Slack account of the person who installed the app. If that user leaves the workspace or their token is revoked, all widgets relying on this token will break. For production deployments, prefer the full OAuth flow.

## `slack://` URL Scheme (Zero-Config Path)

The `slack://` URL scheme is registered by the Slack desktop app on macOS. These URLs require no authentication and open directly in the app.

```
slack://channel?team={TEAM_ID}&id={CHANNEL_ID}
slack://user?team={TEAM_ID}&id={USER_ID}
```

Key facts:
- Uses raw Slack IDs (not names). Team/Channel/User IDs are strings like `T01234567`, `C0123456789`, `U0123456789`.
- The `channel` scheme's `id` parameter accepts channel IDs (`C...`) and group DM IDs (`G...`).
- The `user` scheme's `id` parameter accepts user IDs (`U...`) for 1:1 DMs.
- For group DMs, use `slack://channel?team=T1&id=G1` — no official scheme exists for group DMs; using `slack://channel` with the group ID is the best-effort approach but is undocumented.
- Optional `message` parameter for deep-linking: `slack://channel?team=T1&id=C1&message=1234567890.123456` — **Note:** This parameter is undocumented by Slack and is experimental.

### Capability Matrix

| Action | `slack://` URL | Slack Web API |
|--------|:-------------:|:-------------:|
| Open channel | `slack://channel` | `conversations.open` |
| Open DM | `slack://user` | `conversations.open` |
| Open group DM | `slack://channel` (best-effort, undocumented) | `conversations.open` |
| Open canvas | (HTTPS URL) | — |
| Set status | ✗ | `users.profile.set` |
| Pause notifications | ✗ | `dnd.setSnooze` |
| Send message | ✗ | `chat.postMessage` |
| Mute channel | ✗ | `conversations.mute` |
| Set presence | ✗ | `users.setPresence` |

**Note:** `conversations.open` opens or creates a conversation for API access — it does **not** navigate the Slack client UI to a channel. Navigating to a channel in the desktop app can only be done via `slack://channel?team=...&id=...` (or `slack://user?team=...&id=...` for DMs).

## Widget Manifest

```json
{
  "id": "com.gatecaster.slack",
  "name": "Slack",
  "version": "1.0.0",
  "icon": "icons/slack.png",
  "widgets": [
    {
      "id": "open-channel",
      "name": "Open Channel",
      "description": "Open a Slack channel via slack:// URL scheme",
      "settings": [
        { "key": "teamId", "label": "Workspace ID", "type": "text" },
        { "key": "channelId", "label": "Channel ID", "type": "text", "required": true },
        { "key": "channelName", "label": "Display Name", "type": "text" }
      ],
      "onActivate": "open 'slack://channel?team=${teamId}&id=${channelId}'"
    },
    {
      "id": "open-direct-message",
      "name": "Open Direct Message",
      "description": "Open a DM with a user",
      "settings": [
        { "key": "teamId", "label": "Workspace ID", "type": "text" },
        { "key": "userId", "label": "User ID", "type": "text", "required": true }
      ],
      "onActivate": "open 'slack://user?team=${teamId}&id=${userId}'"
    },
    {
      "id": "open-group-message",
      "name": "Open Group Message",
      "description": "Open a group DM",
      "settings": [
        { "key": "teamId", "label": "Workspace ID", "type": "text" },
        { "key": "groupId", "label": "Group ID", "type": "text", "required": true }
      ],
      "onActivate": "open 'slack://channel?team=${teamId}&id=${groupId}'"
    },
    {
      "id": "open-canvas",
      "name": "Open Canvas",
      "description": "Open a Slack Canvas in the browser",
      "settings": [
        { "key": "canvasUrl", "label": "Canvas URL", "type": "text", "placeholder": "https://app.slack.com/docs/T1/C1", "required": true }
      ],
      "onActivate": "open '${canvasUrl}'"
    },
    {
      "id": "set-status",
      "name": "Set Status",
      "description": "Set Slack status emoji and text",
      "needsAuth": true,
      "settings": [
        { "key": "statusEmoji", "label": "Emoji", "type": "text", "placeholder": ":wave:" },
        { "key": "statusText", "label": "Status Text", "type": "text", "placeholder": "In a meeting" },
        { "key": "statusExpiration", "label": "Clear after (epoch seconds)", "type": "number", "placeholder": "1712345678" }
      ],
      "onActivate": {
        "method": "POST",
        "url": "https://slack.com/api/users.profile.set",
        "headers": { "Authorization": "Bearer ${authToken}" },
        "body": {
          "profile": {
            "status_emoji": "${statusEmoji}",
            "status_text": "${statusText}",
            "status_expiration": "${statusExpiration}"
          }
        }
      }
    },
    {
      "id": "pause-notifications",
      "name": "Pause Notifications",
      "description": "Snooze Slack notifications for a set duration",
      "needsAuth": true,
      "settings": [
        {
          "key": "duration",
          "label": "Duration",
          "type": "select",
          "options": [
            { "label": "15 minutes", "value": "15" },
            { "label": "30 minutes", "value": "30" },
            { "label": "1 hour", "value": "60" },
            { "label": "2 hours", "value": "120" },
            { "label": "Until tomorrow (9 AM)", "value": "960" } <!-- 960 = 16 hrs × 60 min; backend adds Date.now()/1000 to this -->
          ],
          "required": true
        }
      ],
      "onActivate": {
        "method": "POST",
        "url": "https://slack.com/api/dnd.setSnooze",
        "headers": { "Authorization": "Bearer ${authToken}" },
        "body": { "num_minutes": "${duration}" }
      }
    },
    {
      "id": "send-message",
      "name": "Send Message",
      "description": "Post a message to a Slack channel",
      "needsAuth": true,
      "settings": [
        { "key": "channelId", "label": "Channel ID", "type": "text", "required": true },
        { "key": "message", "label": "Message", "type": "text", "multiline": true, "required": true }
      ],
      "onActivate": {
        "method": "POST",
        "url": "https://slack.com/api/chat.postMessage",
        "headers": { "Authorization": "Bearer ${authToken}" },
        "body": { "channel": "${channelId}", "text": "${message}" }
      }
    }
  ]
}
```

**Note (status_expiration):** The `status_expiration` field requires a Unix epoch timestamp in seconds, not a duration in minutes. If your widget provides minutes, compute the value at runtime:
```
status_expiration = Math.floor(Date.now() / 1000) + (minutes * 60)
```
To disable expiration, send `"status_expiration": 0`.

**Note (dnd.setSnooze):** The "Until tomorrow (9 AM)" option above is a placeholder label. `dnd.setSnooze` only accepts a numeric `num_minutes` parameter. The script must compute the minutes until 9 AM the next day at runtime (e.g., `Math.floor((next9am - Date.now()) / 60000)`).

## Shell Commands (macOS)

All `slack://` URL scheme invocations use the `open` command:

```bash
# Open a channel
open "slack://channel?team=T01234567&id=C0123456789"

# Open a DM
open "slack://user?team=T01234567&id=U0123456789"

# Open a group DM
open "slack://channel?team=T01234567&id=G0123456789"

# Open Slack app to a specific message (message parameter is undocumented — experimental)
open "slack://channel?team=T01234567&id=C0123456789&message=1234567890.123456"

# Open Slack workspace switcher
open "slack://workspace"

# Open Slack preferences
open "slack://preferences"

# Open canvas as HTTPS URL (launches default browser)
open "https://app.slack.com/docs/T01234567/C0123456789"
```

Web API calls use `curl`:

```bash
# Set status
curl -s -X POST https://slack.com/api/users.profile.set \
  -H "Authorization: Bearer ${SLACK_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"profile":{"status_emoji":":wave:","status_text":"Be right back","status_expiration":1712345678}}'

# Pause notifications for 60 minutes
curl -s -X POST https://slack.com/api/dnd.setSnooze \
  -H "Authorization: Bearer ${SLACK_TOKEN}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "num_minutes=60"

# Send a message
curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer ${SLACK_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"channel":"C0123456789","text":"Hello from Gatecaster!"}'
```

## Configuration Panel

Each widget exposes a settings panel in Gatecaster where the user configures IDs, tokens, and options.

**URL-scheme widgets** (Open Channel, Open DM, Open Group Message, Open Canvas):
- Text fields for workspace/channel/user/group IDs
- Optional display-name field for labelling the key
- No auth required

**API widgets** (Set Status, Pause Notifications, Send Message):
- Same ID fields plus action-specific parameters
- `needsAuth: true` — Gatecaster shows the auth status and OAuth connect button

### Resolving IDs to Names

Since `slack://` URLs require raw IDs, the user must obtain them. Two approaches:

1. **Manual entry** — User copies IDs from Slack's "About" dialog or API response. Simplest path.
2. **OAuth-backed lookup** — Once authenticated, Gatecaster can call `conversations.list`, `users.list`, and `team.info` to populate selection dropdowns in the settings panel.

## Phased Implementation

### Phase 1 — URL Scheme Only (Zero Config, 4 Widgets)

Widgets: Open Channel, Open DM, Open Group Message, Open Canvas.

- No authentication required
- User provides Slack IDs manually in settings
- Executes as `open "slack://..."` via shell
- Fully functional on macOS with Slack desktop app installed

### Phase 2 — OAuth + Web API (5 Additional Capabilities)

- Register Gatecaster Slack App at `api.slack.com/apps`
- Implement OAuth 2.0 callback in Gatecaster's settings UI
- Add widgets: Set Status, Pause Notifications, Send Message
- Auto-populate channel/user dropdowns in settings via API

### Phase 3 — Rich Presence (Optional)

- Poll `users.getPresence` every 30 seconds
- Display online / away / DnD indicators on widget keys
- React to presence changes with visual feedback on the Gatecaster deck

## Localization (Future)

When Gatecaster gains a localization system, translation JSON files would be placed alongside the widget manifest following the pattern `en.json`, `de.json`, `ja.json`, etc., with the English strings as the fallback defaults.
