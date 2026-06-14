---
name: gatecaster-extension
description: Use when authoring, scaffolding, validating, or debugging a Gatecaster Deck extension (a manifest.json tile with fields/buttons, an optional poll refresh command, or a push NDJSON provider). Covers schema v2, the action vocabulary, capabilities, secrets, and the `gatecaster` CLI.
---

# Authoring a Gatecaster Deck extension

A Gatecaster extension is a folder with a `manifest.json` that renders one **tile**
on the Deck (a touchscreen control surface). A tile shows data (**fields**), runs
**actions** (**buttons**), and gets its data one of three ways. Your job is to pick
the simplest shape that works and write a correct manifest.

## The mental model — two orthogonal axes (schema v2)

1. **Presentation**: declarative (`fields`/`buttons`, the default) **or** a `webview`.
2. **Data**: `none` (static) **or** `refresh` (poll a command on a timer) **or**
   `provider` (a long-lived process that pushes). These three are mutually exclusive.

Complexity is **opt-in** (the "authoring ladder"). Climb only as high as you must:

| Rung | Add | Use when |
|---|---|---|
| static | `buttons[]` with actions | keystrokes / launch apps / Shortcuts; no data |
| poll | `refresh{command,everySeconds}` + `fields[]` | data you can fetch with a command — **the 90% path** |
| actions/config | `actions{}`, `configSchema[]`, `secrets[]` | named/parameterized actions, user settings, tokens |
| push | `provider{command}` + `capabilities:["process"]` | real-time data; a poll can't keep up |

## Workflow — always do this

1. **Scaffold, don't hand-write the skeleton.** Pick the rung and run the CLI:
   ```bash
   gatecaster new com.you.thing --template static|poll|push --name "Thing"
   ```
   `id` is reverse-DNS and becomes the install folder name.
2. **Edit** `manifest.json` (+ `scripts/refresh.sh` for poll, `provider.js` for push).
3. **Validate after every change** — this is the single highest-value habit:
   ```bash
   gatecaster validate          # run in the pack dir
   ```
   The host **tolerant-decodes**: a bad manifest makes the tile *silently vanish* on
   Reload instead of erroring. The validator is the loud counterpart — it mirrors
   exactly what the Swift host accepts. Fix every **error**; weigh every **warning**.
4. **Install + reload**:
   ```bash
   gatecaster install           # validates, then copies into the Deck
   ```
   Then in the Deck: **Reload Extensions**.

If the `gatecaster` CLI is not installed, run it via `npx gatecaster <cmd>` from the
repo's `tools/cli`, or `node tools/cli/bin/gatecaster.js <cmd>`.

## Hard rules (these cause silent failures — check them every time)

- **`fields[].label` is required.** A label-less field is dropped by the host.
- **`refresh` XOR `provider`.** Declaring both is an error — a tile is poll *or* push.
- A **`provider` needs `capabilities:["process"]`** or the host refuses to spawn it
  (the tile shows "Provider unavailable" instead of silently running a child).
- A **`kind:"shell"` action or an `interpreter`/`script` action needs
  `capabilities:["shell"]`.** (A `refresh` poll command does **not** — it's ungated,
  for v1 compatibility.)
- A button uses **`action` (inline) XOR `run:"<actionId>"`** (a named action), never both.
- **`v`/version discipline** (mirrors the Touch API): adding an optional field never
  bumps `v`; the host ignores unknown fields. Set `"v": 2` to use v2 features.
- **Always send the `ended`/cleanup for anything you start** in a provider (clear
  timers in `stop()`), and re-emit current state in `start()` — providers are
  restarted on crash and must be stateless across restarts.

## Reference files (load as needed)

- **references/schema-reference.md** — every manifest key, type, and accepted value
  (the exact mirror of the host model + validator). Read this when writing fields,
  actions, refresh/parse, provider, configSchema, secrets, or oauth.
- **references/examples.md** — complete, copy-ready manifests for each rung
  (static board, JSON poll, delimited poll, push provider with a button command).
- **references/provider-protocol.md** — the NDJSON push protocol (§10): message
  types, the `gatecaster-provider.js` shim hooks, secrets/config env injection,
  lifecycle (spawn/reap/crash-restart). Read this only when building a push pack.

## Scope / safety

Authoring is free and offline; extensions run only inside the Pro-gated Deck. Never
write an extension that tries to reach the touch input socket or run outside the
Deck — the provider is an isolated stdio pipe by construction; it has no `suppress`
or touch-injection path. Secrets are injected as `GATECASTER_SECRET_<KEY>` env and
must never be written into the manifest or any file on disk.
