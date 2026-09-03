#!/usr/bin/env bash
# bin/rename.sh — fork-rename script for the apple-shipkit.
#
# Substitutes 5 identity surfaces + 1 derived value and regenerates the
# xcodeproj. Atomic (all-or-nothing via reset-hard rollback), idempotent
# (silent no-op on re-run with same args), pre-flight-gated.
#
# The project STRUCTURE is a constant and is never renamed: app/App.xcodeproj,
# the App-iOS / App-macOS schemes, app/Shared/App.swift, App.entitlements and
# the App*Tests targets stay as they are on every fork. What this script
# renames is the app's IDENTITY — the values in app/Identity.xcconfig
# (bundle id, product name, display name) plus the docs, metadata and UI
# strings that spell the same placeholders.
#
# Usage:
#   bin/rename.sh APP_NAME BUNDLE_ID DISPLAY_NAME --email=EMAIL [--slug=OWNER/REPO] [--year=YYYY] [--generator=tuist|xcodegen] [--platforms=ios|macos|ios,macos] [--team-id=TEAMID] [--dry-run] [--force]
#   bin/rename.sh -h                                # print this usage
#   bin/rename.sh --help                            # alias for -h
#
# Required positional args:
#   APP_NAME       Swift identifier — capitalized, no spaces/dashes/dots/leading digits
#                  (regex: ^[A-Z][a-zA-Z0-9]*$; e.g. MyApp)
#   BUNDLE_ID      Reverse-DNS, lowercase, dot-separated; no underscores/uppercase
#                  (regex: ^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$; e.g. com.acme.myapp)
#   DISPLAY_NAME   Non-empty display name (Apple allows spaces/punctuation).
#                  MUST NOT contain newline or '|' (sed delimiter).
#
# Required flag:
#   --email=EMAIL  Maintainer/security contact email; substitutes
#                  maintainers@indiagram.com across CODE_OF_CONDUCT.md
#                  and SECURITY.md. MUST NOT contain newline or '|'.
#
# Optional flags:
#   --slug=OWNER/REPO   GitHub org/repo slug; substitutes
#                       indiagrams/apple-shipkit across README.md +
#                       CONTRIBUTING.md. If omitted, auto-derives from
#                       `git remote get-url origin`. MUST NOT contain
#                       newline or '|'.
#   --year=YYYY         Override copyright year (default: current year via date +%Y).
#   --generator=GEN     Project generator to use post-rename. One of:
#                         xcodegen (default; byte-for-byte unchanged behavior;
#                                   Tuist artifacts left in tree but unused)
#                         tuist    (invokes bin/switch-to-tuist.sh --force after
#                                   rename to delete app/project.yml + edit
#                                   Brewfile / Makefile / ci scripts / pr.yml)
#                       Both manifests ship on `main` (#38); the flag picks which
#                       one drives the renamed fork. Pre-flight gate fails if
#                       --generator=tuist and `tuist` is not on PATH.
#   --team-id=TEAMID    Apple Developer team ID (10-char alphanumeric, e.g.
#                       A1B2C3D4E5). Written as DEVELOPMENT_TEAM into the
#                       GITIGNORED app/Local.xcconfig — never into a tracked
#                       manifest — so signed builds (`make ship`,
#                       `make screenshots`, plain xcodebuild) work without
#                       manual edits and the Team ID stays out of git.
#                       Optional; if omitted, no Local.xcconfig is written and
#                       the rename-complete summary says so. bin/bootstrap-fork.rb
#                       auto-fills from .bootstrap.env's FASTLANE_TEAM_ID, so
#                       the `make bootstrap-fork` path never leaves it unset.
#   --dry-run           Preview substitutions without applying.
#   --force             Override the on-main-branch gate AND the partial-
#                       rename detection gate. Other gates (args validation,
#                       xcodegen presence, sed escapes) still fire.
#
# Argument forms:
#   --email=VAL    (preferred, equal-sign form)
#   --email VAL    (split form — VAL must be non-empty and not start with '-')
#
# Pre-flight gate ORDER (canonical; cross-AI HIGH-3 + MEDIUM-2 fix):
#   1. Args parsing (split-flag values rejected if missing or '-'-prefixed)
#   2. xcodegen on PATH
#   3. APP_NAME matches ^[A-Z][a-zA-Z0-9]*$
#   4. BUNDLE_ID matches ^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$
#   5. DISPLAY_NAME non-empty AND no newline/'|'
#   5b. EMAIL non-empty AND no newline/'|'
#   5c. SLUG non-empty (auto-derived if absent) AND no newline/'|' AND OWNER/REPO format
#   5d. GENERATOR ∈ {tuist, xcodegen} (default xcodegen; tuist requires `tuist` on PATH)
#   6. Idempotency check (BEFORE clean-tree gate per HIGH-3) —
#      case 0 = silent exit 0 (already renamed)
#      case 1 = partial-rename fail (unless --force)
#      case 2 = proceed
#   7. Working tree is clean (git status --short empty — strict, includes
#      untracked files; this prevents data-loss via reset-hard)
#   8. Current branch is `main` (override via --force)
#
# Idempotency:
#   Re-running with SAME args after a successful first run detects
#   already-renamed state from app/Identity.xcconfig (APP_PRODUCT_NAME and
#   BUNDLE_ID both already carry the requested values); exits 0 silently.
#   The check runs BEFORE the clean-tree gate so a second invocation on a
#   dirty post-first-rename tree still resolves correctly.
#
# All-or-nothing (HIGH-1 reset-hard rollback — replaces broken git stash):
#   Pre-flight Gate 7 (clean tree) ensures HEAD == working tree pre-mutation.
#   Any failure in sed/xcodegen steps triggers ERR/EXIT/INT/TERM trap
#   which executes:
#     1. rm -rf app/App.xcodeproj        (regenerated dir is gitignored)
#     2. git reset --hard HEAD --quiet   (restores tracked-file mods + git mv)
#     3. git clean -fd --quiet           (removes new untracked files; NOT -fdx)
#   Exits 1 with stderr "rolled back to pre-rename state."
#
# Constraints:
#   - bash 3.2+ (macOS default); no bash 4+ features
#   - BSD-portable sed (sed -i '', | delimiter, escaped dots)
#   - sed replacement values escaped via sed_escape_replacement (HIGH-7)
#   - No new external dependencies (git, bash, sed, mv, find, grep, xcodegen)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

print_usage() {
  # Print every comment line from line 2 until just before the
  # `set -euo pipefail` body line. Pattern-anchored so the usage block
  # adapts as we extend it across T1-T8 incremental edits.
  sed -n '2,/^set -euo pipefail$/{ /^set -euo pipefail$/!p; }' "$0" | sed 's/^# \{0,1\}//'
}

# ── Argument parsing ──────────────────────────────────────────────────────
# Detect -h / --help BEFORE positional consumption so `bin/rename.sh -h`
# works without any other args (REQ-1, AC-2).
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      print_usage
      exit 0
      ;;
  esac
done

# ── Globals (set by parse_args; consumed by gate functions + main) ───────
APP_NAME=""
BUNDLE_ID=""
DISPLAY_NAME=""
EMAIL=""
SLUG=""
YEAR_ARG=""
GENERATOR="xcodegen"   # default; --generator=tuist|xcodegen overrides (#38)
PLATFORMS="ios,macos"  # default; --platforms=ios|macos|ios,macos overrides (matches .bootstrap.env PLATFORMS)
TEAM_ID=""             # optional; --team-id=A1B2C3D4E5 is written to gitignored app/Local.xcconfig as DEVELOPMENT_TEAM
DRY_RUN=0
FORCE=0

# ── Argument parsing (function; called by main in T7) ────────────────────
# MEDIUM-3 split-flag rejection: --email VAL / --slug VAL reject
# missing values AND values starting with '-'.
parse_args() {
  local POSITIONAL=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        print_usage; exit 0 ;;
      --dry-run)
        DRY_RUN=1; shift ;;
      --force)
        FORCE=1; shift ;;
      --email=*)
        EMAIL="${1#--email=}"; shift ;;
      --email)
        [ $# -ge 2 ] || fail "--email requires a value (e.g. --email=address@example.com)"
        case "$2" in -*) fail "--email value cannot start with '-' (got '$2')";; esac
        EMAIL="$2"; shift 2 ;;
      --slug=*)
        SLUG="${1#--slug=}"; shift ;;
      --slug)
        [ $# -ge 2 ] || fail "--slug requires a value (e.g. --slug=acme/myapp)"
        case "$2" in -*) fail "--slug value cannot start with '-' (got '$2')";; esac
        SLUG="$2"; shift 2 ;;
      --year=*)
        YEAR_ARG="${1#--year=}"; shift ;;
      --year)
        [ $# -ge 2 ] || fail "--year requires a value (e.g. --year=2026)"
        case "$2" in -*) fail "--year value cannot start with '-' (got '$2')";; esac
        YEAR_ARG="$2"; shift 2 ;;
      --generator=*)
        GENERATOR="${1#--generator=}"; shift ;;
      --generator)
        [ $# -ge 2 ] || fail "--generator requires a value (e.g. --generator=tuist)"
        case "$2" in -*) fail "--generator value cannot start with '-' (got '$2')";; esac
        GENERATOR="$2"; shift 2 ;;
      --platforms=*)
        PLATFORMS="${1#--platforms=}"; shift ;;
      --platforms)
        [ $# -ge 2 ] || fail "--platforms requires a value (e.g. --platforms=ios)"
        case "$2" in -*) fail "--platforms value cannot start with '-' (got '$2')";; esac
        PLATFORMS="$2"; shift 2 ;;
      --team-id=*)
        TEAM_ID="${1#--team-id=}"; shift ;;
      --team-id)
        [ $# -ge 2 ] || fail "--team-id requires a value (e.g. --team-id=A1B2C3D4E5)"
        case "$2" in -*) fail "--team-id value cannot start with '-' (got '$2')";; esac
        TEAM_ID="$2"; shift 2 ;;
      -*)
        fail "unknown flag '$1' — run with -h for usage" ;;
      *)
        POSITIONAL+=("$1"); shift ;;
    esac
  done

  if [ "${#POSITIONAL[@]}" -lt 3 ]; then
    fail "missing required positional args — usage: bin/rename.sh APP_NAME BUNDLE_ID DISPLAY_NAME --email=EMAIL [--slug=OWNER/REPO]"
  fi
  APP_NAME="${POSITIONAL[0]}"
  BUNDLE_ID="${POSITIONAL[1]}"
  DISPLAY_NAME="${POSITIONAL[2]}"
}

# ── HIGH-7 input-gate helper (function; called by validate_args) ─────────
# The sed delimiter is `|` and BSD sed cannot handle multi-line
# replacements via single-line `s|...|...|` form. Reject these
# characters at the gate so downstream sed_escape_replacement only
# has to handle &, \, |.
reject_special_chars() {
  local label="$1" value="$2"
  case "$value" in
    *$'\n'*) fail "$label contains a newline — not supported (got: $(printf %q "$value"))" ;;
  esac
  case "$value" in
    *'|'*) fail "$label contains '|' — not supported (sed delimiter; got: $value)" ;;
  esac
}

# ── Args-validation gates 3, 4, 5, 5b, 5c (function; called by main) ─────
# Cheap regex + non-empty + special-char checks. Does NOT include
# gate 2 (xcodegen — file-system-touching), gates 7+8 (clean-tree +
# on-main — git-state-touching) — those are gate_xcodegen_present(),
# gate_clean_tree(), gate_on_main() defined in T7.
validate_args() {
  step "Pre-flight gates (args validation)"

  # Gate 3: APP_NAME is a valid Swift identifier
  [[ "$APP_NAME" =~ ^[A-Z][a-zA-Z0-9]*$ ]] || \
    fail "invalid APP_NAME '$APP_NAME' — must match ^[A-Z][a-zA-Z0-9]*$ (e.g. MyApp, no spaces)"
  ok "APP_NAME '$APP_NAME' is a valid Swift identifier"

  # Gate 4: BUNDLE_ID matches reverse-DNS pattern
  [[ "$BUNDLE_ID" =~ ^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$ ]] || \
    fail "invalid BUNDLE_ID '$BUNDLE_ID' — must match reverse-DNS lowercase (e.g. com.acme.myapp)"
  ok "BUNDLE_ID '$BUNDLE_ID' matches reverse-DNS pattern"

  # Gate 5: DISPLAY_NAME non-empty + HIGH-7 input rejection
  [ -n "$DISPLAY_NAME" ] || fail "DISPLAY_NAME is empty — pass a non-empty third positional arg (e.g. \"My App\")"
  reject_special_chars "DISPLAY_NAME" "$DISPLAY_NAME"
  ok "DISPLAY_NAME '$DISPLAY_NAME' is non-empty (no newline / '|')"

  # Gate 5b: --email required + HIGH-7 input rejection
  [ -n "$EMAIL" ] || fail "--email is required — pass --email=address@example.com"
  reject_special_chars "EMAIL" "$EMAIL"
  ok "--email '$EMAIL' provided (no newline / '|')"

  # Gate 5c: --slug auto-derive if omitted, then HIGH-7 + format check
  if [ -z "$SLUG" ]; then
    local ORIGIN
    ORIGIN=$(git config --get remote.origin.url 2>/dev/null || true)
    [ -n "$ORIGIN" ] || \
      fail "--slug not provided AND no origin remote — pass --slug=OWNER/REPO or set origin"
    SLUG=$(echo "$ORIGIN" \
      | sed -E -e 's#^git@github\.com:##' \
               -e 's#^https://github\.com/##' \
               -e 's#\.git$##')
    ok "--slug auto-derived from origin: '$SLUG'"
  else
    ok "--slug '$SLUG' explicit"
  fi
  reject_special_chars "SLUG" "$SLUG"
  [[ "$SLUG" =~ ^[^/]+/[^/]+$ ]] || \
    fail "invalid --slug '$SLUG' — expected OWNER/REPO (e.g. acme/myapp)"
  ok "SLUG format OK"

  # Gate 5d: --generator ∈ {tuist, xcodegen}. Default 'xcodegen' set at
  # file scope so this gate effectively rejects anything that survived
  # parse_args with a non-empty non-default value.
  case "$GENERATOR" in
    tuist|xcodegen) ;;
    *) fail "invalid --generator '$GENERATOR' — must be 'tuist' or 'xcodegen' (default: xcodegen)" ;;
  esac
  ok "--generator '$GENERATOR' valid"

  # Gate 5e: --platforms ⊆ {ios, macos}, comma-separated, non-empty.
  # Computes PLATFORMS_LABEL — the human-readable label baked into the
  # SwiftUI stub's subtitle ("iOS template" / "macOS template" /
  # "iOS + macOS template"). Mirrors .bootstrap.env's PLATFORMS field.
  # Default 'ios,macos' set at file scope.
  PLATFORMS_LABEL=""
  case "$PLATFORMS" in
    ios)              PLATFORMS_LABEL="iOS template" ;;
    macos)            PLATFORMS_LABEL="macOS template" ;;
    ios,macos|macos,ios) PLATFORMS_LABEL="iOS + macOS template" ;;
    *) fail "invalid --platforms '$PLATFORMS' — must be 'ios', 'macos', 'ios,macos', or 'macos,ios' (default: ios,macos)" ;;
  esac
  ok "--platforms '$PLATFORMS' valid (label: '$PLATFORMS_LABEL')"

  # Gate 5f: --team-id format check (optional flag; only validates if set).
  # Apple Developer team IDs are 10-char alphanumeric (uppercase letters
  # + digits). The .bootstrap.env.example FASTLANE_TEAM_ID hint is the
  # same regex; if a forker sets something invalid, fail-loud here rather
  # than silently writing garbage into app/Local.xcconfig.
  if [ -n "$TEAM_ID" ]; then
    [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || \
      fail "invalid --team-id '$TEAM_ID' — must match ^[A-Z0-9]{10}$ (10-char uppercase alphanumeric, e.g. A1B2C3D4E5)"
    ok "--team-id '$TEAM_ID' valid"
  fi
}

# ── Reset-hard rollback (REQ-7; HIGH-1 closure — replaces broken stash) ───
#
# Background: the prior plan iteration used `git stash push --include-untracked`
# to capture pre-state. On a clean working tree (which Gate 7 requires),
# `git stash` creates NO entry and SNAPSHOT_CREATED stays 0 → rollback
# was a no-op → mutations were never undone. Cross-AI HIGH-1.
#
# Fix: leverage Gate 7's clean-tree precondition. Pre-mutation HEAD ==
# working tree, so `git reset --hard HEAD` restores tracked-file
# modifications and `git mv` staging. Plus:
#
#   - rm -rf app/App.xcodeproj        (regenerated dir is gitignored;
#     `git clean -fd` without -x won't touch it)
#   - git clean -fd                    (removes new untracked files;
#     NEVER -fdx — forker's .bootstrap.env / .env.local would be deleted)
#
# No git stash. No SNAPSHOT_REF. No snapshot_drop_on_success.
#
# iter-6 BLOCKER-iter5-1 closure: MUTATION_STARTED guard flag prevents
# the trap from firing destructive ops on a pre-mutation gate failure
# (e.g. dirty-tree gate fails → trap → reset --hard → DESTROYS the
# forker's uncommitted work). The flag is initialized to 0 here at
# file scope and flipped to 1 inside main() right before the first
# mutation call (apply_substitutions). rollback() early-outs unless
# the flag is set.

ROLLBACK_DONE=0
MUTATION_STARTED=0  # set to 1 in main() right before first mutation

rollback() {
  # Idempotent — only fires once even if both ERR and EXIT trip.
  [ "$ROLLBACK_DONE" = "1" ] && return 0
  ROLLBACK_DONE=1

  # iter-6 BLOCKER-iter5-1: pre-mutation early-out. If no mutations
  # were made, nothing to roll back — and running git reset --hard
  # HEAD on a forker's dirty working tree (e.g. when the clean-tree
  # gate failed and triggered the EXIT trap) would DESTROY the
  # forker's uncommitted work. main() flips MUTATION_STARTED=1
  # right before the first mutation call (apply_substitutions); any
  # failure BEFORE that point lands here as a no-op rollback.
  [ "$MUTATION_STARTED" = "1" ] || return 0

  printf '    ✗ rolling back to pre-rename state...\n' >&2

  # Step 1: remove the regenerated xcodeproj if T7 ran (it's gitignored,
  # so `git clean -fd` without -x won't touch it). The project name is a
  # constant, so there is no APP_NAME-derived path to guard.
  if [ -d "app/App.xcodeproj" ]; then
    rm -rf "app/App.xcodeproj" 2>/dev/null || true
  fi

  # Step 2: git reset --hard restores tracked-file modifications +
  # git mv staging back to HEAD.
  if git reset --hard HEAD --quiet 2>/dev/null; then
    # Step 3: git clean -fd removes any NEW untracked files xcodegen
    # may have created alongside. NOT -fdx — forker's .bootstrap.env etc.
    # are precious. Pre-flight Gate 7 already required clean tree, so
    # there should be nothing else to clean except what THIS script
    # introduced.
    git clean -fd --quiet 2>/dev/null || true
    printf '    ✗ rolled back to pre-rename state.\n' >&2
  else
    printf '    ✗ git reset --hard HEAD failed; manual recovery required.\n' >&2
    printf '    ✗ inspect: git status; git log --oneline -5\n' >&2
  fi
}

# Trap on ERR + EXIT + signals (Ctrl-C = INT, kill = TERM)
# The traps remain armed for the entire mutation phase (T5/T6/T7); they
# are disarmed by main() on the success path via `trap - ERR EXIT INT TERM`.
trap 'rollback' ERR
trap 'rollback' INT TERM
trap 'rollback' EXIT

# ── Substitution-target enumeration (REQ-2; HIGH-2 + MEDIUM-1 closure) ───

# Why -nw -e P1 -e P2 (not -nE '(\b|^)P\b'):
# M2 P5 cross-AI HIGH-1 (Codex): the regex form silently false-passes
# in git grep — returns 0 hits when 14 are present. -nw is git-grep-
# native and reliable. Carry-forward.
#
# Why -F on com.example.helloapp / maintainers@indiagram.com /
# indiagrams/apple-shipkit (MEDIUM-1):
# Without -F, the literal `.` in these patterns is regex any-char.
# `git grep -nw -e com.example.helloapp` would match `comXexampleXhelloapp`
# (none exist in tree, but the principle is wrong). -F treats the
# pattern as fixed-string. -F + -w combine correctly in git grep.
#
# Why :!bin/rename.sh :!ci/test-rename.sh exclusions (HIGH-2):
# bin/rename.sh contains every substitution-surface literal in its
# print_usage block, error messages, sed patterns, etc. Without
# exclusion, the broad HelloApp -> APP_NAME sweep would rewrite the
# running script — corrupting future runs. Same for ci/test-rename.sh
# (contains HelloApp, com.example.helloapp, etc. in test fixtures).

# The shared pathspec exclusion list (used everywhere)
# M3 P3 cross-AI HIGH-1 closure (2026-04-29): extended with 3 new
# entries for the verify-rename infrastructure files. Without these,
# the rename script's broad sweep (e.g. Step F's git grep -l HelloApp)
# would rewrite `APP_NAME_ORIG="HelloApp"` -> `APP_NAME_ORIG="MyApp"`
# inside bin/verify-rename.sh, breaking verify on every post-rename
# tree. ci/test-rename-gates.sh has the same problem (its G-01 fixture
# contains HelloAppApp). ci/test-verify-rename.sh embeds the same
# literals in its mutate-and-fail and D-05 marker tests.
PATHSPEC_EXCLUSIONS=(
  ':!.planning'
  ':!LICENSE'
  ':!app/App.xcodeproj'
  ':!bin/rename.sh'
  ':!ci/test-rename.sh'
  ':!ci/test-rename-gates.sh'
  ':!bin/verify-rename.sh'
  ':!ci/test-verify-rename.sh'
  # Upstream-only: validates the apple-shipkit template against the smoketest
  # using indiagrams's secrets. The job's `if: github.repository ==
  # 'indiagrams/apple-shipkit'` guard is the safety check that keeps the
  # workflow dormant on forks. Letting Step D rewrite that string to the
  # fork's slug DEFEATS the safety check — the workflow then runs on every
  # fork's PR and fails because the fork has no ASC secrets, no certs-repo
  # PAT, etc. Excluded entirely from the rename sweep so the safety guard
  # survives.
  # bin/lib/bootstrap.rb is the orchestrator that CALLS bin/rename.sh as
  # part of its pipeline. It contains "HelloApp" in three positions:
  #   - RenameStub#name display string ("Rename HelloApp → ...")
  #   - The :pending check comment ("no leftover HelloApp / ...")
  #   - InitialPush#do_it commit message template
  # The first two are cosmetic, but the commit-message corruption matters:
  # after the broad sweep rewrites HelloApp → SmokeApp here, any subsequent
  # bootstrap-fork that triggers a fresh InitialPush commit produces nonsense
  # like "Bootstrap fork: rename SmokeApp -> SmokeApp" in git history.
  # Excluded so the orchestrator stays self-describing.
  ':!bin/lib/bootstrap.rb'
  ':!.github/workflows/bootstrap-doctor-matrix.yml'
)

# ── Substitutions (REQ-2, REQ-9; D-1; HIGH-6 placeholder + HIGH-7 escape) ─

# HIGH-7 closure: escape sed replacement metacharacters &, \, |.
# Input gates (T2 reject_special_chars) already reject newlines and '|'
# in DISPLAY_NAME/EMAIL/SLUG, so this helper handles the residual cases:
#   - '&'  → in sed replacement, '&' = entire match. Escape to '\&'.
#   - '\'  → backslash. Escape to '\\'.
#   - '|'  → already rejected at gate, but escape to '\|' as belt-suspenders.
#
# In a single regex pass, match any of \ & | in the bracket expression
# and prefix with \. The replacement \\& re-emits the matched literal
# preceded by a backslash, producing the sed-replacement-safe form.
# (BSD sed's bracket expression DOES match a literal backslash inside
# [\&|] — verified empirically on macOS.) Because this is a single
# pass, no ordering concerns apply: each `\`, `&`, or `|` is matched
# at most once and replaced atomically with its escaped form.
sed_escape_replacement() {
  printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'
}

# The DISPLAY_NAME placeholder (HIGH-6 closure). Chosen so it does NOT
# contain HelloApp, com.example.helloapp, maintainers@indiagram.com,
# <year>, indiagrams/apple-shipkit — none of the broad sweeps
# will mutate it. Verified zero hits in current tree.
DISPLAY_PLACEHOLDER='__GSD_DISPLAY_PLACEHOLDER__'

apply_substitutions() {
  local year escaped_email escaped_slug escaped_display
  year="${YEAR_ARG:-$(date +%Y)}"
  escaped_email=$(sed_escape_replacement "$EMAIL")
  escaped_slug=$(sed_escape_replacement "$SLUG")
  escaped_display=$(sed_escape_replacement "$DISPLAY_NAME")

  # Step A: <year> -> current year (3 source sites; pre-xcodegen)
  # WR-01: wrap `git grep` in a brace group with `|| true` so a no-match
  # (`git grep` exit 1) does not abort the pipeline under
  # `set -euo pipefail`. Without this, the --force partial-rename path
  # spuriously triggers rollback when some surfaces are already
  # substituted. Brace group is required because `|` binds tighter than
  # `||`; a bare `git grep ... || true | while ...` would short-circuit
  # the entire pipeline on success.
  step "Substituting <year> -> $year"
  { git grep -lw -e '<year>' -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null || true; } \
    | while read -r f; do
        sed -i '' "s|<year>|$year|g" "$f"
        ok "<year> substituted in $f"
      done

  # Step B: com.example.helloapp -> $BUNDLE_ID
  # BUNDLE_ID is regex-validated to match ^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$
  # so cannot contain &, \, |, newline. No escape needed.
  step "Substituting com.example.helloapp -> $BUNDLE_ID"
  { git grep -lw -F -e 'com.example.helloapp' -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null || true; } \
    | while read -r f; do
        sed -i '' "s|com\.example\.helloapp|$BUNDLE_ID|g" "$f"
        ok "bundle ID substituted in $f"
      done

  # Step C: maintainers@indiagram.com -> $EMAIL (escaped — HIGH-7)
  step "Substituting maintainers@indiagram.com -> $EMAIL"
  { git grep -lw -F -e 'maintainers@indiagram.com' -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null || true; } \
    | while read -r f; do
        sed -i '' "s|maintainers@indiagram\.com|$escaped_email|g" "$f"
        ok "email substituted in $f"
      done

  # Step D: indiagrams/apple-shipkit -> $SLUG (escaped — HIGH-7)
  step "Substituting indiagrams/apple-shipkit -> $SLUG"
  { git grep -lw -F -e 'indiagrams/apple-shipkit' -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null || true; } \
    | while read -r f; do
        sed -i '' "s|indiagrams/apple-shipkit|$escaped_slug|g" "$f"
        ok "GitHub slug substituted in $f"
      done

  # Step E_NEW: DISPLAY_NAME anchored sites -> placeholder (HIGH-6 closure)
  # The placeholder is a literal string with no regex metachars and
  # no HelloApp/com.example.helloapp/etc. literal substrings — it
  # passes through Step F (broad HelloApp -> APP_NAME sweep) untouched.
  #
  # We derive `current_display` from app/Identity.xcconfig's DISPLAY_NAME
  # line instead of hardcoding "HelloApp". Rationale: on a freshly-cloned
  # template DISPLAY_NAME is the broad-sweep token (`HelloApp`), but on any
  # FORK of this template it is the fork's DISPLAY_NAME (e.g.
  # `Indiagram Smoke App`). Hardcoding the broad-sweep token here means
  # Step E silently no-ops on re-forks, then Step F's `HelloApp -> APP_NAME`
  # sweep doesn't catch the already-renamed display name, leaving every
  # re-forked tree with the wrong app display name. Runtime-derive fixes
  # this. The manifests carry no display name at all — both reference
  # $(DISPLAY_NAME) — so there is nothing to anchor there.
  step "Replacing DISPLAY_NAME sites with placeholder (HIGH-6)"

  local current_display=""
  if [ -f app/Identity.xcconfig ]; then
    current_display=$(awk '/^[[:space:]]*DISPLAY_NAME[[:space:]]*=/{
      sub(/^[[:space:]]*DISPLAY_NAME[[:space:]]*=[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      print
      exit
    }' app/Identity.xcconfig)
  fi
  if [ -z "$current_display" ]; then
    fail "Could not extract current DISPLAY_NAME from app/Identity.xcconfig"
  fi
  # Sed safety: a `#` in the display name would break our chosen delimiter.
  # `#` is unusual in app display names (Apple's "App Name" guidance
  # discourages punctuation) so we fail fast with a clear message rather
  # than auto-escape.
  case "$current_display" in
    *'#'*) fail "current CFBundleDisplayName '$current_display' contains '#' which breaks rename.sh's sed delimiter; rename the display name first" ;;
  esac
  ok "current DISPLAY_NAME detected: '$current_display'"

  # Without anchoring, Step F's broad HelloApp -> APP_NAME sweep would set
  # DISPLAY_NAME to the APP_NAME (forker's code-name) instead of the
  # DISPLAY_NAME (forker's user-facing name). One site: the xcconfig feeds
  # CFBundleDisplayName on both platforms through both generators.
  sed -i '' "s#^\([[:space:]]*DISPLAY_NAME[[:space:]]*=[[:space:]]*\)${current_display}[[:space:]]*\$#\1$DISPLAY_PLACEHOLDER#" app/Identity.xcconfig
  grep -q "$DISPLAY_PLACEHOLDER" app/Identity.xcconfig || \
    fail "DISPLAY placeholder was not set in app/Identity.xcconfig — sed regression"
  ok "DISPLAY placeholder set in app/Identity.xcconfig (DISPLAY_NAME)"

  if [ -f app/Shared/ContentView.swift ]; then
    sed -i '' "s#Text(\"$current_display\")#Text(\"$DISPLAY_PLACEHOLDER\")#g" app/Shared/ContentView.swift
    ok "DISPLAY placeholder set in app/Shared/ContentView.swift"
    # Platform label: "iOS + macOS template" → "$PLATFORMS_LABEL" (one of
    # "iOS template" / "macOS template" / "iOS + macOS template"). Driven
    # by --platforms (default ios,macos preserves the byte-for-byte
    # unchanged path on default-flow forks). One-shot direct substitution
    # — no placeholder mechanism needed since this string only appears at
    # one site in the source tree.
    sed -i '' "s|Text(\"iOS + macOS template\")|Text(\"$PLATFORMS_LABEL\")|g" app/Shared/ContentView.swift
    ok "platform label set in app/Shared/ContentView.swift ('$PLATFORMS_LABEL')"
  fi

  if [ -f app/UITests/AppStoreScreenshotTests.swift ]; then
    sed -i '' "s#staticTexts\[\"$current_display\"\]#staticTexts[\"$DISPLAY_PLACEHOLDER\"]#g" app/UITests/AppStoreScreenshotTests.swift
    ok "DISPLAY placeholder set in app/UITests/AppStoreScreenshotTests.swift"
  fi

  if [ -f fastlane/metadata/en-US/name.txt ]; then
    sed -i '' "s#^$current_display\$#$DISPLAY_PLACEHOLDER#" fastlane/metadata/en-US/name.txt
    ok "DISPLAY placeholder set in fastlane/metadata/en-US/name.txt"
  fi

  # Step F: HelloApp -> $APP_NAME (broad sweep; placeholder unaffected
  # because __GSD_DISPLAY_PLACEHOLDER__ contains no HelloApp substring)
  # APP_NAME is regex-validated [A-Z][a-zA-Z0-9]*; no escape needed.
  #
  # NOTE: enumeration is `git grep -l` (NO -w word-boundary). The other
  # surfaces (com.example.helloapp / maintainers@indiagram.com / slug /
  # <year>) are full-token strings, but `HelloApp` appears as a SUBSTRING
  # inside `HelloAppApp` (the SwiftUI @main struct name in
  # app/Shared/HelloApp.swift line 4). With -w, that file is not
  # enumerated → sed never visits it → post-rename file `MyApp.swift`
  # contains residual `HelloAppApp`, violating AC-4 (zero `HelloApp`
  # substring matches post-rename). Without -w, every file containing
  # the literal `HelloApp` substring is visited; sed's replacement
  # pattern is also non-word-bounded so `HelloAppApp` correctly becomes
  # `MyAppApp`. (Goal-backward verification gap-closure G-01.)
  step "Substituting HelloApp -> $APP_NAME (broad sweep)"
  { git grep -l -e 'HelloApp' -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null || true; } \
    | while read -r f; do
        sed -i '' "s|HelloApp|$APP_NAME|g" "$f"
        ok "HelloApp substituted in $f"
      done

  # HIGH-2 belt-and-suspenders assertion: bin/rename.sh and
  # ci/test-rename.sh MUST be bit-identical to pre-substitution.
  # Pathspec exclusion is the primary defense; this is the falsifiable
  # check that the defense worked.
  git diff --quiet -- bin/rename.sh ci/test-rename.sh 2>/dev/null \
    || fail "HIGH-2 violation: bin/rename.sh or ci/test-rename.sh modified by substitution sweep"
  ok "self-exclusion verified — bin/rename.sh + ci/test-rename.sh unchanged"

  # Step G_NEW: placeholder -> $DISPLAY_NAME (escaped — HIGH-7)
  step "Replacing placeholder with DISPLAY_NAME (HIGH-6)"
  { git grep -lw -F -e "$DISPLAY_PLACEHOLDER" -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null || true; } \
    | while read -r f; do
        sed -i '' "s|$DISPLAY_PLACEHOLDER|$escaped_display|g" "$f"
        ok "DISPLAY_NAME substituted in $f"
      done

  # HIGH-6 verifiable assertion: zero placeholder matches post-Step-G.
  # If the placeholder remains anywhere, Step G failed to clean up.
  REMAINING=$(git grep -F -c -e "$DISPLAY_PLACEHOLDER" -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null \
              | awk -F: 'BEGIN{s=0} $2>0{s+=$2} END{print s}' || true)
  [ "${REMAINING:-0}" = "0" ] || \
    fail "HIGH-6 violation: $REMAINING placeholder match(es) remain after Step G"
  ok "placeholder fully replaced (0 remaining)"

  # Step H: DEVELOPMENT_TEAM -> app/Local.xcconfig (gitignored)
  # The Apple Team ID is per-clone signing configuration, not identity: it
  # goes into app/Local.xcconfig, which app/Identity.xcconfig pulls in with
  # `#include?` and which .gitignore keeps out of every commit. It is never
  # substituted into a tracked manifest. (This step used to sed
  # TEAM_ID_PLACEHOLDER inside app/project.yml + app/Project.swift, which
  # put the real Team ID into git on the success path of every rename.)
  #
  # Without a resolvable DEVELOPMENT_TEAM every signed build path fails —
  # `make ship` (always), `make screenshots` outside the
  # CODE_SIGNING_ALLOWED=NO bypass added in #185, and any plain
  # `xcodebuild build` invocation on iOS — and on macOS the build succeeds
  # ad-hoc signed and says nothing. So the outcome here is always explicit:
  # the file is written and named, or the summary says it was not.
  # bin/bootstrap-fork.rb always passes --team-id from .bootstrap.env's
  # FASTLANE_TEAM_ID so the `make bootstrap-fork` path never skips it.
  #
  # Two refusals, both loud. A manifest that still carries the placeholder
  # is a tree from before the identity xcconfig, and writing Local.xcconfig
  # beside it would leave two competing DEVELOPMENT_TEAMs. And the write
  # only happens if git confirms the path is ignored — a Team ID must never
  # land in a file git would track. Other files that contain the literal
  # `TEAM_ID_PLACEHOLDER` (ci/local-release-check.sh's ExportOptions-plist
  # patch, the ExportOptions plists themselves) substitute into a TEMPORARY
  # copy at build time and are correct as they are.
  if [ -n "$TEAM_ID" ]; then
    step "Writing DEVELOPMENT_TEAM -> app/Local.xcconfig (gitignored)"
    for f in app/project.yml app/Project.swift; do
      if [ -f "$f" ] && grep -q 'TEAM_ID_PLACEHOLDER' "$f"; then
        fail "$f still carries TEAM_ID_PLACEHOLDER — the Team ID belongs in gitignored app/Local.xcconfig, never in a tracked manifest; remove the DEVELOPMENT_TEAM line from $f and re-run"
      fi
    done
    git check-ignore -q app/Local.xcconfig || \
      fail "app/Local.xcconfig is not gitignored — refusing to write a Team ID into a file git would track (restore the .gitignore rule)"
    local team_line="DEVELOPMENT_TEAM = $TEAM_ID"
    if [ -f app/Local.xcconfig ] && ! grep -qxF "$team_line" app/Local.xcconfig; then
      fail "app/Local.xcconfig already exists and does not say '$team_line' — refusing to overwrite it; edit it by hand"
    fi
    printf '%s\n' "$team_line" > app/Local.xcconfig
    ok "app/Local.xcconfig written ($team_line) — gitignored, never committed"
  fi
}

# ── Idempotency + partial-rename detection (REQ-6, REQ-10; HIGH-3) ───────

# Returns 0 if fully renamed (caller should silent-exit-0).
# Returns 1 if partial-rename state (caller should fail unless --force).
# Returns 2 if pre-rename state (caller should proceed normally).
# The signal is app/Identity.xcconfig, the one tracked file the rename
# writes identity into. The project structure is a constant, so file paths
# say nothing about whether a rename happened.
check_idempotency() {
  local identity="app/Identity.xcconfig"
  [ -f "$identity" ] || return 1   # no identity file at all: not a tree this script understands

  # Read a key's value: `KEY = value`, leading/trailing blanks stripped.
  xcconfig_value() {
    awk -v key="$1" '
      $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
        sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
        sub(/[[:space:]]*$/, "")
        print
        exit
      }' "$identity"
  }

  local product bundle
  product=$(xcconfig_value APP_PRODUCT_NAME)
  bundle=$(xcconfig_value BUNDLE_ID)

  local renamed=0
  [ "$product" = "$APP_NAME" ]  && renamed=$((renamed + 1))
  [ "$bundle"  = "$BUNDLE_ID" ] && renamed=$((renamed + 1))

  local source_present=0
  [ "$product" = "HelloApp" ]             && source_present=$((source_present + 1))
  [ "$bundle"  = "com.example.helloapp" ] && source_present=$((source_present + 1))

  if [ "$renamed" -eq 2 ] && [ "$source_present" -eq 0 ]; then
    return 0  # idempotent no-op (full rename detected)
  fi

  if [ "$renamed" -eq 0 ] && [ "$source_present" -eq 2 ]; then
    return 2  # proceed with normal rename
  fi

  return 1
}

# ── File paths ─────────────────────────────────────────────────────────────
# There are no file-path renames. app/Shared/App.swift, app/iOS/App.entitlements,
# app/macOS/App.entitlements, app/Tests/AppTests.swift and
# app/MacOSTests/AppMacOSTests.swift are the project's constant structure,
# referenced by literal path from both manifests; renaming them to the
# fork's name would break every CODE_SIGN_ENTITLEMENTS reference. (This
# script used to `git mv` five files here.)

# ── Pre-flight gate functions (called by main; iter-5 BLOCKER-3) ─────────
#
# File-scope is reserved for: helpers (T1) + function defs (T2-T7) +
# trap arming (T3) + main "$@" invocation (this file's last line).
# Everything else lives inside main() so call order is canonical
# AND every callee is defined when called (resolves BLOCKER-3).

gate_xcodegen_present() {
  command -v xcodegen >/dev/null 2>&1 || \
    fail "xcodegen not found — run \`make bootstrap\` first"
  ok "xcodegen on PATH"
}

gate_tuist_present_if_needed() {
  # Only fires when --generator=tuist. Pre-mutation gate so we fail
  # fast before any file mutation. The tuist binary is needed because
  # bin/switch-to-tuist.sh (invoked post-rename when GEN=tuist) gates
  # on `tuist` being on PATH and the rename script's atomic-rollback
  # contract requires no successful mutations before a downstream
  # failure.
  if [ "$GENERATOR" = "tuist" ]; then
    command -v tuist >/dev/null 2>&1 || \
      fail "tuist not found (--generator=tuist) — install with 'brew install --cask tuist' (then re-run)"
    ok "tuist on PATH ($(tuist version 2>/dev/null | head -1))"
  fi
}

gate_clean_tree() {
  # NOTE: We deliberately DO NOT pass --untracked-files=no here.
  # Forker-facing script must catch untracked files (e.g.
  # .bootstrap.env, notes.md, WIP edits) so they don't get touched
  # by reset-hard rollback.
  if [ "$(git status --short | wc -l | tr -d ' ')" != "0" ]; then
    fail "working tree not clean — commit, stash, or remove untracked files before running rename"
  fi
  ok "working tree clean"
}

gate_on_main() {
  local BRANCH
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "$BRANCH" != "main" ] && [ "$FORCE" != "1" ]; then
    fail "not on main branch (currently: $BRANCH) — run with --force to override"
  fi
  ok "branch check: $BRANCH (force=$FORCE)"
}

# ── xcodegen regen (REQ-4; D-1 step 3) ───────────────────────────────────

regen_xcodeproj() {
  step "Regenerating xcodeproj via xcodegen"

  # The project name is a constant, deliberately untouched by the sweep: the
  # generated project is app/App.xcodeproj on every fork, and identity
  # resolves from app/Identity.xcconfig at build time.
  grep -q "^name: App$" app/project.yml || \
    fail "project.yml \`name:\` is not the constant 'App' — the sweep must not touch the project name"
  ok "project.yml \`name: App\` confirmed pre-xcodegen"

  if [ -d "app/App.xcodeproj" ]; then
    rm -rf "app/App.xcodeproj"
    ok "removed gitignored app/App.xcodeproj (stale)"
  fi

  # xcodegen runs bin/preflight-identity.rb first (options.preGenCommand),
  # so an identity key the sweep somehow emptied fails here by name.
  ( cd app && xcodegen generate ) || \
    fail "xcodegen generate failed — check app/project.yml and app/Identity.xcconfig post-substitution"

  [ -d "app/App.xcodeproj" ] || \
    fail "xcodegen completed but app/App.xcodeproj/ not created — unexpected"
  ok "app/App.xcodeproj/ regenerated"
}

# ── --dry-run preview (REQ-8; T8 will extend this) ───────────────────────

print_dry_run_plan() {
  step "DRY RUN — no files will be modified"

  echo
  echo "Substitution surfaces by file (via 'git grep -cw' with -F for fixed-literal patterns):"

  # Per-pattern enumeration. -F applied to fixed-literal patterns
  # (MEDIUM-1); HelloApp + <year> have no regex metachars.
  # All grep invocations use PATHSPEC_EXCLUSIONS from T4 (HIGH-2:
  # excludes :!bin/rename.sh and :!ci/test-rename.sh).
  local pat fflag label
  while IFS='|' read -r pat fflag label; do
    echo
    echo "  $label"
    if [ "$fflag" = "F" ]; then
      git grep -cw -F -e "$pat" -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null \
        | awk -F: '$2 > 0 { printf "    %-50s %d match(es)\n", $1, $2 }' \
        || echo "    (no matches)"
    else
      git grep -cw -e "$pat" -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null \
        | awk -F: '$2 > 0 { printf "    %-50s %d match(es)\n", $1, $2 }' \
        || echo "    (no matches)"
    fi
  done <<EOF
HelloApp||HelloApp -> $APP_NAME (broad sweep)
com.example.helloapp|F|com.example.helloapp -> $BUNDLE_ID
maintainers@indiagram.com|F|maintainers@indiagram.com -> $EMAIL
<year>||<year> -> $(date +%Y)
indiagrams/apple-shipkit|F|indiagrams/apple-shipkit -> $SLUG
EOF

  echo
  echo "DISPLAY_NAME anchored sites (-> $DISPLAY_NAME via __GSD_DISPLAY_PLACEHOLDER__):"
  echo "  app/Identity.xcconfig: DISPLAY_NAME (feeds CFBundleDisplayName on both platforms)"
  echo "  app/Shared/ContentView.swift: Text(\"HelloApp\")"
  echo "  app/UITests/AppStoreScreenshotTests.swift: staticTexts[\"HelloApp\"]"
  echo "  fastlane/metadata/en-US/name.txt: whole-file"

  echo
  echo "File-path renames:"
  echo "  none — app/App.xcodeproj, App.swift, App.entitlements and the App*Tests targets are constants"

  echo
  echo "Team ID:"
  if [ -n "$TEAM_ID" ]; then
    echo "  app/Local.xcconfig (gitignored)  <-  DEVELOPMENT_TEAM = $TEAM_ID"
  else
    echo "  --team-id not given: app/Local.xcconfig will NOT be written"
  fi

  echo
  echo "xcodegen regen:"
  echo "  cd app && xcodegen generate  ->  app/App.xcodeproj/"

  if [ "$GENERATOR" = "tuist" ]; then
    echo
    echo "Post-rename generator switch (--generator=tuist):"
    echo "  bin/switch-to-tuist.sh --force  ->  delete app/project.yml + edit Brewfile / Makefile / ci scripts / .github/workflows/pr.yml"
  else
    echo
    echo "Post-rename generator: xcodegen (default; Tuist artifacts left in tree but unused)"
  fi

  echo
  ok "dry run complete — re-run without --dry-run to apply"
}

# ── Main orchestration (iter-5 BLOCKER-3 — canonical call order) ─────────

main() {
  # 1. Args parsing (defined in T2)
  parse_args "$@"

  # 2. Idempotency dispatch — case 0/1/2 (HIGH-3: BEFORE clean-tree).
  # Goal-backward gap-closure G-02: the dispatch MUST run before
  # validate_args (which prints "==> Pre-flight gates (args validation)").
  # SPEC REQ-6 / AC-13 require the case-0 path to produce NO stdout.
  # Running validate_args first violates that contract on a fully-
  # renamed tree.
  #
  # Trade-off: APP_NAME hasn't been regex-validated yet at this point,
  # so check_idempotency runs against a potentially-invalid
  # `app/$APP_NAME.xcodeproj` path. This is structurally safe because:
  #   - If APP_NAME is invalid, no target paths exist, so case is 2
  #     (or 1 if some-but-not-all source paths missing). Either way
  #     control falls through to validate_args, which rejects the
  #     invalid APP_NAME with the correct error.
  #   - If APP_NAME is valid AND matches a fully-renamed state, case
  #     is 0 → silent exit 0 (the desired contract).
  set +e
  check_idempotency
  local IDEMPOT=$?
  set -e

  case "$IDEMPOT" in
    0)
      # Already-renamed.
      # WR-02: under --dry-run, the user's intent is "show me what
      # WOULD change." Silent exit 0 leaves them unsure whether the
      # script crashed, no-oped, or mis-parsed flags. Print an
      # explicit "nothing to preview" message before exiting.
      if [ "$DRY_RUN" = "1" ]; then
        step "DRY RUN — already-renamed state detected"
        ok "no substitutions would be applied (re-run idempotent)"
      fi
      # Real run on already-renamed tree: silent exit 0 per REQ-6 +
      # SPEC AC-13. No step(), no ok(), no stdout. Disarm traps (no
      # rollback needed because no mutations occurred).
      trap - ERR EXIT INT TERM
      exit 0
      ;;
    1)
      # Partial-rename state OR APP_NAME mismatch. Per MEDIUM-4,
      # --force bypasses this gate. validate_args will fire below
      # so an invalid APP_NAME on this branch surfaces as the
      # validate_args error, not as partial-rename noise.
      step "Pre-flight"
      if [ "$FORCE" = "1" ]; then
        step "Idempotency check"
        ok "partial-rename state detected; --force bypass enabled — proceeding"
      else
        step "Idempotency check"
        fail "partial-rename state detected — restore manually or run --force to override"
      fi
      ;;
    2)
      step "Pre-flight"
      step "Idempotency check"
      ok "pre-rename state confirmed — proceeding with rename"
      ;;
  esac

  # 3. Args validation: gates 3, 4, 5, 5b, 5c (defined in T2)
  validate_args

  # 4. xcodegen presence (gate 2)
  gate_xcodegen_present

  # 4b. Tuist presence (gate 5d-companion; only fires when --generator=tuist).
  gate_tuist_present_if_needed

  # 5+6. Mutation-scoped gates: clean-tree + on-main. Skipped on --dry-run.
  if [ "$DRY_RUN" != "1" ]; then
    # Gate 7: working tree clean
        gate_clean_tree
    # Gate 8: on main (override via --force per MEDIUM-4)
        gate_on_main
  else
    ok "Gates 7+8 (clean-tree + on-main) skipped on --dry-run path"
  fi

  step "All pre-flight gates passed"

  # 7. --dry-run path — no mutations.
  if [ "$DRY_RUN" = "1" ]; then
    print_dry_run_plan
    trap - ERR EXIT INT TERM
    exit 0
  fi

  # 8-10. Real rename: traps from T3 are armed. Helpers fire in D-1 order.
  # iter-6 BLOCKER-iter5-1: arm rollback's destructive-op path.
  # All gates passed; about to make destructive changes. Setting
  # MUTATION_STARTED=1 here ensures rollback() executes its full
  # body (rm -rf xcodeproj + git reset --hard + git clean) on any
  # failure from this line forward. A trap firing BEFORE this line
  # (e.g. on a pre-flight gate failure) is a no-op rollback,
  # protecting the forker's dirty working tree.
      MUTATION_STARTED=1
      apply_substitutions
      regen_xcodeproj

  # Final mutation phase: --generator=tuist invokes bin/switch-to-tuist.sh
  # to delete app/project.yml + edit Brewfile / Makefile / ci scripts /
  # pr.yml. The switch script's idempotency dispatch returns case 2
  # (pre-switch state) on a fresh post-substitution tree — Brewfile
  # still has `brew "xcodegen"`, project.yml is still present (just
  # sed-substituted), Project.swift is still present. --force bypasses
  # switch-to-tuist's clean-tree + on-main gates (the rename script's
  # tree is dirty mid-mutation by design). The rollback trap remains
  # armed; if switch-to-tuist fails, ROLLBACK_DONE=0 + MUTATION_STARTED=1
  # → reset-hard restores the pre-rename tree (including project.yml).
  if [ "$GENERATOR" = "tuist" ]; then
    step "Invoking bin/switch-to-tuist.sh --force (--generator=tuist)"
    bin/switch-to-tuist.sh --force \
      || fail "bin/switch-to-tuist.sh failed — see preceding stderr for diagnostic"
    ok "switched fork to Tuist (project.yml deleted; Brewfile / Makefile / ci scripts / pr.yml updated)"
  fi

  # Success path: disarm rollback traps (no stash to drop per HIGH-1)
  trap - ERR EXIT INT TERM

  step "Rename complete"
  ok "$APP_NAME ($BUNDLE_ID) — \"$DISPLAY_NAME\""
  if [ -z "$TEAM_ID" ]; then
    printf '\033[33m⚠ \033[0m  app/Local.xcconfig NOT written (no --team-id): DEVELOPMENT_TEAM is unresolved. Signed builds fail on iOS and sign ad-hoc on macOS until it exists.\n'
    printf '\033[33m⚠ \033[0m  Create it (gitignored) with `DEVELOPMENT_TEAM = <your Team ID>`, or set FASTLANE_TEAM_ID in .bootstrap.env and run `make bootstrap-fork`. `ruby bin/preflight-identity.rb --require-team` names the gap.\n'
  else
    ok "app/Local.xcconfig carries DEVELOPMENT_TEAM (gitignored; never commit it)"
  fi
  ok "next: run 'make check' to verify the build is green"
}

main "$@"
