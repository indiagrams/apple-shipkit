#!/usr/bin/env bash
# The ground-truth second arm for bin/migrate-identity.rb: a REAL historical
# migration, on a real fork, against a real App Store listing.
#
# WHY THIS EXISTS, AND WHY IT COULD NOT LIVE IN ci/test-migrate-identity.sh
#
# .github/workflows/migrate.yml states the gap this closes, in the comment above
# its one-cell matrix: 212b489 is "the last commit before identity became a slot"
# and there is only one cell "because this repository has no already-renamed
# commit to serve as a ground-truth second arm: it is the thing being forked, and
# nothing in its history was ever renamed away from HelloApp. A fork does have
# such a commit."
#
# indiagrams/tunnelless has one. `d40b915` is the migration, preserved as its own
# commit (the PR was merged with a merge commit rather than squashed, precisely
# so it would survive), and `d40b915^` is the tree it ran against. That pair is
# worth more than any fixture this repository can synthesise, because the fork
# carried THREE shapes at once that the synthetic fixtures each carry one of:
#
#   * both app targets PIN PRODUCT_NAME to a literal (apple-shipkit#293) — after
#     a real Guideline 5.2.5 rejection of `Tunnelless-macOS`, not as a
#     hypothetical;
#   * both manifests still carry `DEVELOPMENT_TEAM: "TEAM_ID_PLACEHOLDER"`
#     (apple-shipkit#296) — the shape whose refusal named a remedy that could not
#     satisfy it;
#   * `.github/workflows/pr.yml` derives the project path from a repository
#     variable whose FALLBACK is the TEMPLATE's old default `TailnetDemo`
#     (apple-shipkit#298), so the fork's own token appears there ZERO times.
#
# And it has an outcome no synthetic fixture can have: the migration shipped
# against two live App Store versions, and `3283376` is the commit where the
# maintainer HAND-CORRECTED the provenance paragraph this command generated into
# the tracked app/Identity.xcconfig, because it was false for a fork that pinned
# PRODUCT_NAME. That hand correction is the regression this script watches: the
# command must now generate what `3283376` had to write by hand.
#
# WHY IT SKIPS RATHER THAN FAILS WHEN THE PIN IS UNREACHABLE
#
# This is the only check in the repository that reads a DOWNSTREAM repository, so
# it is the only one that can go red for a reason that is not a regression here:
# a network blip, a deleted repo, a rewritten history. It therefore runs as a
# STEP of the existing `migrate self-test` job (migrate.yml:111-119 argues a new
# job would be "a status context nothing requires"), and an unreachable pin is a
# LOUD skip — named on stdout and raised as a GitHub Actions warning — never a
# silent pass and never a failure.
#
# The line between the two is drawn where it can be defended: a commit SHA is
# immutable. If the fetch SUCCEEDS, the tree it names cannot have changed, so
# every shape assertion below is a hard failure. Only getting there is allowed to
# be skipped.
#
# Runnable locally, from the repository root:
#   ci/test-historical-migration.sh
#   HISTORICAL_REPO=… HISTORICAL_POST=… ci/test-historical-migration.sh

set -uo pipefail

# The pin. POST is the migration commit; PRE is derived as POST^ rather than
# pinned separately, so a rewritten history is detected instead of assumed.
HISTORICAL_REPO="${HISTORICAL_REPO:-https://github.com/indiagrams/tunnelless.git}"
HISTORICAL_POST="${HISTORICAL_POST:-d40b915}"
# What the fork is called, for the shape assertions. Derived from nothing: if the
# pin is repointed at another fork these must be repointed with it, and a
# mismatch fails loudly at the shape gate rather than quietly asserting less.
FORK_TOKEN="${HISTORICAL_TOKEN:-Tunnelless}"
FORK_STALE_FALLBACK="${HISTORICAL_STALE_FALLBACK:-TailnetDemo}"
FIXTURE_TEAM_ID="A26TJZ8QHQ"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMAND="$REPO_ROOT/bin/migrate-identity.rb"

WORK_DIR=""
cleanup() { [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"; }
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

# A skip is an outcome, not an absence of one: it says WHY on stdout, raises a
# warning annotation so a green run still shows it in the checks UI, and exits 0
# only after having named itself.
skip() {
  printf '\n    SKIPPED — %s\n' "$*"
  printf '    This check reads a downstream repository; being unable to reach it is not\n'
  printf '    evidence about bin/migrate-identity.rb. Nothing was asserted.\n'
  [ -n "${GITHUB_ACTIONS:-}" ] && printf '::warning::historical-migration check SKIPPED — %s\n' "$*"
  exit 0
}

step "0/8 preconditions"
[ -f "$COMMAND" ] || fail "no bin/migrate-identity.rb at $COMMAND — wrong repository root?"
ok "command under test: bin/migrate-identity.rb (this working tree, not the fork's adopted copy)"
for tool in git ruby xcodegen xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || skip "$tool is not on PATH"
done
ok "git, ruby, xcodegen, xcodebuild all present"

step "1/8 fetch the pinned historical migration"
WORK_DIR="$(mktemp -d)"
CLONE="$WORK_DIR/fork"
if ! git clone -q "$HISTORICAL_REPO" "$CLONE" 2>"$WORK_DIR/clone.err"; then
  skip "could not clone $HISTORICAL_REPO ($(tr -d '\n' < "$WORK_DIR/clone.err" | cut -c1-160))"
fi
cd "$CLONE" || fail "could not enter the clone at $CLONE"
POST="$(git rev-parse --verify "$HISTORICAL_POST^{commit}" 2>/dev/null || true)"
[ -n "$POST" ] || skip "$HISTORICAL_POST does not resolve in $HISTORICAL_REPO (history rewritten, or the commit is gone)"
PRE="$(git rev-parse --verify "$POST^" 2>/dev/null || true)"
[ -n "$PRE" ] || skip "$HISTORICAL_POST has no parent to migrate from"
ok "post-migration $(git log --oneline -1 "$POST" | cut -c1-64)"
ok "pre-migration  $(git log --oneline -1 "$PRE" | cut -c1-64)"

step "2/8 the pin still IS the fixture (immutable SHA, so these are failures)"
git checkout -q -B main "$PRE" || fail "could not check out the pre-migration tree"
[ -z "$(git status --porcelain)" ] || fail "the pre-migration checkout is not clean"

pins=$(grep -cE "^\s*PRODUCT_NAME: $FORK_TOKEN\s*$" app/project.yml || true)
[ "$pins" -eq 2 ] || fail "expected 2 pinned 'PRODUCT_NAME: $FORK_TOKEN' lines in app/project.yml, found $pins — the pin is no longer the #293 shape"
ok "both app targets pin PRODUCT_NAME to the literal $FORK_TOKEN (#293 shape)"

grep -q 'TEAM_ID_PLACEHOLDER' app/project.yml \
  || fail "app/project.yml no longer carries TEAM_ID_PLACEHOLDER — the pin is no longer the #296 shape"
[ ! -f app/Local.xcconfig ] || fail "the pre-migration tree already has app/Local.xcconfig; the #296 arm below would prove nothing"
ok "manifests carry the unsubstituted TEAM_ID_PLACEHOLDER and there is no app/Local.xcconfig (#296 shape)"

grep -q "vars.APP_NAME || '$FORK_STALE_FALLBACK'" .github/workflows/pr.yml \
  || fail ".github/workflows/pr.yml no longer derives its project path from a variable falling back to $FORK_STALE_FALLBACK — the pin is no longer the #298 shape"
if grep -q "$FORK_TOKEN" .github/workflows/pr.yml; then
  fail ".github/workflows/pr.yml names $FORK_TOKEN, so the token-keyed report could see it; the #298 premise does not hold on this pin"
fi
ok "pr.yml derives the project path from a variable and names $FORK_TOKEN ZERO times (#298 premise)"

step "3/8 generate the project the command reads its identity from"
( cd app && xcodegen generate ) >"$WORK_DIR/xcodegen.log" 2>&1 \
  || fail "xcodegen generate failed in the fork: $(tail -3 "$WORK_DIR/xcodegen.log" | tr '\n' ' ')"
ok "app/$FORK_TOKEN.xcodeproj generated"

step "4/8 #296 RED — no app/Local.xcconfig, so there is genuinely no Team ID to move"
set +e
ruby "$COMMAND" --root "$CLONE" >"$WORK_DIR/red.log" 2>&1
red_code=$?
set -e
[ "$red_code" -eq 4 ] || fail "expected exit 4 with no Team ID anywhere, got $red_code"
grep -q 'TEAM_ID_PLACEHOLDER' "$WORK_DIR/red.log" || fail "the refusal does not name TEAM_ID_PLACEHOLDER"
grep -q 'app/Local.xcconfig does not assign a DEVELOPMENT_TEAM' "$WORK_DIR/red.log" \
  || fail "the refusal does not say that app/Local.xcconfig has no Team ID either — the remedy it offers must be true"
ok "exit 4, naming both the literal and the empty app/Local.xcconfig"

step "5/8 #296 GREEN — the remedy that used to change nothing"
printf 'DEVELOPMENT_TEAM = %s\n' "$FIXTURE_TEAM_ID" > app/Local.xcconfig
printf '\napp/Local.xcconfig\n' >> .gitignore
git add .gitignore
git -c user.email=historical@local.invalid -c user.name="historical fixture" \
    commit -qm "ignore app/Local.xcconfig" || fail "could not commit the .gitignore row"
[ -z "$(git status --porcelain)" ] || fail "tree not clean before the migration run"
LOCAL_BEFORE="$(shasum -a 256 app/Local.xcconfig | cut -d' ' -f1)"

set +e
ruby "$COMMAND" --root "$CLONE" >"$WORK_DIR/run.log" 2>&1
run_code=$?
set -e
[ "$run_code" -eq 0 ] || fail "the migration exited $run_code on the real fork; see: $(tail -5 "$WORK_DIR/run.log" | tr '\n' ' ')"
grep -q 'MIGRATION COMPLETE' "$WORK_DIR/run.log" || fail "no MIGRATION COMPLETE in the output"
grep -q 'already assigns DEVELOPMENT_TEAM' "$WORK_DIR/run.log" \
  || fail "the run does not report accepting the Team ID already in app/Local.xcconfig"
[ "$(shasum -a 256 app/Local.xcconfig | cut -d' ' -f1)" = "$LOCAL_BEFORE" ] \
  || fail "app/Local.xcconfig was rewritten; a Team ID the forker put there by hand must be left alone"
grep -q 'TEAM_ID_PLACEHOLDER' app/project.yml app/Project.swift \
  && fail "the literal TEAM_ID_PLACEHOLDER survived in a manifest"
ok "exit 0, Team ID accepted from app/Local.xcconfig byte-identically, literal stripped from both manifests"

step "6/8 #295 — the paragraph the fork had to correct BY HAND is now generated"
# d40b915 shipped the false provenance note; 3283376 replaced it by hand. Both
# are read off the pin rather than quoted here, so this asserts against the
# fork's own record instead of against a string this file made up.
git show "$POST:app/Identity.xcconfig" > "$WORK_DIR/theirs.xcconfig" \
  || fail "could not read app/Identity.xcconfig out of $HISTORICAL_POST"
grep -q 'nothing set PRODUCT_NAME' "$WORK_DIR/theirs.xcconfig" \
  || fail "the recorded migration's xcconfig does not carry the false note; #295 cannot be demonstrated against this pin"
ok "the recorded migration shipped the false note ('nothing set PRODUCT_NAME') — the defect, on the record"

grep -q 'ALREADY ONE VALUE' "$WORK_DIR/run.log" \
  || fail "the console still narrates a collapse on a fork that pinned PRODUCT_NAME"
grep -q 'unchanged on both platforms' "$WORK_DIR/run.log" \
  || fail "the console does not state that the built names are unchanged"
grep -q "already resolved $FORK_TOKEN on both" app/Identity.xcconfig \
  || fail "the GENERATED app/Identity.xcconfig does not record that both platforms already resolved $FORK_TOKEN"
grep -q 'unchanged on both platforms' app/Identity.xcconfig \
  || fail "the generated app/Identity.xcconfig does not state that the built names are unchanged"
if grep -qE 'nothing set PRODUCT_NAME|change on at least one platform' app/Identity.xcconfig; then
  fail "the generated app/Identity.xcconfig still carries the false paragraph that $POST shipped and 3283376 removed by hand"
fi
ok "the generated note now says what the hand correction said: spelling changed, resolved value did not"

step "7/8 the outcome matches what the real migration recorded"
for key in BUNDLE_ID APP_PRODUCT_NAME DISPLAY_NAME COPYRIGHT; do
  ours="$(grep -E "^${key}[[:space:]]*=" app/Identity.xcconfig | head -1 | sed 's/^[^=]*=[[:space:]]*//')"
  theirs="$(grep -E "^${key}[[:space:]]*=" "$WORK_DIR/theirs.xcconfig" | head -1 | sed 's/^[^=]*=[[:space:]]*//')"
  [ -n "$ours" ] || fail "$key is missing from the app/Identity.xcconfig this run wrote"
  [ "$ours" = "$theirs" ] || fail "$key differs from the recorded migration: ours '$ours', $HISTORICAL_POST '$theirs'"
  ok "$key = $ours (identical to $HISTORICAL_POST)"
done

# The rename SET, not the similarity indices: the recorded commit bundles content
# edits alongside the moves, so its percentages are lower than a pure move's.
# What must match is which paths git recognises as renames.
git diff --cached -M --summary | sed -nE 's/^ rename (.*) \([0-9]+%\)$/\1/p' | sort > "$WORK_DIR/ours.renames"
git show --find-renames --summary "$POST" | sed -nE 's/^ rename (.*) \([0-9]+%\)$/\1/p' | sort > "$WORK_DIR/theirs.renames"
[ -s "$WORK_DIR/theirs.renames" ] || fail "$HISTORICAL_POST records no renames; the pin is not a renamed-fork migration"
if ! diff -q "$WORK_DIR/ours.renames" "$WORK_DIR/theirs.renames" >/dev/null; then
  printf '    --- ours vs %s ---\n' "$HISTORICAL_POST" >&2
  diff "$WORK_DIR/ours.renames" "$WORK_DIR/theirs.renames" >&2
  fail "the set of git-recognised renames differs from the recorded migration"
fi
ok "$(wc -l < "$WORK_DIR/theirs.renames" | tr -d ' ') renames, staged with history preserved, identical set to $HISTORICAL_POST"

step "8/8 #298 — the workflow is reported although the token is absent from it"
grep -q 'BUILDING A PROJECT PATH OR SCHEME FROM A VARIABLE' "$WORK_DIR/run.log" \
  || fail "the token-independent report did not fire on a fork whose workflows are behind"
grep -qE '\.github/workflows/pr\.yml:[0-9]' "$WORK_DIR/run.log" \
  || fail "the report does not name .github/workflows/pr.yml with line numbers"
ok "pr.yml named by line, on a fork where the token-keyed report structurally could not see it"

printf '\nAll historical-migration assertions passed against %s (%s).\n' \
  "$HISTORICAL_POST" "$HISTORICAL_REPO"
