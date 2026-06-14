// gatecaster-provider — the zero-dependency NDJSON provider shim (PLATFORM_SPEC §10).
//
// A "provider" is the PUSH half of the data axis: a long-lived headless process
// the host spawns once and keeps alive, instead of re-running a poll command on a
// timer. You push tile state up whenever it changes; the host shallow-merges it.
//
// Transport (mirrors the Touch API on purpose): newline-delimited JSON, ONE object
// per line, a `v` on every message.
//   • stdout = events the host READS   (hello / patch / image / options / error)
//   • stdin  = commands the host WRITES (your button `run:`s land here)
//   • stderr = your logs (host ignores; never put protocol on stderr)
// A dead provider just stops printing — the tile goes stale, never wedged (§10.4).
// Crash and the host restarts you with backoff; idle and it reaps you. Be stateless
// across restarts: re-emit your current state in `start()`.
//
// This shim hides the framing. You implement a handful of hooks; you only ever deal
// in plain objects. Delete the hooks you don't need.

import { createInterface } from "node:readline";

// ── transport (you should not need to touch below) ──────────────────────────

let _seq = 0;
function send(obj) {
  // One NDJSON line. `v:1` is the provider-protocol version, independent of the
  // manifest `v`. process.stdout.write (not console.log) keeps it a single write.
  process.stdout.write(JSON.stringify({ v: 1, ...obj }) + "\n");
}

/** Shallow-merge new keys into the tile's state dict (the 90% call). */
export function patch(state) {
  send({ type: "patch", state });
}
/** Push a rendered image for a field by key (PNG/JPEG base64, no data: prefix). */
export function image(key, base64, mime = "image/png") {
  send({ type: "image", key, data: base64, mime });
}
/** Supply dynamic choices for a configSchema `select` with source:"provider:<key>". */
export function options(key, list) {
  send({ type: "options", key, options: list });
}
/** Surface a human-readable error onto the tile without crashing the process. */
export function error(message) {
  send({ type: "error", message });
}

// ── secrets & config (injected as env by the host — never on disk) ──────────

/** Read a declared secret (manifest secrets[].key) → GATECASTER_SECRET_<KEY>. */
export const secret = (key) => process.env[`GATECASTER_SECRET_${key.toUpperCase()}`];
/** Read a config value (manifest configSchema[].key) → GATECASTER_CONFIG_<KEY>. */
export const config = (key) => process.env[`GATECASTER_CONFIG_${key.toUpperCase()}`];

/**
 * Wire up a provider. Pass an object of hooks:
 *   start(api)          — called once after the host is ready; emit your first patch here.
 *   command(name, msg)  — a host→provider command arrived (a button `run:` / action value).
 *   stop()              — host is reaping you; flush/cleanup, then the process exits.
 * `api` is { patch, image, options, error, secret, config }.
 */
export function provider(hooks = {}) {
  const api = { patch, image, options, error, secret, config };

  // Advertise capabilities. `state` = "I push patches"; add "image"/"options" if you do.
  send({ type: "hello", caps: ["state"] });

  const rl = createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    line = line.trim();
    if (!line) return;
    let msg;
    try { msg = JSON.parse(line); } catch { return; } // ignore non-JSON noise
    // The host forwards a button's action value as { action: "<value>" } (§10.3).
    const name = msg.action ?? msg.command ?? msg.type;
    try { hooks.command?.(name, msg, api); }
    catch (e) { error(String(e?.message ?? e)); }
  });

  // Clean reap: SIGTERM from the host → run stop() → exit 0 (never leave a ticker).
  const shutdown = () => { try { hooks.stop?.(api); } finally { process.exit(0); } };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  // Defer start() a tick so the host has consumed `hello` before the first patch.
  queueMicrotask(() => { try { hooks.start?.(api); } catch (e) { error(String(e?.message ?? e)); } });
  return api;
}

export default provider;
