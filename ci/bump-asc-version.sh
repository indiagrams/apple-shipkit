#!/bin/bash
# ci/bump-asc-version.sh — prepare both iOS + macOS App Store records for a
# new version submission, end-to-end:
#
#   1. (optional) Capture iOS + macOS screenshots into fastlane/screenshots/
#   2. Bump the App Store version_string on ASC for both platforms
#   3. Attach the matching TestFlight build to each version
#   4. Re-upload metadata (name/description/keywords/URLs/copyright)
#   5. Re-upload screenshots
#
# After this completes, both ASC records are "Prepare for Submission" with
# all metadata + screenshots populated and the new TestFlight build attached.
# All that's left is `fastlane ios submit_for_review` / `mac submit_for_review`.
#
# Usage:
#   ci/bump-asc-version.sh v0.0.11
#   ci/bump-asc-version.sh v0.0.11 --no-capture       # skip screenshot capture
#   ci/bump-asc-version.sh v0.0.11 --ios-only         # only iOS
#   ci/bump-asc-version.sh v0.0.11 --macos-only       # only macOS
#
# Prerequisites:
#   - .bootstrap.env with ASC_API_KEY_ID, ASC_API_KEY_ISSUER_ID, ASC_API_KEY_P8_BASE64
#   - A TestFlight build at the target version for each platform (run
#     `fastlane release tag:vX.Y.Z` first if not).
#
# Idempotent: re-running with the same tag re-uploads metadata + screenshots
# but skips the version bump / build attach when already in target state.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [ $# -lt 1 ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n 's/^# \?//p' "$0" | head -32
  exit 2
fi

TAG="$1"
shift
CAPTURE=true
IOS=true
MACOS=true
for arg in "$@"; do
  case "$arg" in
    --no-capture)  CAPTURE=false ;;
    --ios-only)    MACOS=false ;;
    --macos-only)  IOS=false ;;
    *)             echo "error: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

# Pin Ruby to .ruby-version so bundler finds the gems installed under
# vendor/bundle/ruby/<MAJOR.MINOR>.0/ (see ci/take-screenshots.sh for
# the full rationale — brew's unversioned `ruby` symlink moves with
# each major release and silently breaks `bundle exec`).
RUBY_VER="$(cat "$(dirname "$0")/../.ruby-version" 2>/dev/null || echo 3.3)"
RUBY_MM="$(echo "$RUBY_VER" | awk -F. '{ print $1 "." $2 }')"
if [ -d "/opt/homebrew/opt/ruby@${RUBY_MM}/bin" ]; then
  export PATH="/opt/homebrew/opt/ruby@${RUBY_MM}/bin:$PATH"
elif [ -d "/opt/homebrew/opt/ruby/bin" ]; then
  echo "WARN: brew ruby@${RUBY_MM} not installed; falling back to /opt/homebrew/opt/ruby." >&2
  export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
fi

# .bootstrap.env for ASC API key (legacy .env.local supported as fallback)
if [ -f .bootstrap.env ]; then
  set -a
  # shellcheck disable=SC1091
  set -a; source .bootstrap.env; set +a
  set +a
fi

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }

# ── 1. Capture screenshots ────────────────────────────────────────────────────
if $CAPTURE; then
  capture_args=()
  $IOS   || capture_args+=(--macos-only)
  $MACOS || capture_args+=(--ios-only)
  step "Capture screenshots"
  # "${a[@]}" on an empty array is an unbound-variable error under `set -u` in
  # bash 3.2, which is what /bin/bash still is on macOS. capture_args is empty
  # in the default both-platform mode, so this aborted every default run.
  ./ci/take-screenshots.sh ${capture_args[@]+"${capture_args[@]}"}
fi

# ── 2 + 3. Bump ASC version + attach TestFlight build ────────────────────────
step "Bump ASC App Store version + attach TestFlight build for $TAG"
bundle exec ruby ci/bump-asc-version.rb "$TAG"

# ── 4. Re-upload metadata ────────────────────────────────────────────────────
if $IOS; then
  step "Re-upload iOS metadata"
  bundle exec fastlane ios upload_metadata
  ok "iOS metadata refreshed"
fi
if $MACOS; then
  step "Re-upload macOS metadata"
  bundle exec fastlane mac upload_metadata
  ok "macOS metadata refreshed"
fi

# ── 5. Re-upload screenshots ─────────────────────────────────────────────────
if $IOS; then
  step "Re-upload iOS screenshots"
  bundle exec fastlane ios upload_screenshots
  ok "iOS screenshots uploaded"
fi
if $MACOS; then
  step "Re-upload macOS screenshots"
  bundle exec fastlane mac upload_screenshots
  ok "macOS screenshots uploaded"
fi

step "Done"
ok "Both ASC records ready at $TAG."
ok "Submit when ready:"
# Plain `$IOS && ok ...` as the final command makes the script exit non-zero
# whenever that flag is false, reporting failure after a clean run.
if $IOS;   then ok "  bundle exec fastlane ios submit_for_review"; fi
if $MACOS; then ok "  bundle exec fastlane mac submit_for_review"; fi
