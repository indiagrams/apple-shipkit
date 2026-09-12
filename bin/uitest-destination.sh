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

# Default simulator: the newest iPhone this machine actually has. A hardcoded
# name rots — "iPhone 16" is not installed on every Mac, and the failure is an
# unhelpful xcodebuild destination error.
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
  # xctrace lists physical devices before simulators; exclude anything that
  # names itself a simulator, and take the first iPhone.
  udid=$(xcrun xctrace list devices 2>/dev/null \
           | grep -E "iPhone.*\(" | grep -iv "simulator" \
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
