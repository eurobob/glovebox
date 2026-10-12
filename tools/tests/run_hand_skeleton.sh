#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/klepton-hand-skeleton.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
xcrun swiftc -warnings-as-errors "$repo_root/klepton/visionos/Sources/KleptonHandSkeleton.swift" \
    "$repo_root/tools/tests/test_hand_skeleton.swift" -o "$scratch/test_hand_skeleton"
"$scratch/test_hand_skeleton"
