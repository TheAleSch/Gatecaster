# Gatecaster Deck — plan (v3 track, PoC first)

The Deck turns the touchscreen itself into a Stream Deck-style control surface:
a grid of tappable buttons, sliders, and (later) knobs that live on the touch
display, fully integrated with the driver. No phone, no extra hardware, no
account.

## What users complain about in existing solutions (research, June 2026)

**Elgato Stream Deck (software)**
- Keys turn into question marks when a plugin is missing — profiles don't
  survive moving between machines.
- Profile/page copying bugs (nested folders lost), stale icons after profile
  switches, Smart Profiles only work while the app is minimized.
- Requires the hardware ($80–250); the software exists to sell the device.

**Touch Portal**
- Needs a separate phone/tablet running a companion app; battery drain.
- Feature-gated free tier; pay to unlock basics.
- Blocked by some game anti-cheat systems.
- Dated, cluttered editor UI.

**Loupedeck / Logitech**
- Editor UX repeatedly called "show-stoppingly difficult": no drag of buttons,
  no copy/paste of actions, custom icons buried several menus deep.
- Plugin ecosystem version-locked (Razer plugins stuck on an old release);
  broken login auth for new users.
- Hardware discontinued March 2025 → users orphaned. Lesson: don't tie the
  product to hardware or a mandatory cloud.

**DIY (Companion, ESP32 builds, Macro Deck)**
- Powerful but technical; macOS is a second-class citizen almost everywhere.

## Design principles (each one answers a complaint above)

1. **Runs on the touchscreen you already have** — no phone, no $250 pad.
2. **Editing is direct manipulation**: tap to edit, drag to reorder,
   copy/paste buttons. Never bury an icon picker three menus deep.
3. **Layouts are one portable JSON file** — export/import anywhere, no cloud
   required, human-readable, versioned schema.
4. **Graceful degradation**: a button whose app/shortcut is missing shows a
   clear badge, never a mystery "?", and keeps its configuration.
5. **macOS-native first**: Apple Shortcuts as a first-class action — one
   action type gives users access to their entire automation library.
6. **No login. Ever — for core function.** Sync (if built) is optional sugar.

## Phases

### PoC — this branch (`v3-deck-poc`) ✅ implemented
Goal: feel it on the screen, validate the concept.
- Deck panel using the existing panel system (drag from top bar, resize bean,
  non-activating — never steals focus).
- Button grid, multiple pages, configurable column count.
- Actions: open app, open URL, keystroke (e.g. `cmd+shift+4`), run Apple
  Shortcut, shell command, set volume.
- Edit mode: tap a button to configure (title, SF Symbol icon, color, action),
  drag to reorder, add/delete buttons and pages.
- Volume slider (vertical) as the first non-button control.
- Import / Export layout as JSON (`.gatedeck`).
- Persistence: `~/gatecaster-deck.json`, debounced atomic writes.

### MVP (validate with real users, 2–4 weeks)
- Custom image icons (drag a PNG onto a button) + icon pack folder.
- Per-app pages: deck auto-switches page when the frontmost app changes
  (the per-app gestures groundwork shares this detection).
- More actions: media keys (play/pause/next), system sleep/lock, text snippet
  paste, open file/folder, window management (left/right half).
- Button copy/paste; page duplication (the Loupedeck complaint, fixed).
- Missing-target badge + "fix" flow.
- Multi-select + alignment in edit mode.

### Beta
- **Plugin API v0**: local JSON manifest + executable hook, building on
  docs/DEVELOPER_API.md. A plugin contributes action types (e.g. OBS scene
  switch, Spotify, Home Assistant). Versioned manifest so plugins never hard-
  break layouts (only badge as missing).
- Knobs: rotary touch control (circular drag) bindable to volume/brightness/
  scroll/plugin values.
- Pack format: `.gatedeck` bundles layout + icons + plugin references.
- Onboarding templates: starter decks for Streaming / Editing / Productivity.

### v1 (ship with Gatecaster 2.x)
- **Marketplace v0 — no accounts**: a curated public repo (or static site)
  of `.gatedeck` packs, browsed in-app, one-tap install. Free packs only.
  This tests demand for a real marketplace with zero backend cost.
- Brightness/secondary sliders; slider binding to plugin values.
- Polish pass: accessibility, localization of the deck UI.

### v2 (only if v1 proves demand)
- **Optional login + sync**: BetterAuth on a Next.js site (same site as the
  store/licensing). Sync layouts + packs across Macs. Strictly optional —
  the local JSON file remains the source of truth.
- Community marketplace: creator uploads, ratings, paid packs (rev share TBD).
- Hardware knob/pedal companions via the generic HID layer (M2 work).

## Schema sketch (PoC, already shipping)

```json
{
  "columns": 4,
  "showVolumeSlider": true,
  "pages": [{
    "id": "…", "name": "Main",
    "buttons": [{
      "id": "…", "title": "Screenshot", "symbol": "camera.viewfinder",
      "colorHex": "#2E6CF6",
      "action": { "kind": "keystroke", "value": "cmd+shift+4" }
    }]
  }]
}
```

`kind` ∈ `app | url | keystroke | shortcut | shell | volume | none`.
Schema carries no version field yet; MVP adds `"schema": 1` before any
breaking change.

## Sources

- https://forum.keyboardmaestro.com/t/touchportal-vs-stream-deck/28522
- https://medium.com/technotim/touch-portal-vs-stream-deck-df9ef1366b33
- https://talk.macpowerusers.com/t/loupedeck-live-vs-stream-deck/24957
- https://community.troikatronix.com/topic/8687/loupedeck-vs-streamdeck
- https://techpoint.africa/guide/best-stream-deck-alternatives-tested/
- https://help.elgato.com/hc/en-us/articles/15894171000333 (plugin "?" keys)
- https://help.elgato.com/hc/en-us/articles/360053419071 (Smart Profiles limitation)
- https://www.kitze.io/posts/stream-deck-for-free
- https://www.xda-developers.com/how-to-use-macro-pad-as-stream-deck-alternative/
