#!/usr/bin/env bash
# ci/test-switch-to-xcodegen.sh — gate + integration test for bin/switch-to-xcodegen.sh.
#
# Mirrors ci/test-switch-to-tuist.sh's structure, exercising the inverse
# direction:
#   - clone main to tmpdir
#   - apply switch-to-tuist.sh + commit (fixture: tree is now tuist-shaped)
#   - run switch-to-xcodegen.sh and verify:
#     * --dry-run produces a plan + leaves the tree clean
#     * forced-failure rollback restores the tuist state
#     * real run produces an xcodegen-shaped tree
#     * idempotency: a second run is a silent no-op
#     * `xcodegen generate` succeeds on the result
#     * `make check` is green on the result
#
# Runs against a fresh clone of REPO_ROOT in a tmpdir so the running tree
# is unaffected. Total budget ~3 min (xcodegen build dominates).
#
# Usage:
#   ci/test-switch-to-xcodegen.sh   # run from repo root
#
# Exit 0 = green; non-zero = a gate behaved unexpectedly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR=""

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap 'cleanup' EXIT INT TERM

# ── Pre-flight ────────────────────────────────────────────────────────────
step "Pre-flight"
cd "$REPO_ROOT"
test -x bin/switch-to-xcodegen.sh || fail "bin/switch-to-xcodegen.sh not executable in $REPO_ROOT"
test -x bin/switch-to-tuist.sh    || fail "bin/switch-to-tuist.sh not executable (needed to set up fixture)"
test -f app/project.yml           || fail "app/project.yml missing — unexpected pre-test state"
test -f app/Project.swift         || fail "app/Project.swift missing — PR #1 not landed?"
command -v git      >/dev/null || fail "git not on PATH"
command -v xcodegen >/dev/null || fail "xcodegen not on PATH — install via 'brew install xcodegen'"
command -v tuist    >/dev/null || fail "tuist not on PATH — install via 'brew install --cask tuist'"
command -v make     >/dev/null || fail "make not on PATH"
ok "tools present"

# ── Clone + set up fixture (apply switch-to-tuist + commit) ──────────────
step "Clone REPO_ROOT to tmpdir + flip to tuist fixture"
WORK_DIR="$(mktemp -d -t test-switch-to-xcodegen-XXXXXX)"
git clone --no-hardlinks --quiet "$REPO_ROOT" "$WORK_DIR"
( cd "$WORK_DIR" && git checkout --quiet -B main HEAD )
( cd "$WORK_DIR" && bin/switch-to-tuist.sh >/dev/null ) || fail "fixture setup: switch-to-tuist.sh failed"
( cd "$WORK_DIR" && git add -A && git commit --quiet -m "Switch to Tuist (test fixture)" )
test ! -f "$WORK_DIR/app/project.yml" || fail "fixture: app/project.yml should be removed after switch-to-tuist"
ok "fixture: tree is now tuist-shaped (and committed)"

# ── --dry-run leaves the tree clean ──────────────────────────────────────
step "--dry-run produces plan + leaves tree clean"
STATUS_BEFORE=$(cd "$WORK_DIR" && git status --short | sort)
set +e
DR_OUT=$(cd "$WORK_DIR" && bin/switch-to-xcodegen.sh --dry-run 2>&1)
DR_EXIT=$?
set -e
STATUS_AFTER=$(cd "$WORK_DIR" && git status --short | sort)

test "$DR_EXIT" -eq 0 || fail "--dry-run exited $DR_EXIT (expected 0); output: $DR_OUT"
echo "$DR_OUT" | grep -q "DRY RUN" || fail "--dry-run output missing 'DRY RUN'; got: $DR_OUT"
echo "$DR_OUT" | grep -q "Would restore" || fail "--dry-run output missing 'Would restore'; got: $DR_OUT"
echo "$DR_OUT" | grep -q "Would edit" || fail "--dry-run output missing 'Would edit'; got: $DR_OUT"
test "$STATUS_BEFORE" = "$STATUS_AFTER" || \
  fail "--dry-run modified the tree:
BEFORE: $STATUS_BEFORE
AFTER:  $STATUS_AFTER"
ok "--dry-run printed plan + tree unchanged"

# ── Forced-failure rollback (chmod 000 trick) ─────────────────────────────
step "Forced-failure rollback (chmod 000 Brewfile)"
chmod 000 "$WORK_DIR/Brewfile"
set +e
( cd "$WORK_DIR" && bin/switch-to-xcodegen.sh >/dev/null 2>&1 )
RB_EXIT=$?
set -e
chmod 644 "$WORK_DIR/Brewfile" 2>/dev/null || true

test "$RB_EXIT" -ne 0 || fail "rollback test: forced failure should exit non-zero (got $RB_EXIT)"
DIRTY=$(cd "$WORK_DIR" && git status --short | wc -l | tr -d ' ')
test "$DIRTY" = "0" || \
  fail "rollback test: working tree not clean after rollback (got $DIRTY entries):
$(cd "$WORK_DIR" && git status --short)"
test ! -f "$WORK_DIR/app/project.yml" || \
  fail "rollback test: app/project.yml shouldn't be present (we're in tuist-fixture state)"
ok "forced-failure rollback restored pre-switch (tuist) state (exit $RB_EXIT)"

# ── Real switch ───────────────────────────────────────────────────────────
step "Real switch (clean run)"
( cd "$WORK_DIR" && bin/switch-to-xcodegen.sh ) || fail "bin/switch-to-xcodegen.sh failed on clean tree"

test -f "$WORK_DIR/app/project.yml" || fail "post-switch: app/project.yml missing"
test -f "$WORK_DIR/app/Project.swift" || fail "post-switch: app/Project.swift missing"
test -f "$WORK_DIR/Tuist.swift" || fail "post-switch: Tuist.swift missing"

grep -q '^brew "xcodegen"' "$WORK_DIR/Brewfile" || \
  fail "post-switch: Brewfile missing 'brew \"xcodegen\"'"
grep -q 'cd app && xcodegen generate' "$WORK_DIR/Makefile" || \
  fail "post-switch: Makefile missing 'cd app && xcodegen generate'"
! grep -q 'cd app && tuist generate --no-open' "$WORK_DIR/Makefile" || \
  fail "post-switch: Makefile still has 'cd app && tuist generate --no-open'"
grep -q 'require_cmd xcodegen' "$WORK_DIR/ci/local-check.sh" || \
  fail "post-switch: ci/local-check.sh missing 'require_cmd xcodegen'"
! grep -q 'require_cmd tuist' "$WORK_DIR/ci/local-check.sh" || \
  fail "post-switch: ci/local-check.sh still has 'require_cmd tuist'"
# pr.yml is intentionally NOT mutated by switch-to-xcodegen.sh anymore — the
# matrix builder in pr.yml detects which generator manifests are present
# (app/project.yml ↔ xcodegen, app/Project.swift ↔ tuist) and only emits
# matching cells. After switch-to-xcodegen restores app/project.yml, pr.yml's
# matrix gains xcodegen cells at runtime with no edits to the workflow.
# (Project.swift is left in place — switch-to-xcodegen is an additive restore,
# not a true inverse; the matrix runs both generators when both manifests
# coexist, which matches apple-shipkit/smoketest template default.)
[ -f "$WORK_DIR/app/project.yml" ] || \
  fail "post-switch: app/project.yml missing (matrix would have no xcodegen cells)"
ok "all 5 mutation surfaces verified post-switch + pr.yml matrix invariant"

# ── Idempotency: second run is silent no-op ───────────────────────────────
step "Idempotency: second run is silent no-op"
( cd "$WORK_DIR" && git add -A && git commit --quiet -m "Switch to XcodeGen (test fixture commit)" )
STATUS_BEFORE=$(cd "$WORK_DIR" && git status --short | sort)
set +e
OUT=$(cd "$WORK_DIR" && bin/switch-to-xcodegen.sh 2>&1)
EXIT=$?
set -e
STATUS_AFTER=$(cd "$WORK_DIR" && git status --short | sort)

test "$EXIT" -eq 0 || fail "second run exit $EXIT (expected 0 silent no-op); output: $OUT"
test -z "$OUT" || fail "second run was not silent (expected empty stdout, got):
$OUT"
test "$STATUS_BEFORE" = "$STATUS_AFTER" || \
  fail "second run modified the tree:
BEFORE: $STATUS_BEFORE
AFTER:  $STATUS_AFTER"
ok "second run was silent no-op (exit 0; status unchanged; stdout empty)"

# ── Integration: xcodegen generate succeeds on the switched tree ─────────
step "Integration: xcodegen generate on switched tree"
( cd "$WORK_DIR/app" && xcodegen generate >/dev/null 2>&1 ) || \
  fail "xcodegen generate failed on switched tree"
test -d "$WORK_DIR/app/App.xcodeproj" || \
  fail "xcodegen generate did not produce app/App.xcodeproj"
ok "xcodegen generate produces app/App.xcodeproj"

# ── Integration: make check green on the switched tree ────────────────────
step "Integration: make check (iOS device build) on switched tree"
bash -euo pipefail <<BASH
cd "$WORK_DIR"
set +e
make check 2>&1 | tee .test-switch-make-check.log
EXIT=\${PIPESTATUS[0]}
set -e
test "\$EXIT" -eq 0 || { echo "ERROR: make check failed with exit \$EXIT"; exit 1; }
BASH
ok "make check exit 0 on switched tree"

# ── Done ──────────────────────────────────────────────────────────────────
step "ci/test-switch-to-xcodegen.sh: all assertions passed"
ok "tmpdir cleanup will run via EXIT trap"
