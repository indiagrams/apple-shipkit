#!/usr/bin/env bash
# bin/rename.sh — fork PERSONALIZATION script for the apple-shipkit template.
#
# Substitutes two things and nothing else: the maintainer contact address and
# the GitHub owner/repo slug. Atomic (all-or-nothing via reset-hard rollback),
# idempotent (silent no-op on re-run), pre-flight-gated.
#
# The app's IDENTITY is no longer this script's business. Bundle id, product
# name, display name and copyright live in app/Identity.xcconfig — the one
# tracked identity file, read natively by both generators as $(VAR) and by
# bin/lib/xcconfig.rb, the one reader. Set them there. A fork created before
# that file existed migrates with bin/migrate-identity.rb; see
# docs/MIGRATING-FROM-RENAME.md.
#
# The project STRUCTURE is a constant and is never renamed: app/App.xcodeproj,
# the App-iOS / App-macOS schemes, app/Shared/App.swift, App.entitlements and
# the App*Tests targets stay as they are on every fork.
#
# Usage:
#   bin/rename.sh --email=EMAIL [--slug=OWNER/REPO] [--dry-run] [--force]
#   bin/rename.sh -h                                # print this usage
#   bin/rename.sh --help                            # alias for -h
#
# Required flag:
#   --email=EMAIL  Maintainer/security contact email; substitutes
#                  maintainers@indiagram.com across CODE_OF_CONDUCT.md
#                  and SECURITY.md. MUST NOT contain newline or '|'.
#
# Optional flags:
#   --slug=OWNER/REPO   GitHub org/repo slug; substitutes
#                       indiagrams/apple-shipkit in README.md and
#                       CONTRIBUTING.md, and ONLY there — see "Slug scope"
#                       below. If omitted, auto-derives from
#                       `git remote get-url origin`. MUST NOT contain
#                       newline or '|'.
#   --dry-run           Preview substitutions without applying.
#   --force             Override the on-main-branch gate AND the partial-
#                       personalization gate. The other gates (args
#                       validation, clean tree, sed escapes) still fire.
#
# Slug scope — why the substitution set is an allowlist and not a sweep:
#   In a fork, nearly every occurrence of the template slug names the TEMPLATE:
#   the upstream you add as a remote, clone beside your fork, and send fixes to.
#   Only README.md's badge URLs and CONTRIBUTING.md's issue link mean "this
#   repository". A tree-wide sweep therefore rewrites the pointers that tell a
#   forker where to file things upstream — and it already has: AGENTS.md's
#   "open an upstream issue at ..." row in this fork names the FORK's own slug,
#   and no gate saw it happen.
#   So the sites that ARE substituted are named explicitly and everything else
#   is left alone, rather than the other way round. A list of exceptions rots
#   the moment somebody adds a file; an allowlist does not. Two sites that must
#   keep naming the template are additionally snapshotted before the step and
#   asserted unchanged after it, so a future widening of the scope fails loudly
#   instead of quietly eating a pointer.
#
# Retired when identity moved into app/Identity.xcconfig, and refused BY NAME
# rather than silently ignored, so a forker who pastes an old command line is
# told what happened instead of getting "unknown flag": the three positional
# args (app name, bundle id,
# display name), --year, --generator, --platforms and --team-id. What replaced
# each one is in the refusal message and in docs/MIGRATING-FROM-RENAME.md.
#
# Argument forms:
#   --email=VAL    (preferred, equal-sign form)
#   --email VAL    (split form — VAL must be non-empty and not start with '-')
#
# Pre-flight gate ORDER (canonical):
#   1. Args parsing (split-flag values rejected if missing or '-'-prefixed;
#      retired flags and positional args refused by name)
#   2. Idempotency check, BEFORE the clean-tree gate —
#      case 0 = silent exit 0 (already personalized)
#      case 1 = partial-personalization fail (unless --force)
#      case 2 = proceed
#   3. EMAIL non-empty AND no newline/'|'
#   4. SLUG non-empty (auto-derived if absent) AND no newline/'|' AND OWNER/REPO
#   5. Working tree is clean (git status --short empty — strict, includes
#      untracked files; this prevents data-loss via reset-hard)
#   6. Current branch is `main` (override via --force)
#
# Idempotency:
#   The signal is the two literals this script substitutes AWAY, counted only in
#   the sites this script actually writes. Neither remaining = done, exit 0
#   silently. Both remaining = proceed. Exactly one remaining = a half-done tree,
#   refused unless --force. Keyed on what the script writes, deliberately: the
#   previous version keyed idempotency on app/Identity.xcconfig's bundle id and
#   product name, which this script no longer touches at all, so it could only
#   ever have reported on somebody else's work.
#
# All-or-nothing (reset-hard rollback — never git stash):
#   Gate 5 (clean tree) ensures HEAD == working tree pre-mutation. Any failure
#   in the sed steps triggers the ERR/EXIT/INT/TERM trap, which executes:
#     1. git reset --hard HEAD --quiet   (restores tracked-file modifications)
#     2. git clean -fd --quiet           (removes new untracked files; NOT -fdx,
#        which would delete the forker's .bootstrap.env and app/Local.xcconfig)
#   Exits 1 with stderr "rolled back to pre-personalization state."
#   A MUTATION_STARTED guard keeps the trap from firing those destructive ops on
#   a pre-mutation gate failure, where they would destroy uncommitted work.
#
# Constraints:
#   - bash 3.2+ (macOS default); no bash 4+ features
#   - BSD-portable sed (sed -i '', | delimiter, escaped dots)
#   - sed replacement values escaped via sed_escape_replacement
#   - No new external dependencies (git, bash, sed, grep, awk)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

print_usage() {
  # Print every comment line from line 2 until just before the
  # `set -euo pipefail` body line. Pattern-anchored so the usage block
  # adapts as we edit it.
  sed -n '2,/^set -euo pipefail$/{ /^set -euo pipefail$/!p; }' "$0" | sed 's/^# \{0,1\}//'
}

# ── Argument parsing ──────────────────────────────────────────────────────
# Detect -h / --help BEFORE anything else so `bin/rename.sh -h` works with no
# other args.
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      print_usage
      exit 0
      ;;
  esac
done

# ── Globals (set by parse_args; consumed by gate functions + main) ───────
EMAIL=""
SLUG=""
DRY_RUN=0
FORCE=0

# ── Argument parsing (function; called by main) ──────────────────────────
# Split-flag rejection: --email VAL / --slug VAL reject missing values AND
# values starting with '-'.
parse_args() {
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

      # Retired flags, refused BY NAME. A generic "unknown flag" here would tell
      # a forker pasting a pre-Phase-5 command line that they mistyped something,
      # which is the wrong diagnosis and sends them looking in the wrong place.
      --year|--year=*)
        fail "--year was retired: the copyright year lives inside COPYRIGHT in app/Identity.xcconfig, which owns it now — edit that file" ;;
      --generator|--generator=*)
        fail "--generator was retired from this script: it performs no manifest surgery and regenerates no project, so it has nothing to switch. Run bin/switch-to-tuist.sh or bin/switch-to-xcodegen.sh directly (both are idempotent and roll back atomically)" ;;
      --platforms|--platforms=*)
        fail "--platforms was retired: it only ever set the app stub's subtitle string, which is app source, not personalization — edit app/Shared/ContentView.swift" ;;
      --team-id|--team-id=*)
        fail "--team-id was retired: the Apple Team ID is per-clone signing configuration, not personalization. Create gitignored app/Local.xcconfig containing 'DEVELOPMENT_TEAM = <your Team ID>'; \`ruby bin/preflight-identity.rb --require-team\` names the gap and prints that exact instruction" ;;

      -*)
        fail "unknown flag '$1' — run with -h for usage" ;;
      *)
        fail "unexpected argument '$1' — this script no longer takes an app name, a bundle id or a display name. Those are identity, and app/Identity.xcconfig owns them; a fork that predates that file migrates with bin/migrate-identity.rb (see docs/MIGRATING-FROM-RENAME.md). Usage: bin/rename.sh --email=EMAIL [--slug=OWNER/REPO]" ;;
    esac
  done
}

# ── Input-gate helper (function; called by validate_args) ────────────────
# The sed delimiter is `|` and BSD sed cannot handle multi-line replacements
# via the single-line `s|...|...|` form. Reject these characters at the gate so
# sed_escape_replacement only has to handle &, \, |.
reject_special_chars() {
  local label="$1" value="$2"
  case "$value" in
    *$'\n'*) fail "$label contains a newline — not supported (got: $(printf %q "$value"))" ;;
  esac
  case "$value" in
    *'|'*) fail "$label contains '|' — not supported (sed delimiter; got: $value)" ;;
  esac
}

# ── Args-validation gates 3 and 4 (function; called by main) ─────────────
# Cheap non-empty + format + special-char checks. Does NOT include the
# git-state-touching gates 5 and 6 — those are gate_clean_tree() and
# gate_on_main() below.
validate_args() {
  step "Pre-flight gates (args validation)"

  # Gate 3: --email required + input rejection
  [ -n "$EMAIL" ] || fail "--email is required — pass --email=address@example.com"
  reject_special_chars "EMAIL" "$EMAIL"
  ok "--email '$EMAIL' provided (no newline / '|')"

  # Gate 4: --slug auto-derive if omitted, then input + format check
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
}

# ── Reset-hard rollback ──────────────────────────────────────────────────
#
# Background: an early iteration used `git stash push --include-untracked` to
# capture pre-state. On a clean working tree — which the clean-tree gate
# requires — `git stash` creates NO entry, so rollback was a silent no-op and
# mutations were never undone.
#
# Fix: leverage the clean-tree precondition. Pre-mutation HEAD == working tree,
# so `git reset --hard HEAD` restores tracked-file modifications. Plus
# `git clean -fd` for any new untracked files — NEVER -fdx, which would delete
# the forker's .bootstrap.env and app/Local.xcconfig.
#
# The MUTATION_STARTED guard prevents the trap from firing destructive ops on a
# PRE-mutation gate failure (e.g. the dirty-tree gate fails → trap →
# reset --hard → destroys the forker's uncommitted work). It is initialized to 0
# here at file scope and flipped to 1 inside main() immediately before the first
# mutation call. rollback() early-outs unless the flag is set.

ROLLBACK_DONE=0
MUTATION_STARTED=0  # set to 1 in main() right before first mutation

rollback() {
  # Idempotent — only fires once even if both ERR and EXIT trip.
  [ "$ROLLBACK_DONE" = "1" ] && return 0
  ROLLBACK_DONE=1

  # Pre-mutation early-out. If no mutations were made, there is nothing to roll
  # back — and running git reset --hard HEAD on a forker's dirty working tree
  # (e.g. when the clean-tree gate failed and triggered the EXIT trap) would
  # DESTROY their uncommitted work.
  [ "$MUTATION_STARTED" = "1" ] || return 0

  printf '    ✗ rolling back to pre-personalization state...\n' >&2

  if git reset --hard HEAD --quiet 2>/dev/null; then
    git clean -fd --quiet 2>/dev/null || true
    printf '    ✗ rolled back to pre-personalization state.\n' >&2
  else
    printf '    ✗ git reset --hard HEAD failed; manual recovery required.\n' >&2
    printf '    ✗ inspect: git status; git log --oneline -5\n' >&2
  fi
}

# Trap on ERR + EXIT + signals (Ctrl-C = INT, kill = TERM). The traps stay armed
# for the whole mutation phase; main() disarms them on the success path via
# `trap - ERR EXIT INT TERM`.
trap 'rollback' ERR
trap 'rollback' INT TERM
trap 'rollback' EXIT

# ── Substitution-target enumeration ──────────────────────────────────────
#
# Why -nw -e P (not -nE '(\b|^)P\b'):
# the regex form silently false-passes in git grep — it returns 0 hits when 14
# are present. -nw is git-grep-native and reliable.
#
# Why -F on both patterns:
# without -F, the literal `.` in an address and the `/` in a slug are regex
# metacharacters, so `git grep -nw -e maintainers@indiagram.com` would match
# `maintainers@indiagramXcom`. -F treats the pattern as a fixed string, and
# -F + -w combine correctly in git grep.
#
# Why the exclusions below (each one MEASURED with a --dry-run against this
# tree, not inherited):
# this file and test/rename_scope_test.rb each SPELL the contact address — in this
# file's usage block, sed patterns and step announcements, and in the test as the
# literal it checks for. Without the exclusions the email sweep would rewrite the
# running script and its own checker. test/rename_scope_test.rb is the sharper of
# the two: it asserts that THIS step still exists, by spelling the address as a
# frozen constant, so a sweep that rewrote it would leave every fork with a test
# looking for the fork's own address inside a script that still says the
# template's — a gate this script broke on its way past. Found by running
# --dry-run rather than by reasoning about it.
#
# The list also carried two exclusions for the rename self-check script
# (bin/verify-rename.sh) and its end-to-end harness (ci/test-rename.sh,
# ci/test-rename-gates.sh), until this change deleted those files.
# A pathspec naming a path that does not exist is not harmless decoration: it is
# an exclusion nobody can evaluate, and the next reader has to go looking for a
# file to find out it is gone. Removed with them.
# app/App.xcodeproj is generated and gitignored, and .planning is gitignored;
# both are listed so the intent survives if either ever becomes tracked.
#
# The earlier list also excluded bin/lib/bootstrap.rb and
# .github/workflows/bootstrap-doctor-matrix.yml. Both exclusions existed for the
# retired app-name sweep and for the tree-wide slug sweep respectively; measured
# on this tree, neither file contains the contact address, and the slug step no
# longer sweeps anything it is not explicitly pointed at, so both were dropped
# rather than carried as decoration. The workflow's
# `github.repository == 'indiagrams/apple-shipkit'` safety guard is protected by
# the slug allowlist below, which never visits that file.
PATHSPEC_EXCLUSIONS=(
  ':!.planning'
  ':!app/App.xcodeproj'
  ':!bin/rename.sh'
  ':!test/rename_scope_test.rb'
)

# `git grep -l` exits 0 on a match, 1 on NO match, and something else on error.
# Only 0 and 1 are answers. Reading an error as an absence is how a check comes
# to report a clean tree it never scanned, so anything above 1 is refused here
# rather than swallowed by a `|| true`.
grep_files() {
  local pattern="$1"; shift
  local out rc
  set +e
  out=$(git grep -lw -F -e "$pattern" -- "$@" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" -gt 1 ]; then
    fail "git grep exited $rc enumerating this pattern, which is an error and not an absence; refusing to guess: $pattern"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
  return 0
}

# ── Slug scope (GSD-SLUG-EXCLUSION) ──────────────────────────────────────
#
# GSD-SLUG-EXCLUSION. The slug substitution is an ALLOWLIST, not a sweep with
# exceptions. These are the only two tracked files in which an occurrence of the
# template slug means "this repository" rather than "the template this
# repository came from":
SLUG_SUBSTITUTION_PATHS=(
  README.md
  CONTRIBUTING.md
)

# GSD-SLUG-EXCLUSION. These sites must keep naming the TEMPLATE. They are not
# merely absent from the list above — their template-slug counts are snapshotted
# before the slug step and compared after it, so if the scope is ever widened
# back into a sweep the script fails loudly instead of quietly eating an
# upstream pointer. Measured on this tree before being written down:
#   AGENTS.md                       — the invariants table's "open an upstream
#                                     issue at ..." row is the pointer that this
#                                     sweep already rewrote to the fork's own
#                                     slug once, with no gate seeing it
#   Makefile                        — the `gh repo create --template` line in its
#                                     header, which tells a reader where forks
#                                     come from
#   .github/workflows/…-matrix.yml  — the `github.repository == '<template>'`
#                                     guard that keeps an upstream-only job
#                                     dormant on every fork. Rewriting that
#                                     string to the fork's slug does not disable
#                                     the job, it ENABLES it.
# A count comparison rather than a presence assertion, deliberately: a fork whose
# AGENTS.md never mentioned the template must not be failed by a check that is
# about what this script CHANGES.
SLUG_KEEP_TEMPLATE_PATHS=(
  AGENTS.md
  Makefile
  .github/workflows/bootstrap-doctor-matrix.yml
)

slug_keep_signature() {
  local f
  for f in "${SLUG_KEEP_TEMPLATE_PATHS[@]}"; do
    if [ -f "$f" ]; then
      # `grep -c` exits 1 when the count is 0 and prints `0` on stdout, so the
      # `|| true` keeps errexit out of it WITHOUT appending a second value the
      # way `|| echo 0` would.
      printf '%s:%s\n' "$f" "$(grep -c -F 'indiagrams/apple-shipkit' "$f" || true)"
    else
      printf '%s:absent\n' "$f"
    fi
  done
}

# ── Substitutions ────────────────────────────────────────────────────────

# Escape sed replacement metacharacters &, \, |. The input gates already reject
# newlines and '|' in EMAIL/SLUG, so this handles the residual cases:
#   - '&'  → in a sed replacement, '&' is the entire match. Escape to '\&'.
#   - '\'  → backslash. Escape to '\\'.
#   - '|'  → already rejected at the gate; escaped to '\|' as belt-and-braces.
# One regex pass, so no ordering concerns: each `\`, `&` or `|` is matched at
# most once and replaced atomically with its escaped form. (BSD sed's bracket
# expression DOES match a literal backslash inside [\&|] — verified empirically
# on macOS.)
sed_escape_replacement() {
  printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'
}

apply_substitutions() {
  local escaped_email escaped_slug keep_before keep_after
  escaped_email=$(sed_escape_replacement "$EMAIL")
  escaped_slug=$(sed_escape_replacement "$SLUG")

  # Step C: maintainers@indiagram.com -> $EMAIL (escaped)
  # Wrap `git grep` in a brace group with `|| true` so a no-match (git grep
  # exit 1) does not abort the pipeline under `set -euo pipefail`. The brace
  # group is required because `|` binds tighter than `||`; a bare
  # `git grep ... || true | while ...` would short-circuit the whole pipeline.
  step "Substituting maintainers@indiagram.com -> $EMAIL"
  grep_files 'maintainers@indiagram.com' . "${PATHSPEC_EXCLUSIONS[@]}" \
    | while read -r f; do
        sed -i '' "s|maintainers@indiagram\.com|$escaped_email|g" "$f"
        ok "email substituted in $f"
      done

  # Step D: indiagrams/apple-shipkit -> $SLUG (escaped), scoped to the two
  # sites where the slug means "this repository". GSD-SLUG-EXCLUSION.
  keep_before=$(slug_keep_signature)

  step "Substituting indiagrams/apple-shipkit -> $SLUG"
  ok "slug scope: ${SLUG_SUBSTITUTION_PATHS[*]} (everything else keeps naming the template)"
  grep_files 'indiagrams/apple-shipkit' "${SLUG_SUBSTITUTION_PATHS[@]}" \
    | while read -r f; do
        sed -i '' "s|indiagrams/apple-shipkit|$escaped_slug|g" "$f"
        ok "GitHub slug substituted in $f"
      done

  # The falsifiable half of GSD-SLUG-EXCLUSION: widen the scope above and this
  # goes red, naming the file whose upstream pointer count moved.
  keep_after=$(slug_keep_signature)
  if [ "$keep_before" != "$keep_after" ]; then
    printf '    ✗ before: %s\n' "$(echo "$keep_before" | tr '\n' ' ')" >&2
    printf '    ✗ after:  %s\n' "$(echo "$keep_after" | tr '\n' ' ')" >&2
    fail "the slug step changed a site that must keep naming the template repository — the substitution scope has been widened into a sweep; see GSD-SLUG-EXCLUSION"
  fi
  ok "upstream pointers unchanged in ${#SLUG_KEEP_TEMPLATE_PATHS[@]} site(s)"

  # Self-exclusion, answered with a check rather than with trust. The pathspec
  # exclusion above is the defense; this is the falsifiable assertion that the
  # defense worked. If this file were rewritten by its own sweep, every
  # subsequent run would substitute the wrong literal.
  git diff --quiet -- bin/rename.sh 2>/dev/null \
    || fail "self-exclusion violated: bin/rename.sh was modified by the substitution sweep"
  ok "self-exclusion verified — bin/rename.sh unchanged"
}

# ── Idempotency + partial-personalization detection ──────────────────────

# Returns 0 if fully personalized (caller should silent-exit-0).
# Returns 1 if partially personalized (caller should fail unless --force).
# Returns 2 if un-personalized (caller should proceed normally).
#
# The signal is the two literals this script substitutes away, counted in
# exactly the sites this script writes — so the check and the substitution
# cannot disagree. It takes no account of WHICH email or slug replaced them:
# "already personalized, by somebody, to something" is the only question this
# script can answer honestly about a tree it did not create.
check_idempotency() {
  local email_left slug_left present

  # Before anything is counted: `git grep` outside a working tree returns
  # nothing, and "nothing left to substitute" is this function's SUCCESS case.
  # Without this guard, running the script outside a repository would exit 0
  # claiming the tree was already personalized.
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    fail "not inside a git working tree — this script enumerates its targets with git grep, and outside a repository an empty result is indistinguishable from a finished job"

  email_left=$(grep_files 'maintainers@indiagram.com' . "${PATHSPEC_EXCLUSIONS[@]}" | wc -l | tr -d ' ')
  slug_left=$(grep_files 'indiagrams/apple-shipkit' "${SLUG_SUBSTITUTION_PATHS[@]}" | wc -l | tr -d ' ')

  present=0
  [ "$email_left" -gt 0 ] && present=$((present + 1))
  [ "$slug_left"  -gt 0 ] && present=$((present + 1))

  case "$present" in
    0) return 0 ;;  # nothing left to personalize
    2) return 2 ;;  # both surfaces still template-owned
    *) return 1 ;;  # exactly one — a half-done tree
  esac
}

# ── Pre-flight gate functions (called by main) ───────────────────────────
#
# File scope is reserved for helpers, function definitions, trap arming and the
# `main "$@"` invocation on the last line. Everything else lives inside main()
# so the call order is canonical AND every callee is defined when called.

gate_clean_tree() {
  # We deliberately DO NOT pass --untracked-files=no here. A forker-facing
  # script must catch untracked files (.bootstrap.env, notes.md, WIP edits) so
  # they are not touched by the reset-hard rollback.
  if [ "$(git status --short | wc -l | tr -d ' ')" != "0" ]; then
    fail "working tree not clean — commit, stash, or remove untracked files before running this script"
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

# ── --dry-run preview ────────────────────────────────────────────────────

print_dry_run_plan() {
  step "DRY RUN — no files will be modified"

  echo
  echo "Substitution surfaces by file (via 'git grep -cw -F'):"

  echo
  echo "  maintainers@indiagram.com -> $EMAIL"
  git grep -cw -F -e 'maintainers@indiagram.com' -- . "${PATHSPEC_EXCLUSIONS[@]}" 2>/dev/null \
    | awk -F: '$2 > 0 { printf "    %-50s %d match(es)\n", $1, $2 }' \
    || echo "    (no matches)"

  echo
  echo "  indiagrams/apple-shipkit -> $SLUG"
  echo "    scope: ${SLUG_SUBSTITUTION_PATHS[*]}"
  git grep -cw -F -e 'indiagrams/apple-shipkit' -- "${SLUG_SUBSTITUTION_PATHS[@]}" 2>/dev/null \
    | awk -F: '$2 > 0 { printf "    %-50s %d match(es)\n", $1, $2 }' \
    || echo "    (no matches)"

  echo
  echo "Sites that keep naming the template (snapshotted and asserted unchanged):"
  slug_keep_signature | awk '{ printf "    %s\n", $0 }'

  echo
  echo "Not touched by this script:"
  echo "  app identity   — app/Identity.xcconfig owns bundle id, product name, display name, copyright"
  echo "  the Team ID    — gitignored app/Local.xcconfig; \`ruby bin/preflight-identity.rb --require-team\` names it if missing"
  echo "  file paths     — app/App.xcodeproj, App.swift, App.entitlements and the App*Tests targets are constants"
  echo "  the xcodeproj  — nothing here edits a manifest, so nothing here regenerates a project"

  echo
  ok "dry run complete — re-run without --dry-run to apply"
}

# ── Main orchestration (canonical call order) ────────────────────────────

main() {
  # 1. Args parsing
  parse_args "$@"

  # 2. Idempotency dispatch — case 0/1/2, BEFORE the clean-tree gate.
  # The dispatch MUST run before validate_args (which prints "==> Pre-flight
  # gates (args validation)") because the case-0 path is required to produce NO
  # stdout. Running validate_args first would violate that contract on an
  # already-personalized tree.
  set +e
  check_idempotency
  local IDEMPOT=$?
  set -e

  case "$IDEMPOT" in
    0)
      # Already personalized. Under --dry-run the user's intent is "show me what
      # WOULD change", so a silent exit 0 would leave them unsure whether the
      # script crashed, no-oped or mis-parsed flags. Say so explicitly.
      if [ "$DRY_RUN" = "1" ]; then
        step "DRY RUN — already-personalized state detected"
        ok "no substitutions would be applied (re-run idempotent)"
      fi
      # Real run on an already-personalized tree: silent exit 0. No step(), no
      # ok(), no stdout. Disarm the traps — no rollback is needed because no
      # mutations occurred.
      trap - ERR EXIT INT TERM
      exit 0
      ;;
    1)
      step "Pre-flight"
      step "Idempotency check"
      if [ "$FORCE" = "1" ]; then
        ok "partial-personalization state detected; --force bypass enabled — proceeding"
      else
        fail "partial-personalization state detected — exactly one of the contact address and the template slug is still present. Restore manually or run --force to override"
      fi
      ;;
    2)
      step "Pre-flight"
      step "Idempotency check"
      ok "un-personalized state confirmed — proceeding"
      ;;
  esac

  # 3. Args validation: gates 3 and 4
  validate_args

  # 4+5. Mutation-scoped gates: clean-tree + on-main. Skipped on --dry-run.
  if [ "$DRY_RUN" != "1" ]; then
    gate_clean_tree
    gate_on_main
  else
    ok "Gates 5+6 (clean-tree + on-main) skipped on --dry-run path"
  fi

  step "All pre-flight gates passed"

  # 6. --dry-run path — no mutations.
  if [ "$DRY_RUN" = "1" ]; then
    print_dry_run_plan
    trap - ERR EXIT INT TERM
    exit 0
  fi

  # 7. Real run: the traps are armed. Setting MUTATION_STARTED=1 here is what
  # arms rollback()'s destructive path; a trap firing BEFORE this line (on a
  # pre-flight gate failure) is a no-op rollback, protecting a dirty tree.
  MUTATION_STARTED=1
  apply_substitutions

  # Success path: disarm the rollback traps.
  trap - ERR EXIT INT TERM

  step "Personalization complete"
  ok "contact: $EMAIL"
  ok "slug:    $SLUG"
  ok "next: set your app's identity in app/Identity.xcconfig, then run 'make check'"
}

main "$@"
