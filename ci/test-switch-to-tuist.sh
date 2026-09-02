#!/usr/bin/env bash
# ci/test-switch-to-tuist.sh — gate + integration test for bin/switch-to-tuist.sh.
#
# Why this exists:
#   bin/switch-to-tuist.sh is invoked by two callers (bin/rename.sh
#   --generator=tuist + the CI parity jobs). Both need confidence the
#   script:
#     - succeeds on a clean main + leaves the tree on Tuist
#     - is idempotent (a second run is a silent no-op)
#     - --dry-run produces a plan + leaves the tree clean
#     - rolls back atomically when a mutation fails (parity with
#       bin/rename.sh's reset-hard rollback)
#     - produces a tree where `tuist generate --no-open` succeeds and
#       `make check` is green
#
# Runs against a fresh clone of REPO_ROOT in a tmpdir so the running
# tree is unaffected. Total budget ~3min (xcodegen build dominates).
#
# Usage:
#   ci/test-switch-to-tuist.sh    # run from repo root
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
test -x bin/switch-to-tuist.sh || fail "bin/switch-to-tuist.sh not executable in $REPO_ROOT"
test -f Tuist.swift             || fail "Tuist.swift missing — PR #1 not landed?"
test -f app/Project.swift       || fail "app/Project.swift missing — PR #1 not landed?"
test -f app/project.yml         || fail "app/project.yml missing — unexpected pre-switch state"
command -v git    >/dev/null || fail "git not on PATH"
command -v tuist  >/dev/null || fail "tuist not on PATH — install via 'brew install --cask tuist'"
command -v make   >/dev/null || fail "make not on PATH"
ok "tools present + Tuist manifests present"

# ── Clone ─────────────────────────────────────────────────────────────────
step "Clone REPO_ROOT to tmpdir"
WORK_DIR="$(mktemp -d -t test-switch-to-tuist-XXXXXX)"
git clone --no-hardlinks --quiet "$REPO_ROOT" "$WORK_DIR"
( cd "$WORK_DIR" && git checkout --quiet -B main HEAD )
ok "cloned to $WORK_DIR"

# ── --dry-run leaves the tree clean ──────────────────────────────────────
step "--dry-run produces plan + leaves tree clean"
STATUS_BEFORE=$(cd "$WORK_DIR" && git status --short | sort)
set +e
DR_OUT=$(cd "$WORK_DIR" && bin/switch-to-tuist.sh --dry-run 2>&1)
DR_EXIT=$?
set -e
STATUS_AFTER=$(cd "$WORK_DIR" && git status --short | sort)

test "$DR_EXIT" -eq 0 || fail "--dry-run exited $DR_EXIT (expected 0); output: $DR_OUT"
echo "$DR_OUT" | grep -q "DRY RUN" || fail "--dry-run output missing 'DRY RUN'; got: $DR_OUT"
echo "$DR_OUT" | grep -q "Would remove" || fail "--dry-run output missing 'Would remove'; got: $DR_OUT"
echo "$DR_OUT" | grep -q "Would edit" || fail "--dry-run output missing 'Would edit'; got: $DR_OUT"
test "$STATUS_BEFORE" = "$STATUS_AFTER" || \
  fail "--dry-run modified the tree:
BEFORE: $STATUS_BEFORE
AFTER:  $STATUS_AFTER"
ok "--dry-run printed plan + tree unchanged"

# ── Forced-failure rollback (chmod 000 trick) ─────────────────────────────
# Force a failure on a mutation step by removing write permission from
# the Brewfile (it's edited mid-script). The trap should run reset-hard
# and the tree should end up exactly as pre-switch.
step "Forced-failure rollback (chmod 000 Brewfile)"
chmod 000 "$WORK_DIR/Brewfile"
set +e
( cd "$WORK_DIR" && bin/switch-to-tuist.sh >/dev/null 2>&1 )
RB_EXIT=$?
set -e
chmod 644 "$WORK_DIR/Brewfile" 2>/dev/null || true

test "$RB_EXIT" -ne 0 || fail "rollback test: forced failure should exit non-zero (got $RB_EXIT)"
DIRTY=$(cd "$WORK_DIR" && git status --short | wc -l | tr -d ' ')
test "$DIRTY" = "0" || \
  fail "rollback test: working tree not clean after rollback (got $DIRTY entries):
$(cd "$WORK_DIR" && git status --short)"
test -f "$WORK_DIR/app/project.yml" || \
  fail "rollback test: app/project.yml not restored"
ok "forced-failure rollback restored pre-switch state (exit $RB_EXIT)"

# ── Real switch ───────────────────────────────────────────────────────────
step "Real switch (clean run)"
( cd "$WORK_DIR" && bin/switch-to-tuist.sh ) || fail "bin/switch-to-tuist.sh failed on clean tree"

test ! -f "$WORK_DIR/app/project.yml" || fail "post-switch: app/project.yml still present"
test -f "$WORK_DIR/app/Project.swift" || fail "post-switch: app/Project.swift missing"
test -f "$WORK_DIR/Tuist.swift" || fail "post-switch: Tuist.swift missing"

! grep -q '^brew "xcodegen"' "$WORK_DIR/Brewfile" || \
  fail "post-switch: Brewfile still has 'brew \"xcodegen\"'"
grep -q 'cd app && tuist generate --no-open' "$WORK_DIR/Makefile" || \
  fail "post-switch: Makefile missing 'tuist generate --no-open'"
! grep -q 'cd app && xcodegen generate' "$WORK_DIR/Makefile" || \
  fail "post-switch: Makefile still has 'cd app && xcodegen generate'"
grep -q 'require_cmd tuist' "$WORK_DIR/ci/local-check.sh" || \
  fail "post-switch: ci/local-check.sh missing 'require_cmd tuist'"
! grep -q 'require_cmd xcodegen' "$WORK_DIR/ci/local-check.sh" || \
  fail "post-switch: ci/local-check.sh still has 'require_cmd xcodegen'"
# pr.yml is intentionally NOT mutated by switch-to-tuist.sh anymore — the
# matrix builder in pr.yml detects which generator manifests are present
# (app/project.yml ↔ xcodegen, app/Project.swift ↔ tuist) and only emits
# matching cells. After switch-to-tuist removes app/project.yml, pr.yml's
# matrix collapses to Tuist-only at runtime with no edits to the workflow.
[ ! -f "$WORK_DIR/app/project.yml" ] || \
  fail "post-switch: app/project.yml still present (matrix would still emit xcodegen cells)"
[ -f "$WORK_DIR/app/Project.swift" ] || \
  fail "post-switch: app/Project.swift missing (matrix would have no tuist cells either)"
ok "all 4 mutation surfaces verified post-switch + pr.yml matrix invariant"

# ── Idempotency: second run is silent no-op ───────────────────────────────
step "Idempotency: second run is silent no-op"
( cd "$WORK_DIR" && git add -A && git commit --quiet -m "Switch to Tuist (test fixture commit)" )
STATUS_BEFORE=$(cd "$WORK_DIR" && git status --short | sort)
set +e
OUT=$(cd "$WORK_DIR" && bin/switch-to-tuist.sh 2>&1)
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

# ── Integration: tuist generate succeeds on the switched tree ─────────────
step "Integration: tuist generate --no-open on switched tree"
( cd "$WORK_DIR/app" && tuist generate --no-open >/dev/null 2>&1 ) || \
  fail "tuist generate failed on switched tree"
test -d "$WORK_DIR/app/App.xcodeproj" || \
  fail "tuist generate did not produce app/App.xcodeproj"
ok "tuist generate produces app/App.xcodeproj"

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
step "ci/test-switch-to-tuist.sh: all assertions passed"
ok "tmpdir cleanup will run via EXIT trap"
