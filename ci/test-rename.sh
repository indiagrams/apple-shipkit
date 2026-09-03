#!/usr/bin/env bash
# ci/test-rename.sh — end-to-end integration test for bin/rename.sh.
#
# Clones the live repo to a tmpdir, runs bin/rename.sh with test args,
# asserts the substitution surfaces are all scrubbed, exercises
# idempotent re-run and the AC-19 forced-failure rollback, and runs
# 'make check' in the tmpdir to confirm the renamed app builds green.
#
# Usage:
#   ci/test-rename.sh                # run from repo root
#
# Exit 0 = green; non-zero = a substitution / build failed.
#
# Iter-4 cross-AI fixes:
#   - HIGH-2: check_zero includes :!bin/rename.sh :!ci/test-rename.sh
#     so post-rename grep doesn't false-positive on the running scripts'
#     literal references
#   - HIGH-4: idempotency uses standard `set +e; OUT=$(...); EXIT=$?;
#     set -e` exit-capture (NOT `OUT=$(... || true); EXIT=$?` which
#     always returns 0 from command substitution)
#   - HIGH-5: idempotency asserts STATUS_BEFORE == STATUS_AFTER
#     (script doesn't commit so post-rename tree is dirty by design;
#     comparing pre/post status detects whether the second run produced
#     ANY new changes — that's the falsifiable idempotency signal)
#   - MEDIUM-1: check_zero uses git grep -F for fixed-literal patterns

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
test -x bin/rename.sh || fail "bin/rename.sh not executable in $REPO_ROOT"
command -v git >/dev/null || fail "git not on PATH"
command -v make >/dev/null || fail "make not on PATH"
command -v xcodegen >/dev/null || fail "xcodegen not on PATH — run 'make bootstrap' first"
ok "tools present"

# ── Clone to tmpdir ───────────────────────────────────────────────────────

step "Clone to tmpdir"
WORK_DIR="$(mktemp -d -t test-rename-XXXXXX)"
ok "tmpdir: $WORK_DIR"

git clone --no-hardlinks --quiet "$REPO_ROOT" "$WORK_DIR"
ok "cloned $REPO_ROOT -> $WORK_DIR"

cd "$WORK_DIR"

# Force-set main to cloned HEAD so bin/rename.sh's on-main pre-flight
# gate passes AND both shell scripts (bin/rename.sh + ci/test-rename.sh)
# remain present.
git checkout --quiet -B main HEAD || \
  fail "failed to set main to current HEAD in clone"
test -x bin/rename.sh || \
  fail "post-checkout: bin/rename.sh missing or not executable in clone"
ok "on main branch in clone (force-set to cloned HEAD)"

# ── Run bin/rename.sh in the tmpdir ───────────────────────────────────────

step "Run bin/rename.sh in tmpdir"
TEST_APP="MyApp"
TEST_BUNDLE="com.test.myapp"
TEST_DISPLAY="My Test App"
TEST_EMAIL="test@example.com"
TEST_SLUG="test/myapp"

bin/rename.sh "$TEST_APP" "$TEST_BUNDLE" "$TEST_DISPLAY" \
  --email="$TEST_EMAIL" --slug="$TEST_SLUG" \
  || fail "bin/rename.sh failed in tmpdir"
ok "rename complete"

# ── Post-rename grep assertions ───────────────────────────────────────────

step "Post-rename assertions"

# HIGH-2 closure: include :!bin/rename.sh and :!ci/test-rename.sh in
# exclusions so post-rename grep doesn't false-positive on the running
# scripts' literal references (e.g. error messages mentioning HelloApp).
# MEDIUM-1: -F applied to fixed-literal patterns containing '.'
#
# M3 P3 cross-AI HIGH-2 part A closure (2026-04-30; SPEC carve-out):
# all 5 git grep invocations below extended with 3 new self-reference
# pathspec entries for the M3 P3 verify-rename infrastructure files
# (the gates test, the new verify script, and its integration test).
# Without these extensions, M3 P1's integration test would false-fail
# on the new verify files (which retain original template literals by
# design). NARROW maintenance only — no test logic, no fixture-arg,
# no assertion-structure change.
#
# Signature: check_zero PATTERN [F|NW]
#   F   → use git grep -F (fixed-string)
#   NW  → drop -w word-boundary (substring match — required for HelloApp
#         per goal-backward gap-closure G-01: HelloAppApp contains
#         HelloApp as a substring; -w would mask it from the scrub check)
check_zero() {
  local pat="$1"
  local mode="${2:-}"
  local hits
  case "$mode" in
    F)
      hits=$(git grep -cw -F -e "$pat" -- . \
              ':!.planning' ':!LICENSE' ':!app/App.xcodeproj' \
              ':!bin/rename.sh' ':!ci/test-rename.sh' ':!bin/lib/bootstrap.rb' ':!.github/workflows/bootstrap-doctor-matrix.yml' \
              ':!ci/test-rename-gates.sh' ':!bin/verify-rename.sh' \
              ':!ci/test-verify-rename.sh' 2>/dev/null \
              | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)
      ;;
    NW)
      hits=$(git grep -c -e "$pat" -- . \
              ':!.planning' ':!LICENSE' ':!app/App.xcodeproj' \
              ':!bin/rename.sh' ':!ci/test-rename.sh' ':!bin/lib/bootstrap.rb' ':!.github/workflows/bootstrap-doctor-matrix.yml' \
              ':!ci/test-rename-gates.sh' ':!bin/verify-rename.sh' \
              ':!ci/test-verify-rename.sh' 2>/dev/null \
              | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)
      ;;
    *)
      hits=$(git grep -cw -e "$pat" -- . \
              ':!.planning' ':!LICENSE' ':!app/App.xcodeproj' \
              ':!bin/rename.sh' ':!ci/test-rename.sh' ':!bin/lib/bootstrap.rb' ':!.github/workflows/bootstrap-doctor-matrix.yml' \
              ':!ci/test-rename-gates.sh' ':!bin/verify-rename.sh' \
              ':!ci/test-verify-rename.sh' 2>/dev/null \
              | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)
      ;;
  esac
  test "$hits" = "0" || fail "post-rename: '$pat' still has $hits matches"
  ok "'$pat' == 0 matches"
}

check_zero "HelloApp" NW
check_zero "com.example.helloapp" F
check_zero "maintainers@indiagram.com" F
check_zero "<year>"
check_zero "indiagrams/apple-shipkit" F

# Positive assertions: new identifiers present
test "$(git grep -cw -e "$TEST_APP" -- . ':!.planning' ':!LICENSE' \
      ':!bin/rename.sh' ':!ci/test-rename.sh' \
      ':!ci/test-rename-gates.sh' ':!bin/verify-rename.sh' \
      ':!ci/test-verify-rename.sh' 2>/dev/null \
      | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)" -gt 0 \
  || fail "post-rename: '$TEST_APP' not present"
ok "'$TEST_APP' has matches"

test "$(git grep -cw -F -e "$TEST_BUNDLE" -- . ':!.planning' ':!LICENSE' \
      ':!bin/rename.sh' ':!ci/test-rename.sh' \
      ':!ci/test-rename-gates.sh' ':!bin/verify-rename.sh' \
      ':!ci/test-verify-rename.sh' 2>/dev/null \
      | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)" -gt 0 \
  || fail "post-rename: '$TEST_BUNDLE' not present"
ok "'$TEST_BUNDLE' has matches"

# The project structure is a constant: no file was renamed, and the files
# the manifests reference by literal path are all still there.
for f in app/Shared/App.swift app/iOS/App.entitlements app/macOS/App.entitlements \
         app/Tests/AppTests.swift app/MacOSTests/AppMacOSTests.swift; do
  test -f "$f" || fail "structural file $f missing after rename — the rename must not touch the constant structure"
done
test ! -f "app/Shared/$TEST_APP.swift" || fail "app/Shared/$TEST_APP.swift was created — the rename must not rename structural files"
ok "constant structure intact (App.swift, App.entitlements x2, App*Tests.swift)"

# Identity landed in the xcconfig, and the Team ID did not land in a tracked file
grep -qE "^[[:space:]]*APP_PRODUCT_NAME[[:space:]]*=[[:space:]]*${TEST_APP}[[:space:]]*$" app/Identity.xcconfig || \
  fail "app/Identity.xcconfig: APP_PRODUCT_NAME is not '$TEST_APP'"
grep -qE "^[[:space:]]*BUNDLE_ID[[:space:]]*=[[:space:]]*${TEST_BUNDLE}[[:space:]]*$" app/Identity.xcconfig || \
  fail "app/Identity.xcconfig: BUNDLE_ID is not '$TEST_BUNDLE'"
grep -qF "DISPLAY_NAME     = $TEST_DISPLAY" app/Identity.xcconfig || \
  fail "app/Identity.xcconfig: DISPLAY_NAME is not '$TEST_DISPLAY'"
ok "app/Identity.xcconfig carries the fork identity"

# xcodegen regenerated — the constant project, referencing the xcconfig
test -d "app/App.xcodeproj" || fail "app/App.xcodeproj missing"
test ! -d "app/$TEST_APP.xcodeproj" || fail "app/$TEST_APP.xcodeproj was generated — the project name must stay the constant App"
test -f "app/App.xcodeproj/project.pbxproj" || fail "project.pbxproj missing"
grep -q 'Identity.xcconfig' "app/App.xcodeproj/project.pbxproj" || \
  fail "generated pbxproj does not reference Identity.xcconfig"
! grep -q "$TEST_BUNDLE" "app/App.xcodeproj/project.pbxproj" || \
  fail "generated pbxproj carries the bundle id as a literal — it must resolve from Identity.xcconfig"
ok "xcodegen regen complete (app/App.xcodeproj, identity via Identity.xcconfig)"

# LICENSE Copyright preserved
grep -q "^Copyright (c) 2026 Indiagram LLC" LICENSE || \
  fail "LICENSE Copyright (c) 2026 Indiagram LLC was modified — MIT requirement violated"
ok "LICENSE Copyright preserved"

# <year> -> current year
test "$(grep -c "$(date +%Y)" fastlane/metadata/copyright.txt)" -gt 0 || \
  fail "current year ($(date +%Y)) not present in fastlane/metadata/copyright.txt"
ok "<year> -> $(date +%Y) substituted"

# ── Idempotency: re-run with same args (HIGH-3 + HIGH-4 + HIGH-5) ─────────
#
# HIGH-3 closure: check_idempotency in bin/rename.sh now runs BEFORE
# the clean-tree gate, so a second invocation on a dirty post-first-
# rename tree returns case 0 = silent exit 0.
#
# HIGH-4 closure: standard exit-capture pattern. The PRIOR plan used
# `OUT=$(cmd 2>&1 || true); EXIT=$?` which ALWAYS sets $? to 0 because
# `|| true` is INSIDE the command substitution — a failing rename
# would have been silently reported as success. Standard pattern:
#
#   set +e
#   OUT=$(cmd 2>&1)
#   EXIT=$?
#   set -e
#
# HIGH-5 closure: assert STATUS_BEFORE == STATUS_AFTER instead of
# asserting clean tree. The script doesn't commit, so post-first-rename
# the tree is dirty (sed mods + git mv staging uncommitted). A truly
# idempotent re-run produces NO new changes — STATUS_BEFORE (sorted
# git status --short) must equal STATUS_AFTER (sorted).

step "Idempotency check (re-run with same args)"

STATUS_BEFORE=$(git status --short | sort)

set +e
OUT=$(bin/rename.sh "$TEST_APP" "$TEST_BUNDLE" "$TEST_DISPLAY" \
        --email="$TEST_EMAIL" --slug="$TEST_SLUG" 2>&1)
EXIT=$?
set -e

STATUS_AFTER=$(git status --short | sort)

test "$EXIT" = "0" || fail "second rename exit $EXIT (expected 0 for idempotent silent no-op); output: $OUT"
test "$STATUS_BEFORE" = "$STATUS_AFTER" || fail "second rename modified the tree (idempotency violated):
BEFORE:
$STATUS_BEFORE
AFTER:
$STATUS_AFTER"

# Goal-backward gap-closure G-02: SPEC REQ-6 / AC-13 require the
# already-renamed re-run to produce NO stdout. The prior form
# asserted only EXIT==0 + tree-equality, so a stray
# "==> Pre-flight gates (args validation)" line from validate_args
# slipped through silently. We now assert OUT is empty.
test -z "$OUT" || fail "second rename was not silent (expected empty stdout, got):
$OUT"
ok "second rename was silent no-op (exit 0; status unchanged; stdout empty)"

# ── make check: build green on the renamed app ────────────────────────────
#
# Goal-backward gap-closure G-03: SPEC AC-12 requires verification that
# the renamed app builds green across all 3 platform targets. The prior
# form ran only `make check` (iOS device) and assumed the other targets
# would follow. We now run all three explicitly: iOS device + iOS Sim
# + macOS, each as a separate gate.

step "make check (iOS device build of the renamed app — AC-11)"
bash -euo pipefail <<'BASH'
set +e
make check 2>&1 | tee .test-rename-make-check.log
EXIT=${PIPESTATUS[0]}
set -e
test "$EXIT" -eq 0 || { echo "ERROR: make check failed with exit $EXIT"; exit 1; }
BASH
ok "make check exit 0"

step "make check-sim (iOS Simulator build of the renamed app — AC-12 part 1)"
bash -euo pipefail <<'BASH'
set +e
make check-sim 2>&1 | tee .test-rename-make-check-sim.log
EXIT=${PIPESTATUS[0]}
set -e
test "$EXIT" -eq 0 || { echo "ERROR: make check-sim failed with exit $EXIT"; exit 1; }
BASH
ok "make check-sim exit 0"

step "make check-macos (macOS build of the renamed app — AC-12 part 2)"
bash -euo pipefail <<'BASH'
set +e
make check-macos 2>&1 | tee .test-rename-make-check-macos.log
EXIT=${PIPESTATUS[0]}
set -e
test "$EXIT" -eq 0 || { echo "ERROR: make check-macos failed with exit $EXIT"; exit 1; }
BASH
ok "make check-macos exit 0"

# ── Forced-failure rollback exercise (SPEC AC-19; HIGH-1 reset-hard) ──────
#
# Per SPEC AC-19: forced failure (chmod -w on target file) triggers
# rollback; `git status --short` empty after script exit 1.
#
# HIGH-1 update: rollback now uses reset-hard mechanism (NOT git stash);
# the contract is unchanged from the test's perspective — pre-rename
# state is restored, working tree is clean.

step "Forced-failure rollback exercise (SPEC AC-19; HIGH-1 reset-hard)"

# Reset clone to pre-rename state.
git reset --hard --quiet HEAD
git clean -fdx --quiet  # -x is fine here because WORK_DIR is fully owned by us

# A Step F sweep target (`HelloApp.title`); the structural files are never
# substitution targets, so the forced failure has to land on a file the
# sweep actually writes.
test -f app/Shared/AccessibilityIdentifiers.swift || \
  fail "AC-19 setup: expected app/Shared/AccessibilityIdentifiers.swift to be present pre-rename after reset"
grep -q 'HelloApp.title' app/Shared/AccessibilityIdentifiers.swift || \
  fail "AC-19 setup: app/Shared/AccessibilityIdentifiers.swift is not a HelloApp sweep target any more — pick another"
test -x bin/rename.sh || \
  fail "AC-19 setup: bin/rename.sh missing or not executable after reset"

# Force a failure on a substitution target by removing write permission.
chmod 000 app/Shared/AccessibilityIdentifiers.swift

set +e
bin/rename.sh "$TEST_APP" "$TEST_BUNDLE" "$TEST_DISPLAY" \
  --email="$TEST_EMAIL" --slug="$TEST_SLUG" >/dev/null 2>&1
RENAME_EXIT=$?
set -e

# Restore permissions BEFORE the assertions
chmod 644 app/Shared/AccessibilityIdentifiers.swift 2>/dev/null || true

# AC-19 (a): non-zero exit
test "$RENAME_EXIT" -ne 0 || \
  fail "AC-19: expected non-zero exit on forced failure, got $RENAME_EXIT"
ok "AC-19 (a): forced-failure rename returned non-zero ($RENAME_EXIT)"

# AC-19 (b): `git status --short` empty after rollback
DIRTY=$(git status --short | wc -l | tr -d ' ')
test "$DIRTY" = "0" || \
  fail "AC-19 (b): working tree not clean after rollback (got $DIRTY entries):
$(git status --short)"
ok "AC-19 (b): working tree clean after rollback"

# AC-19 (c): pre-rename state restored — the constant structure is intact
# and the identity xcconfig is back on the template placeholders.
for f in app/Shared/App.swift app/iOS/App.entitlements app/macOS/App.entitlements; do
  test -f "$f" || fail "AC-19 (c): $f missing after rollback"
done
grep -qE '^[[:space:]]*BUNDLE_ID[[:space:]]*=[[:space:]]*com\.example\.helloapp[[:space:]]*$' app/Identity.xcconfig || \
  fail "AC-19 (c): app/Identity.xcconfig BUNDLE_ID not restored to the template placeholder after rollback"
ok "AC-19 (c): pre-rename state restored (structure intact, identity placeholders back)"

step "AC-19 forced-failure rollback exercise: PASSED"

# ── --generator=tuist end-to-end (#38; PR 4 closure) ──────────────────────
#
# Per #38 acceptance criteria:
#   bin/rename.sh ... --generator=tuist on a fresh clone produces a
#   Tuist-only fork that `make check` is green on.
#
# Reuses the existing tmpdir clone shape (force-set main, fresh checkout)
# because the rename script's idempotency dispatch needs a recognizable
# pre-rename state. The earlier AC-19 reset-hard left the clone in a
# clean post-rollback main, which is exactly what we want here.

step "--generator=tuist end-to-end (#38)"

# Reset clone to clean main (post-AC-19 it should already be clean,
# but be explicit — earlier failed-rename leftovers must not survive).
git reset --hard --quiet HEAD
git clean -fdx --quiet

test -f app/project.yml      || fail "--generator=tuist setup: app/project.yml missing pre-rename"
test -f app/Project.swift    || fail "--generator=tuist setup: app/Project.swift missing pre-rename (PR 1 not landed?)"
test -f Tuist.swift          || fail "--generator=tuist setup: Tuist.swift missing pre-rename"
test -x bin/switch-to-tuist.sh || fail "--generator=tuist setup: bin/switch-to-tuist.sh missing/not executable (PR 2 not landed?)"
command -v tuist >/dev/null  || fail "--generator=tuist setup: tuist not on PATH; install via 'brew install --cask tuist'"

bin/rename.sh "$TEST_APP" "$TEST_BUNDLE" "$TEST_DISPLAY" \
  --email="$TEST_EMAIL" --slug="$TEST_SLUG" --generator=tuist \
  || fail "bin/rename.sh --generator=tuist failed in tmpdir"
ok "rename --generator=tuist complete"

# Post-rename assertions specific to --generator=tuist:
test ! -f app/project.yml || fail "--generator=tuist: app/project.yml still present (switch-to-tuist did not delete it)"
test -f app/Project.swift || fail "--generator=tuist: app/Project.swift missing (substitutions wiped it?)"
test -f Tuist.swift       || fail "--generator=tuist: Tuist.swift missing"
! grep -q '^brew "xcodegen"' Brewfile || \
  fail "--generator=tuist: Brewfile still has 'brew \"xcodegen\"'"
grep -q 'cd app && tuist generate --no-open' Makefile || \
  fail "--generator=tuist: Makefile missing 'tuist generate --no-open'"
! grep -q 'cd app && xcodegen generate' Makefile || \
  fail "--generator=tuist: Makefile still has 'cd app && xcodegen generate'"
grep -q 'require_cmd tuist' ci/local-check.sh || \
  fail "--generator=tuist: ci/local-check.sh missing 'require_cmd tuist'"
! grep -q 'require_cmd xcodegen' ci/local-check.sh || \
  fail "--generator=tuist: ci/local-check.sh still has 'require_cmd xcodegen'"
grep -q 'tuist generate --no-open' .github/workflows/pr.yml || \
  fail "--generator=tuist: .github/workflows/pr.yml missing 'tuist generate --no-open'"
! grep -q 'run: xcodegen generate' .github/workflows/pr.yml || \
  fail "--generator=tuist: .github/workflows/pr.yml still has 'run: xcodegen generate'"
ok "--generator=tuist: 5 mutation surfaces verified (no project.yml, Brewfile, Makefile, ci/local-check.sh, pr.yml)"

# DISPLAY_NAME placeholder verification — the display name lives in
# app/Identity.xcconfig (both manifests reference $(DISPLAY_NAME)) and must
# end up as DISPLAY_NAME (not APP_NAME) on the Tuist path too.
grep -qF "DISPLAY_NAME     = $TEST_DISPLAY" app/Identity.xcconfig || \
  fail "--generator=tuist: app/Identity.xcconfig's DISPLAY_NAME not set to '$TEST_DISPLAY'"
grep -qF '"CFBundleDisplayName": "$(DISPLAY_NAME)"' app/Project.swift || \
  fail "--generator=tuist: app/Project.swift no longer references \$(DISPLAY_NAME) — the sweep must not touch the manifest's identity references"
ok "DISPLAY_NAME placeholder honored in app/Identity.xcconfig ('$TEST_DISPLAY'); Project.swift still references \$(DISPLAY_NAME)"

# Verify-rename must exit 0 silent on the --generator=tuist post-rename tree.
set +e
VERIFY_OUT=$(bin/verify-rename.sh 2>&1)
VERIFY_EXIT=$?
set -e
test "$VERIFY_EXIT" = "0" || fail "--generator=tuist: bin/verify-rename.sh exited $VERIFY_EXIT (expected 0); output:
$VERIFY_OUT"
test -z "$VERIFY_OUT" || fail "--generator=tuist: bin/verify-rename.sh produced output (expected silent); got:
$VERIFY_OUT"
ok "--generator=tuist: bin/verify-rename.sh exit 0 silent (5 surfaces clean + manifest sanity)"

# make check on the renamed Tuist fork (iOS device build via the rewritten
# ci/local-check.sh which now invokes 'tuist generate --no-open' first).
step "--generator=tuist: make check (iOS device build)"
bash -euo pipefail <<'BASH'
set +e
make check 2>&1 | tee .test-rename-tuist-make-check.log
EXIT=${PIPESTATUS[0]}
set -e
test "$EXIT" -eq 0 || { echo "ERROR: --generator=tuist make check failed with exit $EXIT"; exit 1; }
BASH
ok "--generator=tuist: make check exit 0 (Tuist-driven build green)"

step "--generator=tuist end-to-end: PASSED"

# ── --platforms substitution (PLATFORMS-aware stub label) ─────────────────
#
# bin/rename.sh's --platforms flag substitutes the SwiftUI stub's subtitle
# in app/Shared/ContentView.swift. Verify the 3 valid values produce the
# expected literal in the source, plus the invalid case fails loudly.
#
# No make check here — the substitution is a pure-text edit; if the input
# tree compiled, the output (with a different string literal) compiles.
# The earlier `make check` phases above prove the pipeline; this phase
# just verifies the right string lands.

step "--platforms substitution"

# Reset to clean main; the prior --generator=tuist phase left a tuist-shaped
# tree, so reset all the way back.
git reset --hard --quiet HEAD
git clean -fd --quiet

run_platform_case() {
  local label="$1"
  local platforms_arg="$2"
  local expected_substring="$3"

  # Spawn a sibling tmpdir clone so we don't accumulate state across cases.
  local case_dir
  case_dir="$(mktemp -d -t test-rename-platforms-XXXXXX)"
  git clone --no-hardlinks --quiet "$REPO_ROOT" "$case_dir"
  ( cd "$case_dir" && git checkout --quiet -B main HEAD )

  ( cd "$case_dir" && bin/rename.sh "$TEST_APP" "$TEST_BUNDLE" "$TEST_DISPLAY" \
      --email=test@example.com --slug=test/myapp $platforms_arg ) >/dev/null \
      || fail "--platforms case '$label' ($platforms_arg): bin/rename.sh exited non-zero"

  grep -qF "$expected_substring" "$case_dir/app/Shared/ContentView.swift" || \
    fail "--platforms case '$label': ContentView.swift missing expected literal '$expected_substring'
Got:
$(grep -E 'Text\("' "$case_dir/app/Shared/ContentView.swift")"
  ok "--platforms=$label → ContentView.swift contains '$expected_substring'"

  rm -rf "$case_dir"
}

run_platform_case "ios"       "--platforms=ios"       'Text("iOS template")'
run_platform_case "macos"     "--platforms=macos"     'Text("macOS template")'
run_platform_case "ios,macos" "--platforms=ios,macos" 'Text("iOS + macOS template")'
run_platform_case "default"   ""                      'Text("iOS + macOS template")'

# Invalid value must fail loud.
bad_dir=$(mktemp -d -t test-rename-platforms-bad-XXXXXX)
git clone --no-hardlinks --quiet "$REPO_ROOT" "$bad_dir"
( cd "$bad_dir" && git checkout --quiet -B main HEAD )
set +e
( cd "$bad_dir" && bin/rename.sh "$TEST_APP" "$TEST_BUNDLE" "$TEST_DISPLAY" \
    --email=test@example.com --slug=test/myapp --platforms=tvos ) >/dev/null 2>&1
bad_exit=$?
set -e
test "$bad_exit" -ne 0 || fail "--platforms=tvos should have failed with non-zero exit; got $bad_exit"
ok "--platforms=tvos rejected with non-zero exit ($bad_exit)"
rm -rf "$bad_dir"

step "--platforms substitution: PASSED"

# ── Done ──────────────────────────────────────────────────────────────────

step "ci/test-rename.sh: all assertions passed"
ok "tmpdir cleanup will run via EXIT trap"
