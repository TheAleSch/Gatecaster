//
//  GestureKit.h
//  Synthesis of macOS trackpad gesture events (magnify / rotate / swipe),
//  so apps respond as if a real Multi-Touch trackpad sent them.
//
//  Original implementation based on observed CGEvent gesture format
//  (private field ids, event-type numbers).
//
//  Phase values mirror NSEvent phases: 1 = began, 2 = changed, 4 = ended.
//

#ifndef GESTUREKIT_H
#define GESTUREKIT_H

#include <stdint.h>
#include <ApplicationServices/ApplicationServices.h>

// Post a CGEvent of `type` with the given integer and double fields set.
// (Lets Swift set arbitrary private field ids, which its CGEventField enum can't.)
void gk_post_fields(int32_t type,
                    const int32_t *ifields, const int64_t *ivals, int32_t ni,
                    const int32_t *dfields, const double *dvals, int32_t nd);

// Read-only: dumps every non-zero CGEvent field of a live event to stderr, so
// the real magnify/rotate/swipe layout can be learned from the trackpad.
void gk_dump_event(CGEventRef ev);

#endif /* GESTUREKIT_H */
