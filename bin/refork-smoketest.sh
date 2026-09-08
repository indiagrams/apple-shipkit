#!/usr/bin/env bash
# Refork the public smoketest to validate the template end-to-end.
#
# Automates the destructive cycle the E2E refork test depends on (see
# docs/CONTINUOUS-VALIDATION.md). Run from the apple-shipkit repo root.
#
# What it does (in order):
#
#   1. Archive the smoketest's PRs + run logs to .planning/smoketest-history/
#   2. Revoke "Created via API" Apple certs (smoketest residue) to free quota
#   3. Delete the smoketest app repo + clear local clone
#   4. Reset (default) or nuke the certs repo
#         - reset: force-push empty branches, preserves the certs repo's
#           database id so the existing fine-grained PAT keeps working (G12)
#         - nuke: delete + recreate the certs repo (PAT scope must be
#           updated manually after; see G12 in CONTINUOUS-VALIDATION.md)
#   5. Re-fork the smoketest from indiagrams/apple-shipkit
#   6. Personalize (bin/rename.sh --email); identity is set by hand afterwards
#   7. Run make bootstrap (toolchain), commit, push, set branch protection
#   8. Materialize .bootstrap.env in the new clone, pre-filled with
#      smoketest identity + Apple credentials (sourced from
#      ~/.config/secrets.env) + the chosen RELEASE_MODE
#
# After this script exits cleanly, the smoketest is in a state equivalent
# to a fresh forker who has just run `make init` + filled .bootstrap.env.
# The next manual step is `make doctor && make bootstrap-fork` (or
# `make all`) from inside ../ios-macos-smoketest.
#
# Apple-side state NOT touched (Apple disallows API deletion):
#   - Bundle ID (--bundle-id; default com.indiagram.smoke-app) — idempotent
#     register_app_id covers it
#   - ASC App record (verify-mode bootstrap_asc covers it)
#
# Apple inputs (read from a .bootstrap.env, NOT from the shell):
#   FASTLANE_TEAM_ID, ASC_API_KEY_ID, ASC_API_KEY_ISSUER_ID,
#   ASC_API_KEY_P8_PATH  — required
#   KEYCHAIN_PASSWORD_FILE — required when --release-mode=ci
#   MATCH_PASSWORD_FILE, GH_PAT_FILE — carried through when present
# Defaults to the current smoketest checkout's .bootstrap.env; --from overrides.
# Key material is read from the .p8 that file points at.
#
# Required `gh auth` scopes: delete_repo + repo
#
# Usage:
#   bin/refork-smoketest.sh [OPTIONS]
#
# Options:
#   --keep-certs-repo               Reset certs repo (default; PAT scope retained)
#   --nuke-certs-repo               Delete + recreate certs repo (PAT update needed)
#   --generator=xcodegen|tuist      Project generator (default: xcodegen)
#   --release-mode=ci|local         Bootstrap mode written to .bootstrap.env (default: ci)
#   --bundle-id=ID                  App bundle id (default: com.indiagram.smoke-app)
#   --asc-app-name=NAME             ASC app record name (default: Indiagram Smoke App)
#   --skip-cert-revoke              Skip revoking "Created via API" certs — REQUIRED
#                                   when the Apple team is shared with other apps
#                                   (a team-wide revoke kills co-tenant certs)
#   --from=PATH                     .bootstrap.env to read Apple inputs from
#                                   (default: <smoketest checkout>/.bootstrap.env)
#   -h, --help                      Show this message

set -euo pipefail

# ─── Defaults + flag parsing ──────────────────────────────────────────────────

KEEP_CERTS=true
GENERATOR=xcodegen
RELEASE_MODE=ci
SKIP_CERT_REVOKE=false
FROM_ENV_FLAG=""

usage() {
  awk '/^# Usage:/{flag=1} flag && /^[^#]/{exit} flag{sub(/^# ?/, ""); print}' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --keep-certs-repo)        KEEP_CERTS=true ;;
    --nuke-certs-repo)        KEEP_CERTS=false ;;
    --generator=*)            GENERATOR="${1#*=}" ;;
    --release-mode=*)         RELEASE_MODE="${1#*=}" ;;
    --bundle-id=*)            BUNDLE_ID="${1#*=}" ;;
    --asc-app-name=*)         ASC_APP_NAME="${1#*=}" ;;
    --skip-cert-revoke)       SKIP_CERT_REVOKE=true ;;
    --from=*)                 FROM_ENV_FLAG="${1#*=}" ;;
    -h|--help)                usage 0 ;;
    *)                        echo "unknown flag: $1" >&2; usage 64 ;;
  esac
  shift
done

case "$GENERATOR" in
  xcodegen|tuist) ;;
  *) echo "--generator must be xcodegen or tuist (got: $GENERATOR)" >&2; exit 64 ;;
esac

case "$RELEASE_MODE" in
  ci|local) ;;
  *) echo "--release-mode must be ci or local (got: $RELEASE_MODE)" >&2; exit 64 ;;
esac

# ─── Constants ────────────────────────────────────────────────────────────────

ORG=indiagrams
TEMPLATE_REPO="$ORG/apple-shipkit"
APP_REPO="$ORG/ios-macos-smoketest"
CERTS_REPO="$ORG/ios-macos-smoketest-certs"
APP_NAME=SmokeApp
BUNDLE_ID="${BUNDLE_ID:-com.indiagram.smoke-app}"
DISPLAY_NAME='Indiagram Smoke App'
APP_EMAIL=smoketest@indiagram.com
ASC_APP_SKU=indiagram-smoke-001
ASC_APP_NAME="${ASC_APP_NAME:-Indiagram Smoke App}"

CLONE_PARENT="$(cd .. && pwd)"
CLONE_DIR="$CLONE_PARENT/ios-macos-smoketest"

# ─── Preflight ────────────────────────────────────────────────────────────────

echo "Refork smoketest — generator=$GENERATOR release_mode=$RELEASE_MODE certs=$([ "$KEEP_CERTS" = true ] && echo keep || echo nuke)"
echo

# ─── Apple inputs: a .bootstrap.env + the .p8 on disk, never the shell ────────
#
# This script used to `source ~/.config/secrets.env` and hard-require seven
# exported variables. #291 made .bootstrap.env authoritative and made a
# contradicting shell fatal on every release path — so that requirement asked
# the operator to maintain precisely the setup the rest of the kit now refuses:
# a shell profile exporting one project's Apple credentials. That profile line
# is how the smoketest's ASC key reached an unrelated project's release.
#
# Inputs are file-shaped now, the same shape every fork already keeps. Of the
# old seven, only three were ever written into the fresh fork. The rest were
# not inputs at all:
#   ASC_API_KEY_P8_BASE64  — needed only by step 2's fastlane child, and
#     derived there from the .p8. `make bootstrap-fork` builds its own copy for
#     the GH secret via Bootstrap::GHSecrets (`expand_path(...P8_PATH).read`).
#   MATCH_PASSWORD / MATCH_GIT_BASIC_AUTHORIZATION — match is retired; see
#     release.yml's header ("no companion repo, MATCH_PASSWORD, or
#     MATCH_GIT_BASIC_AUTHORIZATION") and Fastfile's sigh-based release lane.
#   KEYCHAIN_PASSWORD — bootstrap-fork generates it into KEYCHAIN_PASSWORD_FILE
#     when the file is absent (`ensure_random_password`).
FROM_ENV="${FROM_ENV_FLAG:-$CLONE_DIR/.bootstrap.env}"

fail_field() {
  echo "ERROR: $1" >&2
  echo >&2
  echo "  bin/refork-smoketest.sh reads the smoketest's Apple inputs from a" >&2
  echo "  .bootstrap.env, never from exported shell variables. See #291 and" >&2
  echo "  docs/APPLE-PREREQS.md 'One key per secret store, not per project'." >&2
  echo "  Read them from a different file with:" >&2
  echo "    bin/refork-smoketest.sh --from=/path/to/.bootstrap.env" >&2
  exit 1
}

[ -f "$FROM_ENV" ] \
  || fail_field "no .bootstrap.env to read Apple inputs from: $FROM_ENV"

# Value semantics mirror Bootstrap::Config.parse: skip comment lines, strip one
# surrounding quote pair, and drop an inline ` #` comment on unquoted values.
env_get() {
  awk -v want="$1" '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    {
      eq = index($0, "=")
      if (eq == 0) next
      name = substr($0, 1, eq - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != want) next
      val = substr($0, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      q = substr(val, 1, 1)
      if (q == "\"" || q == "\x27") {
        rest = substr(val, 2)
        at = index(rest, q)
        val = (at > 0) ? substr(rest, 1, at - 1) : rest
      } else if (match(val, /[[:space:]]#/)) {
        val = substr(val, 1, RSTART - 1)
        gsub(/[[:space:]]+$/, "", val)
      }
      print val
      exit
    }
  ' "$FROM_ENV"
}

require_field() {
  local v
  v="$(env_get "$1")"
  [ -n "$v" ] || fail_field "$1 is missing or empty in $FROM_ENV"
  printf '%s' "$v"
}

echo "Apple inputs ← $FROM_ENV"
FASTLANE_TEAM_ID="$(require_field FASTLANE_TEAM_ID)"           || exit 1
ASC_API_KEY_ID="$(require_field ASC_API_KEY_ID)"               || exit 1
ASC_API_KEY_ISSUER_ID="$(require_field ASC_API_KEY_ISSUER_ID)" || exit 1
ASC_API_KEY_P8_PATH="$(require_field ASC_API_KEY_P8_PATH)"     || exit 1

# Path-shaped secrets are carried through rather than hardcoded to
# ~/.config/secrets/…: whatever the source fork uses is what the fresh one gets.
KEYCHAIN_PASSWORD_FILE="$(env_get KEYCHAIN_PASSWORD_FILE)"
MATCH_PASSWORD_FILE="$(env_get MATCH_PASSWORD_FILE)"
GH_PAT_FILE="$(env_get GH_PAT_FILE)"
if [ "$RELEASE_MODE" = ci ] && [ -z "$KEYCHAIN_PASSWORD_FILE" ]; then
  fail_field "KEYCHAIN_PASSWORD_FILE is missing or empty in $FROM_ENV (required when --release-mode=ci)"
fi

# The .p8 is read twice downstream — base64 for step 2's fastlane child, and by
# `make bootstrap-fork` later through ASC_API_KEY_P8_PATH — so prove it is
# there now rather than several destructive steps in.
P8_ABS="${ASC_API_KEY_P8_PATH/#\~/$HOME}"
[ -f "$P8_ABS" ] \
  || fail_field "ASC_API_KEY_P8_PATH names a file that does not exist: $P8_ABS (from $FROM_ENV)"
echo "  team=$FASTLANE_TEAM_ID  key=$ASC_API_KEY_ID  p8=$ASC_API_KEY_P8_PATH"

gh auth status 2>&1 | grep -qE "delete_repo" \
  || { echo "gh auth missing delete_repo scope; run: gh auth refresh -s delete_repo" >&2; exit 1; }

# ─── 1. Archive ───────────────────────────────────────────────────────────────

echo "=== 1/8: archive PRs + key runs ==="
ARCHIVE_DIR=".planning/smoketest-history/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ARCHIVE_DIR"
gh pr list --repo "$APP_REPO" --state all --limit 100 --json number,title,state,mergedAt,body,url \
  > "$ARCHIVE_DIR/pr-list.json" 2>/dev/null || echo "  (no PRs to archive)"
gh run list --repo "$APP_REPO" --limit 50 --json databaseId,displayTitle,conclusion,createdAt,workflowName,event \
  > "$ARCHIVE_DIR/run-list.json" 2>/dev/null || true
echo "  archive → $ARCHIVE_DIR"

# ─── 2. Revoke residue Apple certs ────────────────────────────────────────────

if [ "$SKIP_CERT_REVOKE" = true ]; then
  echo "=== 2/8: SKIPPING 'Created via API' cert revocation (--skip-cert-revoke) ==="
  echo "  The Apple team is shared with other apps; a team-wide revoke would kill"
  echo "  co-tenant certs. The canary mints + revokes its own certs each run."
else
  echo "=== 2/8: revoke 'Created via API' Apple certs (smoketest residue) ==="
  unset APP_STORE_CONNECT_API_KEY_KEY APP_STORE_CONNECT_API_KEY_KEY_FILEPATH \
        APP_STORE_CONNECT_API_KEY_KEY_ID APP_STORE_CONNECT_API_KEY_ISSUER_ID

  if [ -d "$CLONE_DIR/fastlane" ]; then
    pushd "$CLONE_DIR" >/dev/null
    # Credentials for the fastlane child are derived from $FROM_ENV and confined
    # to this subshell: ASC_API_KEY_P8_BASE64 (the form the Fastfile's
    # asc_api_key reads) lives for the duration of the revoke and is never a
    # script-level variable.
    #
    # These are also what #291's guard compares against this clone's own
    # .bootstrap.env. With the default --from they ARE that file, so they agree
    # by construction. A --from naming a different team is refused there, which
    # is correct: revoking on a team this checkout is not configured for is
    # exactly the ambiguity #291 exists to stop.
    (
      export FASTLANE_TEAM_ID ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID
      ASC_API_KEY_P8_BASE64="$(base64 < "$P8_ABS" | tr -d '\n')"
      export ASC_API_KEY_P8_BASE64
      bundle exec fastlane list_certs 2>&1 \
        | awk '/Created via API/ { for (i=1;i<=NF;i++) if ($i ~ /^[A-Z0-9]{10}$/) { print $i; break } }' \
        | while read -r cert_id; do
            echo "  revoking $cert_id"
            bundle exec fastlane revoke_cert "id:$cert_id" 2>&1 | grep -E "Revoked|error" | head -1
          done
    )
    popd >/dev/null
  else
    echo "  no local smoketest clone at $CLONE_DIR; skipping cert revocation"
  fi
fi

# ─── 3. Delete app repo + clear local clone ───────────────────────────────────

echo "=== 3/8: delete app repo + clear local clone ==="
if gh repo view "$APP_REPO" --json name >/dev/null 2>&1; then
  gh repo delete "$APP_REPO" --yes
  echo "  deleted $APP_REPO"
else
  echo "  $APP_REPO doesn't exist; skipping"
fi
rm -rf "$CLONE_DIR"

# ─── 4. Reset or nuke certs repo ──────────────────────────────────────────────

if [ "$KEEP_CERTS" = false ]; then
  echo "=== 4/8: NUKE certs repo ==="
  echo "  WARNING: PAT will need scope update on github.com/settings/tokens"
  if gh repo view "$CERTS_REPO" --json name >/dev/null 2>&1; then
    gh repo delete "$CERTS_REPO" --yes
  fi
else
  echo "=== 4/8: RESET certs repo (force-push empty branches) ==="
  if gh repo view "$CERTS_REPO" --json name >/dev/null 2>&1; then
    TMPDIR_CERTS=$(mktemp -d)
    gh repo clone "$CERTS_REPO" "$TMPDIR_CERTS" -- --quiet 2>&1 | tail -1 || true
    pushd "$TMPDIR_CERTS" >/dev/null
    git checkout --orphan reset-tmp >/dev/null 2>&1
    git reset --hard >/dev/null 2>&1
    git -c user.email=refork@indiagram.com -c user.name=refork commit --allow-empty -m "reset for E2E" -q
    for branch in $(git branch -r | grep -v HEAD | sed 's|origin/||'); do
      git push origin --delete "$branch" 2>&1 | tail -1 || true
    done
    popd >/dev/null
    rm -rf "$TMPDIR_CERTS"
    echo "  certs repo reset; PAT scope retained"
  else
    echo "  $CERTS_REPO doesn't exist — creating"
    gh repo create "$CERTS_REPO" --private --description "Encrypted certs + profiles for $APP_REPO"
  fi
fi

# ─── 5. Re-fork from template ─────────────────────────────────────────────────

echo "=== 5/8: re-fork smoketest from $TEMPLATE_REPO ==="
( cd "$CLONE_PARENT" && \
    gh repo create "$APP_REPO" --template "$TEMPLATE_REPO" --public --clone 2>&1 | tail -1 )
[ -d "$CLONE_DIR" ] || { echo "expected clone at $CLONE_DIR but it's missing" >&2; exit 1; }
echo "  fresh fork at $CLONE_DIR"

# ─── 6. Personalize (identity is set by hand afterwards) ──────────────────────
#
# bin/rename.sh personalizes the contact address and the repository slug. It no
# longer writes identity: the bundle id, product name, display name and
# copyright are four values in app/Identity.xcconfig, edited by hand.
#
# Nothing is automated in their place here, deliberately. A freshly created
# repository legitimately ships the template's placeholder identity, so a check
# placed at this point would pass on a correct tree and on an incorrect one
# alike — the pass condition met regardless of what it claims to detect. The
# gap is named instead by gates that already run in the operator's next step:
# `make doctor` reports the identity step blocked on template values, and
# `make bootstrap-fork` refuses to continue past it.

echo "=== 6/8: personalize contact address and slug (generator=$GENERATOR) ==="
pushd "$CLONE_DIR" >/dev/null
bin/rename.sh --email="$APP_EMAIL" 2>&1 | tail -3
if [ "$GENERATOR" = "tuist" ]; then
  bin/switch-to-tuist.sh --force 2>&1 | tail -3
fi
echo
echo "  NEXT, BY HAND, in $CLONE_DIR:"
echo "    edit app/Identity.xcconfig — APP_PRODUCT_NAME, BUNDLE_ID, DISPLAY_NAME, COPYRIGHT"
echo "    a repo created before that file existed migrates with:"
echo "      ruby bin/migrate-identity.rb        # see docs/MIGRATING-FROM-RENAME.md"
echo

# ─── 7. Toolchain + initial push + branch protection ──────────────────────────

echo "=== 7/8: bootstrap toolchain + initial push + branch protection ==="
unset TMPDIR # local-check.sh hates a stale TMPDIR
make bootstrap 2>&1 | tail -3
git add -A
git -c user.email="$APP_EMAIL" -c user.name="$APP_NAME bootstrap" \
  commit -m "Rename app stub + initial bootstrap" 2>&1 | tail -1
git push -u origin main 2>&1 | tail -1
bin/setup-github.sh 2>&1 | tail -3

# ─── 8. Materialize .bootstrap.env with chosen mode + smoketest identity ──────

echo "=== 8/8: write .bootstrap.env (release_mode=$RELEASE_MODE) ==="
cat > .bootstrap.env <<EOF
APP_NAME=$APP_NAME
BUNDLE_ID=$BUNDLE_ID
DISPLAY_NAME='$DISPLAY_NAME'
APP_EMAIL=$APP_EMAIL
GENERATOR=$GENERATOR
RELEASE_MODE=$RELEASE_MODE
FASTLANE_TEAM_ID=$FASTLANE_TEAM_ID
ASC_API_KEY_ID=$ASC_API_KEY_ID
ASC_API_KEY_ISSUER_ID=$ASC_API_KEY_ISSUER_ID
ASC_API_KEY_P8_PATH=$ASC_API_KEY_P8_PATH
GH_ORG=$ORG
GH_APP_REPO=ios-macos-smoketest
GH_CERTS_REPO=ios-macos-smoketest-certs
EOF
# Carried through from $FROM_ENV, and omitted when the source file has none —
# a fresh .bootstrap.env should not grow fields naming paths that do not exist.
for kv in "GH_PAT_FILE=$GH_PAT_FILE" \
          "MATCH_PASSWORD_FILE=$MATCH_PASSWORD_FILE" \
          "KEYCHAIN_PASSWORD_FILE=$KEYCHAIN_PASSWORD_FILE"; do
  if [ -n "${kv#*=}" ]; then printf '%s\n' "$kv" >> .bootstrap.env; fi
done
cat >> .bootstrap.env <<EOF
ICON_1024_PATH=
ASC_APP_SKU=$ASC_APP_SKU
ASC_APP_NAME='$ASC_APP_NAME'
EOF
echo "  wrote .bootstrap.env"
popd >/dev/null

# ─── Done ─────────────────────────────────────────────────────────────────────

cat <<EOF

===============================================================================
Refork complete. Smoketest is in fresh-forked + bootstrapped-toolchain state.
generator=$GENERATOR release_mode=$RELEASE_MODE certs=$([ "$KEEP_CERTS" = true ] && echo reset || echo nuked)

Next:
  cd $CLONE_DIR
  make doctor          # validate state — should be ✗-pending in many places
  make bootstrap-fork  # mints certs (ci) or probes keychain (local)

  # ⚠ The app repo was DELETED + recreated, so it has a NEW database id.
  #   Fine-grained PATs scoped to the OLD repo lose access. Re-scope the
  #   SMOKETEST_DISPATCH_PAT (github.com/settings/personal-access-tokens →
  #   Repository access) to the recreated $APP_REPO, or canary-trigger's
  #   dispatch step 403s with "Resource not accessible by personal access token".
  # or:
  make all             # one-shot: doctor → bootstrap-fork → ship → verify
===============================================================================
EOF
