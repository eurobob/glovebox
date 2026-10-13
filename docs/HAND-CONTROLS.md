# Experimental hand controls

This fork adds hand controls to **upstream Glovebox 0.1.5**. **Experimental: headset playtests confirmed
individual finger articulation in build 1012.23.1, but still showed a visible 90° hand rotation and a
translation offset fixed relative to the room.** Earlier tests also exposed jitter and unreliable movement.
Build 1012.24.1 added skeletal-action pose queries, but its headset playtest still showed substantial
misalignment. Build 1013.1.1 keeps native tracking capability at Full before the first sample and during
dropouts; temporary availability still uses bActive/NoData. It also records at most 36 native query lines
per process, covering the actual placement poses and reference/live wrist transforms Alyx requests.
That capability fix did not resolve the visible alignment. Its trace confirmed that Alyx reads raw hand-pose
actions and OpenHand reference transforms alongside live finger bones. With real palms down, the rendered
palms still faced inward. Build **1013.2.2** changed reference transforms to the anatomical palm frame.
Its playtest improved menu placement but still showed incorrect position and rotation in gameplay.

Build **1013.4.1** replaces that reference-only experiment. Valve's original reference skeleton is restored;
the raw placement pose and live skeleton are rebased together so the canonical wrist lands at the measured
wrist. Finger world transforms are preserved, and pose/bone queries share one display-frame sample. This
changes the raw hand axes too. The headset playtest confirmed that the hands now feel aligned, but grabbing
still felt unnatural and seemed to require an index pinch.

Build **1013.5.1** keeps that placement and changes only grasp recognition: a curved hand around an object
can activate grip without closing into a tight fist or pinching thumb and index. Opening the fingers releases
grip. Once grasp debounce starts, incidental thumb contact cannot switch it into movement or a button press.
This improves gesture input; Alyx still decides which nearby object to attach and how to hold it.
Upstream Glovebox remains PS VR2 Sense-only. The launcher defaults to **Hands (Experimental)**,
remembers your choice, and also offers **PS VR2 Sense** with its original two-controller requirement.
Open **Controls** before Play for the in-headset reference.

Hands mode asks for ARKit hand-tracking permission at Play. If access is denied, use the launcher's
**Open Settings** button to enable it. Unsupported hand tracking blocks Play in Hands mode.

## Returning to the game

The app still opens to the launcher. A completed local installation and saved account make Play available
immediately; account, ownership and update checks run in the background. Play uses local saves without a new
network round trip. A pending cloud download cannot replace local saves after game startup begins.

Build **1013.3.1** also disables the exhaustive shader-archive replay in the game's startup. Normal pipeline
creation reuses the persistent Metal cache and compiles missing shaders on demand. Play does not repeat the
local installation check or request tracking permission when it is already granted. A spinner covers actual
game startup; the immersive space opens only after Play and runtime initialization.

## Gestures

Keep both hands visible to the headset. Separate your thumb and index finger before pinching to
select. Aim the in-game hand pointer at a menu item, then pinch and release. Middle pinch works with the other fingers relaxed or curled. For ring/little button pinches, keep the other
two of middle/ring/little open to distinguish a button press from a fist grip.

| Gesture | Controller input / intended action |
| --- | --- |
| Index finger + thumb | Trigger: select or fire |
| Curve at least two of middle, ring and little fingers around the object | Grip: hold or grab; open to release |
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
Hands mode selects head-oriented continuous movement for the live player after spawn/load, matching this
head-relative stick. It leaves the saved movement preference unchanged; Sense mode uses the game's settings.

## Tracking and limitations

- All 25 wrist/finger joints from ARKit now feed Valve’s 31-bone skeleton, including its five helper bones.
  Individual joint bends and finger spread are independent of trigger/grip buttons. ARKit supplies inferred
  visual poses for occluded joints; those estimates are not used to press gesture buttons.
- Bare hands bypass the inherited Sense pitch and Quest controller offsets. Raw/skeletal poses use a
  placement transform derived from the measured wrist and Valve's canonical wrist; explicitly named
  aim/grip/tip actions retain the anatomical palm pose. Adaptive filtering reduces stationary jitter and follows faster motion.
- Index and middle pinches share the 39/44 mm thresholds and 20 ms debounce. A fingertip must lead the
  alternatives by 3 mm before activation; ambiguous pinches stay neutral. Once selected, a pinch keeps ownership.

- Each gesture tracks and rearms independently. A missing little-finger joint no longer disables
  index selection or freezes a tracked hand pose. After a control loses its own tracking, release
  that gesture before trying it again; a held gesture cannot reactivate on reacquisition.
- Whole-hand tracking loss or compositor pause still releases all of that hand's controls and
  invalidates its palm pose independently of finger availability. Native hand prediction uses
  Compositor Services' `trackableAnchorTime`; the head keeps `presentationTime`.
  Index selection needs the thumb and index tips, not a head sample or
  tracking of the other fingers. Heading is only needed to start a movement clutch.
- Index pinch uses the legacy calibrated 39 mm press / 44 mm release thresholds, a 20 ms debounce,
  and a 60 ms minimum accepted press so the game's slower input poll can observe a quick click.
  An accepted trigger survives up to 60 ms of missing index/thumb joint data. Invalid data or whole-hand
  loss releases it immediately; missing joints can never start a new press.
- Only one pinch is recognized per hand at a time. Grip can combine with an index trigger, but
  an existing movement/button pinch suppresses grip. An active grip is protected from incidental
  middle/ring/little contact with the thumb; those fingers must open before starting another gesture.
  Two tracked curved fingers suffice for grip: 0.45 curl to acquire, 0.25 to release, with a 50 ms
  acquisition debounce. In this normalized measure, those correspond to roughly 84° and 60° between
  proximal and distal finger segments; the former 0.80 threshold required about 127°.
  An accepted grip survives up to 120 ms of missing
  curl data while the hand itself remains tracked. Opening the fingers releases immediately.
- Missing finger skeleton data no longer disconnects a valid palm pose or drops its controller buttons.
  Skeletal queries still report unavailable data, and placement keeps the last valid wrist calibration.
- Trigger and grip are on/off controls, not analog pressure. Hands have no controller haptics.
  Tracking can fail when fingers overlap, leave view, or are hidden by the other hand or an object.
- Menu, Y-on-release and stick-click gestures produce one short press per gesture, without repeating
  while held. Reliable aim, throwing, movement, teleporting and gameplay interactions still need further headset testing.

## Build and update this fork

Use an Apple silicon Mac with Xcode, visionOS support, at least 100 GiB free, and the **same paid
Developer Program team** as the installed app. The current helper is configured for paid-team
signing; it does not yet support the upstream Personal Team workflow.

This is an update workflow using the original Mac installer's cached Steam files, not a first-time
game downloader. The runtime kit must match this checkout's `VERSION`, currently **0.1.5**. Select it
with `--kit PATH`, or place it at `build/hand-controls/upstream-0.1.5/kit`. Without `--kit`, the helper
prefers `build/hand-controls/upstream-<VERSION>/kit`, then falls back to the original cached
`alyx/kit` only if its version matches. An older kit is rejected.

The default cache is `~/Library/Application Support/Glovebox`; use `--glovebox-home PATH` if it lives
elsewhere. Preparation reuses `alyx/pipelines.foz` and the matching version's translated game libraries
at `source/<VERSION>/klepton/visionos/build/glovebox-guest/`, including `libs.txt`.

When upgrading a prepared fork from an older kit, existing translations can be reused if the
translator is byte-identical or matches the helper's verified 0.1.1/0.1.5 binary pair. That pair differs
only in UUID, code signature and debug object paths/timestamps; its program bytes are identical.
Otherwise, explicitly pass `--retranslate`: it reads the existing
`alyx/linux/game` and `alyx/sysroot` libraries and generates separate output under the ignored
`build/hand-controls/guest-<VERSION>-<translator hash>/` directory. It does not redownload headset
game assets or modify the original cache. The guest link changes only after translation succeeds.
This upgrade path expects the previous preparation's guest symlink and refuses to replace unrelated folders.

The original signed app remains a rollback candidate. Keep downloaded game assets, generated
binaries and build output out of Git.

Preparation also compiles the small OpenVR shim and replaces only its coalesced object in the staged
Alyx archive. It leaves the selected source kit, other runtime objects and original game translations untouched.
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

For an upgrade that needs new translations, prepare with the matching kit and `--retranslate`, then
run the same deploy command above:

```sh
python3 tools/prepare-hand-build.py --team TEAM --kit /path/to/0.1.5/kit --retranslate
```

Later preparations reuse the completed output after checking its input receipt; omit `--retranslate`
on those runs.

Replace `TEAM` with your Apple development team ID and `<lowerteam>` with that ID in lowercase;
the angle brackets are placeholders, not part of the command. The preparation script also accepts
`--build-number NUMBER` for an explicit build stamp. The deploy command builds, signs and installs;
`--no-launch` leaves opening the app to you.

**Do not uninstall the existing app.** Installing an update with the same team and bundle ID preserves
its container, including downloaded game files and saves. This fork keeps the existing game/save
paths and Steam sign-in flow. A different bundle ID installs a separate app with separate data.

The original Mac Glovebox app's **Install Update** or **Renew** returns you to upstream Sense-only
controls. This fork's **Upstream Update** notice explains the custom rebuild; it does not install an
update. Repeat the preparation and deployment above to update or renew this fork instead.

The game still runs locally on Vision Pro using its ARM64 Linux build through Klepton. Wine is not
required, and this repository does not include Valve's game binaries or downloaded game assets.

## Local validation

`sh tools/tests/run_hand_skeleton.sh` verifies joint hierarchy, both-hand ALVR basis conversion, independent
finger articulation, rigid-motion invariance and filtering. `sh tools/tests/run_hand_gestures.sh` exercises
natural middle-pinches, arbitration, dropout and rearming. The OpenVR host suite (`make test` in
`klepton/runtime/openvr`, with `VULKAN_INCLUDE` set) verifies actual skeletal API output, freshness and
thread-safe snapshots. `python3 tools/tests/test_hand_locomotion.py` verifies the composed gameinit hook
and runs its Lua spawn callback. These checks do not prove visual alignment or comfort on the headset.
