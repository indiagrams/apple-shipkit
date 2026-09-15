#!/usr/bin/env bash
# bin/setup-github.sh — apply standard GitHub configuration (branch protection, squash, auto-merge) to a
# repo derived from this template.
#
# What it sets:
#   - Default branch: main
#   - Branch protection on main:
#       * Require PR before merging (no direct pushes)
#       * Require status checks (swiftlint + swiftformat + per-generator
#         app cells — xcodegen if app/project.yml is committed, tuist if
#         app/Project.swift is committed; both manifests = both check sets)
#       * Require status checks to be up-to-date before merge
#       * Enforce on admins (no bypass — same rules apply to repo owner)
#       * Require linear history
#   - Disable merge commits + rebase merges (squash-only)
#   - Auto-delete head branches after merge
#
# Usage:
#   bin/setup-github.sh                              # uses current repo's origin
#   bin/setup-github.sh owner/repo                   # explicit target
#
# Prerequisites:
#   - gh CLI authenticated with admin:repo scope (`gh auth status` shows it)
#   - You are the repo admin (or an org admin)
#
# Idempotent — safe to re-run; existing settings are overwritten with these.
#
# ── READ-APPEND-ASSERT ─────────────────────────────────────────────────────────
#
# WHAT CHANGED AND WHY. This script used to recompute the required-status-checks
# array from its own idea of the platform matrix and PUT the whole `/protection`
# object. That is destructive twice over. It drops any required check this script
# did not author — a fork that adds one gets it silently removed on the next run,
# and nothing goes red, because the dropped job keeps running and keeps
# reporting; protection just lists one fewer context and a pull request with a
# red check becomes mergeable again. And a PUT rebuilds the entire protection
# object from whatever the caller supplies, so a caller who omits enforce_admins,
# required_linear_history or the approving-review count weakens the branch while
# appearing to add a check. NEVER PUT /protection on a repo that already has
# protection.
#
# What it does instead, when protection already exists:
#   1. GET  …/branches/main/protection/required_status_checks/contexts  -> before
#   2. want    = unique(before + this script's checks + the extra-checks list)
#   3. missing = want - before
#   4. POST …/required_status_checks/contexts {"contexts": missing}   (if any)
#      — the additive endpoint. It cannot remove a context, and it does not
#        rebuild the `checks` objects, so each existing check keeps the `app_id`
#        binding it already had. A rebuilt array would silently rebind them.
#   5. GET the contexts again -> after
#   6. assert sort(after) == sort(want), else print all three lists and exit 1
#   7. enforce_admins / required_linear_history / reviews / strict are NOT
#      touched on this path.
# The full PUT survives only for the case where GET …/protection returns 404 —
# a branch with no protection at all, where there is nothing to preserve.
#
# Environment knobs (all optional; the first two exist for the test harness):
#   SETUP_GITHUB_DRY_RUN=1
#       Print every computed request as `DRY RUN: would <METHOD> <path> <body>`
#       and perform NO write of any kind. GET reads still happen unless stubbed.
#   SETUP_GITHUB_STUB_BEFORE='["ctx",…]'
#       JSON array used instead of the first contexts GET.
#   SETUP_GITHUB_STUB_AFTER='["ctx",…]'
#       JSON array used instead of the second contexts GET.
#   SETUP_GITHUB_STUB_PROTECTION_STATUS=200|404|403
#       Used instead of the status of GET …/branches/main/protection. Setting it
#       also stands in for the repo-reachability probe, so a fully stubbed run
#       makes no network call at all (test/setup_github_test.rb asserts that).
#   SETUP_GITHUB_EXTRA_CHECKS='my check,other'
#       Comma-separated contexts this fork requires that the template does not
#       know about. They are added to the union like any other check. Existing
#       contexts are preserved whether or not they are named here.
#
# The stubs replace READS ONLY. A write is real unless SETUP_GITHUB_DRY_RUN=1.

set -euo pipefail

# Resolve repo root from this script's location (bin/setup-github.sh → repo root).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

DRY_RUN="${SETUP_GITHUB_DRY_RUN:-0}"

# ── gh wrappers ───────────────────────────────────────────────────────────────

# gh_write <METHOD> <PATH> <BODY-or-empty> [extra gh api args…]
#
# The single choke point for every write this script performs. Under dry run it
# prints what it would send and returns 0 without touching the network, which is
# what makes a dry run TOTAL rather than partial — a wrapper that covered only
# the protection write would leave the repo-settings PATCH live and the word
# "dry" would be a lie.
gh_write() {
  local method="$1" path="$2" body="$3"
  shift 3
  local shown
  if [ "$DRY_RUN" = "1" ]; then
    if [ -n "$body" ]; then
      shown=$(printf '%s' "$body" | jq -c . 2>/dev/null || printf '%s' "$body")
    else
      shown="$*"
    fi
    printf '    DRY RUN: would %s %s %s\n' "$method" "$path" "$shown"
    return 0
  fi
  if [ -n "$body" ]; then
    printf '%s' "$body" | gh api -X "$method" "$path" --input - "$@"
  else
    gh api -X "$method" "$path" "$@"
  fi
}

# Status code of GET …/branches/main/protection, or the stub when one is set.
# `gh api -i` prints the response status line even when the request fails, which
# is what separates 404 (no protection — create it) from 403 (branch protection
# is a paid feature on private repos — advise, do not fail).
protection_status() {
  if [ -n "${SETUP_GITHUB_STUB_PROTECTION_STATUS:-}" ]; then
    printf '%s' "$SETUP_GITHUB_STUB_PROTECTION_STATUS"
    return 0
  fi
  local resp status
  resp=$(gh api "repos/$REPO/branches/main/protection" -i 2>/dev/null || true)
  status=$(printf '%s\n' "$resp" | head -1 | awk '{print $2}')
  [ -z "$status" ] && status="000"
  printf '%s' "$status"
}

# The two reads of the required-contexts array, in order. The second read is what
# the assertion judges, so what it may be replaced by is spelled out rather than
# left to a fallback:
#   - SETUP_GITHUB_STUB_AFTER, when the harness is driving the assertion;
#   - under dry run WHERE A POST WAS SKIPPED, the array the endpoint would hold
#     (`want`) — the honest simulation of a write that was not sent, and the
#     reason the assertion has no teeth under dry run. Its teeth are proved by
#     the harness case that stubs `after` short by one, and used on the live run;
#   - under dry run where nothing needed posting, a REAL second GET, so a live
#     dry run's count line is a measurement rather than an echo;
#   - SETUP_GITHUB_STUB_BEFORE, when stubs are driving and no live read exists.
# The read ordinal is an ARGUMENT, not a counter. Both call sites run inside a
# command substitution, which is a subshell, so a counter incremented here would
# be discarded on return and the second read would silently answer as the first —
# a stubbed `after` would be ignored and the assertion could never go red. That
# is exactly the class of bug this file exists to remove, so it is not repeated
# in the fix.
POSTED=0
SIMULATED_AFTER=""
contexts_get() {
  local which="$1"
  if [ "$which" = "before" ]; then
    if [ -n "${SETUP_GITHUB_STUB_BEFORE:-}" ]; then
      printf '%s' "$SETUP_GITHUB_STUB_BEFORE"
      return 0
    fi
  else
    if [ -n "${SETUP_GITHUB_STUB_AFTER:-}" ]; then
      printf '%s' "$SETUP_GITHUB_STUB_AFTER"
      return 0
    fi
    if [ "$DRY_RUN" = "1" ] && [ "$POSTED" = "1" ]; then
      printf '%s' "$SIMULATED_AFTER"
      return 0
    fi
    if [ -n "${SETUP_GITHUB_STUB_BEFORE:-}" ]; then
      printf '%s' "$SETUP_GITHUB_STUB_BEFORE"
      return 0
    fi
  fi
  gh api "repos/$REPO/branches/main/protection/required_status_checks/contexts"
}

# ── Front door ────────────────────────────────────────────────────────────────
#
# `-h` / `--help` is answered BEFORE any argument is consumed and before any
# `gh` call. Without this the flag fell through to the slug check below and was
# refused as `invalid repo '--help'` — safe, because that refusal precedes the
# first gh_write, but it read as a defect rather than as usage. The refusal
# stays exactly where it is; this only gives the two flags an answer.
#
# Follows bin/rename.sh's convention: the usage block IS the header comment, so
# the two cannot drift apart.

print_usage() {
  sed -n '2,/^set -euo pipefail$/{ /^set -euo pipefail$/!p; }' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) print_usage; exit 0 ;;
esac

# ── Resolve target repo ───────────────────────────────────────────────────────

if [ $# -ge 1 ]; then
  REPO="$1"
else
  # Try to read from the current repo's origin remote.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    fail "not in a git repository — pass a repo as 'owner/name' or run from a clone"
  fi
  origin=$(git config --get remote.origin.url 2>/dev/null || true)
  [ -z "$origin" ] && fail "no origin remote — pass a repo as 'owner/name'"
  # Normalize: strip git@github.com: / https://github.com/ / .git
  REPO=$(echo "$origin" \
    | sed -E -e 's#^git@github\.com:##' \
             -e 's#^https://github\.com/##' \
             -e 's#\.git$##')
fi

if ! [[ "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
  fail "invalid repo '$REPO' — expected owner/name (e.g. acme/myapp)"
fi

step "Target: $REPO"

# Sanity-check repo exists + we can reach it. A stubbed protection status stands
# in for this read too: it already presumes the repo, and leaving one live GET
# here would mean a "fully stubbed" run still touched the network.
if [ -n "${SETUP_GITHUB_STUB_PROTECTION_STATUS:-}" ]; then
  ok "repo reachability stubbed (SETUP_GITHUB_STUB_PROTECTION_STATUS is set)"
else
  if ! gh api "repos/$REPO" --silent 2>/dev/null; then
    fail "cannot reach $REPO via gh API — check 'gh auth status' and that the repo exists"
  fi
  ok "repo reachable"
fi

# ── 1. Repo settings: squash-only merge, auto-delete head branches ────────────

step "Repo settings"
gh_write PATCH "repos/$REPO" "" \
  -F allow_squash_merge=true \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true \
  -F allow_auto_merge=true \
  --silent
ok "squash-only merge, auto-delete head branches, auto-merge enabled"

# ── 2. Branch protection on main ──────────────────────────────────────────────

step "Branch protection on main"

# Derive the required-checks list from .bootstrap.env's PLATFORMS field.
# Defaults to 'ios,macos' if the file or field is absent. The PR workflow
# (.github/workflows/pr.yml) only runs the iOS jobs when do_ios=true and
# the macOS jobs when do_macos=true, so the required checks must match.
# Read .bootstrap.env once for both PLATFORMS (which CI checks are required)
# and RELEASE_MODE (whether enforce_admins blocks even-the-admin from pushing
# directly to main). CI mode = team-shared default → enforce_admins=true, no
# bypass even for admins. Local mode = solo first-time-shipper default →
# enforce_admins=false, admin can push directly when needed (PR-required +
# required-checks still gate normal flow; this just lets the solo dev escape
# the lock-out trap). Forkers can flip later by re-running this script.
PLATFORMS_VAL=""
RELEASE_MODE_VAL=""
if [ -f "$REPO_ROOT/.bootstrap.env" ]; then
  PLATFORMS_VAL=$(awk -F= '/^PLATFORMS[[:space:]]*=/ { gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/, "", $2); print $2; exit }' "$REPO_ROOT/.bootstrap.env")
  RELEASE_MODE_VAL=$(awk -F= '/^RELEASE_MODE[[:space:]]*=/ { gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/, "", $2); print $2; exit }' "$REPO_ROOT/.bootstrap.env")
fi
[ -z "$PLATFORMS_VAL" ] && PLATFORMS_VAL="ios,macos"
[ -z "$RELEASE_MODE_VAL" ] && RELEASE_MODE_VAL="ci"

# Detect committed generator manifests so the required-checks list matches
# what pr.yml's matrix builder actually emits. Single-generator forks (the
# typical end state — pick xcodegen OR tuist via bin/switch-to-{xcodegen,
# tuist}.sh) delete the other manifest, so requiring its check names would
# leave PRs permanently unmergeable (those checks never appear). The matrix
# builder in .github/workflows/pr.yml uses the same filesystem rule.
has_xcodegen=0; has_tuist=0
[ -f "$REPO_ROOT/app/project.yml" ]   && has_xcodegen=1
[ -f "$REPO_ROOT/app/Project.swift" ] && has_tuist=1
# Safety: if neither manifest is present (corrupt state), fall back to
# requiring both — same default the matrix builder uses, so pr.yml would
# still emit cells (failing loudly) and the names line up.
if [ "$has_xcodegen" -eq 0 ] && [ "$has_tuist" -eq 0 ]; then
  echo "  WARN: neither app/project.yml nor app/Project.swift present; defaulting required checks to both generator sets"
  has_xcodegen=1; has_tuist=1
fi

CHECKS=()
if echo "$PLATFORMS_VAL" | grep -qw 'ios'; then
  [ "$has_xcodegen" -eq 1 ] && CHECKS+=( "app (iOS device)" "app (iOS Simulator)" )
  [ "$has_tuist"    -eq 1 ] && CHECKS+=( "app (Tuist iOS device)" "app (Tuist iOS Simulator)" )
fi
if echo "$PLATFORMS_VAL" | grep -qw 'macos'; then
  [ "$has_xcodegen" -eq 1 ] && CHECKS+=( "app (macOS)" )
  [ "$has_tuist"    -eq 1 ] && CHECKS+=( "app (Tuist macOS)" )
fi

# `swiftlint` and `swiftformat` always run (no platform gate) — append
# unconditionally so every fork's required-checks list includes them
# regardless of PLATFORMS.
CHECKS+=( "swiftlint" "swiftformat" )

if [ ${#CHECKS[@]} -eq 0 ]; then
  echo "ERROR: PLATFORMS=$PLATFORMS_VAL produced no required checks. Must include 'ios', 'macos', or both." >&2
  exit 1
fi

# Contexts this fork requires that the template has no way to know about. The
# old script assumed it was the only writer of that array. It is not, and the
# fix is to say so out loud rather than to reason about it — a name here is added
# to the union, and any name already live is preserved whether it is listed or not.
EXTRA=()
if [ -n "${SETUP_GITHUB_EXTRA_CHECKS:-}" ]; then
  set -f
  old_ifs="$IFS"; IFS=','
  for raw in $SETUP_GITHUB_EXTRA_CHECKS; do
    trimmed=$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -n "$trimmed" ] && EXTRA+=( "$trimmed" )
  done
  IFS="$old_ifs"
  set +f
fi

echo "  → required CI checks (PLATFORMS=$PLATFORMS_VAL):"
for c in "${CHECKS[@]}"; do echo "    - $c"; done
if [ ${#EXTRA[@]} -gt 0 ]; then
  echo "  → fork-added checks (SETUP_GITHUB_EXTRA_CHECKS):"
  for c in "${EXTRA[@]}"; do echo "    - $c"; done
fi

# Mode-aware admin enforcement. CI mode defaults to true (team safety net).
# Local mode defaults to false so a solo first-time-shipper isn't locked out
# of pushing fixes to their own fork. PR-required + required-checks still
# gate the normal flow either way.
if [ "$RELEASE_MODE_VAL" = "local" ]; then
  ENFORCE_ADMINS_JSON="false"
  echo "  → enforce_admins=false (RELEASE_MODE=local — admin can push directly)"
else
  ENFORCE_ADMINS_JSON="true"
  echo "  → enforce_admins=true (RELEASE_MODE=$RELEASE_MODE_VAL — no admin bypass)"
fi

PROTECTION_HTTP_STATUS=$(protection_status)
echo "  → GET repos/$REPO/branches/main/protection → HTTP $PROTECTION_HTTP_STATUS"

if [ "$PROTECTION_HTTP_STATUS" = "403" ]; then
  # Plan-tier limitation, detected on the READ so no write is attempted at all.
  # GitHub gates branch protection on PRIVATE repos behind paid plans; repo
  # settings (step 1) DO work on free private repos.
  printf '    ⚠ branch protection unavailable on free + private repos\n' >&2
  cat >&2 <<EOF

      GitHub gates branch protection on PRIVATE repos behind paid plans.
      Your repo '$REPO' is private and on the free plan, so reading the
      protection object returned HTTP 403. Repo settings (squash-only merge,
      auto-delete head branches, auto-merge) WERE applied successfully — only
      the protection rules were skipped.

      Three options:

        A) Make the repo public (free, protection works immediately):
             gh repo edit $REPO --visibility public --accept-visibility-change-consequences

        B) Upgrade to GitHub Pro (\$4/mo for private repos + protection):
             https://github.com/settings/billing/plans

        C) Accept no protection — fine for solo work. Trade-off: anyone
           with write access can push directly to main without a PR or CI
           gate. \`make doctor\` will continue to surface this as ⚠ advisory.

      For (C), no further action needed — \`make bootstrap-fork\` continues
      to the remaining steps.

EOF
  step "Done (with advisory)"
  ok "$REPO settings applied (squash-only, auto-merge, auto-delete head branches)."
  printf '    ⚠ branch protection on main: SKIPPED — see advisory above.\n' >&2
  exit 0
fi

if [ "$PROTECTION_HTTP_STATUS" = "404" ]; then
  # FIRST-TIME CREATION, AND THE ONLY PLACE A FULL PUT IS ALLOWED. There is no
  # existing protection object, therefore nothing to preserve and no app_id
  # binding to disturb. test/setup_github_test.rb's static guard fails the build
  # if this write ever escapes this branch.
  echo "  → no protection on main yet: creating it (the only case a full PUT is correct)"

  # Build the JSON checks array from $CHECKS + $EXTRA.
  CREATE_CHECKS=( "${CHECKS[@]}" )
  [ ${#EXTRA[@]} -gt 0 ] && CREATE_CHECKS+=( "${EXTRA[@]}" )
  CHECKS_JSON=$(printf '%s\n' "${CREATE_CHECKS[@]}" | jq -R '{context: .}' | jq -sc 'unique_by(.context)')

  PROTECTION_JSON=$(cat <<JSON
{
  "required_status_checks": {
    "strict": true,
    "checks": $CHECKS_JSON
  },
  "enforce_admins": $ENFORCE_ADMINS_JSON,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
)

  # Capture stderr separately so we can still detect the "Upgrade to GitHub Pro"
  # response here (a repo can answer 404 on the read and 403 on the write).
  PUT_STDERR=$(mktemp "${TMPDIR:-/tmp}/gh-protection-stderr.XXXXXX")
  trap 'rm -f "$PUT_STDERR"' EXIT
  if ! gh_write PUT "repos/$REPO/branches/main/protection" "$PROTECTION_JSON" \
    -H "Accept: application/vnd.github+json" --silent 2>"$PUT_STDERR"; then
    put_err=$(<"$PUT_STDERR")
    if printf '%s' "$put_err" | grep -q "Upgrade to GitHub Pro"; then
      printf '    ⚠ branch protection unavailable on free + private repos\n' >&2
      cat >&2 <<EOF

      GitHub gates branch protection on PRIVATE repos behind paid plans.
      Your repo '$REPO' is private and on the free plan, so the PUT
      returned HTTP 403. Repo settings (squash-only merge, auto-delete head
      branches, auto-merge) WERE applied successfully — only the
      protection rules were skipped.

      Three options:

        A) Make the repo public (free, protection works immediately):
             gh repo edit $REPO --visibility public --accept-visibility-change-consequences

        B) Upgrade to GitHub Pro (\$4/mo for private repos + protection):
             https://github.com/settings/billing/plans

        C) Accept no protection — fine for solo work. Trade-off: anyone
           with write access can push directly to main without a PR or CI
           gate. \`make doctor\` will continue to surface this as ⚠ advisory.

      For (C), no further action needed — \`make bootstrap-fork\` continues
      to the remaining steps.

EOF
      step "Done (with advisory)"
      ok "$REPO settings applied (squash-only, auto-merge, auto-delete head branches)."
      printf '    ⚠ branch protection on main: SKIPPED — see advisory above.\n' >&2
      exit 0
    fi
    # Other failures: 404 (no main branch), 401 (gh auth), etc. Surface the
    # original error so the user can fix the underlying issue.
    printf '%s\n' "$put_err" >&2
    fail "could not create protection — see error above. Common causes: '$REPO' has no 'main' branch yet (push a commit first); your gh token lacks admin:repo scope."
  fi
  ok "main: protection created (PR-required, ${#CREATE_CHECKS[@]} CI checks, strict, enforce on admins, linear history)"

  step "Done"
  ok "$REPO is configured (PR-required, ${#CREATE_CHECKS[@]} CI checks, squash-only, auto-merge)."
  ok "Direct pushes to main are blocked. Open PRs and let CI run."
  exit 0
fi

if [ "$PROTECTION_HTTP_STATUS" != "200" ]; then
  fail "unexpected HTTP $PROTECTION_HTTP_STATUS reading repos/$REPO/branches/main/protection — refusing to write. Check 'gh auth status' (admin:repo scope) and that '$REPO' has a 'main' branch."
fi

# ── 2b. Protection exists: read, append, assert. NEVER PUT. ───────────────────

before=$(contexts_get before)
if ! printf '%s' "$before" | jq -e 'type == "array"' >/dev/null 2>&1; then
  fail "could not read the required-status-check contexts as a JSON array (got: $before)"
fi

UNION_ARGS=( "${CHECKS[@]}" )
[ ${#EXTRA[@]} -gt 0 ] && UNION_ARGS+=( "${EXTRA[@]}" )

want=$(jq -nc --argjson have "$before" --args '($have + $ARGS.positional) | unique' "${UNION_ARGS[@]}")
missing=$(jq -nc --argjson have "$before" --args '($ARGS.positional - $have) | unique' "${UNION_ARGS[@]}")

echo "  → live contexts before: $(printf '%s' "$before" | jq -c 'sort')"

if [ "$missing" != "[]" ]; then
  post_body=$(jq -nc --argjson c "$missing" '{contexts: $c}')
  echo "  → appending $(printf '%s' "$missing" | jq -r 'length') missing context(s): $missing"
  gh_write POST "repos/$REPO/branches/main/protection/required_status_checks/contexts" \
    "$post_body" --silent
  POSTED=1
  SIMULATED_AFTER="$want"
else
  echo "  → nothing to append: every required context is already present"
fi

after=$(contexts_get after)
if ! printf '%s' "$after" | jq -e 'type == "array"' >/dev/null 2>&1; then
  fail "could not re-read the required-status-check contexts as a JSON array (got: $after)"
fi

after_sorted=$(printf '%s' "$after" | jq -c 'sort')
want_sorted=$(printf '%s' "$want" | jq -c 'sort')

if [ "$after_sorted" != "$want_sorted" ]; then
  printf 'protection assert failed: before=%s after=%s want=%s\n' \
    "$(printf '%s' "$before" | jq -c 'sort')" "$after_sorted" "$want_sorted" >&2
  printf '    the required-status-check array is not what this run intended. Nothing was rebuilt;\n' >&2
  printf '    restore a dropped context with: gh api -X POST repos/%s/branches/main/protection/required_status_checks/contexts -f "contexts[]=<name>"\n' "$REPO" >&2
  exit 1
fi

after_n=$(printf '%s' "$after_sorted" | jq -r 'length')
want_n=$(printf '%s' "$want_sorted" | jq -r 'length')
printf '    required contexts: %s (expected %s)\n' "$after_n" "$want_n"
printf '%s' "$after_sorted" | jq -r '.[]' | sed 's/^/      - /'

ok "main: PR-required, $after_n required contexts (strict, enforce_admins and linear history untouched)"

step "Done"
ok "$REPO is configured (PR-required, $after_n required contexts, squash-only, auto-merge)."
ok "Direct pushes to main are blocked. Open PRs and let CI run."
