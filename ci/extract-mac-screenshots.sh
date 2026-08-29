#!/bin/bash
# ci/extract-mac-screenshots.sh — pull macOS App Store screenshots out of an
# xcresult bundle.
#
# Why this exists: fastlane snapshot is iOS-only. The macOS screenshot pipeline
# is XCUITest + XCTAttachment, which writes attachments into the .xcresult.
# This script extracts the PNGs and copies them into
# fastlane/Mac_screenshots/en-US/, where `fastlane upload_screenshots`
# (deliver) infers the macOS device type from the PNG dimensions
# (2880×1800 → APP_DESKTOP, 1440×900 → APP_DESKTOP, etc.).
#
# Why fastlane/Mac_screenshots/ (separate top-level dir, not en-US/Mac/
# subfolder): fastlane's deliver action globs ALL files under its
# `screenshots_path` and assigns display types from PNG dimensions —
# when iOS + macOS share one parent (fastlane/screenshots/en-US/), the
# iOS lane tries to upload macOS PNGs and Apple's API rejects with
# "Display Type Not Allowed" (the parallel macOS lane has the same
# problem in reverse). Separate top-level dirs let the Fastfile pass
# `screenshots_path:` per platform — iOS reads from fastlane/screenshots/,
# macOS reads from fastlane/Mac_screenshots/, neither sees the other's
# files.
#
# Usage:
#   ci/extract-mac-screenshots.sh <path-to.xcresult>
#
# Output: fastlane/Mac_screenshots/en-US/macos-*.png

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -lt 1 ]; then
  sed -n 's/^# \?//p' "$0" | head -15
  exit 2
fi

XCRESULT="$1"
if [ ! -d "$XCRESULT" ]; then
  echo "error: xcresult bundle not found: $XCRESULT" >&2
  exit 2
fi

# Write into fastlane/Mac_screenshots/en-US/ (separate top-level dir
# from iOS to keep deliver from cross-uploading; see header for full
# rationale).
OUT_DIR="$REPO_ROOT/fastlane/Mac_screenshots/en-US"
mkdir -p "$OUT_DIR"

# Clear any prior macos-*.png to avoid stale duplicates if attachment names
# changed. Don't touch iOS PNGs — fastlane snapshot writes them flat to the
# same en-US/ folder with device-prefixed names like
# "iPhone 16 Plus-01-home.png".
rm -f "$OUT_DIR"/macos-*.png

# xcrun xcresulttool's --legacy flag is required on Xcode 16+ where the new
# default JSON format dropped attachment listings. Attachments are nested
# inside ActionTestSummary refs reached via References at the test-summary
# level — Python walks the tree, follows References as needed.
python3 - "$XCRESULT" "$OUT_DIR" <<'PY'
import json
import os
import subprocess
import sys

xcresult, out_dir = sys.argv[1], sys.argv[2]


def get_json(*args):
    """Fetch JSON via xcresulttool. Some refs aren't JSON (binary payloads);
    swallow stderr noise and return None so callers can skip them gracefully."""
    cmd = ["xcrun", "xcresulttool", "get", "--legacy",
           "--path", xcresult, "--format", "json", *args]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
        return json.loads(out)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def collect_attachments(obj, hits):
    """Walk dict/list and collect every attachment reachable in this object."""
    if isinstance(obj, dict):
        t = obj.get("_type", {}).get("_name", "")
        if "Attachment" in t:
            name = (obj.get("name", {}).get("_value")
                    or obj.get("filename", {}).get("_value", ""))
            payload = obj.get("payloadRef", {}).get("id", {}).get("_value", "")
            if name and payload:
                hits.append((name, payload))
        for v in obj.values():
            collect_attachments(v, hits)
    elif isinstance(obj, list):
        for v in obj:
            collect_attachments(v, hits)


def collect_references(obj, refs):
    """Walk dict/list and collect every Reference's id (for follow-up fetch)."""
    if isinstance(obj, dict):
        t = obj.get("_type", {}).get("_name", "")
        if t == "Reference":
            rid = obj.get("id", {}).get("_value", "")
            if rid:
                refs.append(rid)
        for v in obj.values():
            collect_references(v, refs)
    elif isinstance(obj, list):
        for v in obj:
            collect_references(v, refs)


# Start at the top of the xcresult, find the testsRef, walk down through
# Reference chains until we hit attachments. Cap depth at 5 to avoid cycles.
visited = set()
attachments = []
work = [None]  # None = top-level
depth = 0

while work and depth < 5:
    next_work = []
    for ref_id in work:
        args = ("--id", ref_id) if ref_id else ()
        if ref_id in visited:
            continue
        if ref_id:
            visited.add(ref_id)
        data = get_json(*args)
        if data is None:
            continue  # not a JSON ref — likely a binary payload, skip
        collect_attachments(data, attachments)
        # Find any nested References to recurse into.
        nested = []
        collect_references(data, nested)
        for n in nested:
            if n not in visited:
                next_work.append(n)
    work = next_work
    depth += 1

# Dedupe by name (keep first occurrence).
seen = set()
unique = []
for name, payload in attachments:
    # Strip the xcresult-temp suffix that Xcode appends to attachment filenames:
    # "macos-01-home_0_F8D23318-...png" → keep our XCTAttachment.name "macos-01-home"
    # Logic: prefer the .name (set via attachment.name = "..."); only fall back to filename.
    # Already done above (name preferred), so just normalize PNG suffix here.
    if not name.lower().endswith(".png"):
        name = f"{name}.png"
    if name in seen:
        continue
    seen.add(name)
    unique.append((name, payload))

if not unique:
    print(f"error: no attachments found in {xcresult}", file=sys.stderr)
    sys.exit(1)

# Apple App Store macOS screenshot sizes — exact match required, no flexibility.
APPLE_SIZES = [(2880, 1800), (2560, 1600), (1440, 900), (1280, 800)]

def crop_to_apple_size(path):
    """Crop a window screenshot to the nearest Apple App Store macOS size.

    Anchored on the window's own opaque rectangle, not on the image centre.
    XCUITest returns the window plus its drop-shadow margin, and the window
    server does not place the window identically on every run — a fixed centre
    or edge offset therefore crops a different part of the frame each time,
    which on one run clipped the title mid-glyph and on the next left a band of
    empty margin. Locating the opaque rect first makes the result deterministic:
    the crop starts at the window's top-left corner, so the title bar is always
    whole and only the shadow and trailing whitespace are discarded.
    """
    try:
        from PIL import Image
    except ImportError:
        print("    warn: Pillow not available; screenshot left uncropped "
              "(Apple requires an exact size and will reject it)", file=sys.stderr)
        return False

    im = Image.open(path)
    w, h = im.size
    target = next(((tw, th) for tw, th in APPLE_SIZES if tw <= w and th <= h), None)
    if not target:
        print(f"    warn: {os.path.basename(path)} ({w}x{h}) is smaller than every "
              f"Apple-accepted size; left as-is", file=sys.stderr)
        return False
    tw, th = target

    # The opaque window rect. Shadow pixels are partially transparent, so a
    # near-opaque threshold separates the window from the shadow that surrounds it.
    x0 = y0 = 0
    if im.mode == "RGBA":
        solid = im.getchannel("A").point(lambda a: 255 if a >= 250 else 0)
        box = solid.getbbox()
        if box:
            x0, y0 = box[0], box[1]

    # Clamp so the crop stays inside the image.
    x0 = max(0, min(x0, w - tw))
    y0 = max(0, min(y0, h - th))

    if (w, h) == (tw, th) and (x0, y0) == (0, 0):
        return True

    im.crop((x0, y0, x0 + tw, y0 + th)).save(path, "PNG")
    print(f"    cropped: {os.path.basename(path)} {w}x{h} → {tw}x{th} "
          f"(anchored at window {x0},{y0})")
    return True


def flatten_alpha(path):
    """Composite the screenshot onto opaque white and strip the alpha channel.

    XCUITest window captures carry the window's drop-shadow margin and rounded
    corners as fully transparent pixels (0,0,0,0). Two problems: Apple rejects
    App Store screenshots that contain an alpha channel outright, and any viewer
    that does keep the alpha renders those regions black, which reads as a
    rendering glitch around the window corners. White matches the app's own
    background, so the margin disappears into the frame."""
    out = subprocess.run(
        ["sips", "-s", "format", "png", "-s", "formatOptions", "best",
         "--matchTo", "/System/Library/ColorSync/Profiles/sRGB Profile.icc",
         path, "--out", path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    # sips has no alpha-flatten verb, so composite explicitly.
    try:
        from PIL import Image
    except ImportError:
        print("    warn: Pillow not available; alpha channel left in place "
              "(Apple will reject the upload)", file=sys.stderr)
        return False
    im = Image.open(path)
    if im.mode != "RGBA":
        return True
    bg = Image.new("RGB", im.size, (255, 255, 255))
    bg.paste(im, mask=im.split()[3])
    bg.save(path, "PNG")
    print(f"    flattened: {os.path.basename(path)} RGBA → RGB on white")
    return True


count = 0
for name, payload in unique:
    out_path = os.path.join(out_dir, name)
    subprocess.run(
        ["xcrun", "xcresulttool", "get", "--legacy",
         "--path", xcresult, "--id", payload],
        stdout=open(out_path, "wb"),
        check=True,
    )
    size = os.path.getsize(out_path)
    print(f"    extracted: {name} ({size:,} bytes)")
    crop_to_apple_size(out_path)
    flatten_alpha(out_path)
    count += 1

print(f"    ✓ {count} screenshot(s) → {out_dir}")
PY
