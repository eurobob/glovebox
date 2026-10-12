#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/klepton-hand-gestures.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
swiftc "$repo_root/klepton/visionos/Sources/KleptonHandGestures.swift" \
    "$repo_root/tools/tests/test_hand_gestures.swift" \
    -o "$scratch/test_hand_gestures"
"$scratch/test_hand_gestures"
