# Licensing — how the Pro unlock works

Gatecaster's paid tier ("Pro") unlocks the **Deck, on-screen keyboard, and virtual
trackpad**. Everything else — the core driver and the full Touch API (including
input suppression) — is free. Commercial/kiosk use is governed by [`EULA.md`](../EULA.md)
(a legal term), not by a feature gate.

## Design

- **Offline, signed tokens.** A license key is an **Ed25519-signed** token:
  `base64url(payload).base64url(signature)`, where `payload` is `{name, tier, iat}`.
  The app verifies the signature against a baked-in **public key**; the **private
  key** (which mints licenses) never ships. No server, no account — verification is
  one signature check, so licenses work forever and offline, matching the product's
  "no login for core function" principle.
- **Single source of truth.** The key is stored as `licenseKey` in `AppSettings`
  (persisted to `~/v17ut-settings.json` like every other setting, versioned/
  migrating). `AppSettings.proUnlocked` is the cached verification result —
  recomputed only when the key changes (via `didSet`), never on the Engine's
  per-frame path.
- **Gated at activation, not in the hot path.** `showKeyboard()`, `showTrackpad()`,
  and `showDeck()` call `requirePro(_:)`, which shows the paywall when locked. The
  input pipeline never checks licensing.
- **Accepted trade-off.** A determined user could patch the binary to skip the
  check. That's fine: the EULA covers commercial use, and the honest $24 buyer was
  never the threat. Don't over-invest in DRM.

Verification lives in [`Sources/Gatecaster/License.swift`](../Sources/Gatecaster/License.swift).

## One-time setup: generate the signing key pair

```bash
swift scripts/gen-keypair.swift
```

This prints a **PRIVATE** key and a **PUBLIC** key.

1. Paste the **PUBLIC** key into `License.swift` → `publicKeyB64`.
2. Store the **PRIVATE** key **offline and secret** (password manager). Anyone with
   it can mint licenses. Rotating the pair invalidates every license already issued.

> The public key currently committed is a **development key** — regenerate before
> any public release and replace it.

## Issuing a license to a customer

```bash
GATECASTER_PRIVATE_KEY=<your-base64-private-key> \
    swift scripts/gen-license.swift "Customer Name" pro
```

This prints one license key string. Send it to the customer; they paste it into
**menu bar → Unlock Pro…** (or the paywall's "Enter License…"). On success the menu
shows **Gatecaster Pro ✓** and the Pro features unlock.

Hook this up to your checkout provider's post-purchase webhook (Lemon Squeezy /
Paddle / Gumroad) to auto-issue and email the key — but it works fully manually for
the first sales.

## Tiers

| `tier` value | Meaning |
|---|---|
| `free` | Default; no key needed. Core driver + Touch API. |
| `pro`  | Unlocks Deck + on-screen keyboard + virtual trackpad. |

`commercial` is intentionally **not** a code tier — commercial use is a licensing/EULA
matter, sold hand-to-hand to integrators.
