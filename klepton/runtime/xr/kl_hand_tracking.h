// Native hand skeleton shared by the visionOS frontend and the OpenVR shim.
#ifndef KL_HAND_TRACKING_H
#define KL_HAND_TRACKING_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KL_HAND_TRACKING_BONE_COUNT 31
#define KL_HAND_TRACKING_MAX_AGE_SECONDS 0.15

// Mode changes invalidate both hands. Hand: 0 = left, 1 = right.
void kl_hand_tracking_set_enabled(int enabled);
int kl_hand_tracking_enabled(void);
uint64_t kl_hand_tracking_generation(void);
void kl_hand_tracking_set_palm_valid(int hand, int valid);
int kl_hand_tracking_palm_valid(int hand);

// Valve's 31 bones in parent space, seven floats each: xyz, quaternion xyzw.
// Curls (thumb through little finger) and adjacent-finger splays are 0..1.
// Time is the actual sampling time on CACurrentMediaTime's uptime clock,
// not the predicted presentation time. Invalid samples clear the hand.
void kl_hand_tracking_publish(int hand, const float *bones31x7,
                              const float *curl5, const float *splay4, double time);
void kl_hand_tracking_clear(int hand);

// Copies a coherent snapshot only when enabled and at most 150 ms old.
// Each output may be NULL. Failed reads clear supplied outputs.
int kl_hand_tracking_read(int hand, float *bones31x7, float *curl5,
                         float *splay4, double now);

#ifdef __cplusplus
}
#endif
#endif
