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

# ── 10c/10d. A PATH hit is accepted by the SHA OF THE TREE carrying the entry,
#        never by name: the name IS a configured value, so a `path:<name>` key
#        would write the value into the tracked acceptance file. The same name
#        in a DIFFERENT tree is a different publication and must still red.
d=$(mkrepo)
( cd "$d/work" || exit 1; mkdir keys && : > "keys/AuthKey_${V_KEYID}.p8" && "$GIT" add -A && "$GIT" commit -qm "a key-named entry in a subtree" ) >/dev/null 2>&1
tsha=$( cd "$d/work" || exit 1; "$GIT" rev-parse HEAD:keys )
mkdir -p "$d/work/ci"
printf '%s   # selftest: the tree carrying the key-named entry, accepted on purpose\n' "$tsha" > "$d/work/ci/push-secrets-accepted.txt"
run "$d"
if need_valid "case 10c"; then
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qa "ACCEPTED: PATH NAME"; then ok "a PATH hit accepted by its TREE sha is suppressed and still printed with its reason"
  else red "case 10c — accepting the carrying tree's sha did not green the gate (rc=$RC): $(printf '%s' "$OUT" | tail -2)"; fi
fi
# A one-entry subtree holding the same empty blob would be the SAME tree object,
# so the second tree carries one more entry.
( cd "$d/work" || exit 1; mkdir other && : > "other/AuthKey_${V_KEYID}.p8" && printf 'x\n' > other/README.md && "$GIT" add -A && "$GIT" commit -qm "the same name in a different tree" ) >/dev/null 2>&1
run "$d"
if need_valid "case 10d"; then
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "HIT: a PATH NAME"; then ok "the same NAME in a DIFFERENT tree is not covered by that acceptance and still goes RED"
  else red "case 10d — an acceptance keyed on one tree silenced the same name in another tree (rc=$RC)"; fi
fi
rm -rf "$d"

# ── 11b. a tree-sha entry with no reason is a RED, like any other bare key.
d=$(mkrepo)
( cd "$d/work" || exit 1; mkdir keys && : > "keys/AuthKey_${V_KEYID}.p8" && "$GIT" add -A && "$GIT" commit -qm "a key-named entry" ) >/dev/null 2>&1
tsha=$( cd "$d/work" || exit 1; "$GIT" rev-parse HEAD:keys )
mkdir -p "$d/work/ci"
printf '%s\n' "$tsha" > "$d/work/ci/push-secrets-accepted.txt"
OUT=$( cd "$d/work" || exit 1; HOME="$d/home" bash ./check-push-secrets.sh 2>&1 ); RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "no reason"; then ok "a tree-sha acceptance with no stated reason REDS"
else red "case 11b — a bare tree sha with no reason was honoured as an acceptance (rc=$RC)"; fi
rm -rf "$d"

# ── 12. THE MEASURED NO-EDIT FALSE-GREEN. The remote already holds an empty
#        .gitkeep; an unpushed commit adds an EMPTY file whose NAME carries the
#        key id. `rev-list --objects` lists that blob once, under its FIRST path
#        (.gitkeep, already published), so a gate reading the path column sees
#        no key-named path at all and printed `ok (3 object(s): 0 blob, 1
#        commit, 2 tree ...)`. The name is published content: it lives in the
#        NEW tree's entries.
d=$(mkrepo)
( cd "$d/work" || exit 1
  : > .gitkeep && "$GIT" add -A && "$GIT" commit -qm "an empty placeholder" && "$GIT" push -q origin HEAD:refs/heads/main
  mkdir keys && : > "keys/AuthKey_${V_KEYID}.p8" && "$GIT" add -A && "$GIT" commit -qm "add an empty key-named file" ) >/dev/null 2>&1
run "$d"
if need_valid "case 12"; then
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "HIT: a PATH NAME.*keys/"; then ok "an EMPTY key-named file whose bytes the remote already has goes RED (the measured no-edit false-green)"
  else red "case 12 — the measured no-edit repro did NOT go red (rc=$RC): $(printf '%s' "$OUT" | tail -1)"; fi
fi
rm -rf "$d"

# ── 13. THE PATH LEG OF THE CONTROL MUST BE ABLE TO FAIL. Blind the path leg's
#        grep and the control must red BY NAME. With ORed legs and every path
#        plant holding the same bytes as the message plant, the path leg never
#        fired in the control at all and blinding it changed nothing.
d=$(mkrepo)
( cd "$d/work" || exit 1; printf 'nothing here\n' > fine.md && "$GIT" add -A && "$GIT" commit -qm "clean" ) >/dev/null 2>&1
sed -i '' 's|grep -naF -f "\$TMP/pat.\$i" "\$TMP/paths.names"|true|' "$d/work/check-push-secrets.sh"
if [ "$(grep -ac '^      done < <(true || true)$' "$d/work/check-push-secrets.sh")" -eq 1 ]; then
  OUT=$( cd "$d/work" || exit 1; HOME="$d/home" bash ./check-push-secrets.sh 2>&1 ); RC=$?
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "RED: control.*PATH NAME"; then
    ok "blinding the path leg makes the CONTROL fail by name (every leg must fire: AND, not OR)"
  else
    red "case 13 — the path leg was blinded and the gate still reported (rc=$RC). The control's path leg cannot fail."
  fi
else
  red "case 13 — the mutation did not apply (anchor count != 1), so this case proved nothing"
fi
rm -rf "$d"

# ── 14. THE COMMIT-MESSAGE LEG, likewise. Under an ORed control the blob leg
#        alone kept this green.
d=$(mkrepo)
( cd "$d/work" || exit 1; printf 'nothing here\n' > fine.md && "$GIT" add -A && "$GIT" commit -qm "clean" ) >/dev/null 2>&1
sed -i '' "s|cat-file commit \"\$sha\" 2>/dev/null \| sed '1,/^\$/d'|cat-file commit \"\$sha\" 2>/dev/null \| sed '1,\$d'|" "$d/work/check-push-secrets.sh"
if [ "$(grep -ac "cat-file commit \"\$sha\" 2>/dev/null | sed '1,\$d'" "$d/work/check-push-secrets.sh")" -eq 1 ]; then
  OUT=$( cd "$d/work" || exit 1; HOME="$d/home" bash ./check-push-secrets.sh 2>&1 ); RC=$?
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "RED: control.*commit message"; then
    ok "blinding the commit-message leg makes the CONTROL fail by name"
  else
    red "case 14 — the commit-message leg was blinded and the gate still reported (rc=$RC)."
  fi
else
  red "case 14 — the mutation did not apply (anchor count != 1), so this case proved nothing"
fi
rm -rf "$d"

# ── 15. A STALE `path:` KEY. The key form was removed with the first-path
#        column; a fork carrying the documented upstream form would otherwise go
#        from ACCEPTED to FAILED with the stale key still parsing and nothing
#        naming the cause. It is a RED that names the LINE, never the key: a
#        path key's text is a configured value, and this file is tracked.
d=$(mkrepo)
( cd "$d/work" || exit 1; mkdir keys && : > "keys/AuthKey_${V_KEYID}.p8" && "$GIT" add -A && "$GIT" commit -qm "a key-named entry" ) >/dev/null 2>&1
mkdir -p "$d/work/ci"
printf '# a fork upgrading from the documented upstream form\npath:keys/AuthKey_%s.p8   # ruled acceptable under the old key form\n' "$V_KEYID" > "$d/work/ci/push-secrets-accepted.txt"
OUT=$( cd "$d/work" || exit 1; HOME="$d/home" bash ./check-push-secrets.sh 2>&1 ); RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qa "removed 'path:<name>' key form" && printf '%s' "$OUT" | grep -qa "line 2"; then
  if printf '%s' "$OUT" | grep -qa "AuthKey_${V_KEYID}"; then
    red "case 15 — the RED named the stale key, which IS a configured value; it must name the line only"
  else
    ok "a stale path: acceptance key REDS, naming the line and the way out, and never echoing the key"
  fi
else red "case 15 — a stale path: key did not red with the cause named (rc=$RC)"; fi
rm -rf "$d"

# ── 16. A needle containing '/' is planted as a NESTED path, so the path legs
#        are PROVEN for it rather than exempted. (ASC_API_KEY_P8_PATH's basename
#        is a needle; a fork whose value carries a slash used to skip both legs
#        while the control line still claimed all four.)
d=$(mkrepo)
( cd "$d/work" || exit 1
  printf 'APP_EMAIL=%s\nBETA_APP_FEEDBACK_EMAIL=%s\nASC_API_KEY_ID=%s\nAPP_REVIEW_DEMO_USER=%s\n' \
    "$V_APP" "$V_BETA" "$V_KEYID" 'demo/user/selftest' > .bootstrap.env
  printf 'clean\n' > fine.md && "$GIT" add -A && "$GIT" commit -qm "clean" ) >/dev/null 2>&1
run "$d"
if need_valid "case 16"; then
  if printf '%s' "$OUT" | grep -qa "exempt from the path legs only"; then
    red "case 16 — a '/'-bearing needle was exempted from the path legs instead of planted as a nested path"
  else ok "a needle containing '/' is planted as a nested path: no leg is claimed that was not run"; fi
fi
rm -rf "$d"

# ── 17. A needle a filesystem cannot hold as one path component (a base64 key
#        blob is the real case) must not kill the control: the plant is guarded,
#        the needle is exempt from the path legs ONLY, and the control says so.
#        Unguarded, the redirect died inside the control with "File name too
#        long" -- no verdict, rc 1, and the template's pre-push hook renders that
#        as "this push would upload a configured value". The error text also
#        carried the value, which this gate's header promises never happens.
d=$(mkrepo)
long=$(printf 'Z%.0s' $(seq 1 400))
( cd "$d/work" || exit 1
  printf 'APP_EMAIL=%s\nBETA_APP_FEEDBACK_EMAIL=%s\nASC_API_KEY_ID=%s\nASC_API_KEY_P8_BASE64=%s\n' \
    "$V_APP" "$V_BETA" "$V_KEYID" "$long" > .bootstrap.env
  printf 'clean\n' > fine.md && "$GIT" add -A && "$GIT" commit -qm "clean" ) >/dev/null 2>&1
run "$d"
if need_valid "case 17"; then
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qa "could not be planted as a path" && ! printf '%s' "$OUT" | grep -qa "File name too long"; then
    ok "a needle too long to be a path component leaves the control GREEN, exempt from the path legs only, with no filesystem error text"
  else red "case 17 — a long needle broke the control or leaked an error (rc=$RC): $(printf '%s' "$OUT" | grep -a 'too long' | cut -c1-90)"; fi
fi
( cd "$d/work" || exit 1; printf 'the value is %s here\n' "$V_APP" > leak.md && "$GIT" add -A && "$GIT" commit -qm "leak" ) >/dev/null 2>&1
run "$d"
if need_valid "case 17b"; then
  if [ "$RC" -ne 0 ]; then ok "and the gate still catches a real leak with that needle set (the exemption narrows one leg, not the scan)"
  else red "case 17b — with a long needle configured the gate went green over a leak (rc=$RC)"; fi
fi
rm -rf "$d"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "==> test-check-push-secrets: ok ($PASS case(s), 0 red)"
else
  echo "==> test-check-push-secrets: FAILED ($FAIL red, $PASS ok)" >&2
  exit 1
fi
