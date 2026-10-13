#include "kl_hand_tracking.h"
#include <math.h>
#include <pthread.h>
#include <string.h>

typedef struct {
    float bones[KL_HAND_TRACKING_BONE_COUNT * 7], curl[5], splay[4];
    double time;
    int valid;
} hand_snapshot;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static hand_snapshot g_hand[2];
static int g_enabled;
static int g_palm_valid[2];
static uint64_t g_generation;

void kl_hand_tracking_set_enabled(int enabled) {
    pthread_mutex_lock(&g_lock);
    enabled = enabled != 0;
    if (g_enabled != enabled) {
        memset(g_hand, 0, sizeof g_hand);
        memset(g_palm_valid, 0, sizeof g_palm_valid);
        g_generation++;
    }
    g_enabled = enabled;
    pthread_mutex_unlock(&g_lock);
}

int kl_hand_tracking_enabled(void) {
    pthread_mutex_lock(&g_lock);
    int enabled = g_enabled;
    pthread_mutex_unlock(&g_lock);
    return enabled;
}

uint64_t kl_hand_tracking_generation(void) {
    pthread_mutex_lock(&g_lock);
    uint64_t value = g_generation;
    pthread_mutex_unlock(&g_lock);
    return value;
}

void kl_hand_tracking_set_palm_valid(int hand, int valid) {
    if (hand < 0 || hand > 1) return;
    pthread_mutex_lock(&g_lock);
    g_palm_valid[hand] = g_enabled && valid;
    pthread_mutex_unlock(&g_lock);
}

int kl_hand_tracking_palm_valid(int hand) {
    if (hand < 0 || hand > 1) return 0;
    pthread_mutex_lock(&g_lock);
    int valid = g_enabled && g_palm_valid[hand];
    pthread_mutex_unlock(&g_lock);
    return valid;
}

void kl_hand_tracking_clear(int hand) {
    if (hand < 0 || hand > 1) return;
    pthread_mutex_lock(&g_lock);
    memset(&g_hand[hand], 0, sizeof g_hand[hand]);
    pthread_mutex_unlock(&g_lock);
}

void kl_hand_tracking_publish(int hand, const float *bones, const float *curl,
                              const float *splay, double time) {
    if (hand < 0 || hand > 1) return;
    hand_snapshot sample = {0};
    int valid = bones && curl && splay && isfinite(time) && time >= 0;
    if (valid) {
        for (int i = 0; i < KL_HAND_TRACKING_BONE_COUNT * 7; i++)
            if (!isfinite(bones[i])) valid = 0;
        for (int i = 0; i < KL_HAND_TRACKING_BONE_COUNT; i++) {
            const float *q = bones + i * 7 + 3;
            float norm = q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3];
            if (!isfinite(norm) || norm < 1e-6f) valid = 0;
        }
        for (int i = 0; i < 5; i++) if (!isfinite(curl[i])) valid = 0;
        for (int i = 0; i < 4; i++) if (!isfinite(splay[i])) valid = 0;
    }
    if (valid) {
        memcpy(sample.bones, bones, sizeof sample.bones);
        for (int i = 0; i < 5; i++) sample.curl[i] = fminf(1, fmaxf(0, curl[i]));
        for (int i = 0; i < 4; i++) sample.splay[i] = fminf(1, fmaxf(0, splay[i]));
        sample.time = time;
        sample.valid = 1;
    }
    pthread_mutex_lock(&g_lock);
    if (g_enabled) g_hand[hand] = sample;
    pthread_mutex_unlock(&g_lock);
}

int kl_hand_tracking_read(int hand, float *bones, float *curl, float *splay, double now) {
    if (bones) memset(bones, 0, sizeof g_hand[0].bones);
    if (curl) memset(curl, 0, sizeof g_hand[0].curl);
    if (splay) memset(splay, 0, sizeof g_hand[0].splay);
    if (hand < 0 || hand > 1 || !isfinite(now)) return 0;
    pthread_mutex_lock(&g_lock);
    const hand_snapshot *sample = &g_hand[hand];
    double age = now - sample->time;
    int valid = g_enabled && sample->valid && age >= 0 && age <= KL_HAND_TRACKING_MAX_AGE_SECONDS;
    if (valid) {
        if (bones) memcpy(bones, sample->bones, sizeof sample->bones);
        if (curl) memcpy(curl, sample->curl, sizeof sample->curl);
        if (splay) memcpy(splay, sample->splay, sizeof sample->splay);
    }
    pthread_mutex_unlock(&g_lock);
    return valid;
}
