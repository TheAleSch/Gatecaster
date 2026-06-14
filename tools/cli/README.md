# gatecaster

Author, validate, and install [Gatecaster](https://github.com/TheAleSch/gatecaster)
Deck extensions — small tiles that show live data and run actions on a touchscreen
control surface. Zero dependencies, pure ESM, Node ≥ 18.

```bash
npm install -g gatecaster      # or: npx gatecaster <cmd>
```

## Quick start

```bash
gatecaster new com.you.weather --template poll   # scaffold a pack
cd com.you.weather
# …edit manifest.json + scripts/refresh.sh…
gatecaster validate            # catch mistakes before the host silently drops them
gatecaster install             # copy into the Deck; then "Reload Extensions"
```

## Commands

| Command | What it does |
|---|---|
| `gatecaster new <id> [--template static\|poll\|push] [--name "Name"]` | Scaffold a pack from a template. `id` is reverse-DNS (`com.you.thing`) and becomes the install folder. |
| `gatecaster validate [dir]` | Check `manifest.json` against schema v2. Exits non-zero on errors. |
| `gatecaster install [dir]` | Validate, then install into the Deck's extensions folder. Refuses on errors (`--force` to override). |
| `gatecaster list` | List installed extensions. |
| `gatecaster uninstall <id>` | Remove an installed extension. |

Extensions install to
`~/Library/Application Support/Gatecaster/Extensions/<id>/`.

## Why validate

The host **tolerant-decodes** manifests so one bad pack never breaks a registry
reload — which means a mistake makes your tile *silently vanish* instead of
erroring. `validate` is the loud counterpart: it mirrors exactly what the Swift
host accepts and explains each problem before you Reload.

- **errors** — the host won't render this the way you intend.
- **warnings** — it loads, but probably isn't what you meant.

## The three templates (the authoring ladder)

Complexity is opt-in. Start on the lowest rung that does the job.

- **static** — buttons only: keystrokes, launch apps, run Shortcuts. No data, no timer.
- **poll** — fields refreshed by a command on a timer (the 90% path). Your command
  prints JSON to stdout; the host maps it onto fields by `refreshKey`.
- **push** — a long-lived NDJSON **provider** process that pushes state the instant
  it changes (no poll floor). Opt in only when you need real-time. Push packs ship
  with `gatecaster-provider.js`, a zero-dep shim that hides all the NDJSON framing —
  you implement `start` / `command` / `stop` hooks and call `patch({...})`.

A provider needs the `process` capability; a `kind:"shell"` or `interpreter`/`script`
action needs `shell`. The validator enforces this the same way the host does.

## Library use

```js
import { validateManifest } from "gatecaster/schema";
const { errors, warnings } = validateManifest(JSON.parse(text));
```

```js
// inside a push provider:
import { provider } from "gatecaster/provider";
provider({ start: ({ patch }) => patch({ status: "up" }) });
```

## Scope

Authoring and the dev loop are free and offline. This CLI only writes, validates,
and copies pack files — it never *runs* an extension. Extensions execute solely
inside the Gatecaster Deck (a Pro feature). See `PLATFORM_SPEC.md` §5.8–§5.9.
