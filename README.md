# Gatecaster

**Run your whole Mac from a touchscreen.** A user-space macOS driver that gives
HID touchscreens everything Apple never shipped: pointer, tap, drag, momentum
scrolling, native pinch-zoom & rotate, desktop switching, edge gestures, an
on-screen keyboard (7 layouts + numpad), and a virtual trackpad — no mouse or
keyboard required.

Currently supports ELAN-based panels (e.g. the Visual Beat V17UT, `04F3:5512`);
generic HID controller support is on the roadmap.

## Requirements

- macOS 13+ (Liquid Glass styling on macOS 26)
- Xcode 15+ or a matching Swift toolchain
- A USB HID touchscreen

## Build & run

```bash
swift build -c release
.build/release/Gatecaster
```

Or open `Package.swift` in Xcode and Run (scheme: **Gatecaster**).

On first launch:

1. Grant **Accessibility** and **Input Monitoring** when prompted
   (System Settings → Privacy & Security), then relaunch.
2. Pick which display is the touchscreen (tap the number shown, or press it).
3. Calibrate by tapping the four corner targets.

A 👆 icon appears in the menu bar — Settings, keyboard, trackpad, and
calibration all live there.

## Editions

The **core driver is free** for personal use — pointer, tap, drag, right-click,
scroll, native pinch/rotate, edge gestures — plus the full **Touch API** for
third-party apps (including kiosk input suppression).

**Gatecaster Pro** (one-time **$24** unlock) adds the **Deck**, the **on-screen
keyboard**, and the **virtual trackpad**. **Commercial / kiosk / business** use of
any edition requires a separate license — see [EULA.md](EULA.md).

## Documentation

| | |
|---|---|
| [docs/BUILD.md](docs/BUILD.md) | Detailed build, permissions, features |
| [docs/INTERNALS.md](docs/INTERNALS.md) | Technical reference — HID protocol, gesture synthesis, architecture |
| [docs/JOURNEY.md](docs/JOURNEY.md) | How it was reverse-engineered (and every mistake on the way) |
| [docs/DEVELOPER_API.md](docs/DEVELOPER_API.md) | Integration hooks + the multi-touch API at a glance |
| [docs/TOUCH_API.md](docs/TOUCH_API.md) | Full Touch API client guide (protocol, channels, suppression, security) |
| [docs/PRODUCT.md](docs/PRODUCT.md) | Product plan & roadmap |
| [docs/DECK_PLAN.md](docs/DECK_PLAN.md) | Deck (Stream Deck-style) plan & research |
| [docs/LICENSING.md](docs/LICENSING.md) | How the Pro unlock works + how to issue keys |
| [docs/PRE-RELEASE-CHECKLIST.md](docs/PRE-RELEASE-CHECKLIST.md) | Must-do steps before shipping a public build |
| [docs/OEM-ONEPAGER.md](docs/OEM-ONEPAGER.md) | Hardware-vendor bundle pitch |
| [docs/EXTENSIONS.md](docs/EXTENSIONS.md) | Writing widget extensions (no Swift) |
| [docs/EXTENSION_BUILDING.md](docs/EXTENSION_BUILDING.md) | Widget tutorial (publishable walkthrough) |
| [docs/WIDGET_IDEAS.md](docs/WIDGET_IDEAS.md) | Widget/extension ideas & built-in vs extension split |

## License

© Alexandre Schrammel. All rights reserved. Free for personal, non-commercial use;
Pro and commercial terms in [EULA.md](EULA.md). Source published for transparency.
