# Manifest schema v2 — full key reference

The exact mirror of the Swift host model (`WidgetManifest`) and the `gatecaster`
validator. The host **tolerant-decodes**: unknown keys are ignored, missing
optionals take defaults, and a malformed manifest is dropped silently on reload —
so treat "required" as "the host needs this or your tile misbehaves," and run
`gatecaster validate` to surface anything you got wrong.

Legend: **req** = required · *opt* = optional · default in `()`.

## Top level

| Key | Type | Notes |
|---|---|---|
| `v` | number *opt* (→1) | Schema version. `2` for v2. Absent/`1` ⇒ migrated to v2 declarative on load. Adding optional fields never bumps `v`. |
| `id` | string **req** | Reverse-DNS, e.g. `com.you.thing`. Also the install folder name. Letters/digits/dot/hyphen only. |
| `name` | string **req** | Tile title. |
| `symbol` | string *opt* | SF Symbol name, e.g. `music.note`. |
| `colorHex` | string *opt* | 6-digit hex, e.g. `#1DB954` (with or without `#`). |
| `minW`,`minH`,`defaultW`,`defaultH` | number *opt* | Tile grid sizing. |
| `view` | object *opt* | Presentation axis — see below. |
| `fields` | array *opt* | Declarative data rows — see below. |
| `buttons` | array *opt* | Tappable actions — see below. |
| `actions` | object *opt* | Named, reusable actions keyed by id — see below. |
| `refresh` | object *opt* | Poll data source. **Mutually exclusive with `provider`.** |
| `provider` | object *opt* | Push data source. **Mutually exclusive with `refresh`.** |
| `capabilities` | string[] *opt* | Runtime ceiling — see below. |
| `secrets` | array *opt* | Declared secret keys (keychain) — see below. |
| `oauth` | object *opt* | OAuth capture config — see below. |
| `configSchema` | array *opt* | User-facing settings — see below. |

A declarative tile must have at least one of `fields` / `buttons` (or be a webview).

## `view`

| Key | Type | Notes |
|---|---|---|
| `kind` | `"declarative"` (default) \| `"webview"` | |
| `entry` | string | **req if** `kind:"webview"` — HTML path relative to the pack, e.g. `ui/player.html`. |

## `fields[]`

| Key | Type | Notes |
|---|---|---|
| `label` | string **req** | A label-less field is dropped by the host. |
| `type` | `text`(default)\|`image`\|`range`\|`slider`\|`dial` | `range` = read-only bar; `slider`/`dial` = interactive drag-to-set (see below). |
| `size` | `small`\|`regular`\|`large` | |
| `refreshKey` | string | Key into the refresh/provider state dict that fills this field (seeds a slider/dial's start position). |
| `value` | string | Static value / fallback before first data. |
| `min`,`max` | number | For `range`/`slider`/`dial`. `range` with no `max` ⇒ 0..1 bar; `slider`/`dial` default to 0..100. |
| `orientation` | `vertical`(default)\|`horizontal` | `slider` axis only (`dial` is always a rotary gauge). |
| `action` | object | **slider/dial** — inline set-value action (see action shape). |
| `run` | string | **slider/dial** — id of an entry in `actions{}`; wins over inline `action`. |

A non-interactive field with neither `refreshKey` nor `value` is always blank.

### Interactive `slider` / `dial` (drag-to-set, §5.9)

A `slider` (a bar) or `dial` (a 270° rotary gauge) lets the user **drag to set a
value** in `[min,max]` (default `0..100`). The dragged integer is substituted as
the token **`$value`** into the field's `action`/`run` value (then `$config.*`),
which fires **throttled to ~10 Hz** while dragging and once more on release.

```json
{ "label": "Output", "type": "slider", "orientation": "vertical",
  "refreshKey": "out", "min": 0, "max": 100,
  "action": { "kind": "volume", "value": "$value" } }
```

Notes & gotchas:
- The control **opts out of deck scroll routing** automatically (it publishes its
  on-screen frame to the host's drag-region table so a touch becomes a real mouse
  drag, not a scroll). You don't configure this.
- Once touched it **owns its value locally** — live `refresh` data only seeds the
  initial position (same model as the built-in volume widget), so a poll can't
  fight the handle mid-drag.
- A slider/dial with **no `action`/`run` just displays** (the validator warns).
- The action obeys the normal **capability gate**: `kind:"volume"` is ungated;
  `kind:"shell"` / an `interpreter` needs `capabilities:["shell"]`.
- `$value` is substituted **before** `$config.*`, so a config key can't shadow it.

## `buttons[]`

A button is **inline** (`action`) **or** **named** (`run`), not both.

| Key | Type | Notes |
|---|---|---|
| `label` | string *opt* | |
| `symbol` | string *opt* | SF Symbol. A button with neither label nor symbol is blank. |
| `action` | object *opt* | Inline action (see action shape). |
| `run` | string *opt* | Id of an entry in `actions{}`. Must exist. |
| `states` | array *opt* | Multi-state (toggle) button; each state is `{label?,symbol?,action}` — **inline `action` ONLY**. A state has no `run` (unlike a top-level button); the host ignores `run` on a state, leaving it dead. |

## Action shape (inline `action`, or a value in `actions{}`)

Two forms; pick one:

**A. kind/value** (the safe vocabulary):

| Key | Type | Notes |
|---|---|---|
| `kind` | enum **req** | One of: `app url keystroke shortcut shell volume media page activate provider`. |
| `value` | string | Argument: app name, URL, keystroke spec, Shortcut name, shell line, `playpause`/`next`/…, provider command, etc. `$config.<key>` is substituted. |
| `then` | `none`(default)\|`refresh` | Re-pull data after running. |
| `params` | string[] | Parameter names (for parameterized named actions). |

**B. interpreter/script** (requires `capabilities:["shell"]`):

| Key | Type | Notes |
|---|---|---|
| `interpreter` | `osascript`\|`zsh` | |
| `script` | string **req with interpreter** | The script body. `$config.<key>` substituted. |
| `then` | `none`\|`refresh` | |

Capability gates: `kind:"shell"` and any interpreter/script action need **`shell`**;
`kind:"provider"` needs a declared `provider` to forward to.

## `refresh` (poll)

| Key | Type | Notes |
|---|---|---|
| `command` | string **req** | Shell command; stdout is parsed into the state dict. Runs via `/bin/zsh -lc` in the pack dir. **Ungated** (no `shell` cap needed). |
| `everySeconds` | number **req** | Poll interval. Floor is 2s (clamped up). |
| `parse` | object *opt* (→`{kind:"json"}`) | See below. |
| `transform` | object *opt* | Per-key `$value` / value-map remap after parse. |

### `refresh.parse`

| Key | Type | Notes |
|---|---|---|
| `kind` | `json`(default)\|`delimited` | |
| `delimiter` | string | **req if** delimited. |
| `fields` | string[] | **req if** delimited — positional key names for split columns. |

`json`: command prints one JSON object whose keys match field `refreshKey`s.

## `provider` (push)

| Key | Type | Notes |
|---|---|---|
| `command` | string **req** | Long-lived process to spawn, e.g. `node provider.js`. Run via `/bin/zsh -lc` in the pack dir. |
| `args` | string[] *opt* | Extra args appended to the command. |
| `caps` | string[] *opt* | Provider's own advertised caps (`state`/`image`/`options`) — informational; the real gate is the manifest `capabilities`. |

**Requires `capabilities:["process"]`.** See `provider-protocol.md` for the NDJSON wire format.

## `capabilities[]`

Declared runtime ceiling (§8). Known values: `shell network process secrets
native-binary`. Real gates today: `process` (spawn provider), `shell` (shell/
interpreter actions). `network` is *disclosed, not contained* until the P2 sandbox.

## `secrets[]`

| Key | Type | Notes |
|---|---|---|
| `key` | string **req** | Stored in keychain, namespaced per (ext,key). Injected to the child as `GATECASTER_SECRET_<KEY>` (uppercased). Never on disk, never in the manifest. |
| `label` | string *opt* | Shown in the config panel. |

## `oauth`

| Key | Type | Notes |
|---|---|---|
| `authUrl` | string **req** | Provider authorize URL. |
| `redirect` | `loopback`\|`scheme` | |
| `scheme` | string | **req if** `redirect:"scheme"`, e.g. `x-gatecaster`. |
| `store` | string | Secret key (from `secrets[]`) the captured token lands in. |

## `configSchema[]`

| Key | Type | Notes |
|---|---|---|
| `key` | string **req** | Surfaces to commands/provider as `$config.<key>` / `GATECASTER_CONFIG_<KEY>`. |
| `label` | string *opt* | |
| `type` | enum | `text toggle slider select device-picker connect-button secret`. |
| `options` | string[] | For `select` — an array of **plain strings**, e.g. `["local","cloud"]` (or use `source:"provider:<key>"`). An array of `{value,label}` objects throws on host decode and **silently drops the whole manifest** (the tile never appears). |
| `action` | string | **req for** `connect-button` — the named action it fires (e.g. pairing/oauth). |

Any `$config.<key>` you reference in a command/script/value should have a matching
`configSchema` entry or `secrets` key, or it expands to empty (the validator warns).
