# Experimental hand controls

This fork adds hand controls to Glovebox. **Experimental: two headset playtests exposed poor articulation, jitter and unreliable movement.
Build 1012.23.1 replaces controller-style finger animation with tracked joints; headset acceptance is still pending.**
Upstream Glovebox remains PS VR2 Sense-only. The launcher defaults to **Hands (Experimental)**,
remembers your choice, and also offers **PS VR2 Sense** with its original two-controller requirement.
Open **Controls** before Play for the in-headset reference.

Hands mode asks for ARKit hand-tracking permission at Play. If access is denied, use the launcher's
**Open Settings** button to enable it. Unsupported hand tracking blocks Play in Hands mode.

## Gestures

Keep both hands visible to the headset. Separate your thumb and index finger before pinching to
select. Aim the in-game hand pointer at a menu item, then pinch and release. Middle pinch works with the other fingers relaxed or curled. For ring/little button pinches, keep the other
two of middle/ring/little open to distinguish a button press from a fist grip.

| Gesture | Controller input / intended action |
| --- | --- |
| Index finger + thumb | Trigger: select or fire |
| Curl middle, ring and little fingers | Grip: hold or grab |
| Middle finger + thumb, then move that hand | Virtual stick: left moves; right turns, or pull back for teleport |
| Hold middle finger + thumb still for 0.8 seconds | One click of that hand's virtual stick |
| Ring finger + thumb | Left X / right A, held until release |
| Right little finger + thumb | B, held until release |
| Brief left little finger + thumb pinch, then release | One Y press on release |
| Hold left little finger + thumb for 0.8 seconds | One menu press, without a Y press |

The game's bindings determine the resulting actions. A middle pinch sets the stick center and
captures your horizontal viewing direction. Move your hand relative to that center: there is a
1 cm dead zone, with full input at 8 cm. Releasing returns the stick to zero; re-pinching sets a new
center. Moving outside the dead zone cancels the hold-to-click action for that pinch.

## Tracking and limitations

- All 25 wrist/finger joints from ARKit now feed Valve’s 31-bone skeleton, including its five helper bones.
  Individual joint bends and finger spread are independent of trigger/grip buttons. ARKit supplies inferred
  visual poses for occluded joints; those estimates are not used to press gesture buttons.
- A palm-based pointer replaces the inherited Beat Saber/Sense pose correction. Bare hands bypass the
  Sense pitch and Quest controller offsets. Adaptive filtering reduces stationary jitter and follows faster motion.
- Index and middle pinches share the 39/44 mm thresholds and 20 ms debounce. A fingertip must lead the
  alternatives by 3 mm before activation; ambiguous pinches stay neutral. Once selected, a pinch keeps ownership.

- Each gesture tracks and rearms independently. A missing little-finger joint no longer disables
  index selection or freezes a tracked hand pose. After a control loses its own tracking, release
  that gesture before trying it again; a held gesture cannot reactivate on reacquisition.
- Whole-hand tracking loss or compositor pause still releases all of that hand's controls and
  zeros its motion velocity. Index selection needs the thumb and index tips, not a head sample or
  tracking of the other fingers. Heading is only needed to start a movement clutch.
- Index pinch uses the legacy calibrated 39 mm press / 44 mm release thresholds, a 20 ms debounce,
  and a 60 ms minimum accepted press so the game's slower input poll can observe a quick click.
  Losing index tracking cancels even that minimum press immediately.
- Only one pinch is recognized per hand at a time. Grip can combine with an index trigger, but
  middle/ring/little pinches suppress grip. Relax the fingers before grabbing again.
- Trigger and grip are on/off controls, not analog pressure. Hands have no controller haptics.
  Tracking can fail when fingers overlap, leave view, or are hidden by the other hand or an object.
- Menu, Y-on-release and stick-click gestures produce one short press per gesture, without repeating
  while held. Aim, throwing, movement, teleporting and gameplay interactions still need headset testing.

## Build and update this fork

Use an Apple silicon Mac with Xcode, visionOS support, at least 100 GiB free, and the **same paid
Developer Program team** as the installed app. The current helper is configured for paid-team
signing; it does not yet support the upstream Personal Team workflow.

This workflow requires an original Glovebox Mac build matching this checkout's `VERSION`; it is not
a first-time game downloader. Under `~/Library/Application Support/Glovebox`, it reuses:

- `alyx/kit/KIT.json` and its runtime kit
- `alyx/pipelines.foz`
- `source/<VERSION>/klepton/visionos/build/glovebox-guest/libs.txt` and its translated game libraries

Pass `--glovebox-home PATH` to preparation if that cache lives elsewhere. The helper links to the
existing translations, stages generated files in ignored directories, and preserves the original
signed app as a rollback candidate. Keep downloaded game assets, generated binaries and build
output out of Git.

Preparation also compiles the small OpenVR shim and replaces only its coalesced object in the staged
Alyx archive. It leaves the original cached kit, other runtime objects and game translations untouched.
Vulkan headers must exist in the Klepton vendor output or the Homebrew vulkan-headers include directory.
`tools/patch-hand-runtime.py` checks kit/source ABI headers and reuses a content-hashed compiled object.

From this checkout, substitute the **same development team and bundle ID as the installed app**, and
your Vision Pro's device identifier:

```sh
python3 tools/prepare-hand-build.py --team TEAM
visionos-cli-deploy --root . \
  --project klepton/visionos/KleptonAlyx.xcodeproj \
  --scheme KleptonAlyx --configuration Release \
  --team-id TEAM --bundle-id "com.glovebox.alyx.t<lowerteam>" \
  --device DEVICE --no-launch
```

Replace `TEAM` with your Apple development team ID and `<lowerteam>` with that ID in lowercase;
the angle brackets are placeholders, not part of the command. The preparation script also accepts
`--build-number NUMBER` for an explicit build stamp. The deploy command builds, signs and installs;
`--no-launch` leaves opening the app to you.

**Do not uninstall the existing app.** Installing an update with the same team and bundle ID preserves
its container, including downloaded game files and saves. This fork keeps the existing game/save
paths and Steam sign-in flow. A different bundle ID installs a separate app with separate data.

The original Mac Glovebox app's **Update** or **Renew** returns you to upstream Sense-only controls.
Repeat the custom preparation and deployment above to update or renew this fork instead.

The game still runs locally on Vision Pro using its ARM64 Linux build through Klepton. Wine is not
required, and this repository does not include Valve's game binaries or downloaded game assets.

## Local validation

`sh tools/tests/run_hand_skeleton.sh` verifies joint hierarchy, both-hand ALVR basis conversion, independent
finger articulation, rigid-motion invariance and filtering. `sh tools/tests/run_hand_gestures.sh` exercises
natural middle-pinches, arbitration, dropout and rearming. The OpenVR host suite (`make test` in
`klepton/runtime/openvr`, with `VULKAN_INCLUDE` set) verifies actual skeletal API output, freshness and
thread-safe snapshots. These checks do not prove visual alignment or comfort on the headset.
