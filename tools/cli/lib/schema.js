// Gatecaster manifest schema v2 — validation rules.
//
// This is the JS mirror of the Swift `WidgetManifest` model
// (Sources/Gatecaster/DeckWidgets.swift) and PLATFORM_SPEC.md §5–§10. The Swift
// decoder is deliberately TOLERANT (decodeIfPresent + defaults) so a bad pack
// never nukes the whole registry reload — which means the host will silently
// drop/ignore mistakes instead of telling you. This validator is the loud
// counterpart: it catches the things the tolerant decoder swallows BEFORE you
// Reload, so authoring failures are explained, not mysterious.
//
// Two severities:
//   • error   — the host will not render this the way you intend (hard problem).
//   • warning — loads, but probably not what you meant (smell / forward-compat).

// ── controlled vocabularies (keep in lockstep with the Swift host) ──────────

// Safe action kinds (§5.7). The first eight are the shipped set; `activate` and
// `provider` were added by schema v2.
export const ACTION_KINDS = [
  "app", "url", "keystroke", "shortcut", "shell",
  "volume", "media", "page", "activate", "provider",
];

// Capabilities (§8) — the declared runtime ceiling. There is deliberately NO
// `touch`/`suppress` capability (§10 isolation boundary): a plugin cannot ask
// for what the vocabulary doesn't contain.
export const CAPABILITIES = ["shell", "network", "process", "secrets", "native-binary"];

export const FIELD_TYPES = ["text", "image", "range", "slider", "dial"];
export const FIELD_SIZES = ["small", "regular", "large"];
export const VIEW_KINDS = ["declarative", "webview"];
export const PARSE_KINDS = ["json", "delimited"];
export const INTERPRETERS = ["osascript", "zsh"];
export const CONFIG_TYPES = [
  "text", "toggle", "slider", "select", "device-picker", "connect-button", "secret",
];
export const OAUTH_REDIRECTS = ["loopback", "scheme"];

// Action kinds that execute a shell/interpreter and therefore require the
// `shell` capability to run (§8 / §9.3 L4).
const SHELL_KINDS = new Set(["shell"]);

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// A small accumulator so every rule reads as `r.error(path, msg)`.
function makeReport() {
  const errors = [];
  const warnings = [];
  return {
    errors,
    warnings,
    error: (where, msg) => errors.push({ where, msg }),
    warn: (where, msg) => warnings.push({ where, msg }),
  };
}

// Collect every `$config.<key>` / `$<key>` reference inside a string so we can
// cross-check against the declared configSchema/secrets (a typo'd $config.foo
// silently expands to nothing at runtime — a classic head-scratcher).
function configRefsIn(str, out) {
  if (typeof str !== "string") return;
  const re = /\$config\.([A-Za-z0-9_]+)/g;
  let m;
  while ((m = re.exec(str))) out.add(m[1]);
}

/**
 * Validate a parsed manifest object.
 * @param {any} m  parsed JSON (already JSON.parse'd; pass the raw text path separately for IO errors)
 * @returns {{errors: {where:string,msg:string}[], warnings: {where:string,msg:string}[]}}
 */
export function validateManifest(m) {
  const r = makeReport();

  if (!isObj(m)) {
    r.error("(root)", "manifest is not a JSON object");
    return r;
  }

  // ── identity (§5.1) ──────────────────────────────────────────────────────
  if (typeof m.id !== "string" || m.id.trim() === "") {
    r.error("id", "required, non-empty string (reverse-DNS, e.g. com.you.thing)");
  } else {
    if (!/^[A-Za-z0-9][A-Za-z0-9.\-]*$/.test(m.id))
      r.error("id", `"${m.id}" — use only letters, digits, dot, hyphen (it is also the install folder name)`);
    if (!m.id.includes("."))
      r.warn("id", `"${m.id}" is not reverse-DNS — convention is com.you.thing (avoids collisions in the registry)`);
  }
  if (typeof m.name !== "string" || m.name.trim() === "")
    r.error("name", "required, non-empty string (shown as the tile title)");

  if (m.symbol !== undefined && typeof m.symbol !== "string")
    r.error("symbol", "must be an SF Symbol name string, e.g. music.note");
  else if (m.symbol === undefined)
    r.warn("symbol", "no SF Symbol set — the tile header will have no icon");

  if (m.colorHex !== undefined && !/^#?[0-9A-Fa-f]{6}$/.test(String(m.colorHex)))
    r.warn("colorHex", `"${m.colorHex}" — expected a 6-digit hex like #1DB954`);

  // ── schema version (§5.6) ────────────────────────────────────────────────
  if (m.v !== undefined) {
    if (typeof m.v !== "number") r.error("v", "must be a number (2 for schema v2)");
    else if (m.v > 2) r.warn("v", `v:${m.v} is newer than this validator (v2) — newer fields are not checked`);
  } else {
    r.warn("v", 'no "v" — treated as a v1 pack and migrated on load; set "v": 2 to use v2 features');
  }

  // ── presentation axis (§5.1) ─────────────────────────────────────────────
  let isWebview = false;
  if (m.view !== undefined) {
    if (!isObj(m.view)) {
      r.error("view", "must be an object, e.g. { \"kind\": \"declarative\" }");
    } else {
      const kind = m.view.kind ?? "declarative";
      if (!VIEW_KINDS.includes(kind))
        r.warn("view.kind", `"${kind}" unknown — falls back to declarative; expected ${VIEW_KINDS.join(" | ")}`);
      isWebview = kind === "webview";
      if (isWebview && (typeof m.view.entry !== "string" || !m.view.entry))
        r.error("view.entry", "a webview view requires an entry HTML path relative to the pack, e.g. ui/player.html");
    }
  }

  // A tile must show SOMETHING (§5.8: a 5-line manifest needs one of these).
  const hasButtons = Array.isArray(m.buttons) && m.buttons.length > 0;
  const hasFields = Array.isArray(m.fields) && m.fields.length > 0;
  if (!isWebview && !hasButtons && !hasFields)
    r.error("(root)", "declarative tile has nothing to show — add fields[] or buttons[] (or use a webview view)");

  // ── named actions (§5.3) — validate first so fields/buttons can reference them ─
  const actionIds = new Set();
  const declaredCaps = new Set(Array.isArray(m.capabilities) ? m.capabilities : []);
  const providerPresent = isObj(m.provider) && typeof m.provider.command === "string" && m.provider.command !== "";
  const configRefs = new Set();
  let needsShellCap = false;
  let usesProviderAction = false;

  if (m.actions !== undefined) {
    if (!isObj(m.actions)) {
      r.error("actions", "must be an object keyed by action id, e.g. { \"mute\": { ... } }");
    } else {
      for (const [id, a] of Object.entries(m.actions)) {
        actionIds.add(id);
        const at = `actions.${id}`;
        if (!isObj(a)) { r.error(at, "must be an object"); continue; }
        const hasKV = a.kind !== undefined || a.value !== undefined;
        const hasScript = a.interpreter !== undefined || a.script !== undefined;
        if (!hasKV && !hasScript)
          r.error(at, "needs either kind/value or interpreter/script");
        if (hasKV && hasScript)
          r.warn(at, "has both kind/value and interpreter/script — host prefers interpreter/script; pick one");
        if (a.kind !== undefined && !ACTION_KINDS.includes(a.kind))
          r.error(`${at}.kind`, `"${a.kind}" not a safe action kind — one of ${ACTION_KINDS.join(", ")}`);
        if (a.interpreter !== undefined && !INTERPRETERS.includes(a.interpreter))
          r.error(`${at}.interpreter`, `"${a.interpreter}" — expected ${INTERPRETERS.join(" | ")}`);
        if (a.interpreter !== undefined && typeof a.script !== "string")
          r.error(`${at}.script`, "interpreter set but script missing");
        if (a.then !== undefined && !["refresh", "none"].includes(a.then))
          r.warn(`${at}.then`, `"${a.then}" — expected "refresh" or "none" (default)`);
        if (a.then === "refresh" && !m.refresh && !providerPresent)
          r.warn(`${at}.then`, 'then:"refresh" but the tile has no refresh or provider to re-pull');
        if (a.params !== undefined && !Array.isArray(a.params))
          r.error(`${at}.params`, "must be an array of parameter names");
        if (SHELL_KINDS.has(a.kind) || hasScript) needsShellCap = true;
        if (a.kind === "provider") {
          usesProviderAction = true;
          if (!providerPresent)
            r.error(`${at}`, 'kind:"provider" but no provider is declared to receive the command');
        }
        configRefsIn(a.value, configRefs);
        configRefsIn(a.script, configRefs);
      }
    }
  }

  // ── fields (§5.2/§5.9) — after actions so slider/dial `run` can be resolved ─
  if (m.fields !== undefined) {
    if (!Array.isArray(m.fields)) r.error("fields", "must be an array");
    else m.fields.forEach((f, i) => {
      const at = `fields[${i}]`;
      if (!isObj(f)) { r.error(at, "must be an object"); return; }
      // Swift `ManifestField.label` is a non-optional String → required.
      if (typeof f.label !== "string" || f.label === "")
        r.error(`${at}.label`, "required (the Swift model has no default; a label-less field is dropped)");
      if (f.type !== undefined && !FIELD_TYPES.includes(f.type))
        r.warn(`${at}.type`, `"${f.type}" unknown — renders as text; expected ${FIELD_TYPES.join(" | ")}`);
      if (f.size !== undefined && !FIELD_SIZES.includes(f.size))
        r.warn(`${at}.size`, `"${f.size}" unknown — expected ${FIELD_SIZES.join(" | ")}`);
      if ((f.type === "range" || f.type === "slider" || f.type === "dial") && f.max === undefined)
        r.warn(`${at}.max`, `a ${f.type} field with no max defaults to 0..100 (range: 0..1) — set max for a sensible scale`);

      const interactive = f.type === "slider" || f.type === "dial";
      if (interactive) {
        // §5.9 — drag-to-set. EITHER inline action OR named run; run wins.
        const hasInline = f.action !== undefined;
        const hasRun = f.run !== undefined;
        if (f.orientation !== undefined && !["vertical", "horizontal"].includes(f.orientation))
          r.warn(`${at}.orientation`, `"${f.orientation}" — expected "vertical" (default) or "horizontal"`);
        if (!hasInline && !hasRun)
          r.warn(at, `a ${f.type} with neither action nor run just displays — add one to set a value on drag`);
        if (hasInline && hasRun)
          r.warn(`${at}`, "has both action and run — the host prefers run; pick one");
        if (hasRun && !actionIds.has(f.run))
          r.error(`${at}.run`, `references action "${f.run}" which is not defined in actions{}`);
        if (hasInline) {
          if (!isObj(f.action) || typeof f.action.kind !== "string")
            r.error(`${at}.action`, 'inline action needs at least a kind, e.g. { "kind": "volume", "value": "$value" }');
          else if (!ACTION_KINDS.includes(f.action.kind))
            r.error(`${at}.action.kind`, `"${f.action.kind}" not a safe action kind — one of ${ACTION_KINDS.join(", ")}`);
          if (isObj(f.action)) {
            if (SHELL_KINDS.has(f.action.kind)) needsShellCap = true;
            configRefsIn(f.action.value, configRefs);
          }
        }
      } else if (f.refreshKey === undefined && f.value === undefined) {
        r.warn(at, "neither refreshKey nor value — this field will always be blank");
      }
    });
  }

  // ── buttons (§5.3) ───────────────────────────────────────────────────────
  if (m.buttons !== undefined) {
    if (!Array.isArray(m.buttons)) r.error("buttons", "must be an array");
    else m.buttons.forEach((b, i) => {
      const at = `buttons[${i}]`;
      if (!isObj(b)) { r.error(at, "must be an object"); return; }
      const hasInline = b.action !== undefined;
      const hasRun = b.run !== undefined;
      if (!hasInline && !hasRun && !Array.isArray(b.states))
        r.error(at, "a button needs an inline action, a run:\"<actionId>\", or states[]");
      if (hasInline && hasRun)
        r.error(at, "has BOTH action and run — a button uses one or the other (§5.3)");
      if (hasRun && !actionIds.has(b.run))
        r.error(`${at}.run`, `references action "${b.run}" which is not defined in actions{}`);
      if (hasInline) {
        if (!isObj(b.action) || typeof b.action.kind !== "string")
          r.error(`${at}.action`, "inline action needs at least a kind, e.g. { \"kind\": \"media\", \"value\": \"playpause\" }");
        else if (!ACTION_KINDS.includes(b.action.kind))
          r.error(`${at}.action.kind`, `"${b.action.kind}" not a safe action kind — one of ${ACTION_KINDS.join(", ")}`);
        if (isObj(b.action)) {
          if (SHELL_KINDS.has(b.action.kind)) needsShellCap = true;
          configRefsIn(b.action.value, configRefs);
        }
      }
      // A states[] (toggle) button carries its label/symbol INSIDE each state, not
      // at the top level — so validate the states, not the wrapper. The host's
      // ManifestState decodes ONLY {label,symbol,action} — there is NO `run` on a
      // state (unlike a top-level button). A `run` on a state is silently ignored
      // by the host, leaving a dead state, so flag it as an error.
      if (Array.isArray(b.states)) {
        b.states.forEach((s, j) => {
          const sat = `${at}.states[${j}]`;
          if (!isObj(s)) { r.error(sat, "must be an object"); return; }
          if (s.run !== undefined)
            r.error(`${sat}.run`, "a state has no `run` — the host honors only an inline `action` on states; inline the action here");
          if (s.action !== undefined && isObj(s.action)) {
            if (SHELL_KINDS.has(s.action.kind)) needsShellCap = true;
            configRefsIn(s.action.value, configRefs);
          }
          if (s.label === undefined && s.symbol === undefined)
            r.warn(sat, "no label and no symbol — this state will be blank");
        });
      } else if (b.label === undefined && b.symbol === undefined) {
        r.warn(at, "no label and no symbol — the button will be blank");
      }
    });
  }

  // ── data axis: poll vs push are mutually exclusive (§5.4) ─────────────────
  if (m.refresh !== undefined && providerPresent)
    r.error("(root)", "a tile declares refresh (poll) OR provider (push), not both (§5.4)");

  // ── refresh (poll, §5.4) ─────────────────────────────────────────────────
  if (m.refresh !== undefined) {
    if (!isObj(m.refresh)) r.error("refresh", "must be an object");
    else {
      if (typeof m.refresh.command !== "string" || m.refresh.command === "")
        r.error("refresh.command", "required — a shell command whose stdout is parsed into tile state");
      // NB: the host runs the poll command UNGATED — it predates the capability
      // model, so v1 packs with a refresh + no capabilities[] still work. A refresh
      // command therefore does NOT require `shell`; only kind:"shell" / interpreter
      // / script actions do.
      if (typeof m.refresh.everySeconds !== "number")
        r.error("refresh.everySeconds", "required number — poll interval in seconds");
      else if (m.refresh.everySeconds < 2)
        r.warn("refresh.everySeconds", `${m.refresh.everySeconds}s is below the 2s host floor — it will be clamped to 2s`);
      if (m.refresh.parse !== undefined) {
        const p = m.refresh.parse;
        if (!isObj(p)) r.error("refresh.parse", "must be an object, e.g. { \"kind\": \"json\" }");
        else {
          if (p.kind !== undefined && !PARSE_KINDS.includes(p.kind))
            r.warn("refresh.parse.kind", `"${p.kind}" — expected ${PARSE_KINDS.join(" | ")}`);
          if (p.kind === "delimited") {
            if (typeof p.delimiter !== "string") r.error("refresh.parse.delimiter", "delimited parse needs a delimiter");
            if (!Array.isArray(p.fields) || p.fields.length === 0)
              r.error("refresh.parse.fields", "delimited parse needs fields[] (positional key names)");
          }
        }
      }
      configRefsIn(m.refresh.command, configRefs);
    }
  }

  // ── provider (push, §5.5/§10) ────────────────────────────────────────────
  if (m.provider !== undefined) {
    if (!isObj(m.provider)) r.error("provider", "must be an object");
    else {
      if (typeof m.provider.command !== "string" || m.provider.command === "")
        r.error("provider.command", "required — the long-lived process to spawn, e.g. \"node provider.js\"");
      if (m.provider.args !== undefined && !Array.isArray(m.provider.args))
        r.error("provider.args", "must be an array of strings");
      if (!declaredCaps.has("process"))
        r.error("capabilities", 'a provider needs the "process" capability — add it to capabilities[] or the host refuses to spawn');
    }
  }
  if (usesProviderAction && !providerPresent) { /* already reported per-action */ }

  // ── capability cross-checks (§8 / §9.3 L4) ───────────────────────────────
  if (m.capabilities !== undefined) {
    if (!Array.isArray(m.capabilities)) r.error("capabilities", "must be an array of strings");
    else m.capabilities.forEach((c) => {
      if (!CAPABILITIES.includes(c))
        r.warn("capabilities", `"${c}" is not a known capability — one of ${CAPABILITIES.join(", ")}`);
    });
  }
  if (needsShellCap && !declaredCaps.has("shell"))
    r.error("capabilities", 'this pack runs shell/interpreter commands (refresh, shell action, or script) but does not declare "shell" — the host will reject them');
  if (declaredCaps.has("secrets") && m.secrets === undefined && m.oauth === undefined)
    r.warn("capabilities", '"secrets" declared but no secrets[] or oauth block uses it');

  // ── secrets (§7) ─────────────────────────────────────────────────────────
  const secretKeys = new Set();
  if (m.secrets !== undefined) {
    if (!Array.isArray(m.secrets)) r.error("secrets", "must be an array");
    else m.secrets.forEach((s, i) => {
      const at = `secrets[${i}]`;
      if (!isObj(s) || typeof s.key !== "string" || s.key === "")
        r.error(`${at}.key`, "required — injected to the child as GATECASTER_SECRET_<KEY>");
      else secretKeys.add(s.key);
    });
    if (m.secrets.length > 0 && !declaredCaps.has("secrets"))
      r.warn("capabilities", 'secrets[] declared but the "secrets" capability is not — add it for disclosure');
  }

  // ── oauth (§7) ───────────────────────────────────────────────────────────
  if (m.oauth !== undefined) {
    if (!isObj(m.oauth)) r.error("oauth", "must be an object");
    else {
      if (typeof m.oauth.authUrl !== "string") r.error("oauth.authUrl", "required — the provider's authorize URL");
      if (m.oauth.redirect !== undefined && !OAUTH_REDIRECTS.includes(m.oauth.redirect))
        r.warn("oauth.redirect", `"${m.oauth.redirect}" — expected ${OAUTH_REDIRECTS.join(" | ")}`);
      if (m.oauth.redirect === "scheme" && typeof m.oauth.scheme !== "string")
        r.error("oauth.scheme", 'redirect:"scheme" needs a scheme, e.g. "x-gatecaster"');
      if (m.oauth.store !== undefined && secretKeys.size > 0 && !secretKeys.has(m.oauth.store))
        r.warn("oauth.store", `"${m.oauth.store}" is not a declared secret key — the captured token has nowhere named to land`);
    }
  }

  // ── config schema (§6) ───────────────────────────────────────────────────
  const configKeys = new Set();
  if (m.configSchema !== undefined) {
    if (!Array.isArray(m.configSchema)) r.error("configSchema", "must be an array");
    else m.configSchema.forEach((c, i) => {
      const at = `configSchema[${i}]`;
      if (!isObj(c)) { r.error(at, "must be an object"); return; }
      if (typeof c.key !== "string" || c.key === "")
        r.error(`${at}.key`, "required — surfaces to commands/provider as $config.<key>");
      else configKeys.add(c.key);
      if (c.type !== undefined && !CONFIG_TYPES.includes(c.type))
        r.warn(`${at}.type`, `"${c.type}" unknown — expected ${CONFIG_TYPES.join(" | ")}`);
      if (c.type === "connect-button" && typeof c.action !== "string")
        r.error(`${at}.action`, "a connect-button needs an action (the named action it fires, e.g. pairing/oauth)");
      if (c.type === "connect-button" && c.action && !actionIds.has(c.action))
        r.warn(`${at}.action`, `references action "${c.action}" not defined in actions{}`);
      if (c.type === "select" && !Array.isArray(c.options) && c.source === undefined)
        r.warn(`${at}`, "a select needs options[] or source:\"provider:<key>\"");
      // The host decodes options as [String] only. A [{value,label}] array (the
      // shape some specs use) throws on decode and DROPS THE WHOLE MANIFEST — the
      // tile silently never appears. Demand plain strings.
      if (Array.isArray(c.options) && !c.options.every((o) => typeof o === "string"))
        r.error(`${at}.options`, "options must be an array of plain strings (e.g. [\"local\",\"cloud\"]) — objects like {value,label} throw on host decode and drop the entire manifest");
    });
  }

  // ── $config reference cross-check (catches typos that expand to nothing) ──
  for (const ref of configRefs) {
    if (!configKeys.has(ref) && !secretKeys.has(ref))
      r.warn("$config", `$config.${ref} is used but "${ref}" is not in configSchema[] or secrets[] — it will expand to empty`);
  }

  return r;
}
