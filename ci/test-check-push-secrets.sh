#!/usr/bin/env bash
# ci/test-check-push-secrets.sh — proves check-push-secrets.sh can FAIL, and fails for the
# right reasons.
#
# The gate's verdict is only worth what its failure modes are worth, so this
# drives the REAL script against synthetic repositories with their own bare
# remotes, and requires a red for each way a publish-set scan can go quietly
# blind. An earlier blob-only draft of that gate read 31% of a real publish set
# and reported success; cases 2 and 3 exist so that cannot come back.
#
# ⚠ THE TRAP THIS FILE IS ITSELF BUILT AGAINST. The first draft of a self-test
# for this gate PASSED 3/3 against the unfixed gate. `cd "$(dirname "$0")/.."`
# resolved somewhere the gate did not exist, the run exited 127, and every
# `rc != 0` assertion read "127" as "the gate fired". Three vacuous greens over
# a gate that never ran once. So:
#   - the fixture is asserted to exist before anything runs;
#   - a run only counts as a VERDICT if the gate's own "control ok" line is in
#     its output — rc alone is never trusted;
#   - assertions are on the gate's verdict TEXT, not just its status;
#   - case 1 requires the gate to go RED on a plain blob, so a gate that cannot
#     fire at all cannot pass this file.
#
# Everything here is synthetic. The values below are invented and are not
# secrets; $HOME is redirected so the real machine's key ids are never read, and
# no test touches the real repository.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
GATE_SRC="$(pwd)/ci/check-push-secrets.sh"
GIT=$(command -v git)

[ -f "$GATE_SRC" ] || { echo "RED: fixture — $GATE_SRC does not exist; every case below would be vacuous" >&2; exit 1; }
[ -n "$GIT" ]      || { echo "RED: fixture — no git on PATH" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "    ok   — $1"; PASS=$((PASS+1)); }
red() { echo "    RED  — $1" >&2; FAIL=$((FAIL+1)); }

V_APP='selftest-app@example.invalid'
V_BETA='selftest-beta@example.invalid'
V_KEYID='ZZ9SELFTST'

# Build a synthetic repo with its own bare remote, its own gitignored
# .bootstrap.env, and its own HOME carrying one invented .p8.
mkrepo() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/home/.appstoreconnect/private_keys" "$d/work"
  : > "$d/home/.appstoreconnect/private_keys/AuthKey_${V_KEYID}.p8"
  "$GIT" init -q --bare "$d/remote.git"
  "$GIT" init -q "$d/work"
  ( cd "$d/work" || exit 1
    "$GIT" config user.email selftest-committer@example.invalid
    "$GIT" config user.name selftest
    "$GIT" remote add origin "$d/remote.git"
    printf '.bootstrap.env\n' > .gitignore
    printf 'APP_EMAIL=%s\nBETA_APP_FEEDBACK_EMAIL=%s\nASC_API_KEY_ID=%s\n' \
      "$V_APP" "$V_BETA" "$V_KEYID" > .bootstrap.env
    printf 'baseline\n' > README.md
    "$GIT" add -A >/dev/null 2>&1
    "$GIT" commit -qm "baseline" >/dev/null 2>&1
    "$GIT" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
    "$GIT" branch --set-upstream-to=origin/main >/dev/null 2>&1
  ) >/dev/null 2>&1
  cp "$GATE_SRC" "$d/work/check-push-secrets.sh"
  printf '%s' "$d"
}

# Run the gate. A run is only a VERDICT if the gate proved itself first.
# OUT / RC / VALID are set for the caller.
run() {
  local d="$1"; shift
  OUT=$( cd "$d/work" || exit 1; HOME="$d/home" bash ./check-push-secrets.sh "$@" 2>&1 ); RC=$?
  if printf '%s' "$OUT" | grep -qa "control ok"; then VALID=1; else VALID=0; fi
}

need_valid() {
  [ "${VALID:-0}" -eq 1 ] && return 0
  red "$1 — the gate never proved itself (no 'control ok'); rc=$RC. Treating this as NO VERDICT, not a pass."
  return 1
}

echo "==> test-check-push-secrets: driving the real script against synthetic repos"

# ── 1. baseline: a value in a BLOB must go RED. If this fails, the gate cannot
#       fire at all and nothing else in this file means anything.
d=$(mkrepo)
( cd "$d/work" || exit 1; printf 'the value is %s here\n' "$V_APP" > leak.md && "$GIT" add -A && "$GIT" commit -qm "add leak" ) >/dev/null 2>&1
run "$d"
if need_valid "case 1"; then
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "FAILED"; then ok "a value in a BLOB in the publish set goes RED"
  else red "case 1 — a value in an unpushed BLOB did NOT go red (rc=$RC)"; fi
fi
rm -rf "$d"

# ── 2. a value in a COMMIT MESSAGE. A blob-only scan says "ok" here while the
#       push really does publish the value.
d=$(mkrepo)
( cd "$d/work" || exit 1; printf 'clean\n' > note.md && "$GIT" add -A && "$GIT" commit -qm "chore: mentions $V_KEYID in the message" ) >/dev/null 2>&1
run "$d"
if need_valid "case 2"; then
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "commit .*on [0-9]* line"; then ok "a value in a COMMIT MESSAGE goes RED (a blob-only scan says ok here)"
  else red "case 2 — a value in a commit message did NOT go red (rc=$RC)"; fi
fi
rm -rf "$d"

# ── 3. a value as a PATH NAME. The gate loads the key FILENAME as a needle, and
#       a filename can appear in no blob — only in a tree.
d=$(mkrepo)
( cd "$d/work" || exit 1; printf 'clean\n' > "AuthKey_${V_KEYID}.p8.md" && "$GIT" add -A && "$GIT" commit -qm "add a file whose NAME carries the value" ) >/dev/null 2>&1
run "$d"
if need_valid "case 3"; then
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "PATH NAME"; then ok "a value in a PATH NAME goes RED"
  else red "case 3 — a value in a path name did NOT go red (rc=$RC)"; fi
fi
rm -rf "$d"

# ── 4. a genuinely clean publish set must be GREEN, or the gate is useless.
d=$(mkrepo)
( cd "$d/work" || exit 1; printf 'nothing here\n' > fine.md && "$GIT" add -A && "$GIT" commit -qm "a clean commit" ) >/dev/null 2>&1
run "$d"
if need_valid "case 4"; then
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qa "check-push-secrets: ok"; then ok "a clean publish set is GREEN"
  else red "case 4 — a clean publish set did not pass (rc=$RC): $(printf '%s' "$OUT" | tail -2)"; fi
fi
rm -rf "$d"

# ── 5. CRLF in .bootstrap.env poisoned every needle and the control with it, so
#       the gate went green with no edit at all.
d=$(mkrepo)
( cd "$d/work" || exit 1
  printf 'APP_EMAIL=%s\r\nBETA_APP_FEEDBACK_EMAIL=%s\r\nASC_API_KEY_ID=%s\r\n' "$V_APP" "$V_BETA" "$V_KEYID" > .bootstrap.env
  printf 'the value is %s here\n' "$V_APP" > leak.md && "$GIT" add -A && "$GIT" commit -qm "add leak" ) >/dev/null 2>&1
run "$d"
if need_valid "case 5"; then
  if [ "$RC" -ne 0 ]; then ok "a CRLF .bootstrap.env still finds the value (needles are \\r-stripped)"
  else red "case 5 — CRLF env poisoned the needles and the gate went GREEN over a real value"; fi
fi
rm -rf "$d"

# ── 6. a branch that was NEVER PUSHED is the LARGEST possible publish set, and
#       exiting 3 here reads as skipped. A skip is not a pass.
d=$(mkrepo)
( cd "$d/work" || exit 1
  "$GIT" checkout -q -b never-pushed
  printf 'the value is %s here\n' "$V_APP" > leak.md && "$GIT" add -A && "$GIT" commit -qm "add leak on an unpushed branch" ) >/dev/null 2>&1
run "$d"
if need_valid "case 6"; then
  if [ "$RC" -eq 1 ]; then ok "a never-pushed branch is SCANNED and goes red, not skipped"
  elif [ "$RC" -eq 3 ]; then red "case 6 — a never-pushed branch exited 3 (skip read as pass)"
  else red "case 6 — unexpected rc=$RC on a never-pushed branch"; fi
fi
rm -rf "$d"

# ── 7. Control (0): a NAME the env file assigns but that parses empty would be
#       scanned for not at all. That is a hole, not an absence.
d=$(mkrepo)
( cd "$d/work" || exit 1
  printf 'APP_EMAIL=\nBETA_APP_FEEDBACK_EMAIL=%s\nASC_API_KEY_ID=%s\n' "$V_BETA" "$V_KEYID" > .bootstrap.env
  printf 'clean\n' > fine.md && "$GIT" add -A && "$GIT" commit -qm "clean" ) >/dev/null 2>&1
run "$d"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "did not parse"; then ok "a declared-but-unparseable name REDS instead of silently shrinking the needle set"
else red "case 7 — an unparseable declared name did not red (rc=$RC)"; fi
rm -rf "$d"

# ── 8. THE CONTROL MUST BE ABLE TO FAIL. Neuter the scan's content loop and the
#       control has to notice. A control that greps a scratch file instead stays
#       green with the entire scan deleted.
d=$(mkrepo)
( cd "$d/work" || exit 1; printf 'the value is %s here\n' "$V_APP" > leak.md && "$GIT" add -A && "$GIT" commit -qm "add leak" ) >/dev/null 2>&1
# Mutation: make the per-needle content grep always report zero.
sed -i '' 's|n=\$(grep -acF -f "\$TMP/pat.\$i" "\$TMP/o.bin" \|\| true)|n=0|' "$d/work/check-push-secrets.sh"
if grep -qa '^      n=0$' "$d/work/check-push-secrets.sh"; then
  OUT=$( cd "$d/work" || exit 1; HOME="$d/home" bash ./check-push-secrets.sh 2>&1 ); RC=$?
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "control"; then
    ok "neutering the content scan makes the CONTROL fail (it is not a tautology)"
  else
    red "case 8 — the scan was neutered and the gate still reported (rc=$RC). The control cannot fail."
  fi
else
  red "case 8 — the mutation did not apply, so this case proved nothing (the exact vacuous-green shape this file guards against)"
fi
rm -rf "$d"

# ── 9. THE DELIBERATE LIMIT, pinned so a future change cannot quietly widen it
#       into a permanently-red gate: a value identical to the committer identity
#       lives in every commit's ident headers and must NOT trip the gate.
d=$(mkrepo)
( cd "$d/work" || exit 1
  "$GIT" config user.email "$V_APP"        # the needle IS the committer identity
  printf 'clean\n' > fine.md && "$GIT" add -A && "$GIT" commit -qm "clean commit by that identity" ) >/dev/null 2>&1
run "$d"
if need_valid "case 9"; then
  if [ "$RC" -eq 0 ]; then ok "a value equal to the committer identity does NOT red (ident headers excluded, by design)"
  else red "case 9 — the gate red on ident headers; it would be permanently red for any maintainer whose contact address is their git identity"; fi
fi
rm -rf "$d"

# ── 10. an ACCEPTED object is suppressed, but a DIFFERENT one still reds. The
#        acceptance file must not become a way to silence the gate wholesale.
d=$(mkrepo)
( cd "$d/work" || exit 1
  printf 'the value is %s here\n' "$V_APP" > leak.md && "$GIT" add -A && "$GIT" commit -qm "leak one" ) >/dev/null 2>&1
sha=$( cd "$d/work" || exit 1; "$GIT" rev-parse HEAD:leak.md )
mkdir -p "$d/work/ci"
printf '%s   # selftest: accepted on purpose\n' "$sha" > "$d/work/ci/push-secrets-accepted.txt"
run "$d"
if need_valid "case 10a"; then
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qa "ACCEPTED:"; then ok "an accepted object is suppressed AND still printed with its reason"
  else red "case 10a — accepting an object did not green the gate (rc=$RC)"; fi
fi
# now add a SECOND, unaccepted leak — the gate must go red again
( cd "$d/work" || exit 1; printf 'another %s here\n' "$V_BETA" > leak2.md && "$GIT" add -A && "$GIT" commit -qm "leak two" ) >/dev/null 2>&1
run "$d"
if need_valid "case 10b"; then
  if [ "$RC" -ne 0 ]; then ok "a NEW object not in the acceptance file still goes RED"
  else red "case 10b — an unaccepted leak was silenced by an unrelated acceptance (rc=$RC)"; fi
fi
rm -rf "$d"

# ── 11. an acceptance with NO REASON is a RED, not an acceptance. A bare sha is
#        indistinguishable from a mistake, and this file is a ruling record.
d=$(mkrepo)
( cd "$d/work" || exit 1; printf 'the value is %s here\n' "$V_APP" > leak.md && "$GIT" add -A && "$GIT" commit -qm "leak" ) >/dev/null 2>&1
sha=$( cd "$d/work" || exit 1; "$GIT" rev-parse HEAD:leak.md )
mkdir -p "$d/work/ci"
printf '%s\n' "$sha" > "$d/work/ci/push-secrets-accepted.txt"
OUT=$( cd "$d/work" || exit 1; HOME="$d/home" bash ./check-push-secrets.sh 2>&1 ); RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "no reason"; then ok "an acceptance with no stated reason REDS"
else red "case 11 — a bare sha with no reason was honoured as an acceptance (rc=$RC)"; fi
rm -rf "$d"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "==> test-check-push-secrets: ok ($PASS case(s), 0 red)"
else
  echo "==> test-check-push-secrets: FAILED ($FAIL red, $PASS ok)" >&2
  exit 1
fi
