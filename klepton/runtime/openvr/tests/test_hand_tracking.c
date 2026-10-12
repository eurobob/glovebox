#include "../../xr/kl_hand_tracking.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static void sample(float *bones, float *curl, float *splay, float value) {
    for (int i = 0; i < 31; i++) {
        float *b = bones + 7 * i;
        b[0] = value; b[1] = value; b[2] = value;
        b[3] = 0; b[4] = 0; b[5] = 0; b[6] = 1;
    }
    for (int i = 0; i < 5; i++) curl[i] = value;
    for (int i = 0; i < 4; i++) splay[i] = value;
}

static void *publish_many(void *unused) {
    (void)unused;
    float bones[31 * 7], curl[5], splay[4];
    for (int i = 0; i < 20000; i++) {
        sample(bones, curl, splay, (i & 1) ? 0.25f : 0.75f);
        kl_hand_tracking_publish(0, bones, curl, splay, 100);
    }
    return NULL;
}

int main(void) {
    float bones[31 * 7], curl[5], splay[4], out[31 * 7], co[5], so[4];
    sample(bones, curl, splay, 0.25f);
    assert(!kl_hand_tracking_enabled());
    kl_hand_tracking_publish(0, bones, curl, splay, 100);
    assert(!kl_hand_tracking_read(0, out, co, so, 100));
    kl_hand_tracking_set_enabled(1);
    assert(kl_hand_tracking_enabled());
    assert(!kl_hand_tracking_read(0, NULL, NULL, NULL, 100));
    kl_hand_tracking_publish(0, bones, curl, splay, 100);
    assert(kl_hand_tracking_read(0, out, co, so, 100.125));
    assert(!memcmp(out, bones, sizeof out) && !memcmp(co, curl, sizeof co) && !memcmp(so, splay, sizeof so));
    assert(!kl_hand_tracking_read(1, NULL, NULL, NULL, 100));
    assert(!kl_hand_tracking_read(0, out, co, so, 100.151));
    assert(out[0] == 0 && co[0] == 0 && so[0] == 0);
    assert(!kl_hand_tracking_read(0, NULL, NULL, NULL, 99.9));
    assert(!kl_hand_tracking_read(0, NULL, NULL, NULL, NAN));
    assert(!kl_hand_tracking_read(-1, NULL, NULL, NULL, 100));
    kl_hand_tracking_publish(1, bones, curl, splay, 100);
    kl_hand_tracking_clear(0);
    assert(!kl_hand_tracking_read(0, NULL, NULL, NULL, 100));
    assert(kl_hand_tracking_read(1, NULL, NULL, NULL, 100));
    bones[6] = NAN;
    kl_hand_tracking_publish(1, bones, curl, splay, 100);
    assert(!kl_hand_tracking_read(1, NULL, NULL, NULL, 100));
    sample(bones, curl, splay, 0.25f);
    kl_hand_tracking_publish(0, bones, curl, splay, 100);
    kl_hand_tracking_set_enabled(1); // Reasserting mode retains current data.
    assert(kl_hand_tracking_read(0, NULL, NULL, NULL, 100));
    kl_hand_tracking_set_enabled(0);
    kl_hand_tracking_set_enabled(1);
    assert(!kl_hand_tracking_read(0, NULL, NULL, NULL, 100));

    // Concurrent publishers cannot tear a snapshot across bones and summary.
    kl_hand_tracking_publish(0, bones, curl, splay, 100);
    pthread_t writer;
    assert(pthread_create(&writer, NULL, publish_many, NULL) == 0);
    for (int i = 0; i < 20000; i++) {
        assert(kl_hand_tracking_read(0, out, co, so, 100));
        for (int b = 0; b < 31; b++) assert(out[b * 7] == co[0]);
        for (int f = 0; f < 5; f++) assert(co[f] == co[0]);
        for (int f = 0; f < 4; f++) assert(so[f] == co[0]);
    }
    assert(pthread_join(writer, NULL) == 0);
    kl_hand_tracking_set_enabled(0);
    puts("hand tracking bridge: freshness, loss, mode changes and coherent snapshots passed");
    return 0;
}
