# gatecaster-extensions (Claude plugin)

Teaches Claude (or any skill-aware agent) to author **Gatecaster Deck extensions** —
`manifest.json` tiles with fields/buttons, an optional poll `refresh` command, or a
push NDJSON `provider` — and to drive the `gatecaster` CLI to scaffold, validate, and
install them.

## What's inside

- `skills/gatecaster-extension/SKILL.md` — the skill (mental model, workflow, hard rules).
- `skills/gatecaster-extension/references/` — schema reference, copy-ready examples,
  and the provider push protocol.

It pairs with the **`gatecaster` npm CLI** (`tools/cli`): `gatecaster new|validate|
install|list`. Install the CLI globally (`npm i -g gatecaster`) or run via
`npx gatecaster` so the skill's commands work.

## Install

**As a Claude Code plugin** — point your marketplace/plugin config at this folder
(it contains `.claude-plugin/plugin.json`), or copy
`skills/gatecaster-extension/` into `~/.claude/skills/` to use the skill standalone.

The skill activates when you ask to build, scaffold, validate, or debug a Gatecaster
extension.

## Scope

Authoring is free and offline. Extensions run only inside the Pro-gated Gatecaster
Deck; the skill never instructs running an extension outside it.
