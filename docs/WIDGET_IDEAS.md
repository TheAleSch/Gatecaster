# Widget & extension ideas

Guiding principle (per Ale): **keep the app lean.** A small set of genuinely
universal widgets ship built-in; everything else is an installable **extension**
from a registry the user browses. The app shouldn't bloat as the catalog grows.

## What ships built-in (small, universal, needs native code)

These are either tiny or need real local logic the declarative manifest can't
express, and almost everyone wants them:

- **Clock** — time + date (24h option). ✅ shipped
- **Volume** — drag slider. ✅ shipped
- **Media** — play/pause/next via real media keys. ✅ shipped (fixed)
- **Battery** — level + charging. ✅ shipped
- **CPU load** — live %. ✅ shipped
- **Claude usage** — local-log token windows. ✅ shipped

Candidates to *consider* built-in (still universal, light):

- **RAM / memory pressure** — like CPU, via `host_statistics`.
- **Timer / Pomodoro** — countdown + work/break cycles, local only.
- **Window mover** — snap front window left/right/full (Rectangle-style) via
  Accessibility (we already have AX). Useful and on-brand for a touch driver.

## What should be EXTENSIONS (not built-in)

Anything tied to a third-party service, a niche workflow, or a big dependency.
These are exactly where a registry pays off — install only what you use:

- **OBS Studio** — scene switch, start/stop stream, mute sources. (OBS
  WebSocket; the #1 Stream Deck plugin.)
- **Spotify** — now-playing + transport + playlists (Web API + token).
- **Discord** — mute/deafen/push-to-talk, channel hop.
- **Philips Hue / smart home** — scenes, on/off, brightness.
- **Multi-timezone clocks** — a clock pack with configurable zones.
- **GPU / temps / fan** — needs vendor tools; not everyone has them.
- **Twitch / YouTube** — chat, markers, go-live.
- **Figma** — see below.
- **Calendar / next meeting**, **GitHub notifications**, **Home Assistant**,
  **Elgato Key Light**, **stock/crypto ticker**, **weather**, **CI/build status**.

Stream Deck has **4,000+ plugins** across exactly these categories (OBS, Spotify,
Discord, Hue, Twitch/YouTube lead) — strong evidence the registry model is the
right call and that these belong as opt-in installs, not core app weight.

## The Figma extension (concept)

What's actually possible matters here. Figma's REST API is **read-only** and you
**cannot trigger a Figma plugin or run commands from outside** the app. So a
Gatecaster Figma extension realistically does two things:

1. **Fire Figma's own keyboard shortcuts** while Figma is frontmost — our
   `keystroke` action already does this. Pick from a list (Frame, Component,
   Toggle UI, Dev Mode, Pen, etc.) and drop them on the deck as buttons. This is
   the "pick from a list to trigger stuff" flow.
2. **Display read-only data** via the REST API with a personal token (file name,
   variables/design tokens, last-modified) using a `refresh` command.

A starter version ships as
[`examples/extensions/com.figma.shortcuts/`](../examples/extensions/com.figma.shortcuts/manifest.json):
a tile of common Figma shortcut buttons. A richer version (token-authed variable
readout, a picker UI to browse and add shortcut buttons) is a registry
extension, not core.

## Registry (deferred — task #43)

The catalog above is the argument for a registry: browse, one-tap install,
publish. Built-ins stay minimal; the registry carries the long tail. Tiering
(declarative manifest → out-of-process/JSCore data provider → WebView for custom
UI) is task #36; the registry itself is task #43.

## Sources
- https://streamdeck-plugins.com/  (unofficial plugin catalog)
- https://www.elgato.com/us/en/explorer/products/stream-deck/stream-deck-plugins-for-streaming/
- https://wellingbeanbags.com/best-stream-deck-plugins/
- https://developers.figma.com/docs/rest-api/  (REST API is read-only)
- https://forum.figma.com/t/programmatically-trigger-a-plugin/35601  (can't trigger plugins externally)
- https://www.figma.com/plugin-docs/how-plugins-run/
