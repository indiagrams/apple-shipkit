#!/usr/bin/env bash
# bin/switch-to-xcodegen.sh — convert a fork from Tuist back to XcodeGen.
#
# Inverse of bin/switch-to-tuist.sh. Restores app/project.yml from git
# history (the most recent commit that contained it) and reverses the
# Brewfile / Makefile / ci/* mutations switch-to-tuist.sh applied. The
# pr.yml matrix builder auto-detects manifest presence on each run, so
# this script doesn't touch the workflow.
#
# Two callers (mirroring switch-to-tuist.sh):
#   1. A maintainer who switched to Tuist and now wants to switch back.
#      `bin/switch-to-xcodegen.sh` from the repo root applies the inverse.
#   2. The release.yml `Apply generator override` step on a tuist-shaped
#      fork that's dispatched with `generator=xcodegen` — the canary path
#      for testing the xcodegen pipeline against a tuist-permanent fork.
#
# Usage:
#   bin/switch-to-xcodegen.sh                       # apply the switch
#   bin/switch-to-xcodegen.sh --dry-run             # preview without modifying
#   bin/switch-to-xcodegen.sh --force               # bypass clean-tree + on-main gates
#   bin/switch-to-xcodegen.sh -h | --help           # print this header
#
# Pre-flight gates (canonical order; mirrors switch-to-tuist.sh):
#   1. `xcodegen` on PATH (fail with install hint)
#   2. `app/Project.swift` present (else: PR #1 not landed)
#   3. `app/project.yml` exists somewhere in git history (else: this fork
#       was never xcodegen-shaped — restore manually from upstream)
#   4. Idempotency dispatch:
#        case 0 = already-xcodegen (silent exit 0)
#        case 1 = partial state (fail unless --force)
#        case 2 = pre-switch state (proceed)
#   5. Working tree clean (override via --force)
#   6. On `main` branch (override via --force)
#
# Atomic rollback (parity with switch-to-tuist.sh):
#   Pre-flight Gate 5 (clean tree) ensures HEAD == working tree
#   pre-mutation. Any failure during the mutation phase triggers an
#   ERR/EXIT/INT/TERM trap that runs `git reset --hard HEAD` +
#   `git clean -fd` (NOT -fdx — forker's .bootstrap.env / .env.local is precious).
#   MUTATION_STARTED guards the destructive-op path.
#
# Idempotency:
#   Re-running on an already-xcodegen tree (project.yml present +
#   Brewfile has `brew "xcodegen"`) is a silent exit 0 — no stdout,
#   no rollback, no side effects.
#
# Constraints (parity with switch-to-tuist.sh):
#   - bash 3.2+ (macOS default); no bash 4+ features
#   - BSD-portable sed (sed -i '', | delimiter)
#   - No new external dependencies (git, bash, sed, awk, find)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

print_usage() {
  sed -n '2,/^set -euo pipefail$/{ /^set -euo pipefail$/!p; }' "$0" | sed 's/^# \{0,1\}//'
}

# ── Argument parsing ──────────────────────────────────────────────────────
DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) print_usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    *) fail "unknown flag '$arg' — run with -h for usage" ;;
  esac
done

# ── Resolve repo root ─────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || fail "could not cd to repo root ($REPO_ROOT)"

# ── Mutation guard for the rollback trap ──────────────────────────────────
ROLLBACK_DONE=0
MUTATION_STARTED=0

rollback() {
  [ "$ROLLBACK_DONE" = "1" ] && return 0
  ROLLBACK_DONE=1

  [ "$MUTATION_STARTED" = "1" ] || return 0

  printf '    ✗ rolling back to pre-switch state...\n' >&2
  if git reset --hard HEAD --quiet 2>/dev/null; then
    git clean -fd --quiet 2>/dev/null || true
    printf '    ✗ rolled back to pre-switch state.\n' >&2
  else
    printf '    ✗ git reset --hard HEAD failed; manual recovery required.\n' >&2
    printf '    ✗ inspect: git status; git log --oneline -5\n' >&2
  fi
}

trap 'rollback' ERR
trap 'rollback' INT TERM
trap 'rollback' EXIT

# ── Idempotency dispatch ──────────────────────────────────────────────────
# Returns:
#   0 = already-xcodegen (caller silent-exits 0)
#   1 = partial state (caller fails unless --force)
#   2 = pre-switch (tuist) state (caller proceeds)
check_idempotency() {
  local has_yml=0 has_swift=0 brewfile_has_xcodegen=0
  [ -f "app/project.yml" ] && has_yml=1
  [ -f "app/Project.swift" ] && has_swift=1
  if [ -f "Brewfile" ] && grep -q '^brew "xcodegen"' Brewfile 2>/dev/null; then
    brewfile_has_xcodegen=1
  fi

  # Already-xcodegen: project.yml present, Project.swift present (template
  # default), Brewfile has brew "xcodegen". The "pre-switch-to-tuist" /
  # "post-switch-to-xcodegen" shape — same thing.
  if [ "$has_yml" = "1" ] && [ "$has_swift" = "1" ] && [ "$brewfile_has_xcodegen" = "1" ]; then
    return 0
  fi

  # Pre-switch (tuist state): project.yml absent, Project.swift present,
  # Brewfile lacks brew "xcodegen".
  if [ "$has_yml" = "0" ] && [ "$has_swift" = "1" ] && [ "$brewfile_has_xcodegen" = "0" ]; then
    return 2
  fi

  # Anything else is partial state.
  return 1
}

# ── Pre-flight gate functions ─────────────────────────────────────────────
gate_xcodegen_present() {
  command -v xcodegen >/dev/null 2>&1 || \
    fail "xcodegen not found — install with 'brew install xcodegen' (or run 'make bootstrap')"
  ok "xcodegen on PATH ($(xcodegen --version 2>/dev/null | head -1))"
}

gate_project_swift_present() {
  [ -f "app/Project.swift" ] || \
    fail "app/Project.swift missing — unexpected pre-switch state (was the repo ever Tuist-shaped?)"
  [ -f "Tuist.swift" ] || \
    fail "Tuist.swift missing — unexpected pre-switch state (was the repo ever Tuist-shaped?)"
  ok "Tuist manifests present (Tuist.swift + app/Project.swift)"
}

# Find the most recent commit whose tree contained app/project.yml.
# Result stored in PROJECT_YML_SHA (global) for use by the restore mutation.
PROJECT_YML_SHA=""
gate_project_yml_in_history() {
  # --diff-filter=AM excludes Deletion commits — we want a SHA whose tree
  # CONTAINS app/project.yml, not the SHA that deleted it.
  PROJECT_YML_SHA=$(git log --all --diff-filter=AM --pretty=format:'%H' -- app/project.yml 2>/dev/null | head -1 || true)
  if [ -z "$PROJECT_YML_SHA" ]; then
    fail "app/project.yml not found in git history — this fork was never xcodegen-shaped.
   Restoring manually requires fetching project.yml from indiagrams/apple-shipkit/main:
     curl -fsSL https://raw.githubusercontent.com/indiagrams/apple-shipkit/main/app/project.yml > app/project.yml"
  fi
  ok "app/project.yml found in commit ${PROJECT_YML_SHA:0:8}"
}

gate_clean_tree() {
  if [ "$FORCE" = "1" ]; then
    ok "working-tree gate skipped (--force)"
    return 0
  fi
  if [ "$(git status --short | wc -l | tr -d ' ')" != "0" ]; then
    fail "working tree not clean — commit, stash, or remove untracked files (or pass --force)"
  fi
  ok "working tree clean"
}

gate_on_main() {
  local BRANCH
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "$BRANCH" != "main" ] && [ "$FORCE" != "1" ]; then
    fail "not on main branch (currently: $BRANCH) — pass --force to override"
  fi
  ok "branch check: $BRANCH (force=$FORCE)"
}

# ── Mutations ─────────────────────────────────────────────────────────────
# Each step is independently idempotent. The ordered set brings any tuist
# tree to the xcodegen state; running again on an xcodegen tree is no-op
# (handled at the idempotency-dispatch level, not per-step).

mutate_restore_project_yml() {
  step "Restoring app/project.yml from git history (commit ${PROJECT_YML_SHA:0:8})"
  if [ -f "app/project.yml" ]; then
    ok "app/project.yml already present (no restore needed)"
    return 0
  fi
  git show "$PROJECT_YML_SHA:app/project.yml" > app/project.yml

  # The restored manifest carries no identity: the project name, targets,
  # schemes and entitlements paths are the constant `App`, and the bundle id,
  # product name, display name and copyright are $(VAR) references into
  # app/Identity.xcconfig, which this switch never touches. There is nothing
  # to re-apply. (This script used to sed the fork's APP_NAME, Team ID and
  # bundle id back into a restored pre-identity-xcconfig manifest; that put
  # the Team ID into a tracked file.) The one restored shape that cannot
  # build is a manifest from BEFORE the identity xcconfig existed — refuse
  # it rather than patch it.
  if grep -q 'TEAM_ID_PLACEHOLDER' app/project.yml || ! grep -q '^name: App$' app/project.yml; then
    fail "restored app/project.yml ($PROJECT_YML_SHA) predates app/Identity.xcconfig — restore from a commit after the identity xcconfig landed, or copy app/project.yml from the template"
  fi
  ok "restored app/project.yml carries no identity (name: App; identity resolves from app/Identity.xcconfig)"

  git add app/project.yml
  ok "app/project.yml restored from $PROJECT_YML_SHA"
}

mutate_brewfile() {
  step "Editing Brewfile (add brew \"xcodegen\")"
  if [ ! -f "Brewfile" ]; then
    fail "Brewfile missing — unexpected repo state"
  fi
  if grep -q '^brew "xcodegen"' Brewfile; then
    ok "Brewfile: brew \"xcodegen\" already present"
    return 0
  fi
  # Insert before the cask tuist line if it exists; else append at end.
  # Keeps the alphabetical-ish ordering switch-to-tuist.sh removed from.
  if grep -q '^brew "--cask", "tuist"' Brewfile; then
    # BSD sed: \n inside replacement needs to be a literal backslash-newline.
    sed -i '' $'/^brew "--cask", "tuist"/i\\\nbrew "xcodegen"\n' Brewfile
  else
    printf 'brew "xcodegen"\n' >> Brewfile
  fi
  ok "Brewfile: brew \"xcodegen\" line added"
}

mutate_makefile() {
  step "Editing Makefile (tuist generate --no-open → xcodegen generate)"
  if [ ! -f "Makefile" ]; then
    fail "Makefile missing — unexpected repo state"
  fi
  sed -i '' 's|cd app && tuist generate --no-open|cd app \&\& xcodegen generate|g' Makefile
  sed -i '' 's|Regenerate app/App.xcodeproj from app/Project.swift|Regenerate app/App.xcodeproj from app/project.yml|g' Makefile
  ok "Makefile: tuist generate --no-open → xcodegen generate"
}

mutate_local_check() {
  step "Editing ci/local-check.sh (tuist → xcodegen)"
  if [ ! -f "ci/local-check.sh" ]; then
    fail "ci/local-check.sh missing — unexpected repo state"
  fi
  sed -i '' 's|require_cmd tuist|require_cmd xcodegen|g' ci/local-check.sh
  sed -i '' 's|step "app: tuist generate"|step "app: xcodegen generate"|g' ci/local-check.sh
  sed -i '' 's|( cd app && tuist generate --no-open >/dev/null )|( cd app \&\& xcodegen generate >/dev/null )|g' ci/local-check.sh
  ok "ci/local-check.sh: tuist generate --no-open → xcodegen generate"
}

mutate_local_release_check() {
  step "Editing ci/local-release-check.sh (tuist → xcodegen)"
  if [ ! -f "ci/local-release-check.sh" ]; then
    fail "ci/local-release-check.sh missing — unexpected repo state"
  fi
  sed -i '' 's|step "tuist generate"|step "xcodegen generate"|g' ci/local-release-check.sh
  sed -i '' 's|( cd app && tuist generate --no-open >/dev/null )|( cd app \&\& xcodegen generate >/dev/null )|g' ci/local-release-check.sh
  ok "ci/local-release-check.sh: tuist generate --no-open → xcodegen generate"
}

# ── --dry-run preview ─────────────────────────────────────────────────────
print_dry_run_plan() {
  step "DRY RUN — no files will be modified"
  echo
  echo "Would restore:"
  echo "  app/project.yml  (from git commit ${PROJECT_YML_SHA:0:8})"
  echo
  echo "Would edit:"
  echo "  Brewfile                       (add 'brew \"xcodegen\"' line)"
  echo "  Makefile                       (cd app && tuist generate --no-open → cd app && xcodegen generate)"
  echo "  ci/local-check.sh              (require_cmd / step / tuist invocation)"
  echo "  ci/local-release-check.sh      (step + tuist invocation)"
  echo
  echo "Mutation count preview:"
  printf '  %-40s %d hit(s)\n' "Brewfile brew \"--cask\", \"tuist\"" \
    "$(grep -c '^brew "--cask", "tuist"' Brewfile 2>/dev/null || true)"
  printf '  %-40s %d hit(s)\n' "Makefile tuist generate --no-open" \
    "$(grep -c 'tuist generate --no-open' Makefile 2>/dev/null || true)"
  printf '  %-40s %d hit(s)\n' "ci/local-check.sh tuist" \
    "$(grep -c 'tuist' ci/local-check.sh 2>/dev/null || true)"
  printf '  %-40s %d hit(s)\n' "ci/local-release-check.sh tuist" \
    "$(grep -c 'tuist' ci/local-release-check.sh 2>/dev/null || true)"
  echo
  ok "dry run complete — re-run without --dry-run to apply"
}

# ── Main orchestration ────────────────────────────────────────────────────
main() {
  set +e
  check_idempotency
  IDEMPOT=$?
  set -e

  case "$IDEMPOT" in
    0)
      if [ "$DRY_RUN" = "1" ]; then
        step "DRY RUN — already-xcodegen state detected"
        ok "no changes would be applied (already on XcodeGen)"
      fi
      # Real run on already-xcodegen tree: silent exit 0. Disarm traps.
      trap - ERR EXIT INT TERM
      exit 0
      ;;
    1)
      step "Pre-flight"
      step "Idempotency check"
      if [ "$FORCE" = "1" ]; then
        ok "partial state detected; --force bypass enabled — proceeding"
      else
        fail "partial switch-to-xcodegen state detected — restore manually or pass --force"
      fi
      ;;
    2)
      step "Pre-flight"
      step "Idempotency check"
      ok "pre-switch (tuist) state confirmed — proceeding"
      ;;
  esac

  # Pre-flight gates
  gate_xcodegen_present
  gate_project_swift_present
  gate_project_yml_in_history

  if [ "$DRY_RUN" != "1" ]; then
    gate_clean_tree
    gate_on_main
  else
    ok "clean-tree + on-main gates skipped on --dry-run path"
  fi

  step "All pre-flight gates passed"

  if [ "$DRY_RUN" = "1" ]; then
    print_dry_run_plan
    trap - ERR EXIT INT TERM
    exit 0
  fi

  # Mutation phase: arm rollback's destructive-op path.
  MUTATION_STARTED=1
  mutate_restore_project_yml
  mutate_brewfile
  mutate_makefile
  mutate_local_check
  mutate_local_release_check

  trap - ERR EXIT INT TERM

  step "Switch to XcodeGen complete"
  ok "next: run 'cd app && xcodegen generate' then 'make check'"
}

main "$@"
