// The SteamVR hand skeleton, driven from PSVR2 Sense finger curls.
//
// Alyx draws its hands from IVRInput's skeletal actions: 31 bones per hand,
// in SteamVR's bone frames. Getting those frames wrong by an axis is not a
// subtle error, so the reference poses are Valve's own data (see
// tools/gen_hand_poses.py) rather than something derived here, and a live pose
// is a per-finger blend between Valve's open hand and Valve's fist.
//
// The Sense controllers report thumb, index and middle-finger contact and the
// trigger's travel, so the blend weights are an estimate — the same kind
// SteamVR itself makes for Oculus Touch ("partial" skeletal tracking).
#include "klvr_internal.h"
#include "klvr_skeleton.h"
#include <array>
#include <cmath>

namespace klvr {
namespace {
#include "generated/klvr_hand_ref.inc"

const char *const kBoneNames[kBoneCount] = {
    "Root", "Wrist",
    "Thumb0", "Thumb1", "Thumb2", "Thumb3",
    "IndexFinger0", "IndexFinger1", "IndexFinger2", "IndexFinger3", "IndexFinger4",
    "MiddleFinger0", "MiddleFinger1", "MiddleFinger2", "MiddleFinger3", "MiddleFinger4",
    "RingFinger0", "RingFinger1", "RingFinger2", "RingFinger3", "RingFinger4",
    "PinkyFinger0", "PinkyFinger1", "PinkyFinger2", "PinkyFinger3", "PinkyFinger4",
    "Aux_Thumb", "Aux_IndexFinger", "Aux_MiddleFinger", "Aux_RingFinger", "Aux_PinkyFinger",
};

// Aux bones hang off the root: checked against the reference data, where each
// sits beside its finger's last joint only when read relative to the root.
const int8_t kParent[kBoneCount] = {
    -1, 0,
    1, 2, 3, 4,
    1, 6, 7, 8, 9,
    1, 11, 12, 13, 14,
    1, 16, 17, 18, 19,
    1, 21, 22, 23, 24,
    0, 0, 0, 0, 0,
};

// Which finger (0 thumb .. 4 pinky) moves each bone; -1 for root and wrist.
int finger_of(int bone) {
    if (bone >= 2 && bone <= 5) return 0;
    if (bone >= 6 && bone <= 25) return 1 + (bone - 6) / 5;
    if (bone >= 26) return bone - 26;
    return -1;
}

vr::VRBoneTransform_t bone(const float r[7]) {
    vr::VRBoneTransform_t b;
    b.position = { { r[0], r[1], r[2], 1.0f } };
    b.orientation = { r[6], r[3], r[4], r[5] };   // HmdQuaternionf_t is w, x, y, z
    return b;
}

Quat q_of(const vr::VRBoneTransform_t &b) { return { b.orientation.x, b.orientation.y, b.orientation.z, b.orientation.w }; }
Vec3 p_of(const vr::VRBoneTransform_t &b) { return { b.position.v[0], b.position.v[1], b.position.v[2] }; }
vr::VRBoneTransform_t make(Vec3 p, Quat q) {
    vr::VRBoneTransform_t b;
    b.position = { { p.x, p.y, p.z, 1.0f } };
    b.orientation = { q.w, q.x, q.y, q.z };
    return b;
}
} // namespace

const char *skel_bone_name(int i) { return i >= 0 && i < kBoneCount ? kBoneNames[i] : nullptr; }
int skel_parent(int i) { return i >= 0 && i < kBoneCount ? kParent[i] : -1; }

// How far toward Valve's full fist a curl of 1 goes while the hand is holding
// a controller. SteamVR ships a separate "grip limit" reference pose for this;
// the Unity plugin does not include it, so it is approximated as a fraction of
// the fist. KLVR_GRIP_LIMIT tunes it on device.
static float grip_limit() {
    static float v = env_float("KLVR_GRIP_LIMIT", 0.8f);
    return v;
}

void skel_reference(int hand, vr::EVRSkeletalReferencePose which, vr::VRBoneTransform_t out[kBoneCount]) {
    hand = hand ? 1 : 0;
    if (which == vr::VRSkeletalReferencePose_GripLimit) {
        float c[5] = { 1, 1, 1, 1, 1 };
        skel_pose(hand, c, vr::VRSkeletalMotionRange_WithController, out);
        return;
    }
    const float (*t)[7] = which == vr::VRSkeletalReferencePose_Fist ? kRefFist[hand]
                        : which == vr::VRSkeletalReferencePose_OpenHand ? kRefOpen[hand]
                        : kRefBind[hand];
    for (int i = 0; i < kBoneCount; i++) out[i] = bone(t[i]);
}

static const Pose &fallback_raw_from_palm(int hand) {
    // Before any live fingers arrive, place the canonical skeleton by the
    // same anatomical palm geometry used by KleptonTrackedHand. References
    // remain Valve's unmodified data; this transform affects placement only.
    static const std::array<Pose, 2> anatomical_from_reference = [] {
        auto cross = [](Vec3 a, Vec3 b) -> Vec3 {
            return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
        };
        auto unit = [](Vec3 v) { return vscale(v, 1.0f / std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z)); };
        std::array<Pose, 2> result;
        for (int h = 0; h < 2; h++) {
            vr::VRBoneTransform_t local[kBoneCount], model[kBoneCount];
            skel_reference(h, vr::VRSkeletalReferencePose_OpenHand, local);
            skel_to_model(local, model);
            Vec3 z = vscale(unit(vsub(p_of(model[12]), p_of(model[1]))), -1);
            Vec3 across = vscale(vsub(p_of(model[7]), p_of(model[22])), h ? -1 : 1);
            Vec3 y = unit(cross(z, across)), x = unit(cross(y, z));
            Vec3 p = vscale(vadd(p_of(model[11]), p_of(model[12])), 0.5f);
            vr::HmdMatrix34_t palm = {{{x.x, y.x, z.x, p.x},
                                      {x.y, y.y, z.y, p.y},
                                      {x.z, y.z, z.z, p.z}}};
            result[h] = pinv(from_mat34(palm));
        }
        return result;
    }();
    return anatomical_from_reference[hand ? 1 : 0];
}

static std::mutex g_native_mu;
static NativeHand g_native_hand[2];
static Pose g_last_raw_from_palm[2];
static bool g_have_raw[2]{};
static uint32_t g_native_frame;
static double g_native_time, g_native_captured;
static uint64_t g_native_generation;

static void check_native_generation() {
    const uint64_t generation = klvr_plat_hand_tracking_generation();
    if (generation == g_native_generation) return;
    g_native_generation = generation;
    g_native_frame = 0;
    g_have_raw[0] = g_have_raw[1] = false;
}

// Called with g_native_mu held. The bridge returns one atomic set of bones
// and summaries. S and the rebased bones are always derived from that set.
static NativeHand sample_native_hand(int hand, double time) {
    NativeHand result;
    klvr_plat_hand(hand, time, &result.palm);
    result.raw_from_palm = g_have_raw[hand] ? g_last_raw_from_palm[hand] : fallback_raw_from_palm(hand);
    float data[kBoneCount * 7];
    result.skeleton_valid = klvr_plat_skeleton(hand, data, result.curl, result.splay);
    if (!result.skeleton_valid) return result;
    for (int i = 0; i < kBoneCount; i++) result.bones[i] = bone(data + i * 7);
    vr::VRBoneTransform_t reference[kBoneCount];
    skel_reference(hand, vr::VRSkeletalReferencePose_OpenHand, reference);
    const Pose wrist = {p_of(result.bones[1]), q_of(result.bones[1])};
    const Pose canonical = {p_of(reference[1]), q_of(reference[1])};
    // P' = P*S, W' = R: P'*R = P*W. Every root-parented auxiliary
    // gets S^-1; finger-relative joints and measured world poses are kept.
    result.raw_from_palm = pmul(wrist, pinv(canonical));
    result.bones[0] = make({0, 0, 0}, {0, 0, 0, 1});
    result.bones[1] = reference[1];
    const Pose inverse = pinv(result.raw_from_palm);
    for (int i = 26; i < kBoneCount; i++) {
        const Pose local = pmul(inverse, {p_of(result.bones[i]), q_of(result.bones[i])});
        result.bones[i] = make(local.p, local.q);
    }
    g_last_raw_from_palm[hand] = result.raw_from_palm;
    g_have_raw[hand] = true;
    return result;
}

void native_hands_frame(const Frame &f) {
    std::lock_guard<std::mutex> lock(g_native_mu);
    check_native_generation();
    g_native_frame = 0;
    if (!klvr_plat_hand_tracking_enabled()) {
        g_have_raw[0] = g_have_raw[1] = false;
        return;
    }
    for (int hand = 0; hand < 2; hand++) g_native_hand[hand] = sample_native_hand(hand, f.display_time);
    g_native_frame = f.id;
    g_native_time = f.display_time;
    g_native_captured = klvr_plat_now();
}

NativeHand native_hand(int hand, double time) {
    std::lock_guard<std::mutex> lock(g_native_mu);
    check_native_generation();
    const double age = klvr_plat_now() - g_native_captured;
    if (!g_native_frame) return sample_native_hand(hand, time);
    NativeHand result = g_native_hand[hand];
    // A latch holds coordinates, never availability: real palm loss and
    // expired/cleared fingers take effect even between display frames.
    klvr_tracked current{};
    klvr_plat_hand(hand, time, &current);
    if (age < 0 || age > 0.15) {
        // A stalled render frame must not resample a different S separately
        // for each API. Follow the palm with the last placement, withholding
        // articulation until a fresh frame latches both together again.
        result.palm = current;
        result.skeleton_valid = false;
        return result;
    }
    result.palm.valid = result.palm.valid && current.valid;
    result.skeleton_valid = result.skeleton_valid && klvr_plat_skeleton(hand, nullptr, nullptr, nullptr);
    // Keep articulation/S pinned, but honor OpenVR's requested prediction
    // instant using the same bounded rigid motion as the platform adapter.
    if (result.palm.valid && result.palm.motion_known) {
        const float dt = float(std::fmax(-0.05, std::fmin(0.05, time - g_native_time)));
        for (int i = 0; i < 3; i++) result.palm.pose.p[i] += result.palm.vel[i] * dt;
        const Vec3 angular = {result.palm.ang[0], result.palm.ang[1], result.palm.ang[2]};
        const float speed = std::sqrt(angular.x*angular.x + angular.y*angular.y + angular.z*angular.z);
        if (speed > 1e-6f) {
            Quat q = qmul(qfrom_axis_angle(vscale(angular, 1 / speed), speed * dt), to_pose(result.palm.pose).q);
            result.palm.pose.q[0] = q.x; result.palm.pose.q[1] = q.y;
            result.palm.pose.q[2] = q.z; result.palm.pose.q[3] = q.w;
        }
    }
    return result;
}

void skel_pose(int hand, const float curl[5], vr::EVRSkeletalMotionRange range, vr::VRBoneTransform_t out[kBoneCount]) {
    hand = hand ? 1 : 0;
    float limit = range == vr::VRSkeletalMotionRange_WithController ? grip_limit() : 1.0f;
    for (int i = 0; i < kBoneCount; i++) {
        vr::VRBoneTransform_t a = bone(kRefOpen[hand][i]), b = bone(kRefFist[hand][i]);
        int f = finger_of(i);
        float t = f < 0 ? 0.0f : std::fmin(std::fmax(curl[f], 0.0f), 1.0f) * limit;
        out[i] = make(vlerp(p_of(a), p_of(b), t), qslerp(q_of(a), q_of(b), t));
    }
}

void skel_to_model(const vr::VRBoneTransform_t parent[kBoneCount], vr::VRBoneTransform_t model[kBoneCount]) {
    Pose m[kBoneCount];
    for (int i = 0; i < kBoneCount; i++) {
        Pose local = { p_of(parent[i]), q_of(parent[i]) };
        m[i] = kParent[i] < 0 ? local : pmul(m[kParent[i]], local);
        model[i] = make(m[i].p, m[i].q);
    }
}

} // namespace klvr
