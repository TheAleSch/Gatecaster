# Gatecaster Extension Platform — Specification (Approach C)

> **Status:** spec / not yet built. Supersedes the linear ladder sketched in
> `EXTENSIONS.md` ("declarative → data-provider → WebView → registry").
> Scope: **Deck widgets/plugins only.** The Touch API (`DEVELOPER_API.md` §3,
> `TOUCH_API.md`) is shipped and out of scope here — but its transport and
> versioning discipline are deliberately reused below.
>
> Source-of-truth inputs: `PLATFORM_BRIEF.md` (the decision), `EXTENSIONS.md`
> (shipped declarative tier), the six clean-room plugin specs
> (`docs/plugins/01–06`), `DECK_PLAN.md`, `WIDGET_IDEAS.md`, `DEVELOPER_API.md`.

---

## 1. Problem Statement

The shipped extension tier (`EXTENSIONS.md`) is a flat declarative manifest:
`fields[]` + `buttons[]` + an optional polled `refresh` command. It is enough for
a static button board (Figma shortcuts) and simple live read-outs (now-playing
text), but **five of the six clean-room plugin specs cannot be expressed in it.**
Volume, Hue, Spotify, Zoom, and Meetings each independently invented a richer
manifest (typed fields, parsed/transformed refresh, parameterized actions, a
long-lived push provider, OAuth, a config panel) — and those invented schemas do
not interoperate with the shipped one or with each other. Today a plugin author
hand-edits `manifest.json` with no per-instance settings UI, no way to hold a
token, and no way to push live state; half the real plugins are unusable. The
cost of not solving it: the registry/marketplace has nothing coherent to
distribute, and every new plugin re-invents a private protocol.

## 2. The Decision (Approach C)

Build the platform on **two orthogonal axes**, four **first-class cross-cutting
subsystems**, and a **registry** on top. The two axes are independent — that
separation is the whole point of C.

```
                    PRESENTATION axis  (how the tile looks)
                    ─────────────────────────────────────────
                    declarative fields/buttons   │   WebView
                                                  │   (custom canvas)
   DATA / CAPABILITY axis     ┌──────────────────┼──────────────────┐
   (where state comes from)   │                  │                  │
   ─────────────────────────  │   declarative    │   declarative    │
   none (static)              │   button board   │   web button UI  │
   poll  (refresh command)    │   live read-out  │   web read-out   │
   push  (monitor provider)   │   live tile      │   rich player /  │
                              │                   │   dial / chart   │
                              └───────────────────┴──────────────────┘
        Both presentations consume the SAME provider/poll state dict.
        Presentation is a render choice, NOT a privilege tier.

   Four first-class subsystems span both axes:
     ① Secret store + OAuth redirect catcher
     ② Config Panel (per-instance settings UI)
     ③ Capability manifest (shell/network/process/secrets/native-binary)
     ④ Registry / marketplace (discloses ③ at install)

   Two small host primitives the specs surfaced:
     • is-app-running / activate    • provider-pushed dynamic tile image
```

**Why C over the linear ladder:** the ladder conflated *where data comes from*
(capability/privilege) with *how the tile looks* (presentation). A WebView tile
that only reads `fields` is no more privileged than a declarative one; a
declarative tile backed by a token-holding provider is *more* privileged than a
WebView that holds nothing. C makes the registry disclose **one** capability
model (subsystem ③) regardless of render kind.

---

## 3. Goals

1. **One versioned manifest schema** that a v1 (`EXTENSIONS.md`) pack still loads
   under, and that expresses everything the six specs invented — measured by all
   six plugins authoring against it with **zero private protocol extensions**.
2. **Push state as a first-class primitive** (the `monitor` provider): a tile can
   show live state without polling, with tokens held out-of-process — the linchpin
   5 of 6 specs require.
3. **Per-instance configuration without hand-editing JSON**: every plugin that
   needs a device/light/account picker is installable and usable by a
   non-developer (Config Panel), measured by Hue + Volume + Meetings being
   set up end-to-end through UI only.
4. **Disclosed capabilities at install**: the registry shows every pack's
   `shell`/`network`/`process`/`secrets`/`native-binary` footprint before the user
   installs — no silent shell execution.
5. **Reuse, don't reinvent, the transport**: the provider protocol mirrors the
   Touch API's NDJSON + `v`-bump + self-healing-lease discipline, so there is one
   transport story in the codebase, not two.

## 4. Non-Goals

- **Touch API changes.** Done and shipped; this spec only borrows its patterns.
- **Cross-platform abstraction layers "just in case."** Manifest *data* stays
  OS-neutral (per the methodology doc), but execution is macOS-native. No Windows
  runtime is built now; the per-OS `command` map (`EXTENSIONS.md` "Cross-platform")
  remains a documented future field, not implemented.
- **A sandbox / reduced-privilege execution tier.** v1 extensions run with the
  user's privileges (as today). Disclosure (subsystem ③) is the v1 safety story;
  sandboxing is P2.
- **Accounts / cloud sync in the registry.** v0 is a curated, no-accounts,
  free-packs repo. Login + sync is later.
- **Replacing built-in widgets.** Built-ins stay built-in; see §11 boundary policy.
- **Plugin raw-touch access & `suppress`.** v1 widgets get **taps + tile state
  only** — they cannot read the touch/gesture stream and **can never `suppress`**
  system input (§10 isolation boundary). Suppress stays first-party-Touch-API-only.
  A brokered read-only touch tier is deferred until a concrete custom-interaction
  use case exists; building it now is speculative (the deck already self-scrolls).
- **DriverKit virtual-HID work** (animated 3-finger swipe, native `NSTouch`).
  Tracked in `INTERNALS.md` §8, unrelated to the widget platform.

---

## 5. Manifest Schema v2 (Job #1 — reconcile the two schemas)

This is the load-bearing deliverable. Two incompatible schemas exist today:

- **Shipped** (`EXTENSIONS.md`): `fields[]` + `buttons[]` with
  `action:{kind,value}` + `refresh:{command,everySeconds}`.
- **Invented** (specs 01–06): `kind:"widget"|"webview"`, `tile.template`,
  `tile.layout`, typed fields, `refresh.parse`/`transform`, `actions` as a keyed
  object with `params` + `then:"refresh"`, `configuration[]`, a `monitor` process.

v2 **merges them additively**, under the Touch API's `v` discipline: *additive
fields never bump `v`; clients/host ignore unknown fields; `v` bumps only on a
breaking change (field removal or changed semantics).* A v1 manifest (no `v`, or
`"v":1`) loads through a migrator (§5.6).

### 5.1 Top-level shape

```jsonc
{
  "v": 2,                               // schema version (required for v2)
  "id": "com.example.nowplaying",       // reverse-DNS, unique  (v1, unchanged)
  "name": "Now Playing",
  "symbol": "music.note",               // SF Symbol header icon
  "colorHex": "#1DB954",                // brand accent (header tint)
  "minW": 2, "minH": 1, "defaultW": 3, "defaultH": 2,

  // ── PRESENTATION axis ──────────────────────────────────────────────
  "view": { "kind": "declarative" },    // default; or { "kind":"webview", "entry":"ui/player.html" }

  // ── declarative presentation (used when view.kind == "declarative") ──
  "fields":  [ /* §5.2 */ ],
  "buttons": [ /* §5.3, shipped shape retained verbatim */ ],

  // ── DATA / CAPABILITY axis (at most one of poll | push per tile) ─────
  "refresh":  { /* §5.4 — poll, extended additively from v1 */ },
  "provider": { /* §5.5 — push monitor process */ },

  // ── named, parameterized actions (referenced by id) ─────────────────
  "actions": { /* §5.3 */ },

  // ── four first-class subsystems ─────────────────────────────────────
  "configSchema": [ /* §6 — per-instance settings form */ ],
  "capabilities": ["shell", "network"],        // §8 — declared & disclosed
  "secrets":     [ /* §7 */ ],
  "oauth":       { /* §7 */ }
}
```

**Reconciliation decisions (the rulings the brief asked for):**

| Concern | Shipped | Invented | v2 ruling |
|---|---|---|---|
| Render selector | implicit | `kind:"widget"\|"webview"` | `view.kind:"declarative"\|"webview"` (own namespace; "widget" was ambiguous with the deck's internal tile kinds) |
| Tile layout | flat list | `tile.template`/`tile.layout` | `fields[]` order + `size` hint is the layout; `tile.template` **rejected** (over-specified; declarative tiles auto-flow + scroll, per `EXTENSIONS.md` "Scrolling content") |
| Typed fields | string only | `type:"text"\|"image"\|"range"` | adopt `fields[].type` (additive; missing = `text`) |
| Refresh parsing | raw JSON stdout | `parse`/`transform` | adopt `refresh.parse` + `refresh.transform` (additive; missing = parse stdout as flat JSON, as v1) |
| Actions | `buttons[].action` array | `actions{}` keyed + `params` + `then` | **both** — inline `action` stays for simple taps; named `actions{}` map adds params/then; a button references one via `run:"<id>"` |
| Config | opaque `config` KV | `configuration[]` form | adopt as `configSchema[]` (§6); collected values surface as `$config.key` |
| Push data | — | `monitor` process | new `provider` (§5.5) |

### 5.2 Fields (extended)

```jsonc
"fields": [
  { "label": "Track",  "refreshKey": "title" },                 // v1, unchanged
  { "label": "Status", "value": "Paused" },                     // static, v1
  { "refreshKey": "art",  "type": "image",  "size": "large" },  // v2: dynamic image (§9)
  { "refreshKey": "vol",  "type": "range",  "min": 0, "max": 100 }
]
```

`type ∈ text | image | range` (default `text`). `image` renders the state value
as a tile image (data URI, file path, or a provider-pushed PNG — §9).
`size ∈ small | regular | large`. Unknown `type` ⇒ render as `text` (forward-compat).

### 5.3 Buttons & named actions (both forms coexist)

```jsonc
"buttons": [
  // shipped inline form — unchanged, still the common case:
  { "symbol": "playpause.fill", "action": { "kind": "media", "value": "playpause" } },
  { "label": "Open", "action": { "kind": "app", "value": "Spotify" } },

  // v2 — reference a named action by id (enables params + then):
  { "symbol": "speaker.slash", "run": "mute-toggle" }
],

"actions": {
  "mute-toggle": {
    "kind": "shell",                 // any safe kind (§5.7) OR "interpreter"+"script"
    "value": "audio-helper toggle $config.deviceId",
    "params": ["deviceId"],          // names resolved from $config / caller
    "then": "refresh"                // "refresh" | "none" (default) — re-pull/ask provider after
  }
}
```

`then:"refresh"` re-runs the poll command, or sends a `refresh` request to the
provider, immediately after the action — closing the "I tapped mute, now show
muted" loop the specs all needed. A button has **either** inline `action`
**or** `run` (a `$ref` into `actions`), never both.

### 5.4 Refresh (poll — extended additively)

```jsonc
"refresh": {
  "command": "audio-helper status",   // v1, unchanged
  "everySeconds": 5,                   // v1, min 2s
  "parse":  { "delimiter": "|", "fields": ["volume","muted","device"], "trim": true },
  "transform": { "muted": { "true": "Muted", "false": "" }, "volume": "Volume: $value%" }
}
```

`parse` (optional): `"json"` (default — v1 behavior, flat JSON stdout) **or** a
delimiter spec that splits a line into named keys. `transform` (optional): per-key
value remap or `$value` template. Both are additive; a v1 `refresh` with neither
behaves exactly as before. **A tile declares `refresh` (poll) OR `provider`
(push), not both.**

### 5.5 Provider (push — the `monitor`, §10) and 5.6/5.7 follow.

```jsonc
"provider": {
  "command": "node provider.js",   // long-lived; spawned on demand
  "args": [],
  "caps": ["state", "image"]       // what it pushes (advisory; host tolerates extra)
}
```

Full provider protocol in **§10**. A tile with no live data omits both `refresh`
and `provider` (a static button board, e.g. Figma shortcuts).

### 5.6 Versioning & migration

- `v` absent or `1` ⇒ load through the **v1→v2 migrator**: wrap top level in
  `view:{kind:"declarative"}`, treat `refresh` as `parse:"json"`, leave
  `fields`/`buttons` untouched. No author action required; old packs keep working.
- `v:2` ⇒ load directly.
- Additive v2.x fields (new `type`, new action `kind`) **do not** bump `v`.
  Removing/redefining a field bumps to `v:3`. Mirror `AppSettings`'
  versioned/auto-migrating discipline (CLAUDE.md convention) — bump and migrate,
  never silently feed a stale shape.

### 5.7 Safe action kinds

Retain the shipped set (`app`, `url`, `keystroke`, `shortcut`, `shell`,
`volume`, `media`, `page`). Add two the specs surfaced:

- **`activate`** — bring an app to front / launch if needed (the
  is-app-running/activate primitive, §10.4). `value` = app name/path.
- **`provider`** — send a command line to this tile's running provider over its
  stdin (§10.2), e.g. `{ "kind":"provider", "value":"setBrightness", "params":["pct"] }`.

Plus a named action may use `"interpreter":"osascript"|"zsh"` + `"script":"…"`
instead of `kind/value`, for the multi-line AppleScript the Zoom/Meetings/Spotify
specs need.

### 5.8 Authoring & developer experience (the on-ramp)

The full schema above *looks* heavy in one dump; in practice **complexity is
opt-in — you pay only for what you use.** The whole §5–§9 surface is optional keys
layered over a 5-line core. Design principle: **simplify the on-ramp, not the
schema.** Five rules keep DX low without weakening anything:

1. **A 5-line manifest is a complete plugin.** Only `id`, `name`, `symbol`, and one
   of `buttons`/`fields` are required. A static button board (Figma shortcuts)
   touches nothing else — no `provider`, `capabilities`, `configSchema`, signing.
   ```jsonc
   { "v": 2, "id": "com.me.hi", "name": "Hi", "symbol": "hand.wave",
     "buttons": [ { "label": "Open", "action": { "kind": "app", "value": "Safari" } } ] }
   ```
2. **Poll is the 90% path; the provider is opt-in.** `refresh` (print a flat JSON
   object, repeat) covers most live tiles. The long-lived `provider` (NDJSON, §10)
   is only for true push (Hue/Spotify-rich). **Most authors never write a provider
   or learn NDJSON.**
3. **Zero-ceremony dev loop.** A lone `manifest.json` dropped in the Extensions
   folder → *Reload* → live. **No bundle, no zip, no signing to build or test** —
   signing/`.gatecaster` packaging is a *store-distribution* concern only (§9),
   never a development one.
4. **A provider helper shrinks the one hard case.** Ship a tiny
   `gatecaster-provider` shim that owns the NDJSON framing + `hello`/`patch`
   lifecycle; the author just emits state objects, not a hand-rolled loop.
5. **Familiar shape + a scaffold.** The manifest deliberately resembles the
   Stream-Deck mental model (actions, states, a config form) so their authors port
   with little relearning; a `gatecaster new <id>` template kills the blank page.

**Documented as a ladder, not a wall:** *Hello-world (5 lines) → add live data
(`refresh`) → add controls (`actions`/`config`) → go push (`provider`) → ship
(sign + `.gatecaster`).* Each rung is independently useful; nobody climbs higher
than their plugin needs.

### 5.9 Business guardrail (free to author, Pro to run)

DX is intentionally generous because **easy authoring grows the catalog, and the
catalog sells Pro** — every plugin author tells their own users to get Gatecaster
to run it. The model only holds if one line holds: **extensions run *only inside
the Deck*, and the Deck is Pro-gated (`License.swift`, `requirePro()`).** *Free to
build and test; Pro to actually run on a deck.* Never expose a path that runs an
extension outside the Pro Deck — that would trade the $24 for nothing. Authoring,
the registry, and the dev loop stay free and frictionless; the **runtime** is the
gate. (Touch API stays free per its own tier; this guardrail is Deck-only.)

---

## 6. Subsystem ② — Config Panel (per-instance settings)

Today config is an opaque KV dict edited by hand. v2 adds a **declarative form**
the host renders into a per-instance settings sheet:

```jsonc
"configSchema": [
  { "key": "deviceId", "label": "Output device", "type": "device-picker",
    "source": "provider:devices" },              // options pushed by the provider
  { "key": "step",     "label": "Step size", "type": "slider", "min": 1, "max": 25, "default": 5 },
  { "key": "bridge",   "label": "Hue bridge", "type": "connect-button",
    "action": "pair", "secret": "bridgeKey" }     // runs a pairing action, stores a secret
]
```

`type ∈ text | toggle | slider | select | device-picker | connect-button | secret`.
Collected values persist per tile instance and surface to commands, provider env,
and the WebView bridge as `$config.<key>`. `device-picker` options can be static
(`options:[…]`) or live (`source:"provider:<key>"` — populated from a provider
patch, §10). `connect-button` fires a named action (often an OAuth/pairing flow,
§7) and stores its result in the secret store.

**Acceptance:** Hue (bridge + light picker + pairing button), Volume (device
picker + step slider), and Meetings (platform select) are each fully configurable
through this sheet with no JSON editing.

---

## 7. Subsystem ① — Secret store + OAuth redirect catcher

- **Secret store:** keychain-backed, keyed per `(extension id, secret key)`.
  Declared in the manifest:
  ```jsonc
  "secrets": [ { "key": "bridgeKey", "label": "Hue bridge key" },
               { "key": "spotifyToken", "label": "Spotify token", "oauth": true } ]
  ```
  Secrets are injected into provider/command processes as env vars
  (`GATECASTER_SECRET_<KEY>`), never written to the manifest or settings JSON.
- **OAuth redirect catcher:** for packs that need a browser auth round-trip
  (Slack OAuth2, Spotify Web API). The host owns the redirect target so plugins
  don't each run a server:
  ```jsonc
  "oauth": {
    "authUrl": "https://accounts.spotify.com/authorize?…",
    "redirect": "loopback",          // "loopback" (127.0.0.1:<ephemeral>) or "scheme"
    "scheme": "x-gatecaster",        // when redirect == "scheme": x-gatecaster://oauth/<id>
    "store": "spotifyToken"          // captured token → secret store
  }
  ```
  Host opens `authUrl`, catches the redirect (loopback HTTP listener **or**
  registered `x-gatecaster://` URL scheme), extracts the code/token, stores it.
  The plugin never sees the user's credentials, only the resulting token via env.
- **Used by:** Hue (bridge key — pairing, not OAuth, via `connect-button`),
  Slack (OAuth2), Spotify (Web API token).

---

## 8. Subsystem ③ — Capability manifest

Each pack declares the host facilities it uses; the registry (§9) discloses them
at install, and the host can enforce/deny:

```jsonc
"capabilities": ["shell", "network", "process", "secrets", "native-binary"]
```

| Capability | Grants | Example |
|---|---|---|
| `shell` | run `shell`/`refresh`/interpreter commands | almost all |
| `network` | provider/commands may open sockets | Hue (LAN), Spotify (Web API) |
| `process` | spawn a long-lived `provider` | Volume, Hue, Spotify |
| `secrets` | read/write the secret store + OAuth | Hue, Slack, Spotify |
| `native-binary` | pack ships a compiled helper binary | Volume (Audio-Tap helper) |

`native-binary` is the sharp edge: a pack shipping a compiled helper raises a
**notarization/trust** question (see Open Questions). The registry must surface it
distinctly ("this pack includes a native helper").

**There is deliberately no `touch` or `suppress` capability.** Reading the touch
stream and muting system input are *not on the plugin menu* (§10 isolation
boundary) — a plugin can't request what doesn't exist in the manifest vocabulary.

---

## 9. Subsystem ④ — Registry / distribution / install

The registry has three layers, separable: a **catalog** (what exists), an
**ingest transport** (how a pack lands on disk), and an **install gate** (the
consent + verification step both transports funnel through). The capability model
(§8) is reused unchanged — distribution adds *provenance and integrity*, not new
privileges.

### 9.1 Catalog (v0)

No accounts. A curated, git-backed repo of free packs. Browse → one-tap install.
No submission portal yet (curated). Optional login + cross-device sync is later
(P2). Sits entirely on top of §5–§8.

### 9.2 Ingest transports (two ways a pack lands)

A pack is distributed as a **`.gatecaster` bundle** — a zip of `manifest.json` +
assets (+ optional signed native helper, §9.4). Two ways to ingest one, **both
ending at the same install gate (§9.3)**:

1. **File association — double-click a `.gatecaster`.** Register the document type
   in `Gatecaster.app`'s Info.plist (`CFBundleDocumentTypes` +
   `UTExportedTypeDeclarations`, UTI e.g. `com.gatecaster.pack`). Finder routes
   the open-file event to the app → install gate.
2. **Web deep link — an "Install" button on a page.** Reuse the `x-gatecaster://`
   scheme already reserved for OAuth (§7):
   `x-gatecaster://install?src=https://store.example/com.foo.hue.gatecaster`.
   The app fetches the bundle → install gate. A page detects installability by
   attempting the deep link and falling back to a plain `.gatecaster` download.

Both paths require the **app bundle identity** (UTI + URL-scheme registration are
unavailable to the bare binary — same constraint as "Start at login" and the
OAuth scheme, §7 / CLAUDE.md). **Neither transport ever installs silently** — a
deep link *only opens the gate*; there is no programmatic install API a web page
can reach past §9.3.

### 9.3 Install gate — security model

The v0 store is **curated, free, first-party-reviewed**. Security is the
irreducible floor — *not* marketplace-scale ceremony. Don't build defenses for a
hostile third-party ecosystem that doesn't exist yet.

**The floor (v1) — three things, all cheap:**

- **L1 Consent (unconditional).** Every install (file *or* deep link) shows the
  disclosure sheet from §8 — capabilities, native-binary presence, publisher,
  source. **No path installs silently;** a deep link only *opens the gate*.
  ```
    Install “Philips Hue”?            Publisher: Acme  (✓ verified)
      Wants:  network · process · secrets
      ⚠ Includes a native helper binary
    [Cancel]                                        [Install]
  ```
- **L4 Capability enforcement** (the part that makes disclosure real). **Declared
  `capabilities` are the runtime ceiling, host-enforced:** no `network` → outbound
  sockets denied; no `process` → no provider may spawn; no `shell` →
  shell/interpreter kinds rejected; declared nothing → pure declarative tile (a
  Figma button board needs **zero** caps). Disclosure without enforcement = theater.
- **Signed curated packs (Ed25519 — reuse `License.swift`).** The registry signs
  each pack with the *same* CryptoKit Ed25519 path that verifies Pro licenses
  (embedded key, offline verify, `gen-keypair` pattern). Registry-signed → "✓
  verified"; anything else → "⚠ unverified," louder consent. Nearly free because
  the crypto already ships.

**Honest limit:** granting `shell` can't be *contained* before the P2 sandbox —
it's **disclosed, not contained**. L4 is a hard gate for `network`/`process`/
`secrets`; for `shell` it's an informed grant. Say so on the sheet.

**Deferred until the store opens to third parties (P2) — §14 P2 block:**
- **Hash-manifest integrity / MITM hardening** — matters when packs come from
  arbitrary URLs, not our curated repo. (For v1, quarantine is still respected on
  any downloaded `.gatecaster`; never strip `com.apple.quarantine`.)
- **Update-escalation re-consent** (capability-widening diff on reinstall).
- **Notarized third-party native binaries** — v1 accepts only first-party-signed
  helpers; reject unsigned third-party native code until that story lands.

**Install destination:** unzip into
`~/Library/Application Support/Gatecaster/Extensions/<id>/` (the existing location).

### 9.4 Dynamic tile image channel

A provider (or a poll `transform`) can push a rendered image as a tile's state —
Hue light swatches, Volume level glyphs, album art. Surfaced two ways: a
`fields[].type:"image"` that reads a state key, and a provider `image` event
(§10.2) that writes a named field's PNG directly. This is the
"provider-pushed dynamic tile image" primitive the brief calls out.

---

## 10. The `monitor` provider protocol (the linchpin)

A long-lived, headless, stateful child process that holds tokens, talks to the
outside world (OBS/Hue/Spotify/CoreAudio), and **pushes** state patches. It is the
data/capability axis's "push" mode. **It deliberately mirrors the Touch API
transport** (`DEVELOPER_API.md` §3): NDJSON, one object per line, `v` on every
message, additive-compatible, lease-by-close.

> **Isolation boundary (firm).** Resemble, don't couple. The provider is its own
> stdio pipe — it **never** connects to the Touch API socket (`api.sock`), never
> reads fingers/gestures, and **`suppress` is not a plugin capability at all.**
> Muting system input/gestures/edges is reserved exclusively for first-party Touch
> API clients (games/kiosks); no manifest capability, action kind, or bridge method
> grants it to a plugin. **v1 widgets have no raw-touch access** — taps + tile
> state only (the deck already drives its own scroll, `EXTENSIONS.md` "Scrolling
> content"). A future custom-interaction tier, if a real use case appears, would
> broker *read-only* touch through the host bridge — still never `suppress`.
> Caveat: a `shell`/`process` plugin runs at user privilege and could open
> `api.sock` itself; that leak closes only with the P2 sandbox, same as any `shell`
> grant. The rule is "no plugin path *offers* suppress," not a containment claim.

### 10.1 Transport

- **stdio**, not a socket: host spawns the process; provider's **stdout** = events
  the host reads, host writes commands to the provider's **stdin**. NDJSON, one
  object per line, both directions. (Socket would duplicate the Touch API's
  `api.sock`; stdio is the right scope for a host-owned child.)
- Secrets + `$config` injected as env at spawn (§6, §7).

### 10.2 Provider → host messages

```jsonc
{"v":1,"type":"hello","caps":["state","image","devices"]}     // on start
{"v":1,"type":"patch","state":{"title":"…","artist":"…","muted":false}}  // shallow-merge into tile state
{"v":1,"type":"image","field":"swatch","png":"<base64>"}      // dynamic tile image (§9)
{"v":1,"type":"options","key":"devices","items":[…]}          // feeds a device-picker (§6)
{"v":1,"type":"error","message":"…"}
```

`patch` **shallow-merges** into the tile's state dict — the same dict
`fields[].refreshKey` reads and the WebView bridge exposes. Push, not poll: the
tile updates the instant the provider emits.

### 10.3 Host → provider messages

```jsonc
{"v":1,"action":"setBrightness","params":{"pct":40}}   // from a button run / provider action
{"v":1,"action":"refresh"}                              // then:"refresh" requests fresh state
```

### 10.4 Lifecycle (the rules that keep it safe)

- **Spawn on demand:** started when the first tile using it becomes visible.
- **Reap on idle:** killed when the last consuming tile is removed/hidden — no
  orphan token-holders.
- **Crash recovery:** restart with backoff (mirror the app's hotplug-recovery
  posture); surface `error` patches to the tile.
- **Lease-by-close:** like the Touch API's suppress lease, a dead provider simply
  stops pushing — no heartbeat/TTL bookkeeping. State goes stale, not wedged.
- **`network` only if declared** (§8): a provider without the `network` capability
  is denied outbound sockets.

### 10.5 Two host primitives the specs surfaced

- **is-app-running / activate** — query whether a target app is running and
  bring it to front (or launch). Used by Zoom/Meetings as a *focus guard* before
  posting keystrokes, and by Spotify to avoid auto-launching on a status poll.
  Exposed as the `activate` action kind (§5.7) and a provider query.
- **provider-pushed dynamic tile image** — §9 / §10.2 `image` event.

---

## 11. Built-in vs extension boundary policy

Per `DECK_PLAN.md` / `WIDGET_IDEAS.md` ("keep the app lean"): **built-ins stay
minimal; the registry carries the long tail.** Concretely:

- A widget is **built-in** only if it needs custom interaction the manifest can't
  express *and* is broadly useful (the Timer's countdown ring; the on-screen
  keyboard; the virtual trackpad — the last two are **Pro**-gated, `License.swift`).
- **Volume ships built-in today and the Volume *extension* overlaps it.** Policy:
  the built-in Volume tile remains the zero-config default; the Volume *extension*
  is the power-user/customizable variant (device picker, helper, monitor). They
  coexist; the registry labels the extension "advanced — replaces the built-in if
  you want per-device control." Do not delete the built-in.
- Everything a declarative-or-WebView tile + a provider can express is an
  **extension**, not a built-in.

---

## 12. Plugin → platform coverage (all six map onto C)

| Plugin | Needs | Covered by |
|---|---|---|
| **Volume** | CoreAudio/Audio-Tap helper, audible-apps list, device picker | provider (`process`+`native-binary`) wraps helper & pushes list; Config Panel; declarative fields |
| **Hue** | SSE EventStream, REST, bridge key, light picker, pairing | provider (`network`); secret store + `connect-button` pairing; Config Panel; WebView mixer |
| **Slack** | URL-scheme (P1), OAuth2+REST (P2), presence (P3) | declarative P1; OAuth catcher + secrets; provider P3 |
| **Spotify** | osascript (P1), push-state (P2), rich player (P3) | declarative; provider; WebView player |
| **Zoom** | osascript keystrokes + process detect + state poll | declarative + `activate` focus-guard; provider; refresh |
| **Meetings** | multi-platform keystrokes, state machine, AX targeting | declarative; provider; `activate`; Accessibility (already in app) |

**Net: C supports all six with no architecture change** — it only promotes the
four subsystems from footnotes to first-class.

---

## 13. User Stories

**Plugin authors**
- As a plugin author, I want one documented manifest schema so I don't invent a
  private protocol per plugin.
- As a plugin author, I want a long-lived provider process so my tile shows live
  state (now-playing, light state) without a 2-second polling floor.
- As a plugin author, I want the host to hold my OAuth token so I never ship
  credential-handling code.
- As a plugin author, I want to declare a settings form so users configure my
  plugin without editing JSON.

**End users**
- As a user, I want to install a plugin and pick my device/light/account in a
  settings sheet — not a text editor.
- As a user, I want to see what a plugin can do (shell? network? native binary?)
  *before* I install it.
- As a user, I want my existing v1 extensions to keep working after the platform
  update.

**Maintainer**
- As the maintainer, I want one transport (NDJSON + `v`) shared with the Touch API
  so there's a single protocol discipline to reason about.

## 14. Requirements

### Must-Have (P0)
- **P0-1 Manifest schema v2** (§5) with a v1→v2 migrator. *AC:* a `"v":1` pack
  from `examples/extensions/` loads unchanged; a `"v":2` pack with `view`,
  `provider`, named `actions`, and `configSchema` parses and renders.
- **P0-2 `monitor` provider** (§10) — spawn-on-demand, NDJSON stdio, `patch`
  merge, reap-on-idle, crash-restart. *AC:* a provider pushing a `patch` updates a
  `refreshKey` field with no polling; killing the last consuming tile reaps the
  process; a crashed provider restarts and the tile shows stale-not-wedged state.
- **P0-3 Config Panel** (§6) rendering `configSchema` into a per-instance sheet,
  values surfaced as `$config.*`. *AC:* Hue + Volume configurable UI-only.
- **P0-4 Capability manifest + install disclosure** (§8/§9). *AC:* installing a
  pack with `shell`+`network`+`native-binary` shows all three before confirm.
- **P0-5 Secret store** (§7) keychain-backed, env-injected, never serialized to
  settings/manifest. *AC:* a stored token is readable by the provider via env and
  absent from `~/v17ut-settings.json` and the pack folder.

### Nice-to-Have (P1)
- **P1-1 WebView presentation** (`view.kind:"webview"` + `gatecaster.*` JS bridge:
  read state, fire actions). *AC:* a Spotify player / Hue mixer renders a custom
  canvas reading the same provider state.
- **P1-2 OAuth redirect catcher** (§7) — loopback + `x-gatecaster://` scheme.
  *AC:* Spotify Web API token captured end-to-end into the secret store.
- **P1-3 Dynamic tile image** (§9 / §10.2 `image`). *AC:* Hue swatch / album art
  pushed by a provider shows on the tile.
- **P1-4 Registry catalog v0** — curated repo, browse + one-tap install.
- **P1-5 Distribution & install** (§9.2/§9.3) — `.gatecaster` file association +
  `x-gatecaster://install?src=` deep link, **both** through the install gate.
  *AC:* double-clicking a `.gatecaster` and clicking a web Install button both open
  the disclosure sheet (never silent); cancelling leaves nothing on disk.
- **P1-6 Curated-pack signing** (§9.3) — registry signs packs; app verifies
  offline against an embedded registry key, reusing the `License.swift` CryptoKit
  path. *AC:* a registry-signed pack shows "✓ verified"; an unsigned/unknown-signer
  pack is flagged "unverified" with a louder consent step.
- **P1-7 Capability enforcement** (§9.3) — declared `capabilities` are the runtime
  ceiling. *AC:* a pack without `network` is denied outbound sockets; a pack
  without `process` cannot spawn a provider.

### Future Considerations (P2)
- **P2-1 Reduced-privilege sandbox tier** for refresh/provider commands (the only
  thing that *contains* a `shell` grant, and that closes the api.sock/suppress leak).
- **P2-2 Registry accounts + cross-device sync.**
- **P2-3 Per-OS `command` map** (`{macos,windows}`) for a future Windows runtime —
  keep the schema shape forward-compatible now, build nothing.
- **P2-4 Notarized native-helper distribution** for third-party `native-binary`
  packs (v1 = first-party-signed helpers only).
- **P2-5 Hash-manifest integrity / MITM hardening** — for packs from arbitrary
  (non-curated) URLs once the store opens to third parties.
- **P2-6 Update-escalation re-consent** — re-open the gate when a reinstall widens
  the capability set.
- **P2-7 Brokered read-only touch tier** — *only if* a concrete custom-interaction
  widget needs it; still never grants `suppress`.

## 15. Success Metrics

- **Leading:** all 6 clean-room plugins author against schema v2 with **0**
  private extensions (coverage check, at spec sign-off). 100% of shipped v1
  example packs load post-migration (regression gate). A provider-backed tile
  updates in **< 250 ms** from event vs the 2 s poll floor.
- **Lagging:** registry holds ≥ the 6 reference packs + community submissions;
  "had to hand-edit JSON" support reports → 0; no provider-orphan / wedged-input
  reports across a release cycle (the reap + lease-by-close working in the field).

## 16. Open Questions

- **`native-binary` trust** (engineering + legal): how is a pack's compiled helper
  notarized/verified? v1 stance (§9.3 L5) is first-party-signed only; the open part
  is the *third-party* notarized-distribution story. Ship our own notarized helper
  and let packs *declare* it vs. accept third-party binaries? *Blocking for
  third-party Volume-style helpers; not blocking for P0-1..P0-3.*
- **Pack-signing key custody** (engineering): the registry signing key is the trust
  root for "✓ verified" (§9.3 L2) — where does it live, who can sign, and how is it
  rotated if leaked? Mirror the Pro-license key handling in
  `docs/PRE-RELEASE-CHECKLIST.md` (regenerate the committed dev key before
  shipping). *Blocking P1-6.*
- **Unverified-pack policy** (product + engineering): do we *allow* installing an
  unsigned/arbitrary-URL pack at all (behind a loud sheet), or hard-require a
  registry signature in v1? Looser = open ecosystem; stricter = smaller attack
  surface. *Blocking P1-5/P1-6.*
- **WebView bridge surface** (engineering): exact `gatecaster.*` JS API (read
  state, fire action, request refresh) — and does a WebView get its own provider
  command channel? *Blocking P1-1 only.*
- **OAuth redirect mechanism** (engineering): loopback HTTP vs. registered
  `x-gatecaster://` scheme as the default — scheme registration needs a bundle id
  (`Gatecaster.app` only, not the bare binary). *Blocking P1-2.*
- **Spotify dispatcher verbs** (clean-room): `04-spotify.md`'s
  `changevolume`/`setshuffling`/`skipbyseconds` are a low-confidence leak — remap
  onto Spotify's public dictionary terms at all call sites together before the
  pack ships (advisory carried from `PLATFORM_BRIEF.md`). *Non-blocking; pre-ship.*
- **Provider resource limits** (engineering): cap concurrent providers / memory?
  A deck with 10 provider tiles spawns 10 processes. *Non-blocking; tune in P0-2.*

## 17. Timeline / Phasing

- **Phase 1 (P0):** schema v2 + migrator → provider → Config Panel → capability
  disclosure → secret store. Delivers Volume, Zoom, Meetings, and Spotify-P2
  (provider) end-to-end. This is the platform.
- **Phase 2 (P1):** WebView presentation + OAuth catcher + dynamic image +
  registry v0. Unlocks Hue mixer, Spotify rich player, Slack OAuth.
- **Phase 3 (P2):** sandbox tier, registry accounts/sync, notarized native
  helpers.

**Dependency:** Phase 1 is self-contained (reuses Touch API transport patterns,
already shipped). Phase 2's OAuth scheme registration depends on running from
`Gatecaster.app` (bundle identity), same constraint as "Start at login."

---

## 18. Clean-room guardrail (carried)

The six plugin specs are **clean** (audit:
`clean-room-audits/2026-06-13-plugins-audit.md`; spec: `.claude/clean-room-spec.md`).
Keep them clean: this platform spec describes **behavior + public APIs**, never an
original product's source structure, class names, or SDK callback spellings.
macOS-only; manifest *data* stays portable, *execution* is native (methodology doc).
