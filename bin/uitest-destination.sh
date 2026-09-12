#!/usr/bin/env bash
# bin/uitest-destination.sh — print the xcodebuild -destination to use for UI tests.
#
# A connected iPhone is the better signal and the slower one to remember to ask
# for, so this prefers a real device and falls back to a simulator. UI behaviour
# that only a device shows — permission alerts, universal links, backgrounding,
# real keyboards — is exactly what a simulator-only habit hides.
#
# Usage:
#   xcodebuild test -scheme App -destination "$(bin/uitest-destination.sh)" ...
#   bin/uitest-destination.sh --udid            # just the UDID, empty if none
#
# Env:
#   FORCE_SIMULATOR=1   skip the device and name a simulator (CI, or screenshots)
#   SIMULATOR_NAME      simulator to fall back to (default: iPhone 16)
set -euo pipefail

# Default simulator: an iPhone this machine actually has. A hardcoded name rots
# — "iPhone 16" is not installed on every Mac, and the failure is an unhelpful
# xcodebuild destination error.
#
# Deliberately NOT described as "the newest". simctl enumerates per runtime in
# its own order and this takes the last line of that enumeration: measured on a
# Mac with iPhone 17, 17 Pro, 17 Pro Max and Air installed, it returns
# "iPhone 16e". Any available iPhone is a valid destination, so the arbitrary
# pick is fine — claiming it is the newest was not. Set SIMULATOR_NAME when you
# care which one.
SIM_NAME="${SIMULATOR_NAME:-}"
if [[ -z "$SIM_NAME" ]]; then
  SIM_NAME=$(xcrun simctl list devices available 2>/dev/null \
               | sed -nE 's/^[[:space:]]*(iPhone[^(]*)\(.*/\1/p' \
               | sed 's/[[:space:]]*$//' | tail -1) || true
fi
[[ -n "$SIM_NAME" ]] || SIM_NAME="iPhone 16"
WANT_UDID=0
[[ "${1:-}" == "--udid" ]] && WANT_UDID=1

udid=""
if [[ "${FORCE_SIMULATOR:-}" != "1" ]]; then
  # ONLY the "== Devices ==" section. `xctrace list devices` also prints
  # "== Devices Offline ==" — every iPhone this Mac has ever paired with — and
  # a plain grep picks one of those up when nothing is plugged in, emitting
  # `id=<UDID>` for a phone that is not there. That silently defeats the
  # simulator fallback this script exists to provide, and hands xcodebuild the
  # destination error the header promises to avoid. Reproduced on a Mac with
  # two offline phones remembered.
  #
  # Case-insensitive: a phone named "jp's iphone" is an iPhone. The old
  # `grep -E "iPhone"` skipped exactly those while `grep -iv simulator` was
  # already case-insensitive, so lowercase-named phones never got preferred.
  udid=$(xcrun xctrace list devices 2>/dev/null \
           | awk '/^== Devices ==/{inside=1; next} /^== /{inside=0} inside' \
           | grep -iE "iphone.*\(" | grep -iv "simulator" \
           | head -1 | sed 's/.*(\(.*\))/\1/') || true
fi

if [[ "$WANT_UDID" == "1" ]]; then
  echo "$udid"
  exit 0
fi

if [[ -n "$udid" ]]; then
  echo "id=$udid"
else
  echo "platform=iOS Simulator,name=$SIM_NAME"
fi
