#!/bin/bash
# ci/check-embedded-floors.sh
# Every framework embedded in a built .app must load on the oldest OS the app
# says it supports.
# Usage: bash ci/check-embedded-floors.sh <path/to/Built.app>
# Exit 0 = consistent (including "nothing embedded"); 1 = a framework is too new;
#      2 = cannot run (bad arguments, no app, unreadable binary).
#
# WHY THIS EXISTS
#
# Declare a deployment target below the `minos` of a framework you embed and
# nothing objects. It compiles. It links. It signs, uploads, passes App Review,
# and installs from the App Store onto exactly the OS versions you promised —
# and then dyld refuses the framework and the app dies at launch, on those
# versions only.
#
# CI cannot see it, because CI runs current OSes where the floor never matters.
# The failure exists only on the old systems the floor exists to promise, and
# those are precisely the systems no one tests on.
#
# At most you get one line, easily lost in a build log:
#
#     ld: warning: object file (libfoo.a[10]) was built for newer 'macOS'
#     version (15.0) than being linked (14.0)
#
# A downstream fork of this template shipped this bug twice, once in a build
# submitted to App Review, with every CI cell green throughout.
#
# WHAT IT COMPARES, AND WHY THAT
#
# The app's floor is read from Info.plist — `MinimumOSVersion` (iOS) or
# `LSMinimumSystemVersion` (macOS) — because that is the number the App Store
# enforces when deciding which devices may install the app. It is the promise
# actually made to users. Each embedded Mach-O's floor is read from its
# `LC_BUILD_VERSION`, per architecture, because that is what dyld checks at load.
#
# Comparing the BUILT APP rather than project manifests is deliberate. This
# template supports xcodegen, Tuist, and raw .xcodeproj, and a fork may add SPM,
# Carthage or a hand-dropped xcframework. There is no manifest shape common to
# all of them — but every built app has Frameworks/ full of Mach-O binaries, so
# the artifact is the one place the question has a uniform answer. It is also
# the honest one: manifests say what was intended, the bundle says what ships.
#
# WHAT IT DOES NOT DO
#
# It cannot catch a binary that is wrong about ITSELF — a framework stamped
# `minos 14.0` while containing objects built for 15.0. `LC_BUILD_VERSION` is a
# claim, and this reads the claim. The only signal for that case is the `ld:`
# warning above, so do not let your build discard it.
#
# It also does not prove the app runs on its floor. That needs an old OS: a
# simulator runtime in the supported range, or a real device. GitHub's macOS
# images carry neither, which is why this check is structural and lives in CI
# while a runtime check does not.
set -uo pipefail

APP="${1:-}"
if [ -z "$APP" ]; then
  echo "usage: bash ci/check-embedded-floors.sh <path/to/Built.app>" >&2
  exit 2
fi
if [ ! -d "$APP" ]; then
  # FAIL rather than skip. A check that quietly does nothing when its input is
  # missing is how a wrong floor survives: every run is green and none of them
  # looked at anything.
  echo "  CANNOT RUN: no app bundle at '$APP'" >&2
  exit 2
fi

# macOS bundles nest under Contents/; iOS bundles do not.
if [ -d "$APP/Contents/MacOS" ]; then
  PLIST="$APP/Contents/Info.plist"; FW_DIR="$APP/Contents/Frameworks"; PLATFORM="macOS"
  FLOOR_KEY="LSMinimumSystemVersion"
else
  PLIST="$APP/Info.plist"; FW_DIR="$APP/Frameworks"; PLATFORM="iOS"
  FLOOR_KEY="MinimumOSVersion"
fi
[ -f "$PLIST" ] || { echo "  CANNOT RUN: no Info.plist in '$APP'" >&2; exit 2; }

APP_FLOOR="$(plutil -extract "$FLOOR_KEY" raw "$PLIST" 2>/dev/null)"
if [ -z "$APP_FLOOR" ] || [ "$APP_FLOOR" = "null" ]; then
  echo "  CANNOT RUN: $PLIST has no $FLOOR_KEY" >&2
  exit 2
fi

# "17.0" -> 17000000, so shell arithmetic orders versions correctly.
vnum() { echo "$1" | awk -F. '{ printf "%d%03d%03d", $1, ($2==""?0:$2), ($3==""?0:$3) }'; }

echo "==> Embedded framework floor check"
echo "  app:      $(basename "$APP") ($PLATFORM)"
echo "  declares: $FLOOR_KEY $APP_FLOOR"

if [ ! -d "$FW_DIR" ]; then
  # A PASS, and said out loud. Most forks embed nothing, and that is fine — but
  # "I looked and there was nothing" must be distinguishable from "I did not
  # look", which is the failure mode this whole file exists to avoid.
  echo "  ok   no Frameworks/ directory — nothing is embedded, nothing to compare"
  echo
  echo "passed"
  exit 0
fi

fail=0
checked=0

while IFS= read -r bin; do
  [ -f "$bin" ] || continue
  file "$bin" 2>/dev/null | grep -q "Mach-O" || continue
  name="${bin#"$APP"/}"

  # Per architecture: a universal binary can carry a different floor in each
  # slice, and dyld checks the slice it actually loads.
  archs="$(lipo -archs "$bin" 2>/dev/null || echo "")"
  [ -n "$archs" ] || archs="$(uname -m)"
  for arch in $archs; do
    minos="$(otool -l -arch "$arch" "$bin" 2>/dev/null \
             | awk '/LC_BUILD_VERSION/ { f=1 } f && /minos/ { print $2; exit }')"
    [ -n "$minos" ] || continue
    checked=$((checked + 1))
    if [ "$(vnum "$minos")" -gt "$(vnum "$APP_FLOOR")" ]; then
      # Braces on every expansion here: an earlier version wrote "$APP_FLOOR-$minos"
      # with an en-dash, and bash folded the dash's first UTF-8 byte into the
      # variable name, so `set -u` aborted the script on this branch only. The
      # failure path is the one least often exercised; keep it boring.
      echo "  FAIL ${name} [${arch}] needs ${minos}, but the app declares ${APP_FLOOR}"
      echo "       Between ${PLATFORM} ${APP_FLOOR} and ${minos} the app installs and then"
      echo "       dyld refuses this framework at launch. Raise ${FLOOR_KEY} to ${minos},"
      echo "       or rebuild the framework at ${APP_FLOOR}."
      fail=1
    else
      echo "  ok   $name [$arch] minos $minos <= $APP_FLOOR"
    fi
  done
done < <(find "$FW_DIR" -type f 2>/dev/null | sort)

if [ "$checked" -eq 0 ]; then
  echo "  ok   Frameworks/ exists but contains no Mach-O binaries with a build version"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "passed ($checked slice(s) checked)"
  exit 0
fi
echo "FAILED — an embedded framework needs a newer OS than the app promises." >&2
exit 1
