# Gatecaster — Product Plan

*Turn the working V17UT driver into a sellable macOS product.*
*Status: plan for review — nothing here is built yet unless marked ✅.*

---

## 1. What Gatecaster is (positioning)

**"Run your whole Mac from a touchscreen."**
Not a driver-with-settings like UPDD — a **productivity tool for fully standalone
touch use**: no mouse, no trackpad, no keyboard required. The touchscreen IS the
input device: pointer + tap + drag, momentum scrolling, native pinch-zoom and
rotate, desktop switching, a full on-screen keyboard with international layouts,
a virtual trackpad for reaching other displays, edge gestures, and a floating
launcher — with calibration, per-display mapping, and deep tuning.

UPDD sells hardware compatibility to enterprises; Gatecaster sells a *complete
touch-first workflow* to individuals. Different products that happen to share a
foundation.

**Who buys it:** owners of portable USB-C/HDMI touch monitors (the huge
Amazon/AliExpress category the V17UT belongs to), Mac-mini-in-the-kitchen /
wall-mounted setups, kiosk/POS builders, accessibility users, and anyone who
wants a couch-or-counter Mac with zero peripherals.

## 2. Competitive landscape

| | Price | Notes |
|---|---|---|
| **Touch-Base UPDD** | ~$109 personal / ~$171 commercial, per computer (+12% for ongoing support) | The incumbent since the 90s. Powerful but enterprise-priced and enterprise-feeling. |
| **Touch-Up** (open source) | Free | Basic clicks/scroll/zoom; doesn't wake ELAN-family panels at all (our discovery); no keyboard/trackpad/legacy mode. |
| **Apple** | — | No touchscreen support on macOS, no sign of it coming. |

**The gap Gatecaster fills:** consumer-priced, consumer-polished, and feature-
deeper than both (on-screen keyboard, virtual trackpad, gesture engines,
edge gestures, calibration UX). Verify current UPDD pricing before launch copy.

## 3. Pricing (proposal)

- **$24 one-time** per Mac, personal license (impulse-buy zone; ~4–7× cheaper
  than UPDD). Optionally $49 "business" tier later.
- **14-day full trial** — the product sells itself in the first minute of touch
  working; a trial converts better than a crippled free tier.
- Payments + license issuance via **Lemon Squeezy or Paddle** (merchant of
  record → they handle EU VAT etc.; fees ≈ 5% + $0.50 — verify current).
  Public-key-signed license file, offline grace, check kept OUT of the input path.

## 4. Milestones

### M1 — Become a real app (1–2 sessions) ← foundation, do first
- [ ] .app bundle: Info.plist, bundle ID (`com.<you>.gatecaster`), LSUIElement,
      app icon (the 👆 needs a real icon), version/build numbers.
- [ ] Permissions tied to bundle identity; first-run permission flow verified.
- [ ] Build script: release build → sign (Developer ID) → notarize → staple → DMG.

### M2 — Generic HID controller support (the market multiplier)
- [ ] Match by HID usage (Digitizer 0x0D / TouchScreen 0x04), not VID/PID.
- [ ] Standard enable: HID Device Mode feature → MS-cert read fallback →
      per-vendor quirk table (ELAN = quirk #1, already proven).
- [ ] Report-descriptor parsing for contact/X/Y/tip offsets + logical maxima.
- [ ] About tab already shows the live controller ✅.
- [ ] Beta-test call: "have a touch monitor that doesn't work on Mac? try this."

### M3 — Update + license infrastructure
- [ ] Sparkle 2 (EdDSA keys, appcast hosted with the site).
- [ ] License: LS/Paddle webhook → signed license file; in-app entry UI;
      14-day trial clock; offline grace ≥ 30 days.

### M4 — First-run experience & polish
- [ ] Onboarding sequence: welcome → permissions → display pick (numbered
      overlay ✅) → calibration ✅ → "try these gestures" card.
- [ ] Menu-bar icon states (active / no device / no permission).
- [ ] Shrink debug visuals behind the Debug menu ✅.

### M5 — Launch
- [ ] Landing page: 30-second demo video (touch dead → install → everything
      works), feature grid, comparison table, FAQ, buy button.
- [ ] Privacy policy (trivial honestly: no network calls except updates/license,
      no telemetry).
- [ ] Channels: Product Hunt, r/macapps, r/hackintosh-adjacent communities,
      Amazon-review threads of portable touch monitors ("works on Mac with…").

### M6 — Post-launch (v1.x maintenance)
- [ ] Opt-in diagnostics (device descriptor dump → quirk submissions from users
      = hardware support flywheel).
- [ ] Localization (the keyboard already speaks 7 layouts; the UI should too).

---

## Version roadmap (beyond v1)

### v2 — The productivity release
- **Stream Deck-style launcher**: evolve the floating control into a
  configurable grid of touch buttons — app launchers, shortcuts, macros,
  scripts, system toggles. Resizable, paged, per-user layouts. This is the
  feature that makes Gatecaster a daily productivity tool rather than a driver,
  and a natural upsell/marketing hook ("a Stream Deck built into your monitor").
  *Honest sizing: the engine work is small — the cost is the integrations
  (launch app, Shortcuts, AppleScript, URL schemes, system toggles, macros) and
  the configuration UI for them. That's most of v2's effort.*
- **Per-app gesture profiles** (the one UPDD idea worth adopting): gesture →
  action overrides keyed by frontmost app bundle ID. The settings model already
  centralizes gesture behavior, so this is a mapping layer on top.
- Emoji picker + autocomplete bar on the keyboard (already on the wishlist).
- Companion iPad app (network touch surface) — Sidecar can't, we can.
- Developer API (socket spec drafted in DEVELOPER_API.md ✅).

### v3 — The multi-surface release
- **Multiple simultaneous touch panels**, each with its own calibration,
  display mapping, and engine instance (per-device `Engine` + per-device
  settings namespace — significant refactor, gated on v2 revenue).
- Multi-Mac / KVM-ish scenarios, panel-specific launcher layouts.

## 5. Engineering hardening before strangers run it
- QA matrix: macOS 13/14/15/26 × Intel/Apple Silicon × 1–3 displays.
- The watchdogs already added (input wedge, HID buffer, lift recovery) ✅.
- Crash → relaunch resilience (login item + automatic restart).
- A "panic key" documented (any hardware keypress breaks a stuck drag).

## 6. Risks
- **macOS changes** the private gesture-event fields (Smooth mode breaks) →
  Legacy mode is the built-in fallback; field map is config-able internally.
- **TCC friction**: two permission prompts scare novices → onboarding M4 exists
  precisely for this.
- **Hardware zoo**: controllers with weird descriptors → quirk table + opt-in
  diagnostics turn users into test coverage.
- **Cloning**: accept it; price low, update often, own the niche's mindshare.

## 7. Success metrics
- Beta: 25 external testers, ≥3 non-ELAN controllers working.
- Launch month: 200 trials, 25% conversion ≈ $1.2k — validates continuing.
- Support load < 2 emails/day (else fix onboarding, not inbox).
