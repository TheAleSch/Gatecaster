#!/usr/bin/env node
// gatecaster — author, validate, and install Gatecaster Deck extensions.
//
// Zero dependencies, ESM, Node ≥ 18. The CLI is the authoring on-ramp called for in
// PLATFORM_SPEC §5.8: `new` scaffolds a pack, `validate` mirrors the host's accepted
// schema so mistakes are caught before Reload (the host tolerant-decodes and would
// otherwise drop a bad pack silently), `install` runs the dev loop.
//
// Business guardrail (§5.9): authoring + the dev loop are free. This tool never runs
// an extension — it only writes/validates/copies pack files. Extensions execute only
// inside the Pro-gated Deck. Keep it that way.

import { readFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { validateManifest } from "../lib/schema.js";
import { scaffold, TEMPLATE_NAMES } from "../lib/scaffold.js";
import { install, list, uninstall, EXT_DIR } from "../lib/install.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

// tiny ANSI helpers (skip color when not a TTY / NO_COLOR set)
const tty = process.stdout.isTTY && !process.env.NO_COLOR;
const c = (n) => (s) => (tty ? `\x1b[${n}m${s}\x1b[0m` : String(s));
const red = c(31), green = c(32), yellow = c(33), dim = c(2), bold = c(1);

const die = (msg) => { console.error(red("error: ") + msg); process.exit(1); };

// minimal flag parser: collects --k v / --k=v / --bool, leaves positionals in _
function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const eq = a.indexOf("=");
      if (eq !== -1) out[a.slice(2, eq)] = a.slice(eq + 1);
      else if (i + 1 < argv.length && !argv[i + 1].startsWith("--")) out[a.slice(2)] = argv[++i];
      else out[a.slice(2)] = true;
    } else out._.push(a);
  }
  return out;
}

function printReport({ errors, warnings }) {
  for (const w of warnings) console.log(yellow("  warn  ") + dim(w.where) + "  " + w.msg);
  for (const e of errors) console.log(red("  error ") + bold(e.where) + "  " + e.msg);
}

async function cmdNew(args) {
  const id = args._[0];
  if (!id) die("usage: gatecaster new <id> [--template static|poll|push] [--name \"Name\"]");
  const template = args.template || "poll";
  try {
    const { dest } = await scaffold({ id, template, name: args.name, dir: args.dir });
    console.log(green("✓ created ") + bold(dest) + dim(`  (${template})`));
    console.log(dim("  next: ") + `gatecaster validate ${dest}  &&  gatecaster install ${dest}`);
    if (template === "push") console.log(dim("  push pack: edit provider.js, then Reload Extensions in the Deck"));
  } catch (e) { die(e.message); }
}

async function loadManifest(dir) {
  const p = join(dir, "manifest.json");
  let raw;
  try { raw = await readFile(p, "utf8"); }
  catch { die(`no manifest.json at ${p}`); }
  try { return JSON.parse(raw); }
  catch (e) { die(`manifest.json is not valid JSON: ${e.message}`); }
}

async function cmdValidate(args) {
  const dir = args._[0] || process.cwd();
  const m = await loadManifest(dir);
  const report = validateManifest(m);
  printReport(report);
  if (report.errors.length) {
    console.log(red(`\n✗ ${report.errors.length} error(s)`) + dim(`, ${report.warnings.length} warning(s)`));
    process.exit(1);
  }
  console.log(green(`\n✓ valid`) + dim(`  ${report.warnings.length} warning(s) — ${m.id}`));
}

async function cmdInstall(args) {
  const dir = args._[0] || process.cwd();
  const res = await install(dir, { force: !!args.force });
  printReport(res);
  if (!res.ok) {
    console.log(red(`\n✗ refused to install — fix errors above, or --force to override`));
    process.exit(1);
  }
  console.log(green("✓ installed ") + bold(res.id) + dim("  → " + res.dest));
  console.log(dim("  open the Deck → Reload Extensions to pick it up"));
}

async function cmdList() {
  const items = await list();
  if (!items.length) { console.log(dim("no extensions installed in ") + EXT_DIR); return; }
  console.log(dim(EXT_DIR + "\n"));
  for (const it of items)
    console.log("  " + bold(it.id) + dim(`  v${it.v ?? "?"}`) + "  " + it.name);
}

async function cmdUninstall(args) {
  const id = args._[0];
  if (!id) die("usage: gatecaster uninstall <id>");
  try { const { dest } = await uninstall(id); console.log(green("✓ removed ") + dest); }
  catch (e) { die(e.message); }
}

async function version() {
  const pkg = JSON.parse(await readFile(join(__dirname, "..", "package.json"), "utf8"));
  console.log(pkg.version);
}

function help() {
  console.log(`${bold("gatecaster")} — author & install Gatecaster Deck extensions

${bold("usage")}
  gatecaster new <id> [--template ${TEMPLATE_NAMES.join("|")}] [--name "Name"]
  gatecaster validate [dir]        check manifest against schema v2 (defaults to .)
  gatecaster install  [dir]        validate, then install into the Deck (--force to skip errors)
  gatecaster list                  list installed extensions
  gatecaster uninstall <id>        remove an installed extension

${bold("templates")}
  static   buttons only (keystrokes / apps / shortcuts) — no data
  poll     fields refreshed by a command on a timer (the 90% path)
  push     a long-lived NDJSON provider that pushes state (opt-in)

extensions install to:
  ${dim(EXT_DIR)}

authoring & the dev loop are free; extensions run only inside the Pro Deck.`);
}

const COMMANDS = {
  new: cmdNew, validate: cmdValidate, install: cmdInstall,
  list: cmdList, uninstall: cmdUninstall,
};

const [cmd, ...rest] = process.argv.slice(2);
if (!cmd || cmd === "help" || cmd === "--help" || cmd === "-h") { help(); process.exit(0); }
if (cmd === "version" || cmd === "--version" || cmd === "-v") { await version(); process.exit(0); }
const handler = COMMANDS[cmd];
if (!handler) die(`unknown command "${cmd}" — run \`gatecaster help\``);
await handler(parseArgs(rest));
