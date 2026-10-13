// Exercise the actual device adapter, with only its frontend seam scripted.
// Link-time section collection discards the unrelated renderer entry points.
#include "klvr_platform.h"
#include "kl_ovrp.h"
#include "kl_hand_tracking.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int pose_valid[2] = {1, 1}, input_present[2] = {1, 1};

int kl_ovrp_hand_motion(int hand, float *p, float *q, float *v, float *a) {
    if (!pose_valid[hand]) return 0;
    const float position[3] = {hand ? 0.3f : -0.2f, 1.2f, -0.4f};
    const float rotation[4] = {0, 0, 0, 1};
    if (p) memcpy(p, position, sizeof position);
    if (q) memcpy(q, rotation, sizeof rotation);
    if (v) memset(v, 0, 3 * sizeof(float));
    if (a) memset(a, 0, 3 * sizeof(float));
    return 1;
}
int kl_ovrp_hand_motion_known(int hand) { (void)hand; return 0; }
double kl_ovrp_predicted_display_time(void) { return 100; }
int kl_ovrp_controller_input(int hand, uint32_t *buttons, uint32_t *touches,
                             float *trigger, float *grip, float *x, float *y) {
    *buttons = hand ? KL_OVRP_RAW_A : KL_OVRP_RAW_X;
    *touches = *buttons;
    *trigger = 0.75f; *grip = 0.9f; *x = -0.25f; *y = 0.5f;
    return input_present[hand];
}

static void check_independent_channels(int hand) {
    // Missing/stale skeletal data remains unavailable, but palm and gestures
    // keep their measured state, with no controller pitch correction applied.
    assert(!klvr_plat_skeleton(hand, NULL, NULL, NULL));
    klvr_tracked pose;
    klvr_plat_hand(hand, 100, &pose);
    assert(pose.valid && !pose.motion_known);
    assert(pose.pose.p[0] == (hand ? 0.3f : -0.2f));
    assert(pose.pose.p[1] == 1.2f && pose.pose.p[2] == -0.4f);
    assert(pose.pose.q[0] == 0 && pose.pose.q[1] == 0
        && pose.pose.q[2] == 0 && pose.pose.q[3] == 1);
    klvr_controller input;
    klvr_plat_controller(hand, &input);
    assert(input.connected);
    assert(input.buttons & KLVR_BTN_FACE_LOWER);
    assert(input.buttons & KLVR_BTN_GRIP);
    assert(input.trigger == 0.75f && input.grip == 0.9f);
    assert(input.stick[0] == -0.25f && input.stick[1] == 0.5f);

    // Real palm/input loss must still disconnect immediately in Hands mode.
    pose_valid[hand] = 0;
    klvr_plat_hand(hand, 100, &pose);
    assert(!pose.valid);
    klvr_plat_controller(hand, &input);
    assert(!input.connected);
    pose_valid[hand] = 1;
    input_present[hand] = 0;
    klvr_plat_hand(hand, 100, &pose);
    assert(pose.valid);
    klvr_plat_controller(hand, &input);
    assert(!input.connected);
    input_present[hand] = 1;
    // The older OVR seam retains a last pose even after frontend loss. The
    // independent palm flag must invalidate that otherwise-valid old pose.
    kl_hand_tracking_set_palm_valid(hand, 0);
    klvr_plat_hand(hand, 100, &pose);
    klvr_plat_controller(hand, &input);
    assert(!pose.valid && !input.connected);
    kl_hand_tracking_set_palm_valid(hand, 1);
}

int main(void) {
    setenv("KLVR_HOST", "0", 1);
    kl_hand_tracking_set_enabled(1);
    kl_hand_tracking_set_palm_valid(0, 1);
    kl_hand_tracking_set_palm_valid(1, 1);
    float bones[31 * 7] = {0}, curl[5] = {0}, splay[4] = {0};
    for (int i = 0; i < 31; i++) bones[i * 7 + 6] = 1;
    for (int hand = 0; hand < 2; hand++) {
        check_independent_channels(hand); // No skeleton has ever arrived.
        kl_hand_tracking_publish(hand, bones, curl, splay, 1);
        check_independent_channels(hand); // A previously valid sample expired.
        kl_hand_tracking_clear(hand);
        check_independent_channels(hand); // Frontend explicitly lost fingers.
    }
    puts("hand platform: missing/stale fingers preserve palms and gestures; real channel loss disconnects");
    return 0;
}
