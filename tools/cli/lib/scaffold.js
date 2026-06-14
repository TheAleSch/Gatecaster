// `gatecaster new <id>` — scaffold a fresh extension pack from a template.
//
// The whole point of the authoring ladder (§5.8) is that complexity is OPT-IN: a
// static board is ~10 lines, poll adds a refresh block, push adds a provider. So
// `new` takes a --template that picks the rung you start on, copies the matching
// template dir, and substitutes the id/name. Push packs also get the provider shim
// copied in so the pack is self-contained (zero install, zero deps).

import { cp, readFile, writeFile, mkdir, readdir, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const TEMPLATES = join(__dirname, "..", "templates");

export const TEMPLATE_NAMES = ["static", "poll", "push"];

// reverse-DNS-ish id → a human default name ("com.you.now-playing" → "Now Playing")
function humanizeName(id) {
  const last = id.split(".").pop() || id;
  return last.replace(/[-_]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

// Recursively substitute __ID__/__NAME__ in every text file just copied.
async function substitute(dir, id, name) {
  for (const entry of await readdir(dir)) {
    const p = join(dir, entry);
    if ((await stat(p)).isDirectory()) { await substitute(p, id, name); continue; }
    const text = await readFile(p, "utf8");
    if (text.includes("__ID__") || text.includes("__NAME__"))
      await writeFile(p, text.replaceAll("__ID__", id).replaceAll("__NAME__", name));
  }
}

export async function scaffold({ id, template = "poll", name, dir }) {
  if (!id || !/^[A-Za-z0-9][A-Za-z0-9.\-]*$/.test(id))
    throw new Error(`invalid id "${id}" — use reverse-DNS like com.you.thing (letters, digits, dot, hyphen)`);
  if (!TEMPLATE_NAMES.includes(template))
    throw new Error(`unknown template "${template}" — one of ${TEMPLATE_NAMES.join(", ")}`);

  const src = join(TEMPLATES, template);
  const dest = dir || join(process.cwd(), id);
  if (existsSync(dest)) throw new Error(`destination already exists: ${dest}`);

  await mkdir(dest, { recursive: true });
  await cp(src, dest, { recursive: true });

  // Push packs ship the provider shim alongside, so the pack runs with no npm install.
  if (template === "push")
    await cp(join(TEMPLATES, "provider", "gatecaster-provider.js"), join(dest, "gatecaster-provider.js"));

  await substitute(dest, id, name || humanizeName(id));
  return { dest, template };
}
