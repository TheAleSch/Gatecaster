// `gatecaster install [dir]` / `list` / `uninstall <id>` — the dev loop.
//
// The host loads packs from a fixed Application Support folder and re-reads it on
// "Reload Extensions". So install = validate, then copy the pack folder to
// <support>/Extensions/<id>/. We validate FIRST and refuse to install a broken
// manifest, because the host tolerant-decodes — a bad pack silently vanishes on
// Reload instead of erroring, which is miserable to debug. Better to fail loudly here.

import { cp, mkdir, readFile, readdir, rm, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { validateManifest } from "./schema.js";

export const EXT_DIR = join(
  homedir(), "Library", "Application Support", "Gatecaster", "Extensions",
);

async function readManifest(dir) {
  const p = join(dir, "manifest.json");
  if (!existsSync(p)) throw new Error(`no manifest.json in ${dir}`);
  let raw;
  try { raw = await readFile(p, "utf8"); }
  catch (e) { throw new Error(`cannot read ${p}: ${e.message}`); }
  let m;
  try { m = JSON.parse(raw); }
  catch (e) { throw new Error(`manifest.json is not valid JSON: ${e.message}`); }
  return m;
}

export async function install(dir = process.cwd(), { force = false } = {}) {
  const m = await readManifest(dir);
  const { errors, warnings } = validateManifest(m);
  if (errors.length && !force)
    return { ok: false, id: m.id, errors, warnings };

  const dest = join(EXT_DIR, m.id);
  await mkdir(EXT_DIR, { recursive: true });
  if (existsSync(dest)) await rm(dest, { recursive: true, force: true }); // clean reinstall
  await cp(dir, dest, { recursive: true });
  return { ok: true, id: m.id, dest, errors, warnings };
}

export async function list() {
  if (!existsSync(EXT_DIR)) return [];
  const out = [];
  for (const entry of await readdir(EXT_DIR)) {
    const dir = join(EXT_DIR, entry);
    if (!(await stat(dir)).isDirectory()) continue;
    try {
      const m = await readManifest(dir);
      out.push({ id: m.id ?? entry, name: m.name ?? "?", v: m.v ?? 1 });
    } catch {
      out.push({ id: entry, name: "(unreadable manifest)", v: null });
    }
  }
  return out;
}

export async function uninstall(id) {
  const dest = join(EXT_DIR, id);
  if (!existsSync(dest)) throw new Error(`not installed: ${id}`);
  await rm(dest, { recursive: true, force: true });
  return { id, dest };
}
