# Extension Platform — Implementation Status

Tracks what of `PLATFORM_SPEC.md` is actually built. Updated as code lands.

## Built (Phase 1 / P0 foundation)

All additive over the shipped declarative tier — **every v1 example pack still
loads unchanged** (the decoders were already tolerant; v2 only adds optional keys).

| Spec | What landed | Where |
|---|---|---|
| **P0-1** Manifest schema v2 | `v`, `view`, `provider`, `actions{}`, `configSchema`, `capabilities`, `secrets`, `oauth`; `fields[].type/size/min/max`; `refresh.parse/transform`; `buttons[].run` — all tolerant-decoding | `DeckWidgets.swift` `WidgetManifest` |
| **P0-1** v1→v2 migrator | `normalized()` — absent/`v:1` → declarative + `parse:"json"`; runs on registry load | `DeckWidgets.swift` |
| **P0-1** parse/transform | delimited stdout parsing + per-key `$value`/map remap in the poll path | `WidgetDataSource.poll/parse` |
| **P0-2** Provider (`monitor`) | NDJSON-over-stdio child, spawn-on-demand, `patch` shallow-merge, crash-restart w/ backoff, reap-on-idle | `PluginRuntime.swift` `ProviderProcess` / `ProviderHost` |
| **P0-2** Push wiring | provider patches merge into the same `values` dict fields read; tile is push **or** poll **or** static | `WidgetDataSource.startProvider`, `ExtensionWidget` |
| **P0-4** Capability model | declared `capabilities` = runtime ceiling; real gates: `process` to spawn a provider, `shell` for shell/interpreter actions | `PluginRuntime.swift` `PluginCapabilities` |
| **P0-5** Secret store | keychain-backed, namespaced per `(ext,key)`, injected as `GATECASTER_SECRET_<KEY>` env — never on disk | `PluginRuntime.swift` `SecretStore` |
| §5.7 | new `activate` action kind (is-app-running/front); `provider` kind forwards to the running provider stdin; named actions w/ `then:"refresh"` + `$config.<key>` substitution | `Deck.swift`, `DeckWidgets.swift` |

### Honest limits (carried from spec §9.3)
- **`network` is disclosed, not contained.** The capability is modeled and gateable,
  but a granted `process`/`shell` child runs at user privilege — real containment of
  network/api.sock access needs the **P2 sandbox** (§14 P2-1). No pretense otherwise.
- **No `suppress` path exists for plugins** — by construction (§10 isolation). The
  provider is its own stdio pipe; it never touches `api.sock`.

## Not yet built (Phase 2 / P1+)
- Config Panel **UI** (the `configSchema` model exists; the sheet that renders it does not).
- WebView presentation + `gatecaster.*` JS bridge.
- OAuth redirect catcher; dynamic-image **rendering** on the tile (the `image` event is
  received into `data.images` but not yet drawn).
- Registry / `.gatecaster` install / file-association / deep-link / pack signing.
- Install disclosure sheet (capability model is ready to feed it).

## How to test (morning)

A zero-dependency provider example is installed at
`~/Library/Application Support/Gatecaster/Extensions/com.example.heartbeat/`
(source: `examples/extensions/com.example.heartbeat/`).

```bash
swift build -c release && .build/release/Gatecaster   # or run from Xcode
```

1. Open the Deck → edit mode → widget rail **＋** → *Reload Extensions* → drop **Heartbeat**.
2. **Push works** if `Tick` counts up every second and `Time` updates with **no 2s poll floor**.
3. Tap **Ping** → `Last ping` updates (host→provider stdin command + `then:"refresh"`).
4. Reap: remove the tile → the `provider.sh` process exits (verify: `pgrep -f provider.sh`).
5. Crash-restart: `pkill -f provider.sh` while the tile is visible → it respawns, ticking resumes.

Capability gate check: delete `"capabilities": ["process"]` from the manifest →
*Reload* → the tile shows “Provider unavailable (missing `process` capability?)”
instead of silently spawning.

### Regression (v1 still works)
The shipped `com.example.nowplaying` / `com.figma.shortcuts` packs must load and
render exactly as before — they have no `v`, migrate to v2 on load, behave identically.
