#!/usr/bin/env bash
# ci/test-migrate-identity.sh — fixture harness for the rename→config migration.
#
# ── WHAT THIS SCRIPT PROVES ──────────────────────────────────────────────────
#
# End to end, against a real toolchain: that a *genuinely* structurally-renamed fork can be
# reconstructed on demand from an immutable git object; that the reconstruction is what we
# believe it is BEFORE any migration runs against it; that ONE documented command migrates it
# onto the config-based identity scheme; that the migrated tree BUILDS on iOS and
# builds-and-tests on macOS; that the identity the BUILT .app carries is the identity
# app/Identity.xcconfig declares; and that the migrated fork can RUN
# its own entry points afterwards, proven by executing ci/local-check.sh and reading the
# project path it resolves rather than by grepping the file for a string.
#
# ── WHY THE ASSERTIONS READ THE BUILT BUNDLE AND NOT THE MANIFEST ────────────
#
# generate-and-gate-only is rejected BY NAME, because the file-level gate is the one that has
# already let two real defects through in THIS repository:
#
#   * XcodeGen bakes the host TARGET NAME into TEST_HOST when it generates, while the per-target rule makes
#     PRODUCT_NAME resolve at BUILD time. Nothing builds at the derived path and the test
#     action cannot run. Fixed at 23c7124 — and reintroduced by this migration's own rewrite
#     while this work was being built, where every file-level assertion was green while it was true and it was
#     found only by reading resolved build settings.
#   * INFOPLIST_KEY_NSHumanReadableCopyright reaches the bundle only under
#     GENERATE_INFOPLIST_FILE = YES, which an app target carrying its own Info.plist does not
#     set. The setting resolved; the built plist had no key. Fixed at b8b1ac9.
#
# Neither was visible to app/project.yml, to test/identity_test.rb or to
# a manifest-comparison tool. Both were found by an actual xcodebuild and by reading a built
# bundle. So steps 17 and 19 below read four keys out of each platform's BUILT Info.plist with
# `plutil -extract`, locating it from BUILT_PRODUCTS_DIR + INFOPLIST_PATH in that build's own
# -showBuildSettings dump, and compare each to what bin/lib/xcconfig.rb resolves from the
# tracked app/Identity.xcconfig. Eight reads, both platforms, no manifest consulted.
#
# ── WHY BOTH HALVES OF THE PAIR ARE PRINTED ──────────────────────────────────
#
# Steps 0-10 were built and run before the migration command existed, so this script refused
# BY NAME at step 10 and exited 1 by design. That red baseline is NOT discarded now that the
# command exists: step 10 still records the exit-2 measurement on the un-migrated fixture and
# step 15 measures the green half on the migrated one, and BOTH are printed on one greppable
# line. A pass with no recorded failing arm is a pass nobody can falsify.
#
# ── THE FIXTURE BASE (FIXTURE_REF) ───────────────────────────────────────────
#
#   212b489  the last commit before identity became a slot. Ships app/Shared/HelloApp.swift,
#            `name: HelloApp` in app/project.yml, and NO app/Identity.xcconfig — the exact
#            shape a fork created from this template before that change is still in. Not
#            renamed, so bin/rename.sh RUNS here and performs the structural rename the
#            migration then has to undo.
#
# A SECOND base would be better and this repository cannot supply one. The stronger fixture
# is a real historical rename performed by the real script on a real fork — a commit whose
# `git show --find-renames` records the five `git mv`s rather than a regeneration that
# reproduces them. This template has no such commit, because it is the thing being forked:
# nothing in its history has ever been renamed away from HelloApp. A fork of it does have
# one, and the fork this migration was built in runs both arms. Upstream runs the
# regeneration arm alone, and that limit is stated here rather than left for a reader to
# infer from a matrix with one cell in it.
#
# The recipe cannot be "clone the current main and run bin/rename.sh", because the current
# script performs no structural rename at all — its own comment says so: "There are no
# file-path renames. … (This script used to `git mv` five files here.)". Running it against
# HEAD produces a fixture with none of the defect the migration exists to fix, and every
# assertion in this file would stay green while proving nothing. Hence a historical ref.
#
# ── WHY THE BLOB SHA IS PINNED ───────────────────────────────────────────────
#
# f9b58ca07875619dbae60fe7f64c829d19721190 is the blob of bin/rename.sh at 212b489 — the
# script that actually performs the five `git mv`s.
#
# The working-tree copy of bin/rename.sh was byte-identical to that blob until the retirement
# trimmed it, and the equality has now ENDED. A fixture generator that resolved bin/rename.sh
# from the working tree, or from whatever the repository currently has checked out, would
# from that point on silently build a fixture with no structural rename in it — a generator
# that stops containing the defect the test exists to prove, while every assertion stays
# green. That is why the pin is a git blob and why step 3 asserts it by name.
#
# So the assertion below pins the two FIXTURE COMMITS by name and deliberately never compares
# against the repository's current copy. That comparison is exactly what adopting a new
# upstream copy of the script breaks.
#
# ── EXIT-CODE CONTRACT OF THE GATE THIS HARNESS DRIVES RED ───────────────────
# (bin/preflight-identity.rb:32-48)
#
#   0  every required variable present and non-empty
#   1  unknown or malformed argv
#   2  Identity.xcconfig not found, or not a regular file, or unresolvable
#   3  one or more required variables missing or empty
#   4  --require-team given and the team is unresolvable
#
# The un-migrated fixture has no app/Identity.xcconfig at all, so the expected baseline is
# exit 2 — the RED half of the falsifiable pair. It is RECORDED as a greppable transcript
# line, not asserted away; step 15 supplies the green half (exit 0 on the migrated fixture).
#
# ── PINNED INTERPRETERS ──────────────────────────────────────────────────────
#
#   /opt/homebrew/opt/ruby@3.3/bin/ruby   (3.3.12)  — first choice
#   /opt/homebrew/opt/ruby@4.0/bin/ruby   (4.0.6)   — second choice
#   NEVER /usr/bin/ruby (2.6.10) when a pinned interpreter is on the machine. All three were
#   measured to exit 2 on a missing --config path on 2026-09-02, but the project rule is to
#   pin rather than to rely on that coincidence continuing to hold. The resolved interpreter
#   is announced on every run.
#
# ── HOW THIS FILE'S OWN GUARDS WERE PROVEN ───────────────────────────────────
#
# A gate is trusted only after being observed RED against a deliberately broken input. All
# three guards below were driven red on 2026-09-03 against ce6479e, each mutation reverted
# from a copy taken before the edit, and each revert proven by an empty diff AND by
# `git diff --quiet`. The transcripts are summarised here, in the tracked artifact, the
# way bin/preflight-identity.rb's header records how its own exit paths were re-observed.
#
# The step numbers in each entry are the ones the control was TAKEN at, while the file was
# being built: the first three against a ten-step version, the next four against a
# twenty-one-step one. THIS FILE NOW HAS 23 STEPS — the stale-entry-point enumeration is at
# 9 and the entry-point execution at 21, so old N maps to new N for N<=8, to N+1 for
# 9<=N<=19, and 20/21 -> 22/23. The numbers are left as taken: a transcript rewritten to
# match a later file is not a transcript. The first three guards are now steps 3/23, 6/23
# and 11/23; nothing about them changed.
#
#   control=fixture-blob-pin — exit 1 at step 3/10, before the clone. The RENAME_SH_BLOB
#     constant was replaced with an all-zero SHA and the script refused with the drift
#     message naming 212b489. Only the constant was mutated, not the copy of the SHA in the
#     prose above: that is the tighter control, because it proves the ASSERTION reads the
#     constant rather than proving that a find-and-replace can break a file.
#   control=fixture-base-shape — exit 1 at step 6/10. The step-5 checkout was pointed at the
#     repository's current commit, whose shape is app/Shared/App.swift, `name: App`, and a
#     PRESENT app/Identity.xcconfig. The base assertions named the missing pre-rename Swift
#     file. Steps 0-5 stayed green, so the red is attributable to the base assertions alone
#     and they are not vacuous.
#   control=fixture-precondition-missing-command — exit 1 at step 10/10; no mutation needed,
#     the command genuinely did not exist yet. The OTHER branch of that refusal (command
#     present) was measured at exit 1 as well, in a scratchpad clone carrying an empty
#     `chmod +x` file at bin/migrate-identity.rb — so this script's exit code was not a race
#     against the suite that created that file.
#
# Steps 11-21 drove FOUR more controls red on 2026-09-03, each mutation proven to have
# landed before the run was trusted, each restored and the restoration proven by sha256 AND
# by `git diff --quiet`:
#
#   control=artefact-plist-mismatch — the fixture's app/Identity.xcconfig BUNDLE_ID was
#     rewritten AFTER the iOS build and before the plist read, so the built bundle and the
#     tracked config disagree about a value the build had already used. Red at step 16/21
#     naming BOTH values. Measured first in the plan's literal placement (rewrite BEFORE the
#     build): that run stayed GREEN, because the build reads the xcconfig and the two sides
#     agree again — recorded in the transcript as an INVALID control rather than a passing one.
#   control=artefact-empty-read — two sub-mutations. (a) one plist key replaced with a key
#     that is not in the bundle: plutil exits non-zero and the step refuses naming the key.
#     (b) the read forced to the empty string, simulating a plutil that exits 0 with nothing:
#     the step refuses naming the key as EMPTY. An empty read is a failure here, never a match
#     against an empty expectation — which is the shape a plist comparison rots into.
#   control=productname-collapse-not-asserted — two halves, because a guard no control can
#     drive red is decoration — a latch that cannot be tripped. (a) PRODUCT_NAME=<one value> was
#     passed to both step-11 -showBuildSettings dumps, so the pre-migration tree reports ONE
#     value on both schemes — the shape of a fork that is not pre-#281 and cannot exercise the
#     collapse. Red at step 11/21, naming both equal values. (b) the same run with the
#     assertion neutered proceeded past step 11, proving that assertion, and not something
#     downstream, is what stops the test against an input it cannot exercise.
#   control=copyright-encoding — the fixture's COPYRIGHT was rewritten with the © replaced by
#     a different non-ASCII character AFTER the build. Red at step 16/21 with the byte strings
#     printed and the FIRST DIFFERING BYTE named by offset — not a bare inequality. the inherited-encoding class /
#     this template has shipped an inherited-encoding defect before
#     surfacing exactly here.
#
# ── THE FIXTURE CARRIES A SYNTHETIC APPLE TEAM ID, AND WHY ───────────────────
#
# A fork that never ran `bin/rename.sh --team-id` still carries the literal TEAM_ID_PLACEHOLDER
# in both manifests, and bin/migrate-identity.rb REFUSES that by design (exit 4: "there is no
# Apple Team ID in this tree to move"). That refusal is correct, is asserted in
# test/migrate_identity_test.rb's M7-team-id case, and is documented in
# docs/MIGRATING-FROM-RENAME.md. This harness is not testing the refusal — it is testing the
# end-to-end migration — so step 12a substitutes a synthetic ten-character Team ID into both
# manifests and asserts the substitution landed. The migration then exercises the Team-ID MOVE
# into gitignored app/Local.xcconfig, which is the path a real forker takes. The value is
# obviously not a real Apple Team ID and reaches nothing but a tmpdir.
#
# ── THE ONE ANNOUNCING KNOB, AND THE GATEKEEPER TRAP IT EXISTS FOR ───────────
#
#   MIGRATE_MACOS_ONLY_TESTING=<test-identifier>
#
# Step 17 runs the FULL macOS scheme deliberately: CI is the arbiter for the UI targets, and
# weakening the CI command to make a local run comfortable is how a gate stops covering the
# thing it exists for. But a full-scheme unsigned macOS `xcodebuild test` launches an unsigned
# AppMacOSUITests-Runner, and macOS shows the OPERATOR a "damaged, move to Trash" dialog on
# their own desktop. So a local runner sets this knob (typically to AppMacOSTests) and step 18
# adds `-only-testing:` — announcing itself LOUDLY on every use, the discipline
# bin/preflight-identity.rb:154-163 established for --config, so a scoped run can never be
# mistaken for a full one in a log. The other sanctioned local escape is an ad-hoc signature
# (CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES). CI sets neither. Never `open` a built app.
#
# ── THIS SCRIPT'S OWN EXIT CODES ─────────────────────────────────────────────
#
#   0  the migration ran, both platforms built, and every built-artefact assertion held
#   1  any assertion failed, or a named precondition refusal fired
#
# Usage:
#   bash ci/test-migrate-identity.sh                      # 212b489 regeneration (default)
#   MIGRATE_MACOS_ONLY_TESTING=AppMacOSTests bash ci/test-migrate-identity.sh   # local, scoped

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

# ── Helpers for the built-artefact reads (steps 17 and 19) ───────────────────

# One setting out of an xcodebuild -showBuildSettings dump. sed, not awk, because the value
# may contain ' = ' and awk -F' = ' would split it; and the result is a display/extraction
# path, never an exit-code path — $? here is sed's and is deliberately not consulted.
setting_of() {
  printf '%s\n' "$2" | sed -n "s/^[[:space:]]*$1 = //p" | head -1
}

# Byte-level rendering. COPYRIGHT carries
# © (U+00A9, UTF-8 c2 a9) and "it looked right in the terminal" is how a mojibake'd copyright
# reaches the App Store. od, not xxd: xxd ships with vim and is not guaranteed on a runner.
hex_bytes() {
  printf '%s' "$1" | od -An -v -tx1 | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# Names the FIRST differing byte by offset, so a mismatch reports which byte went wrong rather
# than a bare inequality. Takes two space-separated hex strings from hex_bytes.
first_byte_difference() {
  local -a a b
  local n i
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  n=${#a[@]}
  if [ "${#b[@]}" -gt "$n" ]; then n=${#b[@]}; fi
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${a[$i]-<absent>}" != "${b[$i]-<absent>}" ]; then
      printf 'first differing byte at offset %d: built=%s xcconfig=%s' \
        "$i" "${a[$i]-<absent>}" "${b[$i]-<absent>}"
      return 0
    fi
    i=$((i + 1))
  done
  printf 'no differing byte — the two byte strings are identical'
}

# The four pairs. Left: a key in the BUILT bundle's
# Info.plist. Right: the app/Identity.xcconfig variable it must equal. Neither side is a
# literal here — a spelled-out expectation would be a fifth reader of the identity and would
# go stale the first time the fixture changed.
PLIST_KEYS=(CFBundleIdentifier CFBundleDisplayName CFBundleName NSHumanReadableCopyright)
XCCONFIG_KEYS=(BUNDLE_ID          DISPLAY_NAME        APP_PRODUCT_NAME  COPYRIGHT)

# Reads the four keys out of ONE platform's built bundle and asserts each against the tracked
# xcconfig. Consumes the globals ARTEFACT_LABEL / ARTEFACT_SCHEME / ARTEFACT_DD and the array
# ARTEFACT_FLAGS, because bash cannot pass an array as a positional argument.
#
# The plist is located from the SAME
# build's -showBuildSettings dump, as BUILT_PRODUCTS_DIR + INFOPLIST_PATH. That resolves to
# App.app/Info.plist on iOS and App.app/Contents/Info.plist on macOS without this script
# having to know which platform it is on.
assert_built_identity() {
  local dump bpd ipp fpn plist bundle apps first_app i pkey xkey actual expected
  local plutil_exit xcconfig_exit dump_exit
  local actual_hex expected_hex

  set +e
  dump="$(xcodebuild -project app/App.xcodeproj -scheme "$ARTEFACT_SCHEME" \
    -configuration "$CONFIGURATION" "${ARTEFACT_FLAGS[@]}" \
    -derivedDataPath "$ARTEFACT_DD" -showBuildSettings 2>&1)"
  dump_exit=$?
  set -e
  [ "$dump_exit" -eq 0 ] || fail "${ARTEFACT_LABEL}: xcodebuild -showBuildSettings exited ${dump_exit} for scheme ${ARTEFACT_SCHEME}; there is no settings dump to locate the built plist from:
${dump}"

  bpd="$(setting_of BUILT_PRODUCTS_DIR "$dump")"
  ipp="$(setting_of INFOPLIST_PATH "$dump")"
  fpn="$(setting_of FULL_PRODUCT_NAME "$dump")"
  [ -n "$bpd" ] || fail "${ARTEFACT_LABEL}: the settings dump reports no BUILT_PRODUCTS_DIR"
  [ -n "$ipp" ] || fail "${ARTEFACT_LABEL}: the settings dump reports no INFOPLIST_PATH"
  [ -n "$fpn" ] || fail "${ARTEFACT_LABEL}: the settings dump reports no FULL_PRODUCT_NAME"

  plist="${bpd}/${ipp}"
  bundle="${bpd}/${fpn}"

  # The pr.yml:275-284 locator, kept for its emptiness refusal. It is NOT the sole locator:
  # measured on this machine, the macOS products directory holds a SECOND .app — the
  # AppMacOSUITests-Runner — and find returns directory order, so `| head -1` can hand back a
  # bundle nobody wrote this identity into. The authoritative path is the settings dump's, and
  # the find result is used to assert that path is really among the products.
  apps="$(find "${ARTEFACT_DD}/Build/Products" -maxdepth 2 -name '*.app')"
  [ -n "$apps" ] || fail "${ARTEFACT_LABEL}: no .app under ${ARTEFACT_DD}/Build/Products"
  first_app="${apps%%$'\n'*}"
  printf '%s\n' "$apps" | grep -qxF "$bundle" || fail "${ARTEFACT_LABEL}: the settings dump names ${bundle} but find(1) under ${ARTEFACT_DD}/Build/Products returned only:
${apps}"
  ok "${ARTEFACT_LABEL}: built bundle ${bundle} (first .app found: ${first_app})"

  [ -f "$plist" ] || fail "${ARTEFACT_LABEL}: no Info.plist at ${plist}; the settings dump says the bundle keeps it there, so either the build wrote nothing or the dump describes a different derived-data path"
  ok "${ARTEFACT_LABEL}: built Info.plist at ${plist}"

  i=0
  while [ "$i" -lt "${#PLIST_KEYS[@]}" ]; do
    pkey="${PLIST_KEYS[$i]}"
    xkey="${XCCONFIG_KEYS[$i]}"

    set +e
    actual="$(plutil -extract "$pkey" raw -o - "$plist" 2>&1)"
    plutil_exit=$?
    set -e
    [ "$plutil_exit" -eq 0 ] || fail "${ARTEFACT_LABEL}: plutil -extract ${pkey} exited ${plutil_exit} on ${plist}: ${actual}. The key app/Identity.xcconfig feeds is not in the BUILT bundle — which is the inert-INFOPLIST_KEY shape (b8b1ac9) and is exactly what this read exists to catch."
    # An empty read is a FAILURE, never a match against an empty expectation. A comparison
    # that passes when both sides are empty is the shape this whole step rots into.
    [ -n "$actual" ] || fail "${ARTEFACT_LABEL}: plutil -extract ${pkey} returned an EMPTY value from ${plist}. An empty built-plist value is a failure here, not a match."

    set +e
    expected="$("$RUBY_BIN" "$REPO_ROOT/bin/lib/xcconfig.rb" app/Identity.xcconfig "$xkey" 2>&1)"
    xcconfig_exit=$?
    set -e
    [ "$xcconfig_exit" -eq 0 ] || fail "${ARTEFACT_LABEL}: bin/lib/xcconfig.rb exited ${xcconfig_exit} for ${xkey} in the migrated app/Identity.xcconfig (3 = undefined or empty): ${expected}"
    [ -n "$expected" ] || fail "${ARTEFACT_LABEL}: bin/lib/xcconfig.rb resolved ${xkey} to the EMPTY string; an empty expectation would make this comparison vacuous."

    if [ "$pkey" = "NSHumanReadableCopyright" ]; then
      # Byte comparison as well as string comparison. © is U+00A9 and an inherited-encoding
      # fault surfaces here first and nowhere else.
      actual_hex="$(hex_bytes "$actual")"
      expected_hex="$(hex_bytes "$expected")"
      [ "$actual_hex" = "$expected_hex" ] || fail "${ARTEFACT_LABEL}: ${pkey} BYTES differ from ${xkey}.
  built    (${plist}): ${actual}
  xcconfig (app/Identity.xcconfig): ${expected}
  built    bytes: ${actual_hex}
  xcconfig bytes: ${expected_hex}
  $(first_byte_difference "$actual_hex" "$expected_hex")"
      ok "${ARTEFACT_LABEL}: ${pkey} == \$(${xkey}) — string AND bytes (${actual_hex})"
    else
      [ "$actual" = "$expected" ] || fail "${ARTEFACT_LABEL}: ${pkey} in the BUILT bundle does not match ${xkey} in app/Identity.xcconfig.
  built    (${plist}): ${actual}
  xcconfig (app/Identity.xcconfig): ${expected}"
      ok "${ARTEFACT_LABEL}: ${pkey} == \$(${xkey}) == ${actual}"
    fi

    i=$((i + 1))
  done
}

# The pin. See "WHY THE BLOB SHA IS PINNED" above.
RENAME_SH_BLOB="f9b58ca07875619dbae60fe7f64c829d19721190"

# The identity the fixture is renamed TO when regenerating from 212b489. Fixed, non-secret,
# and .invalid / example.com by construction — no operator-supplied value reaches sed here.
# The email is on local.invalid, not example.invalid: local.invalid is the domain
# a fork-side domain allowlist would permit for "canary fixtures and throwaway git author
# identities", and that fail-closed list should not gain a row for a use it already covers.
FIXTURE_APP_NAME="MigrateFixture"
FIXTURE_BUNDLE_ID="com.example.migratefixture"
FIXTURE_DISPLAY_NAME="Migrate Fixture"
FIXTURE_EMAIL="fixture@local.invalid"
FIXTURE_SLUG="example/fixture"

# A synthetic Apple Team ID for the fixture. See "THE FIXTURE CARRIES A SYNTHETIC APPLE TEAM
# ID" above: without one, both fixture bases carry the unsubstituted literal and the migration
# refuses by design at exit 4 rather than exercising the Team-ID move. Ten characters, the
# shape Apple uses, and deliberately a sequence no team could be issued.
FIXTURE_TEAM_ID="ABCDE12345"
TEAM_ID_LITERAL="TEAM_ID_PLACEHOLDER"

# The two configurations, spelled once. Debug is what 05-VALIDATION.md's Per-Task Verification
# Map names for both platforms, and bin/migrate-identity.rb reads its identity from Debug too.
CONFIGURATION="Debug"

# ── Fixture selection ────────────────────────────────────────────────────────
#
# Announced on EVERY run, the way ci/local-release-check.sh:165-177 announces IDENTITY_XCCONFIG:
# a ground-truth run must never be mistakable for a regeneration run in a log.
if [ -n "${FIXTURE_REF+x}" ]; then
  FIXTURE_REF_OVERRIDDEN=true
else
  FIXTURE_REF_OVERRIDDEN=false
fi
FIXTURE_REF="${FIXTURE_REF:-212b489}"

case "$FIXTURE_REF" in
  212b489)
    FIXTURE_TOKEN="HelloApp"          # the token present in the base, BEFORE rename.sh runs
    RENAMED_TOKEN="$FIXTURE_APP_NAME" # the token the fixture must carry AFTER rename.sh runs
    RUN_RENAME=true
    EXPECT_XCODEPROJ=true
    FIXTURE_MODE="regeneration — bin/rename.sh runs and performs the structural rename"
    ;;
  *)
    fail "FIXTURE_REF='${FIXTURE_REF}' rejected — the only accepted value is '212b489'. Anything else would build a fixture whose shape this script cannot assert."
    ;;
esac

# ── The macOS test-scoping knob, announced on every use ──────────────────────
#
# See "THE ONE ANNOUNCING KNOB" above. Unset is the CI shape: the FULL App-macOS scheme,
# UI targets included. Set, it narrows step 18 with -only-testing: and says so loudly.
if [ -n "${MIGRATE_MACOS_ONLY_TESTING:-}" ]; then
  MACOS_SCOPED=true
else
  MACOS_SCOPED=false
fi

step "0/23 Fixture selection"
printf '    fixture base: %s (%s)\n' "$FIXTURE_REF" "$FIXTURE_MODE"
printf '    pre-rename token: %s   post-rename token: %s\n' "$FIXTURE_TOKEN" "$RENAMED_TOKEN"
if [ "$FIXTURE_REF_OVERRIDDEN" = true ]; then
  printf '    FIXTURE_REF override in effect — this is NOT the default regeneration run\n'
fi
if [ "$MACOS_SCOPED" = true ]; then
  printf '    ==== MIGRATE_MACOS_ONLY_TESTING IN EFFECT ====\n'
  printf '    step 18 will run ONLY -only-testing:%s on the macOS scheme.\n' "$MIGRATE_MACOS_ONLY_TESTING"
  printf '    The macOS UI-test target is NOT exercised by this run; CI is the arbiter for it.\n'
fi

# Pin the interpreter. Never /usr/bin/ruby (2.6.10) when a pinned one is installed.
RUBY_BIN=""
for candidate in /opt/homebrew/opt/ruby@3.3/bin/ruby /opt/homebrew/opt/ruby@4.0/bin/ruby; do
  if [ -x "$candidate" ]; then
    RUBY_BIN="$candidate"
    break
  fi
done
if [ -z "$RUBY_BIN" ]; then
  # CI runners use setup-ruby / the runner image's ruby; neither pinned path exists there.
  RUBY_BIN="$(command -v ruby || true)"
  [ -n "$RUBY_BIN" ] || fail "no ruby on PATH and neither pinned interpreter is installed"
fi
printf '    ruby: %s (%s)\n' "$RUBY_BIN" "$("$RUBY_BIN" -e 'print RUBY_VERSION')"

# ── 1/23 Non-shallow self-assertion ──────────────────────────────────────────
#
# Asserted HERE, in the test, and not left to `fetch-depth: 0` in the workflow. That YAML line
# is a config line anybody can delete with nothing going red — deleting it would blind this
# test rather than break it. actions/checkout defaults to depth 1 and structurally
# cannot see 212b489.
step "1/23 Non-shallow self-assertion"
cd "$REPO_ROOT"

SHALLOW="$(git rev-parse --is-shallow-repository)"
[ "$SHALLOW" = "false" ] || \
  fail "shallow clone (git rev-parse --is-shallow-repository = '$SHALLOW') — the fixture commits are unreachable. The workflow needs 'fetch-depth: 0'; actions/checkout defaults to depth 1."
ok "repository is not a shallow clone"

git rev-parse --verify --quiet "${FIXTURE_REF}^{commit}" >/dev/null || \
  fail "fixture commit ${FIXTURE_REF} does not resolve in this repository"
ok "fixture commit ${FIXTURE_REF} resolves"

# ── 2/23 Pre-flight ──────────────────────────────────────────────────────────
step "2/23 Pre-flight"
test -x bin/rename.sh          || fail "bin/rename.sh not executable in $REPO_ROOT"
command -v git      >/dev/null || fail "git not on PATH"
command -v xcodegen >/dev/null || fail "xcodegen not on PATH — run 'make bootstrap' first"
test -f bin/preflight-identity.rb || fail "bin/preflight-identity.rb missing in $REPO_ROOT"
ok "tools present"

if git rev-parse --verify --quiet origin/main >/dev/null; then
  ANCESTOR_REF="origin/main"
else
  ANCESTOR_REF="HEAD"
  ok "origin/main is not a local ref here — asserting ancestry against HEAD instead"
fi
git merge-base --is-ancestor "$FIXTURE_REF" "$ANCESTOR_REF" || \
  fail "${FIXTURE_REF} is not an ancestor of ${ANCESTOR_REF} — this is not the history the fixture was pinned against"
ok "${FIXTURE_REF} is an ancestor of ${ANCESTOR_REF}"

# ── 3/23 Blob pin ────────────────────────────────────────────────────────────
#
# The fixture commit, by name. Never the repository's current copy — that equality ended with
# the retirement, and depending on it is how this fixture would go quietly vacuous.
step "3/23 Blob pin on bin/rename.sh"
ACTUAL_BLOB="$(git rev-parse "${FIXTURE_REF}:bin/rename.sh")"
[ "$ACTUAL_BLOB" = "$RENAME_SH_BLOB" ] || \
  fail "rename.sh blob drifted at ${FIXTURE_REF} — the fixture generator is no longer the script that performs the five git mv operations; refusing to build a fixture that cannot contain the defect this test exists to prove (expected ${RENAME_SH_BLOB}, got ${ACTUAL_BLOB})"
ok "${FIXTURE_REF}:bin/rename.sh == ${RENAME_SH_BLOB}"

# ── 4/23 Clone to tmpdir ─────────────────────────────────────────────────────
step "4/23 Clone to tmpdir"
WORK_DIR="$(mktemp -d -t test-migrate-identity-XXXXXX)"
ok "tmpdir: $WORK_DIR"

git clone --no-hardlinks --quiet "$REPO_ROOT" "$WORK_DIR"
ok "cloned $REPO_ROOT -> $WORK_DIR"

cd "$WORK_DIR"
# Every destructive command below runs relative to CWD. A failed `cd` would aim them at the
# operator's real tree, where `-fdx` would delete the gitignored .bootstrap.env and
# app/Local.xcconfig (the Team ID). Assert, do not assume.
[ "$PWD" = "$WORK_DIR" ] || \
  fail "cd to the tmpdir did not take: PWD='$PWD' but WORK_DIR='$WORK_DIR' — refusing to run anything destructive"
ok "CWD is the tmpdir"

# ── 5/23 Fixture base ────────────────────────────────────────────────────────
step "5/23 Fixture base ${FIXTURE_REF}"
# The branch MUST be named 'main': bin/rename.sh's gate_on_main reads it, and a detached
# worktree reports 'HEAD' and fails the gate.
git checkout -q -B main "$FIXTURE_REF" || \
  fail "failed to set main to ${FIXTURE_REF} in the clone"
ok "on branch main at ${FIXTURE_REF} (gate_on_main will pass)"

# -x is permitted ONLY on this line, ONLY inside the verified tmpdir, because rename.sh's
# gate_clean_tree counts untracked files and a fresh checkout leaves generated ones behind.
# The PWD assertion immediately above this line is the guard; do not separate them.
[ "$PWD" = "$WORK_DIR" ] || fail "refusing a destructive clean outside the tmpdir: PWD='$PWD'"
git clean -qffdx
ok "tmpdir tree clean (gate_clean_tree will pass)"

# ── 6/23 Base assertions, BEFORE use ─────────────────────────────────────────
#
# Driven red as control=fixture-base-shape by pointing the checkout at the
# repository's current commit, which has app/Shared/App.swift, `name: App` and DOES ship
# app/Identity.xcconfig. Without that control these three lines could be vacuous.
step "6/23 Base assertions"
[ -f "app/Shared/${FIXTURE_TOKEN}.swift" ] || \
  fail "fixture base wrong: app/Shared/${FIXTURE_TOKEN}.swift is missing at ${FIXTURE_REF}"
ok "app/Shared/${FIXTURE_TOKEN}.swift present"

grep -q "^name: ${FIXTURE_TOKEN}$" app/project.yml || \
  fail "fixture base wrong: app/project.yml has no '^name: ${FIXTURE_TOKEN}$' at ${FIXTURE_REF}"
ok "app/project.yml carries 'name: ${FIXTURE_TOKEN}'"

[ ! -f app/Identity.xcconfig ] || \
  fail "fixture base wrong: app/Identity.xcconfig EXISTS at ${FIXTURE_REF} — a pre-#281 fork has no identity config, and its presence would make the exit-2 red baseline unreachable"
ok "app/Identity.xcconfig absent, as a pre-#281 fork must be"

# ── 7/23 Rename (regeneration bases only) ────────────────────────────────────
step "7/23 Structural rename"
if [ "$RUN_RENAME" = true ]; then
  # Exit code captured under `set +e`/`set -e`. Never piped through sed or grep first — $? would
  # become the pipeline's last exit code (the exit-code trap below).
  set +e
  RENAME_OUT="$(bash bin/rename.sh "$FIXTURE_APP_NAME" "$FIXTURE_BUNDLE_ID" "$FIXTURE_DISPLAY_NAME" \
    --email="$FIXTURE_EMAIL" --slug="$FIXTURE_SLUG" 2>&1)"
  RENAME_EXIT=$?
  set -e
  [ "$RENAME_EXIT" -eq 0 ] || \
    fail "bin/rename.sh exited ${RENAME_EXIT} (expected 0) in the fixture tmpdir; output:
${RENAME_OUT}"
  # The "TEAM_ID_PLACEHOLDER still in app/project.yml + app/Project.swift" warning is EXPECTED
  # here — no --team-id is passed, deliberately, because the fixture must carry no real team.
  ok "bin/rename.sh exit 0 (TEAM_ID_PLACEHOLDER warning is expected, not a failure)"
else
  ok "skipped — ${FIXTURE_REF} is already renamed; re-renaming it would destroy the ground truth"
fi

# ── 8/23 Renamed-shape assertions — the property the migration must undo ─────
step "8/23 Renamed-shape assertions"
if [ "$EXPECT_XCODEPROJ" = true ]; then
  [ -d "app/${RENAMED_TOKEN}.xcodeproj" ] || \
    fail "renamed shape wrong: app/${RENAMED_TOKEN}.xcodeproj is not a directory"
  ok "app/${RENAMED_TOKEN}.xcodeproj present"
else
  ok "xcodeproj not required at ${FIXTURE_REF} (that ref predates generation in CI)"
fi

[ -f "app/Shared/${RENAMED_TOKEN}.swift" ] || \
  fail "renamed shape wrong: app/Shared/${RENAMED_TOKEN}.swift is missing"
ok "app/Shared/${RENAMED_TOKEN}.swift present"

[ -f "app/iOS/${RENAMED_TOKEN}.entitlements" ] || \
  fail "renamed shape wrong: app/iOS/${RENAMED_TOKEN}.entitlements is missing — the structural rename did not move the entitlements"
ok "app/iOS/${RENAMED_TOKEN}.entitlements present"

grep -q "^struct ${RENAMED_TOKEN}Main: App {$" "app/Shared/${RENAMED_TOKEN}.swift" || \
  fail "renamed shape wrong: 'struct ${RENAMED_TOKEN}Main: App {' not found in app/Shared/${RENAMED_TOKEN}.swift"
ok "@main struct is ${RENAMED_TOKEN}Main"

grep -q "^name: ${RENAMED_TOKEN}$" app/project.yml || \
  fail "renamed shape wrong: app/project.yml has no '^name: ${RENAMED_TOKEN}$'"
ok "app/project.yml carries 'name: ${RENAMED_TOKEN}'"

[ ! -f app/Identity.xcconfig ] || \
  fail "renamed shape wrong: app/Identity.xcconfig exists post-rename — rename.sh does not write it, so something else did"
ok "app/Identity.xcconfig still absent — the fixture is un-migrated"

# ── 9/23 Stale entry-point enumeration — the gap the runbook measured ───────
#
# A real exit-0 migration was run on this fixture family and what it left behind measured:
# bin/rename.sh had substituted the fork token into 49 of the pre-rename template's 135 tracked
# files, the migration rewrote the ones under app/ plus .gitignore, and ci/local-check.sh:68 was
# still passing app/<N>.xcodeproj to `xcodebuild -project` while the tree held only
# app/App.xcodeproj. `make check`, `make ship` and `make screenshots` were all broken on a fork
# that had done nothing wrong. The command closes that itself; this step and step 21
# are the two halves of its proof.
#
# THE SET IS ENUMERATED FROM THE FIXTURE, NEVER HARDCODED. This template has been bitten by a
# plan-time literal that went stale by allocation; a list of files written here would go stale
# the first time the template gained or lost one. `git grep -lE` over the tracked tree is the
# measurement, and its count is printed so a run that enumerated NOTHING is visible rather than
# silently green.
#
# This predicate is written out here rather than read from the command: a set read out of the
# thing it is supposed to check is not a second opinion. It deliberately spells the same two
# token classes bin/migrate-identity.rb rewrites — a generated project path
# (<N>.xcodeproj / <N>.xcworkspace) and an app scheme name (<N>-iOS / <N>-macOS) — and nothing
# else. There is no bare-token sweep here for the same reason there is none in the command.
#
# CHANGELOG.md is excluded on BOTH sides. It is historical record, it is not
# an entry point, and its occurrences sit inside quoted CI error messages from 2026-05 that a
# rewrite would falsify. Step 21 asserts it is byte-identical across the migration, which is
# the stronger claim than "the count went to zero because we stopped looking".
step "9/23 Stale entry-point enumeration"

ENTRY_POINT_ERE="${RENAMED_TOKEN}\.(xcodeproj|xcworkspace)|${RENAMED_TOKEN}-(iOS|macOS)"

# grep exits 1 on "no match" and 2 on ERROR, and `|| true` cannot tell them apart — this hit
# exactly this and every gate in that plan's evidence records grep_raw= beside exit= for it.
# So the raw status is captured, branched on, and printed.
set +e
STALE_FILES="$(git grep -lE "$ENTRY_POINT_ERE" -- . ":!app/" ":!CHANGELOG.md")"
STALE_GREP_RAW=$?
set -e
case "$STALE_GREP_RAW" in
  0|1) : ;;
  *) fail "git grep -lE exited ${STALE_GREP_RAW} enumerating stale entry points — that is grep's ERROR status, not 'no match', and a gate that read it as zero matches would be green on a broken invocation" ;;
esac
# grep -c prints 0 AND exits 1 on no match; the `|| true` keeps set -e off the value, and the
# value itself is grep's stdout, never an appended echo (a trap .continue-here.md records).
STALE_COUNT="$(printf '%s' "$STALE_FILES" | grep -c . || true)"
printf 'RESULT enumeration=stale-entry-points count=%s grep_raw=%s\n' "$STALE_COUNT" "$STALE_GREP_RAW"
printf '%s\n' "$STALE_FILES" | sed '/^$/d; s/^/      /'

[ "$STALE_COUNT" -ge 1 ] || \
  fail "the enumeration found NO tracked file outside app/ naming ${RENAMED_TOKEN}.xcodeproj or a ${RENAMED_TOKEN}-iOS/-macOS scheme. This fixture cannot exercise the entry-point rewrite, so step 21 would be vacuous, and a count of zero here is the shape a gate rots into rather than a pass."
ok "${STALE_COUNT} tracked file(s) outside app/ still name the fork's project or schemes"

# Anti-vacuity, and the reason it is one named file rather than a list: step 21 EXECUTES
# ci/local-check.sh and reads the project path it resolves. If this fixture's copy did not
# carry a stale reference to begin with, that execution would prove nothing at all.
printf '%s\n' "$STALE_FILES" | grep -qx 'ci/local-check.sh' || \
  fail "ci/local-check.sh is NOT among the enumerated stale files. Step 21 runs that script and asserts the project path it resolves; if it never named the fork's project, that assertion is satisfied by a file that was already correct and measures nothing."
ok "ci/local-check.sh is among them — step 21's execution assertion is not vacuous"

# Held across the migration and compared in step 21. Captured HERE, before any mutation: a
# digest taken afterwards would compare the file to itself.
CHANGELOG_SHA_BEFORE=""
if [ -f CHANGELOG.md ]; then
  CHANGELOG_SHA_BEFORE="$(shasum -a 256 CHANGELOG.md | cut -d" " -f1)"
  set +e
  grep -qE "$ENTRY_POINT_ERE" CHANGELOG.md
  CHANGELOG_MATCH_RAW=$?
  set -e
  case "$CHANGELOG_MATCH_RAW" in
    0) ok "CHANGELOG.md carries the token in the excluded class (sha256 ${CHANGELOG_SHA_BEFORE:0:12}…) — the must-not-rewrite assertion in step 21 is not vacuous" ;;
    1) fail "CHANGELOG.md carries NO occurrence of the two rewritten classes, so step 21's byte-identical assertion would be true of a file the rewrite could never have reached. This fixture cannot exercise the exclusion." ;;
    *) fail "grep -qE on CHANGELOG.md exited ${CHANGELOG_MATCH_RAW} — grep's ERROR status, not a match result" ;;
  esac
else
  fail "the fixture has no CHANGELOG.md; the exclusion this harness asserts has no subject"
fi


# ── 10/23 Red baseline — recorded, not asserted away ──────────────────────────
step "10/23 Red baseline: the identity gate against the un-migrated fixture"
set +e
PREFLIGHT_OUT="$("$RUBY_BIN" "$REPO_ROOT/bin/preflight-identity.rb" --config "$PWD/app/Identity.xcconfig" 2>&1)"
PREFLIGHT_EXIT=$?
set -e
printf 'RESULT baseline=preflight-unmigrated-fixture exit=%s expected=2\n' "$PREFLIGHT_EXIT"
[ "$PREFLIGHT_EXIT" -eq 2 ] || \
  fail "identity gate exited ${PREFLIGHT_EXIT} against the un-migrated fixture (expected 2 = 'not found'); output:
${PREFLIGHT_OUT}"
ok "exit 2 — the RED half of criterion 1's falsifiable pair (the CI harness adds the green half)"

# ── 11/23 Precondition refusal ───────────────────────────────────────────────
#
# TWO named refusals, not one, and both exit 1. This script and bin/migrate-identity.rb were
# built alongside each other, so the command may or may not exist when this script runs. A
# single `[ -x ]` assertion here would make this script's exit code a race against which of
# the two landed first — and an acceptance criterion that passes or fails
# on scheduling order is not a criterion.
#
# The shape is test/doctor_identity_test.rb:100-114's RED precondition block: a NAMED condition,
# never a backtrace, and never a silent pass.
step "11/23 Precondition: the migration command"
MIGRATE_CMD="$REPO_ROOT/bin/migrate-identity.rb"
[ -e "$MIGRATE_CMD" ] || fail "migration command not present at bin/migrate-identity.rb — the harness has nothing to drive"
[ -r "$MIGRATE_CMD" ] || fail "migration command at bin/migrate-identity.rb is not readable"
ok "bin/migrate-identity.rb present"

# ── 12/23 Pre-migration build settings — the collapse guard ──────────────────
#
# 11a first: the fixture needs a Team ID before the migration can move one. See "THE FIXTURE
# CARRIES A SYNTHETIC APPLE TEAM ID" in the header. The substitution is asserted to have
# LANDED before anything depends on it — a silently-failed edit here would send the migration
# to its exit-4 placeholder refusal, which is a real refusal for the wrong reason.
step "12/23 Pre-migration build settings"

[ "$PWD" = "$WORK_DIR" ] || fail "refusing to edit manifests outside the tmpdir: PWD='$PWD'"
for manifest in app/project.yml app/Project.swift; do
  [ -f "$manifest" ] || fail "fixture is missing ${manifest}; the migration reads DEVELOPMENT_TEAM from both manifests"
  BEFORE_COUNT="$(grep -c "$TEAM_ID_LITERAL" "$manifest" || true)"
  [ "$BEFORE_COUNT" -ge 1 ] || fail "fixture's ${manifest} carries no ${TEAM_ID_LITERAL}; this base is not the pre-#281 shape this harness assumes"
  # perl, not `sed -i`: BSD sed requires an argument to -i and GNU sed refuses one, so the two
  # spellings are not portable between this machine and a runner. The expression is SINGLE
  # quoted and both values arrive through the environment: a double-quoted $ENV{...} would be
  # expanded by bash first, and under `set -u` an unset $ENV aborts the script.
  TEAM_ID_LITERAL="$TEAM_ID_LITERAL" FIXTURE_TEAM_ID="$FIXTURE_TEAM_ID" \
    perl -pi -e 's/\Q$ENV{TEAM_ID_LITERAL}\E/$ENV{FIXTURE_TEAM_ID}/g' "$manifest"
  AFTER_LITERAL="$(grep -c "$TEAM_ID_LITERAL" "$manifest" || true)"
  AFTER_TEAM="$(grep -c "$FIXTURE_TEAM_ID" "$manifest" || true)"
  [ "$AFTER_LITERAL" -eq 0 ] || fail "substitution did not land: ${manifest} still carries ${AFTER_LITERAL} occurrence(s) of ${TEAM_ID_LITERAL}"
  [ "$AFTER_TEAM" -eq "$BEFORE_COUNT" ] || fail "substitution did not land: ${manifest} has ${AFTER_TEAM} occurrence(s) of the fixture Team ID, expected ${BEFORE_COUNT}"
  ok "${manifest}: ${BEFORE_COUNT} Team-ID placeholder(s) -> the fixture Team ID"
done

# Regenerate from the substituted manifests: 212b489's
# project was generated by bin/rename.sh before this substitution, and an already-renamed base predates
# generated-project-in-CI entirely and has none at all. bin/migrate-identity.rb refuses a
# tree with no app/<N>.xcodeproj/project.pbxproj (exit 4), because it reads identity from the
# BUILD and a manifest is not a build.
( cd app && xcodegen generate >/dev/null ) || fail "xcodegen generate failed in the fixture; the migration cannot read identity from a tree with no generated project"
FIXTURE_PROJECT="app/${RENAMED_TOKEN}.xcodeproj"
[ -f "${FIXTURE_PROJECT}/project.pbxproj" ] || fail "xcodegen completed but ${FIXTURE_PROJECT}/project.pbxproj is not there"
ok "regenerated ${FIXTURE_PROJECT} from the substituted manifests"

# Commit the fixture. bin/rename.sh leaves its own git mv + sed output UNCOMMITTED (measured:
# 51 dirty lines on the 212b489 base), and bin/migrate-identity.rb's clean-tree gate refuses
# a dirty tree by design. A forker migrating for real has committed their rename; the fixture
# must be in that state too or the harness would only ever reach the clean-tree refusal.
git add -A
git -c user.email="$FIXTURE_EMAIL" -c user.name="Migrate Fixture" \
  commit -q -m "fixture: renamed fork with a synthetic Team ID, ready to migrate"
FIXTURE_DIRTY="$(git status --porcelain)"
[ -z "$FIXTURE_DIRTY" ] || fail "fixture tree is still dirty after the commit; the migration's clean-tree gate counts untracked files too:
${FIXTURE_DIRTY}"
FIXTURE_HEAD="$(git rev-parse HEAD)"
ok "fixture committed at ${FIXTURE_HEAD} — clean tree, on branch main"

# The collapse guard. Measured rather than predicted: a pre-#281 renamed fork resolves
# TWO PRODUCT_NAME values because nothing sets it and Xcode defaults it to each target's own
# name, platform suffix included. If the two are ALREADY equal this is not a pre-#281 fork,
# the migration has nothing to collapse, and every assertion after step 20 would be vacuous.
#
# THE DESTINATION IS PINNED, and that is not decoration. MEASURED on this machine
# 2026-09-03: `xcodebuild -showBuildSettings` with no -destination warns "Using the first of
# multiple matching destinations" and takes whatever heads that list. For an iOS-ONLY scheme
# it can pick a macOS destination, and when it does the dump reports `PRODUCT_NAME = ` — the
# EMPTY string — with FULL_PRODUCT_NAME = .app. The list order is a property of the machine,
# not of the project, so an unpinned read is a coin flip that resolves the right answer most
# of the time. Every dump below therefore carries the same flags as the build it describes.
PRE_PRODUCT_NAME_IOS=""
PRE_PRODUCT_NAME_MACOS=""
PRE_IOS_FLAGS=(-sdk iphoneos -destination 'generic/platform=iOS')
PRE_MACOS_FLAGS=(-destination 'platform=macOS')
for platform in iOS macOS; do
  FIXTURE_SCHEME="${RENAMED_TOKEN}-${platform}"
  if [ "$platform" = "iOS" ]; then
    PRE_FLAGS=("${PRE_IOS_FLAGS[@]}")
  else
    PRE_FLAGS=("${PRE_MACOS_FLAGS[@]}")
  fi
  set +e
  PRE_DUMP="$(xcodebuild -project "$FIXTURE_PROJECT" -scheme "$FIXTURE_SCHEME" \
    -configuration "$CONFIGURATION" "${PRE_FLAGS[@]}" -showBuildSettings 2>&1)"
  PRE_DUMP_EXIT=$?
  set -e
  [ "$PRE_DUMP_EXIT" -eq 0 ] || fail "xcodebuild -showBuildSettings exited ${PRE_DUMP_EXIT} for the pre-migration scheme ${FIXTURE_SCHEME}:
${PRE_DUMP}"
  PRE_VALUE="$(setting_of PRODUCT_NAME "$PRE_DUMP")"
  [ -n "$PRE_VALUE" ] || fail "the pre-migration dump for ${FIXTURE_SCHEME} (destination ${PRE_FLAGS[*]}) reports an EMPTY PRODUCT_NAME. An empty build setting is not a value; xcodebuild resolves one when the destination does not match the scheme's platform."
  if [ "$platform" = "iOS" ]; then
    PRE_PRODUCT_NAME_IOS="$PRE_VALUE"
  else
    PRE_PRODUCT_NAME_MACOS="$PRE_VALUE"
  fi
  printf '    pre-migration: scheme %-24s resolves PRODUCT_NAME = %s\n' "$FIXTURE_SCHEME" "$PRE_VALUE"
done

[ "$PRE_PRODUCT_NAME_IOS" != "$PRE_PRODUCT_NAME_MACOS" ] || fail "the two pre-migration schemes resolve the SAME PRODUCT_NAME ('${PRE_PRODUCT_NAME_IOS}'). A pre-#281 renamed fork resolves two different values, one per target name. This tree has nothing for the migration to collapse, so every later assertion about the collapse would be vacuous, and this harness refuses to run against an input it cannot exercise."
ok "the two pre-migration values DIFFER — this fixture can exercise the collapse"

case "$PRE_PRODUCT_NAME_IOS" in
  *-iOS) ok "iOS value ends in -iOS, the target-name default the PRODUCT_NAME collapse describes" ;;
  *) fail "pre-migration iOS PRODUCT_NAME '${PRE_PRODUCT_NAME_IOS}' does not end in -iOS; this is not the target-name default a pre-#281 fork resolves" ;;
esac
case "$PRE_PRODUCT_NAME_MACOS" in
  *-macOS) ok "macOS value ends in -macOS, the target-name default the PRODUCT_NAME collapse describes" ;;
  *) fail "pre-migration macOS PRODUCT_NAME '${PRE_PRODUCT_NAME_MACOS}' does not end in -macOS; this is not the target-name default a pre-#281 fork resolves" ;;
esac

# ── 13/23 Migrate ────────────────────────────────────────────────────────────
step "13/23 Migrate"
# Exit code captured under `set +e`/`set -e`, never through a pipe: piping into sed or grep
# first would make $? the FILTER's status (the exit-code trap below).
set +e
MIGRATE_OUT="$("$RUBY_BIN" "$MIGRATE_CMD" --root "$PWD" 2>&1)"
MIGRATE_EXIT=$?
set -e
printf '%s\n' "$MIGRATE_OUT" | sed 's/^/    | /'
[ "$MIGRATE_EXIT" -eq 0 ] || fail "bin/migrate-identity.rb exited ${MIGRATE_EXIT} (expected 0) against the fixture; its output is above"
printf '%s\n' "$MIGRATE_OUT" | grep -q '^MIGRATE-IDENTITY: ==== MIGRATION COMPLETE ====$' || fail "the migration exited 0 but never printed its MIGRATION COMPLETE report; an exit code with no report is the silent exit 0 the three-state contract rejected by name"
ok "migration exit 0, with the MIGRATION COMPLETE report"

# ── 14/23 Structural assertions on the migrated tree ─────────────────────────
step "14/23 Structural assertions"
[ -f app/Shared/App.swift ] || fail "migrated tree has no app/Shared/App.swift"
ok "app/Shared/App.swift present"

[ ! -e "app/Shared/${RENAMED_TOKEN}.swift" ] || fail "the fork-token Swift file app/Shared/${RENAMED_TOKEN}.swift survived the migration; a copy-and-leave is not an un-rename"
ok "app/Shared/${RENAMED_TOKEN}.swift is gone"

grep -q '^struct AppMain: App {$' app/Shared/App.swift || fail "app/Shared/App.swift has no '^struct AppMain: App {\$'; the @main struct did not move with the file"
ok "@main struct is AppMain"

grep -q '^name: App$' app/project.yml || fail "app/project.yml has no '^name: App\$'"
ok "app/project.yml carries 'name: App'"

for entitlement in app/iOS/App.entitlements app/macOS/App.entitlements; do
  [ -f "$entitlement" ] || fail "migrated tree has no ${entitlement}"
  ok "${entitlement} present"
done

[ -f app/Identity.xcconfig ] || fail "migrated tree has no app/Identity.xcconfig — the migration reported success without writing the file it exists to write"
ok "app/Identity.xcconfig present"

git check-ignore -q app/Local.xcconfig || fail "git does not consider app/Local.xcconfig ignored in the migrated fixture; the Apple Team ID would land in the next commit"
ok "git confirms app/Local.xcconfig is ignored"

# ── 15/23 Identity gate, GREEN half ──────────────────────────────────────────
step "15/23 Identity gate: the GREEN half of criterion 1"
set +e
GREEN_OUT="$("$RUBY_BIN" "$REPO_ROOT/bin/preflight-identity.rb" --config "$PWD/app/Identity.xcconfig" 2>&1)"
GREEN_EXIT=$?
set -e
printf 'RESULT pair=criterion-1-identity-gate red=%s green=%s\n' "$PREFLIGHT_EXIT" "$GREEN_EXIT"
[ "$GREEN_EXIT" -eq 0 ] || fail "the identity gate exited ${GREEN_EXIT} against the MIGRATED fixture (expected 0); output:
${GREEN_OUT}"
[ "$PREFLIGHT_EXIT" -eq 2 ] || fail "the recorded red half is ${PREFLIGHT_EXIT}, not 2; without both halves the pair is not falsifiable"
ok "exit 0 on the same tree that exited 2 at step 10 — the pair is complete"

# ── 16/23 iOS build ──────────────────────────────────────────────────────────
step "16/23 iOS build (unsigned, generic device)"
DD_IOS="$WORK_DIR/dd-ios"
IOS_FLAGS=(-sdk iphoneos -destination 'generic/platform=iOS')
# pipefail is already set at the top of this file, so a build failure upstream of xcbeautify
# is not swallowed by the formatter's exit 0. xcbeautify is a formatter, not a dependency:
# .github/workflows/migrate.yml installs xcodegen only, so on the runner this branch is the
# one that runs. A missing formatter must never turn into a skipped build.
set +e
if command -v xcbeautify >/dev/null; then
  xcodebuild build \
    -project app/App.xcodeproj \
    -scheme App-iOS \
    -configuration "$CONFIGURATION" \
    "${IOS_FLAGS[@]}" \
    -derivedDataPath "$DD_IOS" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | xcbeautify --renderer terminal
  IOS_BUILD_EXIT=$?
else
  printf '    (xcbeautify absent — running the same build unformatted)\n'
  xcodebuild build \
    -project app/App.xcodeproj \
    -scheme App-iOS \
    -configuration "$CONFIGURATION" \
    "${IOS_FLAGS[@]}" \
    -derivedDataPath "$DD_IOS" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    > "$WORK_DIR/ios-build.log" 2>&1
  IOS_BUILD_EXIT=$?
  # Printed on FAILURE only, and generously: the cleanup trap deletes $WORK_DIR
  # on the way out, so this tail is the only record that survives a red CI run.
  if [ "$IOS_BUILD_EXIT" -ne 0 ]; then
    printf '    ---- last 80 lines of %s ----\n' "$WORK_DIR/ios-build.log"
    tail -80 "$WORK_DIR/ios-build.log" | sed 's/^/    | /'
  fi
fi
set -e
[ "$IOS_BUILD_EXIT" -eq 0 ] || fail "the migrated fixture failed to build for iOS (xcodebuild exited ${IOS_BUILD_EXIT}); the tail of its log is above and the temporary tree is about to be removed"
ok "iOS build exit 0"

# ── 17/23 iOS built-artefact read ────────────────────────────────────────────
step "17/23 iOS built-artefact read"
ARTEFACT_LABEL="iOS"
ARTEFACT_SCHEME="App-iOS"
ARTEFACT_DD="$DD_IOS"
ARTEFACT_FLAGS=("${IOS_FLAGS[@]}")
assert_built_identity

# ── 18/23 macOS build and test ───────────────────────────────────────────────
#
# THE FULL SCHEME, DELIBERATELY. CI is the arbiter for the UI targets and this command is not
# weakened to make a local run comfortable. A LOCAL run must instead set
# MIGRATE_MACOS_ONLY_TESTING=AppMacOSTests (or ad-hoc sign with CODE_SIGN_IDENTITY=-
# CODE_SIGNING_ALLOWED=YES), because an unsigned macOS UI-test runner makes Gatekeeper show
# the operator a "damaged, move to Trash" dialog on their own desktop. Never `open` a built
# app, and never delete these flags to silence that dialog.
step "18/23 macOS build and test"
DD_MACOS="$WORK_DIR/dd-macos"
MACOS_FLAGS=(-destination 'platform=macOS')
MACOS_SCOPE_FLAGS=()
if [ "$MACOS_SCOPED" = true ]; then
  MACOS_SCOPE_FLAGS=("-only-testing:${MIGRATE_MACOS_ONLY_TESTING}")
  printf '    ==== SCOPED RUN: -only-testing:%s ====\n' "$MIGRATE_MACOS_ONLY_TESTING"
  printf '    This run did NOT exercise the macOS UI-test target. CI runs the full scheme.\n'
fi
set +e
if command -v xcbeautify >/dev/null; then
  xcodebuild test \
    -project app/App.xcodeproj \
    -scheme App-macOS \
    -configuration "$CONFIGURATION" \
    "${MACOS_FLAGS[@]}" \
    -derivedDataPath "$DD_MACOS" \
    ${MACOS_SCOPE_FLAGS[@]+"${MACOS_SCOPE_FLAGS[@]}"} \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | xcbeautify --renderer terminal
  MACOS_TEST_EXIT=$?
else
  printf '    (xcbeautify absent — running the same test unformatted)\n'
  xcodebuild test \
    -project app/App.xcodeproj \
    -scheme App-macOS \
    -configuration "$CONFIGURATION" \
    "${MACOS_FLAGS[@]}" \
    -derivedDataPath "$DD_MACOS" \
    ${MACOS_SCOPE_FLAGS[@]+"${MACOS_SCOPE_FLAGS[@]}"} \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    > "$WORK_DIR/macos-test.log" 2>&1
  MACOS_TEST_EXIT=$?
  if [ "$MACOS_TEST_EXIT" -ne 0 ]; then
    printf '    ---- last 80 lines of %s ----\n' "$WORK_DIR/macos-test.log"
    tail -80 "$WORK_DIR/macos-test.log" | sed 's/^/    | /'
  fi
fi
set -e
[ "$MACOS_TEST_EXIT" -eq 0 ] || fail "the migrated fixture failed to build-and-test on macOS (xcodebuild exited ${MACOS_TEST_EXIT}); the tail of its log is above and the temporary tree is about to be removed"
ok "macOS build and test exit 0"

# ── 19/23 macOS built-artefact read ──────────────────────────────────────────
step "19/23 macOS built-artefact read"
ARTEFACT_LABEL="macOS"
ARTEFACT_SCHEME="App-macOS"
ARTEFACT_DD="$DD_MACOS"
ARTEFACT_FLAGS=("${MACOS_FLAGS[@]}")
assert_built_identity

# ── 20/23 Post-migration PRODUCT_NAME collapse ───────────────────────────────
#
# The change is STATED. It is not characterised as safe, no Apple documentation is cited, and
# nothing here decides for a forker whether their live listing can take it: assumption A1 is
# unverified, and the PRODUCT_NAME collapse makes this a warning the migration hands over rather
# than a claim this repository makes.
step "20/23 Post-migration PRODUCT_NAME collapse"
POST_PRODUCT_NAME_IOS=""
POST_PRODUCT_NAME_MACOS=""
for platform in iOS macOS; do
  # Same destination pinning as step 12, and for the same measured reason.
  if [ "$platform" = "iOS" ]; then
    POST_FLAGS=("${IOS_FLAGS[@]}")
  else
    POST_FLAGS=("${MACOS_FLAGS[@]}")
  fi
  set +e
  POST_DUMP="$(xcodebuild -project app/App.xcodeproj -scheme "App-${platform}" \
    -configuration "$CONFIGURATION" "${POST_FLAGS[@]}" -showBuildSettings 2>&1)"
  POST_DUMP_EXIT=$?
  set -e
  [ "$POST_DUMP_EXIT" -eq 0 ] || fail "xcodebuild -showBuildSettings exited ${POST_DUMP_EXIT} for the migrated scheme App-${platform}:
${POST_DUMP}"
  POST_VALUE="$(setting_of PRODUCT_NAME "$POST_DUMP")"
  [ -n "$POST_VALUE" ] || fail "the post-migration dump for App-${platform} (destination ${POST_FLAGS[*]}) reports an EMPTY PRODUCT_NAME"
  if [ "$platform" = "iOS" ]; then
    POST_PRODUCT_NAME_IOS="$POST_VALUE"
  else
    POST_PRODUCT_NAME_MACOS="$POST_VALUE"
  fi
done

set +e
XCCONFIG_PRODUCT_NAME="$("$RUBY_BIN" "$REPO_ROOT/bin/lib/xcconfig.rb" app/Identity.xcconfig APP_PRODUCT_NAME 2>&1)"
XCCONFIG_PN_EXIT=$?
set -e
[ "$XCCONFIG_PN_EXIT" -eq 0 ] || fail "bin/lib/xcconfig.rb exited ${XCCONFIG_PN_EXIT} for APP_PRODUCT_NAME: ${XCCONFIG_PRODUCT_NAME}"

printf '\n    PRODUCT_NAME, before and after\n'
printf '    %-22s %-28s %s\n' "scheme" "before (pre-#281 fork)" "after (migrated)"
printf '    %-22s %-28s %s\n' "----------------------" "----------------------------" "----------------"
printf '    %-22s %-28s %s\n' "iOS app target"   "$PRE_PRODUCT_NAME_IOS"   "$POST_PRODUCT_NAME_IOS"
printf '    %-22s %-28s %s\n' "macOS app target" "$PRE_PRODUCT_NAME_MACOS" "$POST_PRODUCT_NAME_MACOS"
printf '    app/Identity.xcconfig APP_PRODUCT_NAME = %s\n\n' "$XCCONFIG_PRODUCT_NAME"

[ "$POST_PRODUCT_NAME_IOS" = "$POST_PRODUCT_NAME_MACOS" ] || fail "the two migrated schemes still resolve DIFFERENT PRODUCT_NAME values ('${POST_PRODUCT_NAME_IOS}' and '${POST_PRODUCT_NAME_MACOS}'); the collapse did not happen"
ok "both migrated schemes resolve one PRODUCT_NAME: ${POST_PRODUCT_NAME_IOS}"

[ "$POST_PRODUCT_NAME_IOS" = "$XCCONFIG_PRODUCT_NAME" ] || fail "the migrated PRODUCT_NAME '${POST_PRODUCT_NAME_IOS}' is not APP_PRODUCT_NAME '${XCCONFIG_PRODUCT_NAME}' from app/Identity.xcconfig; the build is resolving it from somewhere else"
ok "the resolved value IS APP_PRODUCT_NAME from the tracked xcconfig"

printf '    The built executable filename therefore changes on at least one platform. This\n'
printf '    harness reports the change and nothing more: whether it is acceptable for a live\n'
printf '    App Store listing is not a question this repository answers. See\n'
printf '    docs/MIGRATING-FROM-RENAME.md.\n'

# ── 21/23 Entry points: the migrated fork RUNS its own ci/local-check.sh ─────
#
# This is the half of the entry-point work that cannot be satisfied by a grep, and the reason is a
# measurement rather than a preference. This work found the migration itself producing a tree
# whose generated project could not run its own tests — TEST_HOST resolved to an app that
# never existed — while EVERY file-level assertion about it was green. That was the second
# TEST_HOST-behind-a-green-manifest defect here once already. So this step does not read
# ci/local-check.sh; it EXECUTES it, and reads the project path and scheme that the running
# script actually handed to xcodebuild.
#
# HOW IT REACHES THE INVOCATION AND NO FURTHER. ci/local-check.sh has no dry-run flag at any
# ref this harness runs against (measured, not assumed: its argv case accepts only --fast,
# --owner-app, --owner-app-sim and -h/--help). So the script is run in full under a PATH whose
# first entry holds ONE file: a recording xcodebuild. It is not a wrapper and never execs the
# real tool — it appends its argv to a log and then does the one thing a real xcodebuild would
# do first, which is refuse when -project names something that is not on disk. That refusal is
# what makes exit 0 here mean "the path this fork resolved exists", instead of "a stub said
# yes". Everything upstream of xcodebuild in that script runs for real: the ci/lib SHA256SUMS
# integrity check, the mode dispatch, and a genuine `cd app && xcodegen generate`.
#
# The real xcodebuild is then used, OFF the stub PATH, to list the project the entry point
# named — because a project that exists but does not contain the scheme the script asked for
# is the same defect one layer down.
step "21/23 Entry points: the migrated fork runs its own ci/local-check.sh"

[ "$PWD" = "$WORK_DIR" ] || fail "refusing to run the entry point outside the tmpdir: PWD='$PWD'"

# ── 21a: re-measure the enumeration with the SAME predicate step 9 used ──────
set +e
POST_STALE_FILES="$(git grep -lE "$ENTRY_POINT_ERE" -- . ":!app/" ":!CHANGELOG.md")"
POST_GREP_RAW=$?
set -e
case "$POST_GREP_RAW" in
  0|1) : ;;
  *) fail "git grep -lE exited ${POST_GREP_RAW} re-enumerating stale entry points after the migration — grep's ERROR status, not 'no match'" ;;
esac
POST_STALE_COUNT="$(printf '%s' "$POST_STALE_FILES" | grep -c . || true)"
printf 'RESULT pair=entry-points red=%s green=%s grep_raw=%s\n' "$STALE_COUNT" "$POST_STALE_COUNT" "$POST_GREP_RAW"
if [ "$POST_STALE_COUNT" -ne 0 ]; then
  printf '%s\n' "$POST_STALE_FILES" | sed '/^$/d; s/^/      /'
  fail "${POST_STALE_COUNT} tracked file(s) outside app/ still name ${RENAMED_TOKEN}.xcodeproj or a ${RENAMED_TOKEN}-iOS/-macOS scheme after an exit-0 migration; they are listed above"
fi
ok "the enumerated set went ${STALE_COUNT} -> 0 under the same predicate"

# ── 21b: CHANGELOG.md, the excluded file, byte-identical ────────────────────
CHANGELOG_SHA_AFTER="$(shasum -a 256 CHANGELOG.md | cut -d" " -f1)"
[ "$CHANGELOG_SHA_AFTER" = "$CHANGELOG_SHA_BEFORE" ] || \
  fail "CHANGELOG.md changed across the migration: sha256 ${CHANGELOG_SHA_BEFORE} -> ${CHANGELOG_SHA_AFTER}. It is historical record; its occurrences of the token sit inside quoted CI error messages that a rewrite would falsify."
ok "CHANGELOG.md is byte-identical across the migration (sha256 ${CHANGELOG_SHA_AFTER:0:12}…)"

# ── 21c: build the recording xcodebuild ─────────────────────────────────────
ENTRY_BIN="$WORK_DIR/entry-point-bin"
ENTRY_ARGV_LOG="$WORK_DIR/entry-point-argv.txt"
rm -rf "$ENTRY_BIN"
mkdir -p "$ENTRY_BIN"
rm -f "$ENTRY_ARGV_LOG"

# Written with a QUOTED heredoc delimiter so not one $ in it is expanded by this script. An
# unquoted one would bake this harness's variables into the stub and the stub would then be
# measuring the harness rather than the fork.
cat > "$ENTRY_BIN/xcodebuild" <<'ENTRY_STUB'
#!/usr/bin/env bash
# Recording xcodebuild for ci/test-migrate-identity.sh step 21. Writes one argv element per
# line to $ENTRY_ARGV_LOG, then refuses exactly as the real tool refuses when -project names a
# path that is not there. It never builds and never execs the real xcodebuild.
set -u
: "${ENTRY_ARGV_LOG:?ENTRY_ARGV_LOG must be set for the recording xcodebuild}"
printf '%s\n' "$@" >> "$ENTRY_ARGV_LOG"

project=""
want=""
for a in "$@"; do
  if [ "$want" = "1" ]; then project="$a"; want=""; fi
  if [ "$a" = "-project" ]; then want="1"; fi
done

if [ -n "$project" ] && [ ! -d "$project" ]; then
  echo "xcodebuild: error: the project '$project' does not exist." >&2
  exit 66
fi
exit 0
ENTRY_STUB
chmod +x "$ENTRY_BIN/xcodebuild"
[ -x "$ENTRY_BIN/xcodebuild" ] || fail "could not create the recording xcodebuild at $ENTRY_BIN/xcodebuild"
bash -n "$ENTRY_BIN/xcodebuild" || fail "the recording xcodebuild does not parse"
ok "recording xcodebuild at $ENTRY_BIN/xcodebuild"

# ── 21d: RUN the entry point ────────────────────────────────────────────────
#
# --fast is the mode the pre-push hook uses and the one that reaches the iOS invocation with
# the fewest side effects. The PATH override is scoped to this one command; nothing else in
# this harness sees the stub.
set +e
ENTRY_OUT="$(ENTRY_ARGV_LOG="$ENTRY_ARGV_LOG" PATH="$ENTRY_BIN:$PATH" bash ci/local-check.sh --fast 2>&1)"
ENTRY_EXIT=$?
set -e
printf '%s\n' "$ENTRY_OUT" | sed 's/^/    | /'

[ -s "$ENTRY_ARGV_LOG" ] || \
  fail "ci/local-check.sh exited ${ENTRY_EXIT} without ever invoking xcodebuild — the argv log is empty, so this step measured nothing. An exit code with no recorded invocation is the vacuous pass this whole step exists to avoid."

ENTRY_PROJECT="$(awk '/^-project$/{getline; print; exit}' "$ENTRY_ARGV_LOG")"
ENTRY_SCHEME="$(awk '/^-scheme$/{getline; print; exit}' "$ENTRY_ARGV_LOG")"
printf 'RESULT gate=entry-point-local-check exit=%s project=%s scheme=%s\n' \
  "$ENTRY_EXIT" "${ENTRY_PROJECT:-<none>}" "${ENTRY_SCHEME:-<none>}"

[ "$ENTRY_EXIT" -eq 0 ] || \
  fail "the migrated fork's own ci/local-check.sh --fast exited ${ENTRY_EXIT}. It resolved -project '${ENTRY_PROJECT:-<none>}' -scheme '${ENTRY_SCHEME:-<none>}'; the tree holds app/App.xcodeproj. This is 'make check' on a fork that ran one documented command and did nothing else wrong. Output is above."
ok "ci/local-check.sh --fast exit 0"

[ "$ENTRY_PROJECT" = "app/App.xcodeproj" ] || \
  fail "the entry point resolved -project '${ENTRY_PROJECT:-<none>}', not app/App.xcodeproj. Read from the argv the running script actually handed xcodebuild, never from the file's text — file-level assertions stayed green here while the resolved value was wrong."
ok "resolved -project is app/App.xcodeproj, read off the invocation"

[ "$ENTRY_SCHEME" = "App-iOS" ] || \
  fail "the entry point resolved -scheme '${ENTRY_SCHEME:-<none>}', not App-iOS"
ok "resolved -scheme is App-iOS"

[ -d "$ENTRY_PROJECT" ] || fail "the resolved project ${ENTRY_PROJECT} is not a directory on disk"

# ── 21e: the REAL xcodebuild, off the stub PATH, lists the scheme it named ───
#
# A project that exists but does not carry the scheme the entry point asked for is the same
# class of defect one layer down, and the recording stub structurally cannot see it.
set +e
ENTRY_LIST="$(xcodebuild -list -project "$ENTRY_PROJECT" 2>&1)"
ENTRY_LIST_EXIT=$?
set -e
[ "$ENTRY_LIST_EXIT" -eq 0 ] || \
  fail "xcodebuild -list -project ${ENTRY_PROJECT} exited ${ENTRY_LIST_EXIT}; the entry point named a project the real tool cannot read:
${ENTRY_LIST}"
set +e
printf '%s\n' "$ENTRY_LIST" | grep -qE "^[[:space:]]+${ENTRY_SCHEME}$"
ENTRY_SCHEME_RAW=$?
set -e
[ "$ENTRY_SCHEME_RAW" -eq 0 ] || \
  fail "xcodebuild -list on ${ENTRY_PROJECT} reports no scheme line for ${ENTRY_SCHEME} (grep raw ${ENTRY_SCHEME_RAW}; 2 would mean the grep itself broke):
${ENTRY_LIST}"
ok "the real xcodebuild lists ${ENTRY_SCHEME} in ${ENTRY_PROJECT} — the entry point is runnable end to end"

# ── 22/23 Idempotency ────────────────────────────────────────────────────────
step "22/23 Idempotency: a second run changes nothing"
PORCELAIN_BEFORE="$(git status --porcelain)"
set +e
RERUN_OUT="$("$RUBY_BIN" "$MIGRATE_CMD" --root "$PWD" 2>&1)"
RERUN_EXIT=$?
set -e
[ "$RERUN_EXIT" -eq 0 ] || fail "the second migration run exited ${RERUN_EXIT} (expected 0) on an already-migrated tree:
${RERUN_OUT}"
printf '%s\n' "$RERUN_OUT" | grep -q 'already fully migrated' || fail "the second run exited 0 without the loud 'already fully migrated' line; the three-state contract rejected a SILENT idempotent exit 0 because it cannot be told apart from a migration that did nothing because it could not see the tree"
ok "second run exit 0 with the loud already-migrated report"

PORCELAIN_AFTER="$(git status --porcelain)"
[ "$PORCELAIN_BEFORE" = "$PORCELAIN_AFTER" ] || fail "git status --porcelain changed across the second run:
--- before ---
${PORCELAIN_BEFORE}
--- after ---
${PORCELAIN_AFTER}"
ok "git status --porcelain is byte-identical across the re-run"

# ── 23/23 Tuist cell, guarded and never silent ───────────────────────────────
#
# Assumption A4: Tuist has no pre-generation hook and a content-keyed manifest cache, so this
# cell is the only real coverage the Tuist path gets in this harness. A skip must be VISIBLE.
# This runs last because `tuist generate` replaces app/App.xcodeproj with its own.
step "23/23 Tuist generation (guarded)"
if command -v tuist >/dev/null; then
  set +e
  ( cd app && tuist generate --no-open ) > "$WORK_DIR/tuist.log" 2>&1
  TUIST_EXIT=$?
  set -e
  tail -12 "$WORK_DIR/tuist.log" | sed 's/^/    | /'
  [ "$TUIST_EXIT" -eq 0 ] || fail "tuist generate exited ${TUIST_EXIT} in the migrated fixture; the migrated app/Project.swift is not a manifest Tuist can read"
  [ -d app/App.xcworkspace ] || fail "tuist generate exited 0 but app/App.xcworkspace was not created"
  ok "tuist generate exit 0 and app/App.xcworkspace exists ($(tuist version 2>/dev/null || echo 'version unknown'))"
else
  printf '    !!!! SKIPPED tuist: not installed on this machine — the Tuist path was NOT exercised\n'
  printf '    !!!! (assumption A4: Tuist has no pre-generation hook and a content-keyed manifest\n'
  printf '    !!!!  cache, so this cell is the only real coverage that path gets here.)\n'
fi

# ── Done ─────────────────────────────────────────────────────────────────────
step "DONE"
printf '    fixture base %s migrated, built on both platforms, and every identity key read\n' "$FIXTURE_REF"
printf '    out of the BUILT bundle matched the tracked app/Identity.xcconfig. Its own\n'
printf '    ci/local-check.sh then RAN and resolved app/App.xcodeproj / App-iOS.\n'
