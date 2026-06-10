//
//  GestureKit.c — trackpad-gesture synthesis.
//
//  How a synthetic magnify/rotate/swipe is made honored by AppKit:
//    1. create a real mouse event (CGEventCreateMouseEvent) — this gives the
//       event valid internal state (location, timestamp, source) that a bare
//       CGEventCreate(NULL) lacks;
//    2. retype it to the gesture CGEventType (29) and clear its flags;
//    3. set the private tagged fields that carry the gesture's subtype, phase,
//       and value (the caller supplies the exact field ids);
//    4. post it to the HID event tap.
//
//  This is the approach that works on current macOS. The older technique of
//  grafting a raw IOHID payload onto a serialized event (CGEventCreateFromData)
//  crashed WindowServer on recent releases and has been removed.
//
//  Field ids are passed in from Swift (GestureSynth) rather than hard-coded
//  here, because Swift's CGEventField enum can't express the private ids.
//

#include "GestureKit.h"

#include <ApplicationServices/ApplicationServices.h>
#include <string.h>
#include <stdio.h>

// Post a CGEvent of `type` with the given integer and double fields set.
void gk_post_fields(int32_t type,
                    const int32_t *ifields, const int64_t *ivals, int32_t ni,
                    const int32_t *dfields, const double *dvals, int32_t nd) {
    // A real mouse event carries the internal state that makes AppKit honor the
    // event once we retype it to a gesture. (Technique learned from Touch-Up.)
    CGEventRef probe = CGEventCreate(NULL);
    CGPoint loc = probe ? CGEventGetLocation(probe) : CGPointZero;
    if (probe) CFRelease(probe);

    CGEventRef e = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, loc, kCGMouseButtonLeft);
    if (!e) return;
    CGEventSetType(e, (CGEventType)type);
    CGEventSetFlags(e, 0);
    for (int32_t k = 0; k < ni; k++)
        CGEventSetIntegerValueField(e, (CGEventField)ifields[k], ivals[k]);
    for (int32_t k = 0; k < nd; k++)
        CGEventSetDoubleValueField(e, (CGEventField)dfields[k], dvals[k]);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

// ---- capture helper (learning tool) ---------------------------------------
// Constant device/window noise fields — skip them so real gesture fields stand
// out when dumping a live trackpad event.
static int gk_is_noise(int f) {
    static const int noise[] = { 39, 40, 45, 50, 53, 55, 58, 85, 87, 101, 107, 169 };
    for (unsigned i = 0; i < sizeof(noise) / sizeof(noise[0]); i++)
        if (noise[i] == f) return 1;
    return 0;
}

void gk_dump_event(CGEventRef ev) {
    if (!ev) return;
    char line[2048];
    int n = snprintf(line, sizeof(line), "[t=%d]", (int)CGEventGetType(ev));
    int fields = 0;
    for (int i = 0; i < 256 && n < (int)sizeof(line) - 32; i++) {
        if (gk_is_noise(i)) continue;
        int64_t iv = CGEventGetIntegerValueField(ev, (CGEventField)i);
        double  dv = CGEventGetDoubleValueField(ev, (CGEventField)i);
        if (iv == 0 && dv == 0.0) continue;
        fields++;
        if (dv != 0.0 && dv != (double)iv)
            n += snprintf(line + n, sizeof(line) - n, " %d=%.4f", i, dv);
        else
            n += snprintf(line + n, sizeof(line) - n, " %d=%lld", i, (long long)iv);
    }
    if (fields == 0) return;                  // skip empty/contentless events
    static char last[2048];
    if (strcmp(line, last) == 0) return;      // skip exact repeats
    strncpy(last, line, sizeof(last) - 1);
    last[sizeof(last) - 1] = '\0';            // strncpy doesn't guarantee termination
    fprintf(stderr, "%s\n", line);
}
