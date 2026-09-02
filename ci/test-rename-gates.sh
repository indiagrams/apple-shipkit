#!/usr/bin/env bash
# ci/test-rename-gates.sh — fast gate-coverage tests for bin/rename.sh.
#
# Complements ci/test-rename.sh (the slow end-to-end integration test
# that runs `make check*` × 3 platforms) by exercising the script's
# pre-flight gate behaviors, --dry-run mode, --force semantics,
# --slug auto-derive, special-character DISPLAY_NAME handling,
# partial-rename detection, and -h/--help — all without invoking
# xcodebuild. Runs in <30s vs the 5-10 min integration-test budget.
#
# Closes M3 P1 Nyquist coverage gaps:
#   AC-2  — `bin/rename.sh -h` prints usage with all 5 args
#   AC-15 — pre-flight failure (dirty tree) exits 1 with explicit stderr
#   AC-16 — pre-flight failure (invalid APP_NAME) exits 1
#   AC-17 — pre-flight failure (invalid BUNDLE_ID) exits 1
#   AC-18 — --dry-run produces stdout describing changes; tree unchanged after
#   AC-21 — `.planning/` is not modified by the script
#   REQ-1 — auto-derive --slug from `git remote get-url origin`
#   REQ-5 — pre-flight gates (empty DISPLAY_NAME, missing --email,
#           split-flag rejection, '|' in DISPLAY_NAME)
#   REQ-8 — --dry-run mode shows what WOULD change without applying
#   REQ-10 — partial-rename detection + --force bypass
#
# Plus the 5 explicit gaps from .planning/.../01-ADD-TESTS.md:
#   - --dry-run output is non-empty + tree-clean after
#   - --force scenarios (branch + partial-rename bypass)
#   - --slug auto-derive from origin URL (both git@ and https forms)
#   - Special-character DISPLAY_NAME (apostrophe, ampersand, backslash)
#   - Re-rename to a different APP_NAME → case-1 partial-rename fail
#
# Usage:
#   ci/test-rename-gates.sh    # run from repo root
#
# Exit 0 = green; non-zero = a gate behaved unexpectedly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIRS=()

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

cleanup() {
  # M3 P3 cross-AI WR-01 closure (bash 3.2 unbound-array fix):
  # guard the iteration with a length check. On bash 3.2.57 (macOS
  # system bash), expanding "${TMPDIRS[@]}" when the array is empty
  # raises 'unbound variable' under `set -u` — which fires if any
  # pre-flight failure exits before the first fresh_clone populates
  # the array. Length-guard is bash-3.2-portable and POSIX-equivalent.
  local d
  if [ "${#TMPDIRS[@]}" -gt 0 ]; then
    for d in "${TMPDIRS[@]}"; do
      [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
  fi
}
trap 'cleanup' EXIT INT TERM

# Make a fresh clone in a tmpdir, force-set main, return the path on stdout.
fresh_clone() {
  local td
  td="$(mktemp -d -t test-rename-gates-XXXXXX)"
  TMPDIRS+=("$td")
  git clone --no-hardlinks --quiet "$REPO_ROOT" "$td"
  ( cd "$td" && git checkout --quiet -B main HEAD )
  printf '%s' "$td"
}

# ── Pre-flight ────────────────────────────────────────────────────────────

step "Pre-flight"
cd "$REPO_ROOT"
test -x bin/rename.sh || fail "bin/rename.sh not executable in $REPO_ROOT"
command -v git >/dev/null || fail "git not on PATH"
ok "tools present"

# ── AC-1 (extension): bin/rename.sh starts with #!/usr/bin/env bash ───────
#
# The integration test asserts `test -x bin/rename.sh` but does NOT verify
# the shebang line per AC-1's exact wording. Falsifiable check.

step "AC-1: shebang is #!/usr/bin/env bash"
SHEBANG=$(head -1 "$REPO_ROOT/bin/rename.sh")
test "$SHEBANG" = "#!/usr/bin/env bash" || \
  fail "AC-1: shebang is '$SHEBANG' (expected '#!/usr/bin/env bash')"
ok "shebang verified"

# ── AC-2 + REQ-1: -h and --help print usage with all 5 args ───────────────
#
# Per SPEC AC-2: "bin/rename.sh -h prints usage with all 5 args documented."
# The 5 args are APP_NAME, BUNDLE_ID, DISPLAY_NAME, --email, --slug.
# Both -h and --help paths must work (REQ-1 hybrid surface).

step "AC-2: bin/rename.sh -h prints usage with all 5 args"
set +e
H_OUT=$(cd "$REPO_ROOT" && bin/rename.sh -h 2>&1)
H_EXIT=$?
set -e
test "$H_EXIT" -eq 0 || fail "AC-2: -h exited $H_EXIT (expected 0)"
test -n "$H_OUT" || fail "AC-2: -h produced empty output"
echo "$H_OUT" | grep -q "APP_NAME"     || fail "AC-2: -h missing APP_NAME"
echo "$H_OUT" | grep -q "BUNDLE_ID"    || fail "AC-2: -h missing BUNDLE_ID"
echo "$H_OUT" | grep -q "DISPLAY_NAME" || fail "AC-2: -h missing DISPLAY_NAME"
echo "$H_OUT" | grep -q -- "--email"   || fail "AC-2: -h missing --email"
echo "$H_OUT" | grep -q -- "--slug"    || fail "AC-2: -h missing --slug"
ok "-h prints usage with all 5 args (APP_NAME / BUNDLE_ID / DISPLAY_NAME / --email / --slug)"

step "REQ-1: bin/rename.sh --help is an alias for -h"
set +e
HELP_OUT=$(cd "$REPO_ROOT" && bin/rename.sh --help 2>&1)
HELP_EXIT=$?
set -e
test "$HELP_EXIT" -eq 0 || fail "REQ-1: --help exited $HELP_EXIT (expected 0)"
test -n "$HELP_OUT" || fail "REQ-1: --help produced empty output"
echo "$HELP_OUT" | grep -q "APP_NAME" || fail "REQ-1: --help missing APP_NAME"
ok "--help works as alias for -h"

# ── AC-15 + REQ-5: pre-flight failure on dirty tree exits 1 ───────────────
#
# Per SPEC AC-15: "Pre-flight failure (dirty tree) exits 1 with explicit
# stderr identifying the gate." The integration test does not exercise
# this; manually verified per VERIFICATION.md spot-check only.

step "AC-15: dirty tree exits 1 with stderr identifying the gate"
TD=$(fresh_clone)
( cd "$TD" && touch .junk-probe )
set +e
DT_OUT=$(cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --slug=test/myapp 2>&1)
DT_EXIT=$?
set -e
test "$DT_EXIT" -ne 0 || fail "AC-15: dirty tree should exit non-zero (got $DT_EXIT); output: $DT_OUT"
echo "$DT_OUT" | grep -q "working tree not clean" || \
  fail "AC-15: stderr does not identify clean-tree gate; got: $DT_OUT"
ok "AC-15 verified — dirty tree exits $DT_EXIT with 'working tree not clean' stderr"

# ── AC-16 + REQ-5: invalid APP_NAME exits 1 ───────────────────────────────
#
# SPEC AC-16: "Pre-flight failure (invalid APP_NAME — e.g. lowercase
# or contains space) exits 1." Three falsifiable rejection forms:
# space, lowercase, leading digit.

step "AC-16: invalid APP_NAME exits 1 (3 rejection forms)"

for INVALID in "my app" "lowercase" "9starts-digit"; do
  set +e
  AN_OUT=$(cd "$REPO_ROOT" && bin/rename.sh "$INVALID" com.acme.myapp "My App" \
    --email=test@acme.com 2>&1)
  AN_EXIT=$?
  set -e
  test "$AN_EXIT" -ne 0 || \
    fail "AC-16: APP_NAME '$INVALID' should exit non-zero (got $AN_EXIT); output: $AN_OUT"
  echo "$AN_OUT" | grep -q "invalid APP_NAME" || \
    fail "AC-16: stderr for '$INVALID' missing 'invalid APP_NAME'; got: $AN_OUT"
  ok "APP_NAME '$INVALID' rejected (exit $AN_EXIT)"
done

# ── AC-17 + REQ-5: invalid BUNDLE_ID exits 1 ──────────────────────────────
#
# SPEC AC-17: "Pre-flight failure (invalid BUNDLE_ID — e.g. UPPERCASE
# or no dots) exits 1." Three falsifiable rejection forms.

step "AC-17: invalid BUNDLE_ID exits 1 (3 rejection forms)"

for INVALID in "My.App" "no-dots" "com.UPPER.case"; do
  set +e
  BI_OUT=$(cd "$REPO_ROOT" && bin/rename.sh MyApp "$INVALID" "My App" \
    --email=test@acme.com 2>&1)
  BI_EXIT=$?
  set -e
  test "$BI_EXIT" -ne 0 || \
    fail "AC-17: BUNDLE_ID '$INVALID' should exit non-zero (got $BI_EXIT); output: $BI_OUT"
  echo "$BI_OUT" | grep -q "invalid BUNDLE_ID" || \
    fail "AC-17: stderr for '$INVALID' missing 'invalid BUNDLE_ID'; got: $BI_OUT"
  ok "BUNDLE_ID '$INVALID' rejected (exit $BI_EXIT)"
done

# ── REQ-5: empty DISPLAY_NAME exits 1 ─────────────────────────────────────

step "REQ-5: empty DISPLAY_NAME exits 1"
set +e
ED_OUT=$(cd "$REPO_ROOT" && bin/rename.sh MyApp com.acme.myapp "" \
  --email=test@acme.com 2>&1)
ED_EXIT=$?
set -e
test "$ED_EXIT" -ne 0 || \
  fail "REQ-5: empty DISPLAY_NAME should exit non-zero (got $ED_EXIT); output: $ED_OUT"
echo "$ED_OUT" | grep -q "DISPLAY_NAME is empty" || \
  fail "REQ-5: stderr missing 'DISPLAY_NAME is empty'; got: $ED_OUT"
ok "empty DISPLAY_NAME rejected (exit $ED_EXIT)"

# ── REQ-5: missing --email exits 1 ────────────────────────────────────────

step "REQ-5: missing --email exits 1"
set +e
ME_OUT=$(cd "$REPO_ROOT" && bin/rename.sh MyApp com.acme.myapp "My App" 2>&1)
ME_EXIT=$?
set -e
test "$ME_EXIT" -ne 0 || \
  fail "REQ-5: missing --email should exit non-zero (got $ME_EXIT); output: $ME_OUT"
echo "$ME_OUT" | grep -q -- "--email is required" || \
  fail "REQ-5: stderr missing '--email is required'; got: $ME_OUT"
ok "missing --email rejected (exit $ME_EXIT)"

# ── REQ-5 + MEDIUM-3: split-flag rejection (--email --slug=foo/bar) ───────
#
# Per MEDIUM-3 closure: --email VAL form rejects '-'-prefixed values
# so '--email --slug=foo/bar' doesn't consume the next flag as the
# email value. Falsifiable via explicit '-'-prefix.

step "REQ-5 (MEDIUM-3): split-flag rejection on '-'-prefixed value"
set +e
SF_OUT=$(cd "$REPO_ROOT" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email --slug=foo/bar 2>&1)
SF_EXIT=$?
set -e
test "$SF_EXIT" -ne 0 || \
  fail "MEDIUM-3: split-flag '-'-prefix should exit non-zero (got $SF_EXIT); output: $SF_OUT"
echo "$SF_OUT" | grep -q "cannot start with '-'" || \
  fail "MEDIUM-3: stderr missing 'cannot start with -'; got: $SF_OUT"
ok "split-flag '-'-prefix rejected (exit $SF_EXIT)"

# ── REQ-5 + HIGH-7: '|' in DISPLAY_NAME exits 1 ──────────────────────────

step "REQ-5 (HIGH-7): '|' in DISPLAY_NAME rejected (sed-delimiter safety)"
set +e
PIPE_OUT=$(cd "$REPO_ROOT" && bin/rename.sh MyApp com.acme.myapp "My|App" \
  --email=test@acme.com 2>&1)
PIPE_EXIT=$?
set -e
test "$PIPE_EXIT" -ne 0 || \
  fail "HIGH-7: DISPLAY_NAME with '|' should exit non-zero (got $PIPE_EXIT); output: $PIPE_OUT"
echo "$PIPE_OUT" | grep -q "DISPLAY_NAME contains '|'" || \
  fail "HIGH-7: stderr missing \"DISPLAY_NAME contains '|'\"; got: $PIPE_OUT"
ok "'|' in DISPLAY_NAME rejected (exit $PIPE_EXIT)"

# ── AC-18 + REQ-8: --dry-run prints plan + tree unchanged ─────────────────
#
# Per SPEC AC-18: "--dry-run produces stdout output describing intended
# changes; git status --short returns empty after the dry-run."
# Falsifiable assertion that BOTH conditions hold.

step "AC-18 + REQ-8: --dry-run produces plan + leaves tree clean"
TD=$(fresh_clone)
STATUS_BEFORE=$(cd "$TD" && git status --short | sort)

set +e
DR_OUT=$(cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --slug=test/myapp --dry-run 2>&1)
DR_EXIT=$?
set -e

STATUS_AFTER=$(cd "$TD" && git status --short | sort)

test "$DR_EXIT" -eq 0 || fail "AC-18: --dry-run exited $DR_EXIT (expected 0); output: $DR_OUT"
test -n "$DR_OUT" || fail "AC-18: --dry-run produced empty stdout"
echo "$DR_OUT" | grep -q "DRY RUN" || \
  fail "AC-18: --dry-run output missing 'DRY RUN' header; got: $DR_OUT"
echo "$DR_OUT" | grep -q "match(es)" || \
  fail "AC-18: --dry-run output missing per-file match counts; got: $DR_OUT"
echo "$DR_OUT" | grep -q "File-path renames:" || \
  fail "AC-18: --dry-run output missing file-path-rename plan; got: $DR_OUT"
echo "$DR_OUT" | grep -q "xcodegen regen:" || \
  fail "AC-18: --dry-run output missing xcodegen-regen plan; got: $DR_OUT"
test "$STATUS_BEFORE" = "$STATUS_AFTER" || \
  fail "AC-18: --dry-run modified tree:
BEFORE: $STATUS_BEFORE
AFTER:  $STATUS_AFTER"
ok "--dry-run printed plan + tree unchanged (exit 0; $(echo "$DR_OUT" | wc -l | tr -d ' ') lines)"

# Also verify post-rename --dry-run announces "already-renamed" (WR-02)
step "WR-02: --dry-run on already-renamed announces 'already-renamed'"
set +e
( cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
    --email=test@acme.com --slug=test/myapp >/dev/null 2>&1 )
set -e
set +e
DR2_OUT=$(cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --slug=test/myapp --dry-run 2>&1)
DR2_EXIT=$?
set -e
test "$DR2_EXIT" -eq 0 || fail "WR-02: post-rename --dry-run exited $DR2_EXIT"
echo "$DR2_OUT" | grep -q "already-renamed" || \
  fail "WR-02: post-rename --dry-run missing 'already-renamed'; got: $DR2_OUT"
ok "post-rename --dry-run announces 'already-renamed'"

# ── AC-21: .planning/ is not modified by the script ───────────────────────
#
# Per SPEC AC-21: ".planning/ and app/App.xcodeproj/ are not
# modified by the script." Defense-in-depth pathspec exclusion check —
# drop a sentinel file into .planning/ before rename, assert it's
# byte-identical after.

step "AC-21: .planning/ sentinel file untouched after rename"
TD=$(fresh_clone)
( cd "$TD" && mkdir -p .planning && \
    printf 'sentinel for AC-21 %s\n' "$(date +%s)" > .planning/probe.txt )
SENTINEL_BEFORE=$(cd "$TD" && shasum -a 256 .planning/probe.txt | awk '{print $1}')
( cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
    --email=test@acme.com --slug=test/myapp >/dev/null 2>&1 ) || \
  fail "AC-21 setup: rename failed unexpectedly"
test -f "$TD/.planning/probe.txt" || fail "AC-21: .planning/probe.txt deleted"
SENTINEL_AFTER=$(cd "$TD" && shasum -a 256 .planning/probe.txt | awk '{print $1}')
test "$SENTINEL_BEFORE" = "$SENTINEL_AFTER" || \
  fail "AC-21: .planning/probe.txt modified
BEFORE: $SENTINEL_BEFORE
AFTER:  $SENTINEL_AFTER"
ok "AC-21 verified — .planning/probe.txt byte-identical (sha256 $SENTINEL_AFTER)"

# ── REQ-1: --slug auto-derive from origin URL (git@ form) ─────────────────
#
# Per SPEC REQ-1: if --slug omitted, auto-derive from `git remote get-url
# origin`. Two URL forms supported: git@github.com:OWNER/REPO.git and
# https://github.com/OWNER/REPO.git. Falsifiable via dry-run output
# inspection.

step "REQ-1: --slug auto-derive from origin (git@ form)"
TD=$(fresh_clone)
( cd "$TD" && git remote set-url origin "git@github.com:acme/myapp.git" )
set +e
SLUG_OUT=$(cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --dry-run 2>&1)
SLUG_EXIT=$?
set -e
test "$SLUG_EXIT" -eq 0 || fail "REQ-1: auto-derive (git@ form) exited $SLUG_EXIT"
echo "$SLUG_OUT" | grep -q "auto-derived from origin: 'acme/myapp'" || \
  fail "REQ-1: git@ form did not auto-derive 'acme/myapp'; got: $SLUG_OUT"
ok "git@github.com:acme/myapp.git -> 'acme/myapp'"

step "REQ-1: --slug auto-derive from origin (https form)"
TD=$(fresh_clone)
( cd "$TD" && git remote set-url origin "https://github.com/acme/myapp.git" )
set +e
SLUG_OUT=$(cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --dry-run 2>&1)
SLUG_EXIT=$?
set -e
test "$SLUG_EXIT" -eq 0 || fail "REQ-1: auto-derive (https form) exited $SLUG_EXIT"
echo "$SLUG_OUT" | grep -q "auto-derived from origin: 'acme/myapp'" || \
  fail "REQ-1: https form did not auto-derive 'acme/myapp'; got: $SLUG_OUT"
ok "https://github.com/acme/myapp.git -> 'acme/myapp'"

# ── HIGH-7 / sed-escape: special-character DISPLAY_NAME ───────────────────
#
# DISPLAY_NAMEs containing apostrophe + ampersand + backslash exercise
# sed_escape_replacement (BLOCKER-1: \\& in replacement; BSD-portable).
# Falsifiable: post-rename, the literal special chars must appear in
# the substituted artifacts (name.txt, ContentView.swift, etc.) — NO
# corruption from sed metacharacter mishandling.

step "HIGH-7: special-character DISPLAY_NAME (apostrophe + ampersand)"
TD=$(fresh_clone)
SPECIAL_DISPLAY="Joe's & Co"
( cd "$TD" && bin/rename.sh MyApp com.acme.myapp "$SPECIAL_DISPLAY" \
    --email=test@acme.com --slug=test/myapp >/dev/null 2>&1 ) || \
  fail "HIGH-7: rename with special-char DISPLAY failed (apostrophe + ampersand)"
NAME_TXT=$(cd "$TD" && cat fastlane/metadata/en-US/name.txt)
test "$NAME_TXT" = "$SPECIAL_DISPLAY" || \
  fail "HIGH-7: name.txt content '$NAME_TXT' (expected '$SPECIAL_DISPLAY')"
( cd "$TD" && grep -qF "Text(\"$SPECIAL_DISPLAY\")" app/Shared/ContentView.swift ) || \
  fail "HIGH-7: ContentView.swift missing Text(\"$SPECIAL_DISPLAY\")"
ok "apostrophe + ampersand DISPLAY_NAME survived sed_escape (literal preserved)"

step "HIGH-7: special-character DISPLAY_NAME (backslash)"
TD=$(fresh_clone)
BACKSLASH_DISPLAY='My\App'
( cd "$TD" && bin/rename.sh MyApp com.acme.myapp "$BACKSLASH_DISPLAY" \
    --email=test@acme.com --slug=test/myapp >/dev/null 2>&1 ) || \
  fail "HIGH-7: rename with backslash DISPLAY failed"
NAME_TXT=$(cd "$TD" && cat fastlane/metadata/en-US/name.txt)
test "$NAME_TXT" = "$BACKSLASH_DISPLAY" || \
  fail "HIGH-7: name.txt content '$NAME_TXT' (expected '$BACKSLASH_DISPLAY')"
ok "backslash DISPLAY_NAME survived sed_escape (literal preserved)"

# ── REQ-10: partial-rename detection + --force bypass ─────────────────────
#
# Per SPEC REQ-10: corrupting state post-rename (e.g. moving a renamed
# file back) triggers exit 1 with "partial-rename state detected" stderr.
# --force bypasses the gate (per MEDIUM-4). Two falsifiable paths.

step "REQ-10: partial-rename detected (move one renamed file back) exits 1"
TD=$(fresh_clone)
( cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
    --email=test@acme.com --slug=test/myapp >/dev/null 2>&1 ) || \
  fail "REQ-10 setup: initial rename failed"
( cd "$TD" && git add -A && git commit --quiet -m "first rename" )
# Corrupt state: put ONE identity value back to the template placeholder
# (the structure is a constant, so identity is the only rename signal).
( cd "$TD" && sed -i '' 's|^\(BUNDLE_ID[[:space:]]*=[[:space:]]*\)com.acme.myapp$|\1com.example.helloapp|' app/Identity.xcconfig && \
    git commit --quiet -am "partial-rename corruption" )

set +e
PR_OUT=$(cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --slug=test/myapp 2>&1)
PR_EXIT=$?
set -e
test "$PR_EXIT" -ne 0 || \
  fail "REQ-10: partial-rename should exit non-zero (got $PR_EXIT); output: $PR_OUT"
echo "$PR_OUT" | grep -q "partial-rename state detected" || \
  fail "REQ-10: stderr missing 'partial-rename state detected'; got: $PR_OUT"
ok "partial-rename detected (exit $PR_EXIT) — restore-or-force guidance emitted"

step "REQ-10 (MEDIUM-4): --force bypasses partial-rename gate"
# Same TD as above. With --force, the partial-rename gate is bypassed and
# the script proceeds: the sweep re-substitutes the one value we put back
# (BUNDLE_ID) and regen runs — control reached past the gate.
set +e
FB_OUT=$(cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --slug=test/myapp --force 2>&1)
FB_EXIT=$?
set -e
echo "$FB_OUT" | grep -qF -- "--force bypass enabled" || \
  fail "REQ-10 (MEDIUM-4): --force did not announce bypass; got: $FB_OUT"
# Bypass-announced is the falsifiable signal — the downstream behavior
# (whether mv succeeds) depends on which file we moved. The SPEC says
# --force "bypasses the on-main-branch gate AND the partial-rename
# detection gate" — that's the contract under test.
ok "--force bypassed partial-rename gate (downstream exit $FB_EXIT — bypass announced)"

# ── REQ-10 (MEDIUM-4): --force bypasses on-main-branch gate ──────────────
#
# Per SPEC REQ-5 / MEDIUM-4: --force bypasses the on-main gate (so power
# users on a feature branch can run the rename). Falsifiable via clean
# clone on a non-main branch.

step "REQ-10 (MEDIUM-4): --force bypasses on-main-branch gate"
TD=$(fresh_clone)
( cd "$TD" && git checkout --quiet -b feature/probe HEAD )

# Without --force: should fail at on-main gate.
set +e
NB_OUT=$(cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --slug=test/myapp 2>&1)
NB_EXIT=$?
set -e
test "$NB_EXIT" -ne 0 || \
  fail "REQ-5: feature branch without --force should exit non-zero (got $NB_EXIT)"
echo "$NB_OUT" | grep -q "not on main branch" || \
  fail "REQ-5: stderr missing 'not on main branch'; got: $NB_OUT"
ok "feature branch without --force rejected (exit $NB_EXIT)"

# With --force: should succeed (rename completes; xcodegen runs).
set +e
FB_OUT=$(cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --slug=test/myapp --force 2>&1)
FB_EXIT=$?
set -e
test "$FB_EXIT" -eq 0 || \
  fail "MEDIUM-4: feature branch + --force should succeed (got $FB_EXIT); output: $FB_OUT"
test -d "$TD/app/App.xcodeproj" || \
  fail "MEDIUM-4: --force rename completed but app/App.xcodeproj missing (the project name is a constant)"
grep -qE '^[[:space:]]*APP_PRODUCT_NAME[[:space:]]*=[[:space:]]*MyApp[[:space:]]*$' "$TD/app/Identity.xcconfig" || \
  fail "MEDIUM-4: --force rename completed but app/Identity.xcconfig does not carry APP_PRODUCT_NAME = MyApp"
ok "feature branch + --force succeeded (exit $FB_EXIT, app/App.xcodeproj regenerated, identity in the xcconfig)"

# ── HelloApp scrub: G-01 closure verification (substring not whole-word) ──
#
# G-01 closure changed Step F from `git grep -lw` to `git grep -l` so
# `HelloApp` matches as a substring (`HelloApp.title` in
# AccessibilityIdentifiers.swift, `HelloAppTemplate`-style compounds).
# Falsifiable: the @main struct is the constant `AppMain` and must be
# untouched; the selector `HelloApp.title` must have become `MyApp.title`.

step "G-01: HelloApp scrub (substring match in Step F broad sweep)"
TD=$(fresh_clone)
( cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
    --email=test@acme.com --slug=test/myapp >/dev/null 2>&1 ) || \
  fail "G-01 setup: rename failed"
# The structure is constant: App.swift still exists, still declares AppMain.
test -f "$TD/app/Shared/App.swift" || fail "G-01: app/Shared/App.swift missing post-rename"
grep -qF "struct AppMain: App" "$TD/app/Shared/App.swift" || \
  fail "G-01: app/Shared/App.swift no longer declares 'struct AppMain: App' — the sweep must not touch the constant structure"
# Substring assertion: the accessibility selector was swept.
grep -qF '"MyApp.title"' "$TD/app/Shared/AccessibilityIdentifiers.swift" || \
  fail "G-01: AccessibilityIdentifiers.swift missing 'MyApp.title' — substring substitution did not occur"
# Repo-wide: zero HelloApp substring matches outside the standard exclusions.
# M3 P3 cross-AI HIGH-2 part B closure (2026-04-30; SPEC carve-out):
# extended with 2 new pathspec entries for the verify-rename
# infrastructure files so this gate does not false-fail on them.
# NARROW maintenance only — no other change to this gate.
# Exclusions mirror bin/rename.sh's PATHSPEC_EXCLUSIONS and
# bin/verify-rename.sh's list: bin/lib/bootstrap.rb and the upstream-only
# matrix workflow keep their HelloApp literals by design (the orchestrator
# stays self-describing; the workflow's repository guard survives).
HITS=$(cd "$TD" && git grep -c -e HelloApp -- . \
        ':!.planning' ':!LICENSE' ':!app/App.xcodeproj' \
        ':!bin/rename.sh' ':!ci/test-rename.sh' ':!ci/test-rename-gates.sh' \
        ':!bin/verify-rename.sh' ':!ci/test-verify-rename.sh' \
        ':!bin/lib/bootstrap.rb' ':!.github/workflows/bootstrap-doctor-matrix.yml' \
        2>/dev/null \
        | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)
test "$HITS" = "0" || \
  fail "G-01: $HITS HelloApp substring matches remain post-rename (substring form, no -w)"
ok "AppMain untouched; MyApp.title present; 0 HelloApp substring hits repo-wide"

# ── Gate 5d: --generator validation (#38; PR 4) ───────────────────────────
#
# Per #38: bin/rename.sh's --generator=GEN flag accepts only 'tuist' or
# 'xcodegen' (default 'xcodegen'). Three falsifiable forms exercised:
#   - --generator=invalid → fail at validate_args
#   - --generator=tuist on dry-run from REPO_ROOT (where tuist IS on PATH)
#     → succeeds with 'Post-rename generator switch' line in dry-run output
#   - --generator=xcodegen explicit (the default) → succeeds with 'xcodegen'
#     in dry-run output

step "Gate 5d: --generator=invalid exits 1 with descriptive error"
set +e
GI_OUT=$(cd "$REPO_ROOT" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --slug=test/myapp --generator=invalid 2>&1)
GI_EXIT=$?
set -e
test "$GI_EXIT" -ne 0 || \
  fail "Gate 5d: --generator=invalid should exit non-zero (got $GI_EXIT); output: $GI_OUT"
echo "$GI_OUT" | grep -q -- "invalid --generator 'invalid'" || \
  fail "Gate 5d: stderr missing \"invalid --generator 'invalid'\"; got: $GI_OUT"
echo "$GI_OUT" | grep -q "must be 'tuist' or 'xcodegen'" || \
  fail "Gate 5d: stderr missing \"must be 'tuist' or 'xcodegen'\"; got: $GI_OUT"
ok "--generator=invalid rejected (exit $GI_EXIT)"

step "Gate 5d: --generator=tuist dry-run shows 'Post-rename generator switch'"
TD=$(fresh_clone)
set +e
GT_OUT=$(cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --slug=test/myapp --generator=tuist --dry-run 2>&1)
GT_EXIT=$?
set -e
test "$GT_EXIT" -eq 0 || fail "Gate 5d: --generator=tuist --dry-run exited $GT_EXIT (expected 0); output: $GT_OUT"
echo "$GT_OUT" | grep -q -- "--generator 'tuist' valid" || \
  fail "Gate 5d: --generator=tuist did not announce valid; got: $GT_OUT"
echo "$GT_OUT" | grep -q "Post-rename generator switch (--generator=tuist):" || \
  fail "Gate 5d: --generator=tuist dry-run missing 'Post-rename generator switch'; got: $GT_OUT"
echo "$GT_OUT" | grep -q "tuist on PATH" || \
  fail "Gate 5d: --generator=tuist did not run gate_tuist_present_if_needed; got: $GT_OUT"
ok "--generator=tuist dry-run announces switch + runs tuist-presence gate"

step "Gate 5d: --generator=xcodegen (default) dry-run announces xcodegen path"
TD=$(fresh_clone)
set +e
GX_OUT=$(cd "$TD" && bin/rename.sh MyApp com.acme.myapp "My App" \
  --email=test@acme.com --slug=test/myapp --generator=xcodegen --dry-run 2>&1)
GX_EXIT=$?
set -e
test "$GX_EXIT" -eq 0 || fail "Gate 5d: --generator=xcodegen --dry-run exited $GX_EXIT (expected 0); output: $GX_OUT"
echo "$GX_OUT" | grep -q -- "--generator 'xcodegen' valid" || \
  fail "Gate 5d: --generator=xcodegen did not announce valid; got: $GX_OUT"
echo "$GX_OUT" | grep -q "Post-rename generator: xcodegen" || \
  fail "Gate 5d: --generator=xcodegen dry-run missing 'Post-rename generator: xcodegen'; got: $GX_OUT"
# Tuist gate must NOT run on the xcodegen path (avoid forcing forkers
# without tuist installed to install it).
! echo "$GX_OUT" | grep -q "tuist on PATH" || \
  fail "Gate 5d: --generator=xcodegen unexpectedly ran tuist-presence gate; got: $GX_OUT"
ok "--generator=xcodegen (default) announces xcodegen path; tuist gate not invoked"

# ── Done ──────────────────────────────────────────────────────────────────

step "ci/test-rename-gates.sh: all gate-coverage assertions passed"
ok "tmpdir cleanup will run via EXIT trap"
