# Making ELAN touchscreens (e.g. Visual Beat V17UT) work — notes for Touch-Up & others

This documents why some USB touchscreens that work on Windows do **nothing** on
macOS with generic user-space drivers like [Touch-Up](https://github.com/shueber/Touch-Up),
and the one-line fix. Written so it can be contributed upstream.

## TL;DR

Some panels (ELAN controllers — e.g. Visual Beat **V17UT**, USB `VID 0x04F3 /
PID 0x5512`) ship their **10-finger digitizer disabled**. Out of the box they
only emit a single-touch *mouse* report and a *keyboard* gesture report. The real
multitouch (HID Report ID 1) stays dormant until the host performs the feature-
report handshake that the Windows ELAN driver does at startup. Generic macOS
drivers don't send it, so they never see any touch data and appear to do nothing.

**Fix:** after opening the device, read two feature reports:

```c
// Report ID 0x0A: Contact Count Maximum (1 byte payload)
IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 0x0A, buf, &len4);
// Report ID 0x44: 256-byte vendor/MS "certification" blob (usagePage 0xFF00, usage 0xC5)
IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 0x44, buf, &len257);
```

In Python (`hidapi`):

```python
d.get_feature_report(0x0a, 4)
d.get_feature_report(0x44, 257)   # this read flips ELAN into 10-finger digitizer mode
```

After that read, Report ID 1 starts streaming on every touch.

## Why this happens

The V17UT's HID report descriptor (1067 bytes) declares several top-level
collections on one interface:

| Report ID | Collection                | Behavior out of the box        |
|-----------|---------------------------|--------------------------------|
| 1         | Digitizer / Touch Screen  | **dormant** until enabled      |
| 7         | Mouse (absolute pointer)  | active (single-touch)          |
| 9         | Keyboard                  | active (firmware pinch→⌘±, etc.)|
| 10 (0x0A) | Feature: Contact Count Max| info                           |
| 68 (0x44) | Feature: 256-byte vendor blob (`0xFF00:0xC5`) | the enable trigger |
| 2 / 3     | Vendor in/out (`0xFF00`)  | ELAN private channel           |

There is **no** standard HID "Input Mode / Device Configuration" feature on this
panel, so the usual Windows-Precision-Touch switch isn't present. On Windows the
ELAN driver reads the vendor/certification feature reports during enumeration,
which is what wakes the digitizer. macOS's generic HID path doesn't, and falls
back to the mouse collection — which is why the cursor sort of works but
multitouch never appears.

## Report ID 1 format (once enabled)

`0x01` followed by up to 10 contact slots of **11 bytes**, then scan-time +
contact-count tail:

```
byte 0       report id (0x01)
per finger k, base = 1 + k*11:
  base+0     bit0 = tip switch; bits2..7 = contact id
  base+1     width   (unused)
  base+2     height  (unused)
  base+3..4  X uint16 LE   (logical 0..2624)   <- use
  base+5..6  X uint16 LE   (duplicate — firmware quirk)
  base+7..8  Y uint16 LE   (logical 0..1856)   <- use
  base+9..10 Y uint16 LE   (duplicate)
```

Two gotchas a generic parser must handle: the **per-finger stride is 11 bytes**
(not the usual 8–10), and **X/Y are duplicated** (read the first of each pair).
Logical maxima: X 2624, Y 1856.

## Suggested contribution to Touch-Up

Touch-Up's `HIDInterpreter.c` opens the device and waits for digitizer input. To
support ELAN panels like the V17UT, after the device is matched/opened it should
issue `IOHIDDeviceGetReport(..., kIOHIDReportTypeFeature, 0x44, ...)` (and 0x0A)
once. A safe heuristic: if a device exposes a digitizer collection but produces
no touch reports within ~1s, send the ELAN feature-report handshake and retry.
Gating it on `VID 0x04F3` (ELAN) avoids poking unrelated devices.

## Bonus: the gesture-synthesis recipe Touch-Up already uses

For anyone extending this: Touch-Up's `TUCCursorUtilities.m` shows the working
way to synthesize a continuous **magnify** gesture on current macOS without the
crashy IOHID graft — start from a real mouse event, retype it to `29`
(NSEventTypeGesture), set magic ints `50=248`, `101=4`, `110=8`, magnification in
doubles `113/114/116/118`, phase in `132` (1 began / 2 moved / 8 ended). Do not
emit scroll-wheel events during the pinch. See `INTERNALS.md` §4.7 for the full map
(rotate = subtype `110=5`).

---

*Hardware: Visual Beat V17UT, ELAN `04F3:5512`. Field/format details are from the
author's macOS version; re-verify on yours.*
