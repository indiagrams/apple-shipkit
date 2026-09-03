#!/usr/bin/env bash
# Local check — runs the same checks CI runs on PRs.
#
# Wired up as a pre-push hook via lefthook (see lefthook.yml). Also invokable
# directly:
#   ci/local-check.sh --fast            iOS device build (primary signal)
#   ci/local-check.sh --owner-app       iOS device + macOS
#   ci/local-check.sh --owner-app-sim   iOS Simulator (backup signal)
#
# Exit 0 = green; exit non-zero = at least one check failed.
#
# iOS device build is primary: it uses the iphoneos SDK, real entitlements
# pathway, and any device-only frameworks. Catches bugs the Simulator misses.
# Simulator is the backup for when a framework version mismatch breaks device.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mode="${1:---fast}"

case "$mode" in
  --fast|--owner-app|--owner-app-sim)
    : # accepted
    ;;
  -h|--help)
    sed -n '1,/^set -e/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "error: unknown mode '$mode'" >&2
    echo "usage: $0 [--fast | --owner-app | --owner-app-sim]" >&2
    exit 2
    ;;
esac

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not on PATH — run 'make bootstrap' (or 'brew bundle')"
}

# Verify shared release helpers (ci/lib/) match their pinned SHA-256s.
# Identical copies live in this template and downstream consumer projects.
# Drift would silently re-introduce per-project divergence — the exact
# problem the lib was created to prevent.
verify_helpers_in_sync() {
  if [ ! -f ci/lib/SHA256SUMS ] || [ ! -d ci/lib ]; then
    fail "ci/lib/SHA256SUMS missing — shared helper integrity cannot be checked"
  fi
  if ! shasum -a 256 -c ci/lib/SHA256SUMS --ignore-missing --quiet 2>&1; then
    fail "ci/lib/*.sh drifted from pinned SHA256SUMS — regenerate with \`shasum -a 256 ci/lib/*.sh > ci/lib/SHA256SUMS\`"
  fi
}

ensure_xcodeproj() {
  require_cmd xcodebuild
  require_cmd xcodegen
  step "app: xcodegen generate"
  ( cd app && xcodegen generate >/dev/null )
}

build_ios_device() {
  step "app: build iOS device"
  xcodebuild build \
    -project app/App.xcodeproj \
    -scheme App-iOS \
    -configuration Debug \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    | { command -v xcbeautify >/dev/null && xcbeautify --quiet --renderer terminal || cat; }
}

build_ios_sim() {
  step "app: build iOS Simulator"
  xcodebuild build \
    -project app/App.xcodeproj \
    -scheme App-iOS \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    | { command -v xcbeautify >/dev/null && xcbeautify --quiet --renderer terminal || cat; }
}

build_macos() {
  step "app: build macOS"
  xcodebuild build \
    -project app/App.xcodeproj \
    -scheme App-macOS \
    -configuration Debug \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    | { command -v xcbeautify >/dev/null && xcbeautify --quiet --renderer terminal || cat; }
}

step "preflight: shared release helpers in sync"
verify_helpers_in_sync

# Same check pr.yml's config job runs, so a hole in app/Identity.xcconfig is
# named here before xcodegen would silently generate around it.
ci/check-identity.sh || fail "app/Identity.xcconfig incomplete — see ci/check-identity.sh"

# Same check pr.yml's `shell scripts` job runs. Cheap (seconds) and worth having
# on the pre-push path: a broken shell script is otherwise invisible until a
# release runs it. Needs shellcheck, which is in the Brewfile.
ci/check-shell.sh || fail "a tracked shell script is broken — see ci/check-shell.sh"

case "$mode" in
  --fast)
    ensure_xcodeproj
    build_ios_device
    ;;
  --owner-app)
    ensure_xcodeproj
    build_ios_device
    build_macos
    ;;
  --owner-app-sim)
    ensure_xcodeproj
    build_ios_sim
    ;;
esac

printf '\n✓ local check passed\n'
