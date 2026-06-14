# Pre-release checklist — DO THIS BEFORE SHIPPING

Two things were stubbed for development and **must** be replaced before any public
build. The build scripts warn about #1 and #2, and `release.sh` will **refuse to
package** while the development key is still in place. (Each check self-clears once
you fix it — no manual bookkeeping.)

## 1. Regenerate the license signing key pair  ⚠️ security-critical

The public key committed in [`Sources/Gatecaster/License.swift`](../Sources/Gatecaster/License.swift)
(`publicKeyB64`) is a **development key**, and its matching **private key was exposed
in a chat transcript** — treat both as compromised. Anyone with that private key can
mint valid Pro licenses.

```bash
swift scripts/gen-keypair.swift
```

- Paste the new **PUBLIC** key into `License.swift` → `publicKeyB64`.
- Store the new **PRIVATE** key **offline and secret** (password manager). Never
  commit it.
- Re-issue any real licenses with the new private key
  (`scripts/gen-license.swift`). Rotating the key **invalidates every license issued
  with the old key**, so do this before selling anything.

See [`docs/LICENSING.md`](LICENSING.md) for the full flow.

## 2. Set the real checkout URL and contact email

- `purchaseURL` in [`Sources/Gatecaster/main.swift`](../Sources/Gatecaster/main.swift)
  is a placeholder (`https://gatecaster.app/buy`). Point it at your real checkout
  (Lemon Squeezy / Paddle / Gumroad).
- [`EULA.md`](../EULA.md) references `licensing@gatecaster.app` — make sure that
  mailbox exists (or swap in the real address).

## How you're reminded

| When | What happens |
|---|---|
| `swift build` then run the binary | App prints a ⚠️ block to **stderr** at launch while the dev key / placeholder URL is present. |
| `scripts/make-app.sh` | Prints a ⚠️ reminder, then **continues** (dev app builds are fine). |
| `scripts/release.sh` | **Refuses to build** while the dev key is present. Override only if you really mean it: `ALLOW_DEV_KEY=1 scripts/release.sh`. |
