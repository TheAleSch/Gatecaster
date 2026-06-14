# Gatecaster Onboarding — Design Spec

**Date:** 2026-06-10
**Branch:** `onboarding`
**Status:** Approved design pending user review of this document

## Goal

A Raycast-quality first-run experience shown *before* the current "which
monitor has touch" picker. Four steps: **Welcome → Permissions → Monitor →
Calibration**, opened by a full-screen "vortex" intro animation that collapses
a starfield through an event horizon into the centered onboarding window.

## Who sees it

- **Fresh installs** (no settings file / `hasOnboarded == false`): full flow.
- **Existing users missing a permission** at launch: onboarding opens directly
  on the Permissions step (no intro animation, no welcome).
- Existing users with everything granted and a display picked: never see it.
  Migration sets `hasOnboarded = true` when `hasPickedDisplay == true`.
- Re-runnable any time via a **"Setup Assistant…"** menu-bar item (starts at
  Welcome, with intro).

## Flow

```
launch
  └─ hasOnboarded? ──yes──► permissions OK? ──yes──► normal startup
        │no                      │no
        ▼                        ▼
  vortex intro ──► Welcome ──► Permissions ──► Monitor ──► Calibration ──► done
                                   │                                        │
                                   └── relaunch (TCC) resumes here ◄────────┘
                                        via persisted onboardingStage
```

Progress persists (`onboardingStage`) so the TCC-mandated relaunch after
granting permissions auto-resumes on the step the user left.

## Step 1 — Welcome

Large centered borderless window (**~780 × 620**, Raycast-sized), confined
starfield drifting inside it (the residue of the intro), title + tagline +
three feature rows + "Get Started" CTA.

Copy (gate/space themed; **no Stream Deck mention**):

> **Welcome to Gatecaster**
> Your touchscreen, cast into a true Mac input surface.
>
> 🌀 **Open the gate** — pointer, taps, drags, native gestures
> ✨ **Cast across space** — pinch, rotate, momentum scroll
> 🛰️ **Summon controls** — keyboard, trackpad & deck
>
> [Get Started]

## Intro animation (the vortex)

Full-screen borderless window on the main display, pure black. Approved look
is the WebGL demo `vortex-shader-v5.html`; the Swift implementation ports its
fragment shader to Metal.

Reference implementation (port 1:1): `vortex-final.html` in the brainstorm
session dir (`.superpowers/brainstorm/71582-1781147118/content/`).

**Timeline** (seconds, total 6 s): `0–1.6` stars fade in and fill the screen
→ `1.6–4.6` vortex suck (inverse-mapped spiral, chromatic aberration,
tangential star stretching) → `4.6–6.0` **dive + reveal together**: the
camera plunges into the vortex (world coords shrink to ×0.08) while the
modal simultaneously pops out of the center with an easeOutBack overshoot
and the welcome text fades in as the pop settles. No end flash. Starfield
stays confined inside the window, twinkling indefinitely (animation clock
never stops).

**Visual rules:**

- **The vortex is invisible** — no event-horizon ring, no halo, no tunnel
  interior. You only see space itself bend: glass distortion (wavy fbm
  displacement of sampling coords, strongest near the virtual horizon) and
  gravitational lens warp (stars bow around the core).
- **Black & white only** — stars, glow, window chrome all monochrome. The
  *only* color is chromatic aberration: per-channel swirl offsets on stars.
- Small stars, pure-black background. Log-polar procedural starfield
  (seam-free angular wrap), rounded-rect SDF masks the confined window
  region during reveal.

**Locked shader constants** (from the approved demo):

| Constant | Value | Meaning |
|---|---|---|
| swirl turns `SW` | 12 | suck-phase rotation |
| kepler profile | `min(140/(r+70), 2.5)` | inner stars orbit fast (1/r), outer crawl |
| inward rush `RUSH` | 14 | radial sample growth during suck |
| star stretch `STR` | 30 | tangential streak cap (anisotropy ×7/×34) |
| aberration `AB` | 0.26 | `suck · clamp(340/r, 0, 6) · AB` |
| lens warp `LENS` | 8 | `suck · hr²·LENS / (r² + hr²/2)` |
| glass amount `GAMP` | 110 px | fbm displacement, mask `exp(-|r−hr|/(hr·1.6))` |
| glass scale `GFREQ` | 0.03 | fbm ripple frequency |
| dive depth `DIVEZ` | 0.08 | end-of-dive world zoom |
| virtual horizon `hr` | `26 + 40·(1−suck)` | drives glass/lens falloff only (never drawn) |

**Tech:** `MTKView` + fragment shader. MSL source is a Swift string compiled
at runtime via `device.makeLibrary(source:)` — no `.metal` build phase, no
SPM resource changes, works on the macOS 13 platform floor (the SwiftUI
shader API needs macOS 14). Uniforms: time, resolution, window rect, phase
scalars. Text/CTA are SwiftUI/AppKit layers positioned from the same
center/size math as the shader's window rect, so they can't misalign.

**Reduce Motion:** if `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`,
skip the vortex entirely — fade the welcome window in over black.

**Skippable:** any click/key during the intro jumps to the revealed window.

## Step 2 — Permissions

Reuses the row pattern from `PermissionsView` (SettingsView.swift): one row
per permission with live status checkmark, polled every 2 s.

- **Accessibility** — `AXIsProcessTrusted()`; Grant button deep-links
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
- **Input Monitoring** — `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`;
  deep-links `…?Privacy_ListenEvent`.

Both granted → Continue enables. Since TCC grants require relaunch, the step
shows a **Relaunch** button once a grant is detected; `onboardingStage`
ensures the relaunched app resumes at the next step.

## Step 3 — Monitor

Hybrid picker (replaces today's full-screen number overlay *within
onboarding*; the standalone picker remains for the menu item):

- The onboarding window lists connected displays as rows (name, resolution,
  number).
- Each physical display shows a small **corner identify badge** (numbered,
  top-right) — *identify-only*, because touch reports carry no display
  identity: until a display is bound, touches click through to the currently
  bound display, so badges must not be tap targets.
- Pick via: clicking a row, pressing number keys 1–9, or *mouse*-clicking a
  badge.
- Selection persists by **display UUID** (existing convention), sets
  `hasPickedDisplay`.

## Step 4 — Calibration

Own intro panel inside the onboarding window ("Final step — map the corners")
with a Start button, then hands off to the existing corner-tap calibration
flow (`startCalibration`, KeyableWindow at `.screenSaver` level). Completion
returns to a short "You're all set" close-out, sets `hasOnboarded = true`,
and the app proceeds to normal operation. A "Skip for now" path exists
(calibration is re-runnable from settings); skipping still sets
`hasOnboarded = true`.

## Settings & persistence

All new state lives in `AppSettings` (single source of truth, versioned):

- `hasOnboarded: Bool` (default false)
- `onboardingStage: Int` (0 = not started … persists resume point)
- Settings **version bump + migration**: existing configs with
  `hasPickedDisplay == true` get `hasOnboarded = true` so current users are
  not funneled through the full flow.

## Files

| File | Change |
|---|---|
| `Sources/Gatecaster/Onboarding.swift` | new — window controller + step views + stage machine |
| `Sources/Gatecaster/VortexIntro.swift` | new — MTKView subclass + runtime-compiled MSL shader |
| `Sources/Gatecaster/AppSettings.swift` | `hasOnboarded`, `onboardingStage`, version bump + migration |
| `Sources/Gatecaster/main.swift` | launch branch (onboarding vs normal), "Setup Assistant…" menu item, wire monitor-step badges |
| `Sources/Gatecaster/DisplayPicker.swift` | add `IdentifyBadgeView` (corner badge); existing picker untouched |

## Constraints honored

- No `nextEvent` tracking loops anywhere in onboarding windows (would pause
  HID callbacks and deadlock touch input).
- Touch cannot pick a display before binding — badges are identify-only.
- Display persistence by UUID, not `CGDirectDisplayID`.
- Settings format versioned and auto-migrating.
- macOS 13 platform floor — no macOS 14-only SwiftUI shader API.

## Error handling

- Metal unavailable / shader compile fails → log, fall back to the Reduce
  Motion path (plain fade-in). Onboarding never blocks on the animation.
- Display unplugged mid-monitor-step → list refreshes via the existing
  reconfiguration callback; selection of a vanished display is cleared.
- Settings write failure follows existing AppSettings behavior.

## Testing

No test suite exists; verification is manual:

1. Delete `~/v17ut-settings.json` → full flow, intro plays, B&W + aberration only.
2. Existing settings with `hasPickedDisplay` → no onboarding (migration check).
3. Revoke Accessibility → launch opens on Permissions step directly.
4. Grant mid-flow → relaunch resumes on next stage.
5. Reduce Motion on → no vortex, fade-in only.
6. Two displays → badges identify, row/keys/mouse-badge all select.
7. "Setup Assistant…" menu re-entry.
