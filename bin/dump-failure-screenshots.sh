#!/usr/bin/env bash
# bin/dump-failure-screenshots.sh — pull the screenshots for FAILED tests out of an .xcresult.
#
# THE SHARP EDGE THIS EXISTS FOR: `xcresulttool export attachments --only-failures`
# does not do what its name says. It looks for attachments inside XCTest *failure
# activities* (assertion records), not attachments taken at test scope — and a
# teardown screenshot (`XCTAttachment` added in `tearDown`, the usual place) is at
# test scope. So the flag returns nothing and the screenshots look lost.
#
# Drop the flag and the opposite happens: XCTest auto-generates a "Debug
# description" .txt plus a binary "UI Snapshot" for EVERY `waitForExistence`
# poll, so one 300-second wait buries the real PNG under 300+ junk attachments.
#
# The way through is per-test export plus a filter:
#   1. list the failed tests   (`xcresulttool get test-results tests`)
#   2. export each one by id   (`--test-id` catches test-scope attachments)
#   3. keep only .png          (drops the .txt and binary-plist noise)
#   4. rename UUID -> the attachment's own name, from the "suggested name" line
#
# Usage:   bin/dump-failure-screenshots.sh <xcresult-path> [output-dir]
# Output:  <output-dir>/<TestClass-testName>/<attachment-name>.png
# Exit:    always 0 — a missing screenshot must not mask the test failure itself.
#
# To get screenshots worth dumping, attach one in tearDown:
#   let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
#   shot.name = "final-state"; shot.lifetime = .keepAlways; add(shot)
set -euo pipefail

XCRESULT="${1:-}"
OUTPUT_DIR="${2:-/tmp/failure-screenshots}"

if [[ -z "$XCRESULT" ]]; then
  echo "usage: $0 <xcresult-path> [output-dir]" >&2
  exit 1
fi
if [[ ! -d "$XCRESULT" ]]; then
  echo "[screenshots] no xcresult at: $XCRESULT" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
echo "[screenshots] reading $(basename "$XCRESULT")"

# 1. Failed test identifiers. The JSON is a tree of testNodes; walk it for every
#    node that is a Test Case and Failed.
FAILED_TESTS=$(xcrun xcresulttool get test-results tests --path "$XCRESULT" 2>/dev/null | python3 -c '
import sys, json

def failed(node):
    out = []
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
            nid = node.get("nodeIdentifier", "")
            if nid:
                out.append(nid)
        for v in node.values():
            if isinstance(v, (dict, list)):
                out.extend(failed(v))
    elif isinstance(node, list):
        for item in node:
            out.extend(failed(item))
    return out

try:
    for t in failed(json.load(sys.stdin)):
        print(t)
except Exception:
    pass
' 2>/dev/null) || true

if [[ -z "$FAILED_TESTS" ]]; then
  echo "[screenshots] no failed tests in this bundle."
  exit 0
fi

FOUND=()
while IFS= read -r test_id; do
  [[ -z "$test_id" ]] && continue
  # "SuiteName/testSomething()" -> "SuiteName-testSomething"
  safe=$(echo "$test_id" | sed 's|/|-|g; s|[^a-zA-Z0-9_.-]||g')
  dir="$OUTPUT_DIR/$safe"
  mkdir -p "$dir"

  # xcresulttool writes its file map to stdout/stderr and exits non-zero even on
  # success, hence the `|| true` and the combined capture.
  OUT=$(xcrun xcresulttool export attachments \
          --path "$XCRESULT" --output-path "$dir" --test-id "$test_id" 2>&1) || true

  while IFS= read -r line; do
    # File: <UUID>.png, suggested name: "<name>_0_<UUID>.png"
    if [[ "$line" =~ ^File:\ ([A-F0-9-]+\.png),.*suggested\ name:\ \"(.+)\" ]]; then
      uuid="${BASH_REMATCH[1]}"
      suggested="${BASH_REMATCH[2]}"
      name=$(echo "$suggested" | sed 's/_[0-9]*_[0-9A-F-]*\.png$//')
      src="$dir/$uuid"; dest="$dir/${name}.png"
      if [[ -f "$src" ]]; then
        mv "$src" "$dest" 2>/dev/null || true
        FOUND+=("$dest")
        echo "[screenshots] $test_id -> $(basename "$dest")"
      fi
    fi
  done <<< "$OUT"
done <<< "$FAILED_TESTS"

# If the rename parsing ever drifts with a future xcresulttool, still surface
# whatever PNGs landed rather than reporting nothing.
if [[ ${#FOUND[@]} -eq 0 ]]; then
  while IFS= read -r f; do FOUND+=("$f"); done \
    < <(find "$OUTPUT_DIR" \( -name "*.png" -o -name "*.PNG" \) 2>/dev/null | sort)
fi

if [[ ${#FOUND[@]} -eq 0 ]]; then
  echo "[screenshots] failed tests, but no PNG attachments — is anything attaching one in tearDown?"
  exit 0
fi

echo
echo "[screenshots] ${#FOUND[@]} screenshot(s):"
for f in "${FOUND[@]}"; do echo "[screenshots]   $f"; done
