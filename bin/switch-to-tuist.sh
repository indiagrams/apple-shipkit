#!/usr/bin/env bash
# bin/switch-to-tuist.sh — convert a fork from XcodeGen to Tuist.
#
# Why this exists:
#   `main` ships both XcodeGen (`app/project.yml`) and Tuist
#   (`Tuist.swift` + `app/Project.swift`) manifests so forkers can pick
#   their generator (#38). This script flips a fork to Tuist-only by:
#   removing `app/project.yml`, dropping `brew "xcodegen"` from
#   Brewfile, and replacing every `xcodegen generate` invocation in
#   Makefile / ci/local-check.sh / ci/local-release-check.sh with
#   `tuist generate --no-open`. The pr.yml matrix builder auto-detects
#   that app/project.yml is gone and stops emitting xcodegen cells.
#
#   Two callers:
#     1. `bin/refork-smoketest.sh --generator=tuist` calls this script
#        (with --force, since rename.sh's tree is mid-mutation).
#     2. The 3 Tuist parity jobs in .github/workflows/pr.yml call this
#        script before building, so CI verifies the Tuist manifest
#        stays compatible with the XcodeGen one on every PR.
#
#   Factoring the surgery out of the fork-creation path into a standalone script
#   keeps both call-sites testable in isolation. The inverse direction
#   is bin/switch-to-xcodegen.sh (added later for the canary-trigger
#   `generator=xcodegen` override against tuist-permanent forks).
#
# Usage:
#   bin/switch-to-tuist.sh                       # apply the switch
#   bin/switch-to-tuist.sh --dry-run             # preview without modifying
#   bin/switch-to-tuist.sh --force               # bypass clean-tree + on-main gates
#   bin/switch-to-tuist.sh -h | --help           # print this header
#
# Pre-flight gates (canonical order):
#   1. `tuist` on PATH (fail with install hint)
#   2. `app/Project.swift` present (else: PR #1 not landed in this fork)
#   3. Idempotency dispatch:
#        case 0 = already-switched (silent exit 0)
#        case 1 = partial state (fail unless --force)
#        case 2 = pre-switch state (proceed)
#   4. Working tree clean (override via --force)
#   5. On `main` branch (override via --force)
#
# Atomic rollback (parity with bin/rename.sh):
#   Pre-flight Gate 4 (clean tree) ensures HEAD == working tree
#   pre-mutation. Any failure during the mutation phase triggers an
#   ERR/EXIT/INT/TERM trap that runs `git reset --hard HEAD` +
#   `git clean -fd` (NOT -fdx — forker's .bootstrap.env / .env.local is precious).
#   MUTATION_STARTED guards the destructive-op path so a pre-mutation
#   gate failure does not destroy a forker's dirty working tree.
#
# Idempotency:
#   Re-running on an already-switched tree (project.yml absent +
#   Project.swift present + Brewfile lacks `brew "xcodegen"`) is a
#   silent exit 0 — no stdout, no rollback, no side effects.
#
# Constraints (parity with bin/rename.sh):
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

# ── Mutation guard for the rollback trap (mirrors bin/rename.sh) ─────────
ROLLBACK_DONE=0
MUTATION_STARTED=0

rollback() {
  [ "$ROLLBACK_DONE" = "1" ] && return 0
  ROLLBACK_DONE=1

  # Pre-mutation early-out: nothing to roll back if we never started
  # mutating. Without this guard, a pre-flight gate failure on a dirty
  # working tree would trigger the EXIT trap and `git reset --hard`
  # would destroy the forker's uncommitted work.
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

# ── Idempotency dispatch (HIGH-3 parity with bin/rename.sh) ──────────────
# Returns:
#   0 = already-switched (caller silent-exits 0)
#   1 = partial state (caller fails unless --force)
#   2 = pre-switch state (caller proceeds)
check_idempotency() {
  local has_yml=0 has_swift=0 brewfile_has_xcodegen=0
  [ -f "app/project.yml" ] && has_yml=1
  [ -f "app/Project.swift" ] && has_swift=1
  if [ -f "Brewfile" ] && grep -q '^brew "xcodegen"' Brewfile 2>/dev/null; then
    brewfile_has_xcodegen=1
  fi

  # Already-switched: project.yml gone, Project.swift present, Brewfile
  # has no brew "xcodegen" line. All three together — any one of them
  # alone is partial state.
  if [ "$has_yml" = "0" ] && [ "$has_swift" = "1" ] && [ "$brewfile_has_xcodegen" = "0" ]; then
    return 0
  fi

  # Pre-switch: project.yml present, Project.swift present (PR 1 landed),
  # Brewfile has brew "xcodegen". The expected `main` shape.
  if [ "$has_yml" = "1" ] && [ "$has_swift" = "1" ] && [ "$brewfile_has_xcodegen" = "1" ]; then
    return 2
  fi

  # Anything else is partial state (e.g. Project.swift missing entirely
  # — PR 1 not landed in this fork).
  return 1
}

# ── Pre-flight gate functions ─────────────────────────────────────────────
gate_tuist_present() {
  command -v tuist >/dev/null 2>&1 || \
    fail "tuist not found — install with 'brew install --cask tuist' (or run 'make bootstrap' after PR-1 landed)"
  ok "tuist on PATH ($(tuist version 2>/dev/null | head -1))"
}

gate_project_swift_present() {
  [ -f "app/Project.swift" ] || \
    fail "app/Project.swift missing — PR #1 (refs #38) not landed in this fork; pull main first"
  [ -f "Tuist.swift" ] || \
    fail "Tuist.swift missing — PR #1 (refs #38) not landed in this fork; pull main first"
  ok "Tuist manifests present (Tuist.swift + app/Project.swift)"
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
# Each step is independently idempotent (file may already be in target
# state). The ordered set of steps brings any pre-switch tree to the
# switched state; running again on the switched tree is a no-op.

mutate_remove_project_yml() {
  step "Removing app/project.yml"
  if [ -f "app/project.yml" ]; then
    # -f bypasses git's "file has local modifications" refusal.
    # A fork-creation path may invoke this script mid-mutation (project.yml is sed-
    # substituted but uncommitted); -f tolerates that. On a clean tree
    # there are no local modifications so -f is a no-op.
    git rm -f --quiet app/project.yml
    ok "app/project.yml removed (git rm -f)"
  else
    ok "app/project.yml already absent"
  fi
}

mutate_brewfile() {
  step "Editing Brewfile (drop brew \"xcodegen\")"
  if [ -f "Brewfile" ] && grep -q '^brew "xcodegen"' Brewfile; then
    sed -i '' '/^brew "xcodegen"/d' Brewfile
    ok "Brewfile: brew \"xcodegen\" line removed"
  else
    ok "Brewfile: no brew \"xcodegen\" line (already removed or absent)"
  fi
}

mutate_makefile() {
  step "Editing Makefile (xcodegen generate → tuist generate --no-open)"
  if [ ! -f "Makefile" ]; then
    fail "Makefile missing — unexpected repo state"
  fi
  # 2 occurrences: bootstrap target + generate target.
  # `cd app && xcodegen generate` → `cd app && tuist generate --no-open`
  sed -i '' 's|cd app && xcodegen generate|cd app \&\& tuist generate --no-open|g' Makefile
  # Help line: "Regenerate app/App.xcodeproj from app/project.yml"
  sed -i '' 's|Regenerate app/App.xcodeproj from app/project.yml|Regenerate app/App.xcodeproj from app/Project.swift|g' Makefile
  ok "Makefile: xcodegen generate → tuist generate --no-open"
}

mutate_local_check() {
  step "Editing ci/local-check.sh (xcodegen → tuist)"
  if [ ! -f "ci/local-check.sh" ]; then
    fail "ci/local-check.sh missing — unexpected repo state"
  fi
  sed -i '' 's|require_cmd xcodegen|require_cmd tuist|g' ci/local-check.sh
  sed -i '' 's|step "app: xcodegen generate"|step "app: tuist generate"|g' ci/local-check.sh
  sed -i '' 's|( cd app && xcodegen generate >/dev/null )|( cd app \&\& tuist generate --no-open >/dev/null )|g' ci/local-check.sh
  ok "ci/local-check.sh: xcodegen generate → tuist generate --no-open"
}

mutate_local_release_check() {
  step "Editing ci/local-release-check.sh (xcodegen → tuist)"
  if [ ! -f "ci/local-release-check.sh" ]; then
    fail "ci/local-release-check.sh missing — unexpected repo state"
  fi
  sed -i '' 's|step "xcodegen generate"|step "tuist generate"|g' ci/local-release-check.sh
  sed -i '' 's|( cd app && xcodegen generate >/dev/null )|( cd app \&\& tuist generate --no-open >/dev/null )|g' ci/local-release-check.sh
  ok "ci/local-release-check.sh: xcodegen generate → tuist generate --no-open"
}

# ── --dry-run preview ─────────────────────────────────────────────────────
print_dry_run_plan() {
  step "DRY RUN — no files will be modified"
  echo
  echo "Would remove:"
  echo "  app/project.yml"
  echo
  echo "Would edit:"
  echo "  Brewfile                       (drop 'brew \"xcodegen\"' line)"
  echo "  Makefile                       (cd app && xcodegen generate → cd app && tuist generate --no-open)"
  echo "  ci/local-check.sh              (require_cmd / step / xcodegen generate)"
  echo "  ci/local-release-check.sh      (step + xcodegen generate)"
  echo
  echo "Mutation count preview:"
  printf '  %-40s %d hit(s)\n' "Brewfile brew \"xcodegen\"" \
    "$(grep -c '^brew "xcodegen"' Brewfile 2>/dev/null || echo 0)"
  printf '  %-40s %d hit(s)\n' "Makefile xcodegen generate" \
    "$(grep -c 'xcodegen generate' Makefile 2>/dev/null || echo 0)"
  printf '  %-40s %d hit(s)\n' "ci/local-check.sh xcodegen" \
    "$(grep -c 'xcodegen' ci/local-check.sh 2>/dev/null || echo 0)"
  printf '  %-40s %d hit(s)\n' "ci/local-release-check.sh xcodegen" \
    "$(grep -c 'xcodegen' ci/local-release-check.sh 2>/dev/null || echo 0)"
  echo
  ok "dry run complete — re-run without --dry-run to apply"
}

# ── Main orchestration ────────────────────────────────────────────────────
main() {
  # Idempotency dispatch first (parity with bin/rename.sh):
  # already-switched state must produce no stdout, even before printing
  # the "Pre-flight gates" banner. The clean-tree gate runs after.
  set +e
  check_idempotency
  IDEMPOT=$?
  set -e

  case "$IDEMPOT" in
    0)
      if [ "$DRY_RUN" = "1" ]; then
        step "DRY RUN — already-switched state detected"
        ok "no changes would be applied (already on Tuist)"
      fi
      # Real run on already-switched tree: silent exit 0. Disarm traps
      # (no rollback needed because no mutations occurred).
      trap - ERR EXIT INT TERM
      exit 0
      ;;
    1)
      step "Pre-flight"
      step "Idempotency check"
      if [ "$FORCE" = "1" ]; then
        ok "partial state detected; --force bypass enabled — proceeding"
      else
        fail "partial switch-to-tuist state detected — restore manually or pass --force"
      fi
      ;;
    2)
      step "Pre-flight"
      step "Idempotency check"
      ok "pre-switch state confirmed — proceeding"
      ;;
  esac

  # Pre-flight gates
  gate_tuist_present
  gate_project_swift_present

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

  # Mutation phase: arm rollback's destructive-op path. Any failure
  # below this line triggers `git reset --hard HEAD` + `git clean -fd`.
  MUTATION_STARTED=1
  mutate_remove_project_yml
  mutate_brewfile
  mutate_makefile
  mutate_local_check
  mutate_local_release_check

  # Success path: disarm rollback traps.
  trap - ERR EXIT INT TERM

  step "Switch to Tuist complete"
  ok "next: run 'cd app && tuist generate --no-open' then 'make check'"
}

main "$@"
