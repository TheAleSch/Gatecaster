# Provider protocol (push) — PLATFORM_SPEC §10

A **provider** is the push half of the data axis: a long-lived headless process the
host spawns once and keeps alive, instead of re-running a poll command on a timer.
Use it only when a poll can't keep up (real-time state). Otherwise prefer `refresh`.

## Wire format

Newline-delimited JSON (NDJSON), **one object per line**, a `v` on every message.
Mirrors the Touch API transport on purpose.

- **stdout** = events the host READS.
- **stdin** = commands the host WRITES (your button `run:`s / `kind:"provider"` actions).
- **stderr** = your logs (host ignores). Never put protocol on stderr.

### Events you emit (stdout)

| `type` | Shape | Meaning |
|---|---|---|
| `hello` | `{v,type:"hello",caps:["state"]}` | First line. Advertise caps: `state` (you patch), `image`, `options`. |
| `patch` | `{v,type:"patch",state:{key:val,…}}` | **Shallow-merge** these keys into the tile state dict (the 90% call). |
| `image` | `{v,type:"image",key,data:<base64>,mime}` | Dynamic image for a field (PNG/JPEG base64, no `data:` prefix). |
| `options` | `{v,type:"options",key,options:[…]}` | Choices for a `configSchema` select with `source:"provider:<key>"`. |
| `error` | `{v,type:"error",message}` | Surface a human error onto the tile without crashing. |

### Commands you receive (stdin)

The host forwards a button's action value as `{v,action:"<value>"}` (plus optional
`params`). React and usually answer with a `patch`.

## Lifecycle (§10.4) — design for it

- **Spawn on demand**, **reap on idle** — the host starts you when a tile appears and
  kills you (SIGTERM) when it's gone. Handle SIGTERM, clean up, exit 0.
- **Crash → restart with backoff.** You may be relaunched at any time. Be **stateless
  across restarts**: re-emit current state in `start()`; don't assume continuity.
- **Stale, not wedged.** A dead provider just stops printing; the tile goes stale. So
  never block forever holding the gesture/recognizer — there's nothing to wedge here,
  but do flush patches promptly.

## The `gatecaster-provider.js` shim

`gatecaster new --template push` drops this zero-dep ESM shim into the pack. It hides
all framing; you implement hooks and call `patch({...})`.

```js
import { provider } from "./gatecaster-provider.js";

provider({
  // Called once after the host consumes `hello`. Emit your first patch here.
  start({ patch, image, options, error, secret, config }) { /* … */ },

  // A host→provider command arrived (a button run / kind:"provider" value).
  command(name, msg, api) { /* if (name === "refresh") api.patch({ … }) */ },

  // Host is reaping you (SIGTERM). Clear timers, flush, then the process exits.
  stop(api) { /* clearInterval(...) */ },
});
```

API methods (also importable individually): `patch(state)`, `image(key,base64,mime)`,
`options(key,list)`, `error(message)`, `secret(KEY)`, `config(KEY)`.

### Secrets & config injection (§7)

Never read tokens from a file or hardcode them. The host injects:

- declared `secrets[].key` → `GATECASTER_SECRET_<KEY>` (uppercased) → `secret("API_TOKEN")`.
- `configSchema[].key` → `GATECASTER_CONFIG_<KEY>` → `config("project")`.

## Isolation (§10) — what a provider CANNOT do

A provider is its own stdio pipe. It has **no** access to the touch input socket, **no**
`suppress`, **no** input injection. That boundary is by construction — don't try to
reach around it. Network/filesystem run at user privilege today (disclosed via
`capabilities`, not yet sandboxed); declare what you use honestly.

## Manual test

```sh
# feed one command, watch the stream, then Ctrl-C
( printf '{"v":1,"action":"ping"}\n'; sleep 2 ) | node provider.js
# expect: hello → initial patch → a pong patch → periodic patches
```
