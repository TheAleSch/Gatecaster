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

## Documentation

| | |
|---|---|
| [docs/BUILD.md](docs/BUILD.md) | Detailed build, permissions, features |
| [docs/INTERNALS.md](docs/INTERNALS.md) | Technical reference — HID protocol, gesture synthesis, architecture |
| [docs/JOURNEY.md](docs/JOURNEY.md) | How it was reverse-engineered (and every mistake on the way) |
| [docs/DEVELOPER_API.md](docs/DEVELOPER_API.md) | Integration hooks + planned multi-touch API |
| [docs/PRODUCT.md](docs/PRODUCT.md) | Product plan & roadmap |
| [docs/DECK_PLAN.md](docs/DECK_PLAN.md) | Deck (Stream Deck-style) plan & research |
| [docs/EXTENSIONS.md](docs/EXTENSIONS.md) | Writing widget extensions (no Swift) |
| [docs/EXTENSION_BUILDING.md](docs/EXTENSION_BUILDING.md) | Widget tutorial (publishable walkthrough) |
| [docs/WIDGET_IDEAS.md](docs/WIDGET_IDEAS.md) | Widget/extension ideas & built-in vs extension split |

## License

© Alexandre Schrammel. All rights reserved. Source published for transparency;
license terms TBD.
