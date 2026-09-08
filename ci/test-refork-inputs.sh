#!/usr/bin/env bash
# Control test for bin/refork-smoketest.sh's input contract.
#
# Why this exists: the refork script used to `source ~/.config/secrets.env` and
# hard-require seven exported variables. #291 made .bootstrap.env authoritative
# and made a contradicting shell fatal on every release path, so that
# requirement asked the operator to maintain exactly the setup the rest of the
# kit refuses — and that shell profile is how the smoketest's ASC key reached an
# unrelated project's release.
#
# The property under test is the one that closes it: with the old seven
# variables exported to DIFFERENT values, the .bootstrap.env the script
# generates must carry the FILE's values and none of the shell's.
#
# How it runs the real code without the destructive steps: it splices the actual
# script — everything above "1. Archive" (flag parsing + input reading) plus the
# verbatim .bootstrap.env generation block — into a harness. Nothing is retyped,
# so a change to either region is exercised here rather than mirrored.
#
# Runnable locally:
#   ci/test-refork-inputs.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/refork-smoketest.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
ok()   { echo "  ✓ $1"; }
bad()  { echo "  ✗ $1"; failures=$((failures + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; echo "      expected: $3"; echo "      actual:   $2"; fi; }

# ─── Build the harness from the real script ───────────────────────────────────

HARNESS="$WORK/harness.sh"
awk '/^# ─── 1\. Archive/{exit} {print}' "$SCRIPT" > "$HARNESS"
awk '/^cat > \.bootstrap\.env <<EOF/{f=1} f{print} f && /^EOF$/{n++; if(n==2) exit}' \
  "$SCRIPT" >> "$HARNESS"

grep -q 'require_field FASTLANE_TEAM_ID' "$HARNESS" \
  || { echo "harness missing the input-reading region — splice markers moved" >&2; exit 1; }
grep -q 'ASC_API_KEY_P8_PATH=\$ASC_API_KEY_P8_PATH' "$HARNESS" \
  || { echo "harness missing the generation region — splice markers moved" >&2; exit 1; }

# ─── Fixture: the FILE's values (team B), plus a real .p8 on disk ─────────────

P8="$WORK/AuthKey_FILEKEY123.p8"
printf 'not-a-real-key\n' > "$P8"

FIXTURE="$WORK/source.bootstrap.env"
cat > "$FIXTURE" <<EOF
APP_NAME=Ferry
BUNDLE_ID=com.indiagram.ferry
FASTLANE_TEAM_ID=TEAMFILE99
ASC_API_KEY_ID=FILEKEY123   # inline comment must not reach the value
ASC_API_KEY_ISSUER_ID='file-issuer-uuid'
ASC_API_KEY_P8_PATH=$P8
KEYCHAIN_PASSWORD_FILE=$WORK/keychain-password
EOF

# ─── The shell contradicts it: the old seven, all different (team A) ──────────

export FASTLANE_TEAM_ID=TEAMSHELL1
export ASC_API_KEY_ID=SHELLKEY99
export ASC_API_KEY_ISSUER_ID=shell-issuer-uuid
export ASC_API_KEY_P8_BASE64=c2hlbGwtYmFzZTY0
export MATCH_PASSWORD=shell-match-password
export MATCH_GIT_BASIC_AUTHORIZATION=shell-match-git-auth
export KEYCHAIN_PASSWORD=shell-keychain-password

run_harness() { # run_harness <outdir> [extra args...]
  local out="$1"; shift
  mkdir -p "$out"
  ( cd "$out" && bash "$HARNESS" --from="$FIXTURE" "$@" ) >"$out/stdout" 2>"$out/stderr"
}

echo
echo "=== generated .bootstrap.env carries the FILE's values, not the shell's ==="

OUT="$WORK/gen"
run_harness "$OUT" --release-mode=ci
GEN="$OUT/.bootstrap.env"

field() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$GEN"; }

check "FASTLANE_TEAM_ID from file"      "$(field FASTLANE_TEAM_ID)"      "TEAMFILE99"
check "ASC_API_KEY_ID from file"        "$(field ASC_API_KEY_ID)"        "FILEKEY123"
check "ASC_API_KEY_ISSUER_ID from file" "$(field ASC_API_KEY_ISSUER_ID)" "file-issuer-uuid"
check "ASC_API_KEY_P8_PATH from file"   "$(field ASC_API_KEY_P8_PATH)"   "$P8"
check "KEYCHAIN_PASSWORD_FILE carried"  "$(field KEYCHAIN_PASSWORD_FILE)" "$WORK/keychain-password"

# The blunt property: no value the shell exported may appear anywhere in the
# generated file. Catches a re-introduced $VAR interpolation that the
# field-by-field checks above would miss if a NEW field were added later.
leaked=""
for v in TEAMSHELL1 SHELLKEY99 shell-issuer-uuid c2hlbGwtYmFzZTY0 \
         shell-match-password shell-match-git-auth shell-keychain-password; do
  if grep -q "$v" "$GEN"; then leaked="$leaked $v"; fi
done
check "no shell value leaked into the file" "${leaked:-none}" "none"

# The old hardcoded convention must be gone: the p8 path is whatever the source
# file said, not a path assembled from the key id.
if grep -qE '^ASC_API_KEY_P8_PATH=~/\.config/secrets/AuthKey_' "$GEN"; then
  bad "p8 path is no longer hardcoded to ~/.config/secrets/AuthKey_<id>.p8"
else
  ok "p8 path is no longer hardcoded to ~/.config/secrets/AuthKey_<id>.p8"
fi

# Absent optional fields are omitted rather than invented — the fixture has no
# MATCH_PASSWORD_FILE / GH_PAT_FILE, and match is retired.
for k in MATCH_PASSWORD_FILE GH_PAT_FILE; do
  if grep -q "^$k=" "$GEN"; then bad "$k omitted when absent from source"; else ok "$k omitted when absent from source"; fi
done

echo
echo "=== parser parity with Bootstrap::Config.parse ==="
check "inline comment stripped"   "$(field ASC_API_KEY_ID)"        "FILEKEY123"
check "surrounding quotes stripped" "$(field ASC_API_KEY_ISSUER_ID)" "file-issuer-uuid"

echo
echo "=== missing input fails by NAME and by FILE PATH ==="

expect_fail() { # expect_fail <label> <fixture> <needle...>
  local label="$1" fixture="$2"; shift 2
  local out="$WORK/fail-$RANDOM"; mkdir -p "$out"
  local rc=0
  ( cd "$out" && bash "$HARNESS" --from="$fixture" --release-mode=ci ) \
    >"$out/stdout" 2>"$out/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then bad "$label (expected non-zero exit)"; return; fi
  local missing=""
  for needle in "$@"; do
    grep -q -- "$needle" "$out/stderr" || missing="$missing '$needle'"
  done
  if [ -n "$missing" ]; then
    bad "$label — stderr missing:$missing"
    sed 's/^/        /' "$out/stderr"
  else
    ok "$label"
  fi
}

NO_KEY="$WORK/no-key.env"; grep -v '^ASC_API_KEY_ID=' "$FIXTURE" > "$NO_KEY"
expect_fail "missing ASC_API_KEY_ID names the field + the file" "$NO_KEY" \
  "ASC_API_KEY_ID" "$NO_KEY"

NO_KC="$WORK/no-keychain.env"; grep -v '^KEYCHAIN_PASSWORD_FILE=' "$FIXTURE" > "$NO_KC"
expect_fail "missing KEYCHAIN_PASSWORD_FILE fails in ci mode" "$NO_KC" \
  "KEYCHAIN_PASSWORD_FILE" "$NO_KC"

BAD_P8="$WORK/bad-p8.env"
sed "s|^ASC_API_KEY_P8_PATH=.*|ASC_API_KEY_P8_PATH=$WORK/nope.p8|" "$FIXTURE" > "$BAD_P8"
expect_fail "nonexistent .p8 is caught before any destructive step" "$BAD_P8" \
  "ASC_API_KEY_P8_PATH" "$WORK/nope.p8"

expect_fail "absent source file names the path it looked for" "$WORK/does-not-exist.env" \
  "$WORK/does-not-exist.env"

echo
echo "=== the shell requirement is gone from the script ==="
if grep -qE '^\s*source .*secrets\.env' "$SCRIPT"; then
  bad "no 'source ~/.config/secrets.env' remains"
else
  ok "no 'source ~/.config/secrets.env' remains"
fi
# The retired inputs must not survive as VALUES the script reads. They may
# still be named in comments (the header explains why they went away), so the
# check runs against executable lines only, and the trailing [^_] keeps
# MATCH_PASSWORD_FILE / KEYCHAIN_PASSWORD_FILE — which ARE still carried
# through as paths — from matching their own bare-name prefixes.
CODE="$WORK/code-only.sh"
grep -vE '^[[:space:]]*#' "$SCRIPT" > "$CODE"
for dead in MATCH_GIT_BASIC_AUTHORIZATION MATCH_PASSWORD KEYCHAIN_PASSWORD; do
  if grep -qE "${dead}([^_]|$)" "$CODE"; then
    bad "$dead is no longer read by the script"
    grep -nE "${dead}([^_]|$)" "$CODE" | sed 's/^/        /'
  else
    ok "$dead is no longer read by the script"
  fi
done
# The old seven-variable gate itself must be gone.
if grep -q 'secrets.env missing' "$SCRIPT"; then
  bad "the seven-variable export gate is gone"
else
  ok "the seven-variable export gate is gone"
fi
# ASC_API_KEY_P8_BASE64 must still be DERIVED for the fastlane child, in-step.
if grep -q 'ASC_API_KEY_P8_BASE64="$(base64 < "$P8_ABS"' "$SCRIPT"; then
  ok "ASC_API_KEY_P8_BASE64 is derived from the .p8 at the step that needs it"
else
  bad "ASC_API_KEY_P8_BASE64 is derived from the .p8 at the step that needs it"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "All refork input-contract assertions passed."
else
  echo "$failures assertion(s) FAILED."
  exit 1
fi
