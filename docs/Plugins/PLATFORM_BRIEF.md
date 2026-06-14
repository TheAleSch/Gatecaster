# Gatecaster Extension Platform — Handoff Brief

One-page handoff so the spec can be written in a fresh chat with no re-derivation.
To start: open a new chat and say *"write the Gatecaster extension-platform spec,
Approach C"* — this file is the pointer.

## Decision

Build the Deck extension/plugin platform on **Approach C**: two orthogonal axes plus
four first-class cross-cutting subsystems plus a registry. (Touch API is done and out
of scope here — this is Deck widgets/plugins only.)

- **Data / capability axis** — an optional long-lived **`monitor` provider process**
  (NDJSON over stdio, reusing the Touch API's transport discipline). Headless,
  stateful, *push* (not polled). Holds tokens, talks to OBS/Hue/Spotify, emits state
  patches. A tile with no live data declares no provider. **This is the linchpin
  primitive — 5 of the 6 clean-room specs demand it.**
- **Presentation axis** — either declarative `fields`/`buttons` (cheap, the common
  case) **or** a WebView (custom canvas: rings, dials, charts). Both consume the same
  provider patches. Presentation is a render choice, not a privilege tier.

Why C over the docs' linear ladder (declarative → data-provider → WebView → registry):
the ladder conflates *where data comes from* (capability/privilege) with *how the tile
looks* (presentation). C separates them, so the registry has **one** capability model
to disclose regardless of how a tile renders.

## Four subsystems to make first-class (the specs proved these; don't leave implicit)

1. **Secret store + OAuth redirect catcher** — keychain-backed tokens + a redirect
   handler (custom scheme `x-gatecaster://` or loopback HTTP). Needed by Hue (bridge
   key), Slack (OAuth2), Spotify (Web API).
2. **Config Panel system** — per-instance settings collected through UI (device
   picker, light selector, "Connect" button). Today you hand-edit `manifest.json`;
   half these plugins are unusable without it.
3. **Capability manifest** — each pack declares `shell` / `network` / `process` /
   `secrets` / `native-binary`; the registry discloses them at install. Includes a
   flag for packs shipping **native helper binaries** (volume's Audio-Tap helper) →
   notarization/trust question to resolve.
4. **Registry / marketplace** — v0 no-accounts (curated repo, browse + one-tap
   install, free packs); optional login + sync later. Sits on top, disclosing #3.

Plus two small host primitives the specs surfaced: **is-app-running / activate** (Zoom,
Spotify) and a **provider-pushed dynamic tile image** channel (volume/Hue live swatches).

## First job of the spec

**Reconcile two incompatible manifest schemas into one versioned format:**
- Shipped (`docs/EXTENSIONS.md`): `fields[]` + `buttons[]` with `action:{kind,value}`
  + `refresh:{command,everySeconds}`.
- Invented by the plugin specs: `kind:"widget"|"webview"`, `tile.template`,
  `tile.layout`, `refresh.parse/transform`, `actions` keyed object with `params` +
  `then:"refresh"`.
These do not interoperate. One versioned schema (additive-fields-don't-break, mirror
the Touch API's `v` discipline) is job #1.

## Plugin → platform coverage (all six map onto C)

| Plugin | Needs | Covered by |
|---|---|---|
| Volume | CoreAudio/Audio-Tap helper, audible-apps monitor, device-picker | provider wraps helper + pushes list; config panel; declarative P1 |
| Hue | SSE EventStream, REST, bridge key, light picker, pairing wizard | provider; secret store; config panel; WebView setup window |
| Slack | URL-scheme (P1), OAuth+token+REST (P2), presence poll (P3) | declarative P1; OAuth catcher + secret store; monitor |
| Spotify | osascript (P1), push-state monitor (P2), rich player (P3) | declarative; `monitor` provider; WebView |
| Zoom | osascript keystrokes + process detect, state poll | declarative; is-app-running primitive; monitor |
| Meetings | multi-platform keystrokes, state machine, AX targeting | declarative; monitor; Accessibility (already in app) |

Net: **C supports all six with no architecture change** — just promote the four
subsystems from footnotes to first-class.

## Inputs for the spec

- `docs/plugins/01–06` — clean-room requirements (now remediated; see audit below).
- `docs/EXTENSIONS.md`, `docs/EXTENSION_BUILDING.md` — shipped declarative tier.
- `docs/DECK_PLAN.md`, `docs/WIDGET_IDEAS.md` — roadmap + built-in-vs-extension policy
  ("keep the app lean": built-ins minimal, registry carries the long tail).
- `docs/DEVELOPER_API.md` — Touch API (done; reuse its NDJSON/`v`-versioning patterns).

## Guardrails carried from this session

- **Clean-room:** the plugin specs are now CLEAN (audit:
  `clean-room-audits/2026-06-13-plugins-audit.md`; spec: `.claude/clean-room-spec.md`).
  Keep them clean — describe behavior + public APIs, never original source structure,
  class names, or SDK callback spellings.
- **macOS-only, no cross-platform abstraction "just in case"** (per methodology doc).
  Manifest *data* stays portable; execution is macOS-native.
- **Built-in vs extension:** Volume already ships built-in; the volume *extension*
  overlaps. State the boundary policy explicitly in the spec.
- **Open advisory:** `04-spotify.md` dispatcher verbs (`changevolume`/`setshuffling`/
  `skipbyseconds`) — optionally remap onto Spotify's public dictionary terms to remove
  the low-confidence leak; must rename at all call sites together.
