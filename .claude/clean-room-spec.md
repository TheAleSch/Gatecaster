# Gatecaster Plugin Docs — Violation Spec

Project: Gatecaster — clean-room reimplementation of Elgato Stream Deck plugins for macOS.
Docs under review may describe ONLY: public API facts, observable behaviors,
and independently designed Gatecaster architecture.

Derived from `docs/plugins/00-clean-room-methodology.md` (the methodology doc, which
binds the placeholder mappings) and the clean-room-doc-review spec template's worked
example for this project. TARGET of this audit: `docs/plugins/` specs `01`–`06`.
The methodology doc `00` is the METHODOLOGY_DOC — trademark mentions in its explanatory
scope are exempt; original identifiers in it are still violations.

## Exact-match list (Pass 1 grep)

Trademarks (allowed only in methodology doc's explanatory scope):
- Elgato
- Stream Deck / StreamDeck / Stream-Deck / "Stream Deck XL" / "Stream Deck +" / "Stream Deck Mini"
- Property Inspector  (original trade name for the config panel)
- Smart Profile / Smart Profiles
- Multi Action / Multi-Action
- Wave Link / WaveLink  (Elgato audio product, possible original of the volume plugin)

Original identifiers (never allowed anywhere, including methodology doc):
- `com.elgato.`  (reverse-DNS plugin/action prefix)
- `sdpi-`  / `sdpi-components`  (Stream Deck Property Inspector CSS/component prefix)
- SDK lifecycle / API method names (source-only unless on the public-facts list):
  `willAppear`, `willDisappear`, `keyDown`, `keyUp`, `dialRotate`, `dialDown`, `dialUp`,
  `touchTap`, `didReceiveSettings`, `didReceiveGlobalSettings`, `sendToPlugin`,
  `sendToPropertyInspector`, `setImage`, `setFeedback`, `setTitle`, `setSettings`,
  `setGlobalSettings`, `showAlert`, `showOk`
- SDK manifest field names used verbatim: `Controller` (["Keypad","Encoder"]), `Keypad`,
  `Encoder` (as SDK action-type tokens), `.sdPlugin`, `.deckProfile`/`.streamDeckProfile`
- Original helper/entrypoint filenames if echoed: `app.js`, `pi.js` with SDK structure

## Known-original names (Pass 2, category 3) — reconstructed source names

Class/function/variable names reconstructed from original plugin source. Exact match =
violation; remediation is a rename to a behavioral description or independent name.
Generic-sounding ones still flagged on exact match, rated lower confidence.

- `AudioDeviceEngine`, `DeviceVolumeAction`, `AudioProcessState`, `AudioProcessTracker`,
  `CoreAudioAdapter`, `GridProfileEngine`, `AppVolumeAction`  (spec 01)
- `DeckConnection`, `ActionPanel`  (spec 01 config-panel libs — mirror SDK `StreamDeckConnection`/base PI classes)
- Action-tree structure tokens remapped 1:1 from the original (category 6/7 when the
  whole tree is preserved): `auto-detection`, `auto-detection.mute`,
  `auto-detection.volume(-up/-down)`, `auto-detection.next/previous/blank`,
  `back-to-profile`, `manual-detection`, `input-device-control`, `output-device-control`
- Any `com.gatecaster.<plugin>.<...>` UUID tree that is a 1:1 remap of the original's
  action hierarchy (the remap preserves copyrightable structure even with a new prefix)
- Persisted settings key names copied from the original: `appDisplayMode`, `stepSize`,
  `controlAction`, `displayStyle`, `deviceKey` (flag on exact match; rate by distinctiveness)
- Other plugin specs — watch for reconstructed names: any PascalCase `*Action`,
  `*Panel`, `*Engine`, `*Tracker`, `*Adapter` class not independently introduced.

## Known-public facts (do NOT flag)

- **Hue:** REST API v1 & v2 (CLIP), `/api`, EventStream (SSE), bridge discovery via
  `discovery.meethue.com` and mDNS `_hue._tcp`, link-button pairing, `username`/app-key concept.
- **Slack:** Web API methods `users.profile.set`, `dnd.setSnooze`, `chat.postMessage`,
  `users.getPresence`; OAuth 2.0 scopes; `slack://` URL scheme.
- **Spotify:** public AppleScript dictionary (`player state`, `current track`, etc.);
  Spotify Web API; `spotify:` URIs.
- **Zoom / Meetings:** observable keyboard shortcuts (⌘⇧A mute, etc.); `zoommtg://`,
  `calls://`, Google Meet/Teams URL schemes; menu-item names visible in the UI.
- **macOS:** CoreAudio (`AudioObjectGetPropertyData`/`SetPropertyData`,
  `kAudioDevicePropertyVolume`, `kAudioDevicePropertyMute`,
  `kAudioHardwarePropertyProcessObjectList`, `kAudioObjectPropertyScope*`), Audio Tap API
  (`AudioHardwareCreateProcessTap`, `CATapDescription`), System Events, `osascript`, JXA,
  `NSWorkspace`, `SwitchAudioSource` (public CLI). These are platform facts, not leakage.
- User-visible error/toast strings are observable facts; internal log strings are not.
