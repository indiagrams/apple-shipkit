#!/bin/bash
# ci/check-app-icon.sh — refuse to release a placeholder app icon.
#
# WHY THIS EXISTS
#
# This template ships a placeholder icon — a flat blue square — and a fork that
# never replaces it will hand that square to App Store review. At least one has:
# it came back as a Guideline 2.3.8 (Accurate Metadata) rejection, one full
# review cycle spent.
#
# Nothing objected on the way out. The asset was a valid 1024x1024 PNG, every CI
# cell was green, and App Store Connect's upload validation accepted it. The
# first thing to notice was a human reviewer.
#
# The check that existed was looking at the wrong thing: doctor's Icon1024 step
# compares the icon's hash against ICON_1024_PATH, so pointing that at a
# placeholder reports "done". Presence was verified; content never was.
#
# This runs on the RELEASE path only, not on every build. The template's own
# icon is a placeholder by design, so a fork must stay free to build and test
# with it — what must not happen is shipping it.
#
# WHAT COUNTS AS A PLACEHOLDER
#
# A single flat colour, or a smooth gradient with nothing drawn on it. Measured
# structurally, without knowing anything about the app's brand: quantise the
# icon to 8 colours and take the largest distance between any two clusters that
# each cover at least 3% of the image. Artwork puts distant clusters on the
# canvas; a flat fill or a bare gradient does not.
#
#   this template's placeholder icon    spread   0   -> placeholder
#   a real app icon (gradient + mark)   spread 282   -> art
#
# The threshold is 40, which sits with wide margin on both sides of a gap that
# is 0 vs 282 in practice.
#
# NO PILLOW. Icons inside a built .ipa are CgBI PNGs (Apple's crushed variant)
# and Pillow refuses them with "broken data stream", which would make this check
# silently skip exactly the artifact that matters most. sips reads them, so the
# pixels come via `sips -s format bmp` and a stdlib BMP parse.
#
# Escape hatch, for a design that really is one flat colour:
#   ALLOW_PLACEHOLDER_ICON=true

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0

check_icon() {
  local label="$1" path="$2" want_size="$3"
  if [ ! -f "$path" ]; then
    echo "  FAIL $label: not found at $path" >&2
    fail=1
    return
  fi

  local w h alpha
  w=$(sips -g pixelWidth  "$path" 2>/dev/null | awk '/pixelWidth/  { print $2 }')
  h=$(sips -g pixelHeight "$path" 2>/dev/null | awk '/pixelHeight/ { print $2 }')
  alpha=$(sips -g hasAlpha "$path" 2>/dev/null | awk '/hasAlpha/ { print $2 }')

  if [ "$w" != "$want_size" ] || [ "$h" != "$want_size" ]; then
    echo "  FAIL $label: is ${w}x${h}, expected ${want_size}x${want_size}" >&2
    fail=1
    return
  fi

  # Apple rejects an App Store icon with an alpha channel outright.
  if [ "$alpha" = "yes" ]; then
    echo "  FAIL $label: has an alpha channel; Apple rejects app icons with alpha" >&2
    fail=1
    return
  fi

  local spread
  spread=$(icon_spread "$path")
  if [ -z "$spread" ]; then
    echo "  FAIL $label: could not read pixels (sips conversion failed)" >&2
    fail=1
    return
  fi

  # Integer compare; icon_spread prints a rounded value.
  if [ "$spread" -lt 40 ]; then
    if [ "${ALLOW_PLACEHOLDER_ICON:-}" = "true" ]; then
      echo "  warn $label: looks like a placeholder (spread $spread) — allowed by ALLOW_PLACEHOLDER_ICON"
    else
      echo "  FAIL $label: looks like a placeholder — flat colour or bare gradient (spread $spread, need >= 40)." >&2
      echo "       This is Guideline 2.3.8, and it costs a full review cycle to learn from Apple." >&2
      echo "       Replace the icon, or set ALLOW_PLACEHOLDER_ICON=true if this is deliberate." >&2
      fail=1
    fi
    return
  fi

  echo "  ok   $label ${w}x${w}, no alpha, spread $spread"
}

# Largest distance between dominant colour clusters, as an integer.
icon_spread() {
  local bmp
  bmp=$(mktemp -t iconprobe).bmp
  sips -s format bmp --resampleHeightWidth 64 64 "$1" --out "$bmp" >/dev/null 2>&1 || { rm -f "$bmp"; return 1; }
  python3 - "$bmp" <<'PY'
import struct, sys, itertools, math
d = open(sys.argv[1], "rb").read()
off = struct.unpack_from("<I", d, 10)[0]
w, h = struct.unpack_from("<ii", d, 18)
bpp = struct.unpack_from("<H", d, 28)[0]
h = abs(h)
step = bpp // 8
row = ((bpp * w + 31) // 32) * 4
px = []
for y in range(h):
    base = off + y * row
    for x in range(w):
        i = base + x * step
        b, g, r = d[i], d[i+1], d[i+2]          # BMP is BGR
        px.append((r // 32 * 32, g // 32 * 32, b // 32 * 32))  # coarse quantise
from collections import Counter
total = len(px)
big = [c for c, n in Counter(px).items() if n / total >= 0.03]
if len(big) < 2:
    print(0)
else:
    print(int(max(math.dist(a, b) for a, b in itertools.combinations(big, 2))))
PY
  rm -f "$bmp"
}

echo "==> App icon check"

# iOS marketing icon, resolved from the asset catalog rather than hardcoded.
IOS_SET="app/iOS/Assets.xcassets/AppIcon.appiconset"
if [ -d "$IOS_SET" ]; then
  IOS_ICON=$(python3 -c "
import json,sys
c=json.load(open('$IOS_SET/Contents.json'))
n=[i.get('filename') for i in c.get('images',[]) if i.get('size')=='1024x1024' and i.get('filename')]
print(n[0] if n else '')
" 2>/dev/null)
  if [ -n "$IOS_ICON" ]; then
    check_icon "iOS 1024 icon" "$IOS_SET/$IOS_ICON" 1024
  else
    echo "  FAIL iOS asset catalog declares no 1024x1024 icon" >&2
    fail=1
  fi
fi

# macOS: the 512@2x entry is the 1024 the App Store uses.
MAC_ICON="app/macOS/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
[ -f "$MAC_ICON" ] && check_icon "macOS 1024 icon" "$MAC_ICON" 1024

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: releasing this icon invites a Guideline 2.3.8 rejection." >&2
  exit 1
fi
echo "passed"
exit 0
