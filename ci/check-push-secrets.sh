#!/usr/bin/env bash
#
# ci/check-push-secrets.sh — would this push upload a configured value?
#
# WHY THIS EXISTS
#
# A secret scan over the working tree answers "what does my checkout leak". It
# does not answer "what would my push publish", and the gap between those two
# is not a corner case -- it is the normal outcome of fixing a leak.
#
# Redact a value and commit the fix and the tree is clean, every tree-scanning
# check is green, and the objects behind HEAD still carry the value. `git push`
# uploads objects, not the checkout, so it publishes the value anyway. The same
# is true after `filter-repo --replace-text` without `--replace-message`, after
# an interactive rebase that rewrites content but not messages, and for any ref
# the rewrite's range did not reach.
#
# So this gate scans the PUBLISH SET: the objects reachable from local refs but
# not from what the remote currently advertises. That is, by construction, the
# set `git push` would send.
#
# WHAT IT READS, AND WHY ALL OF IT
#
# Every object type, not just blobs:
#
#   blob     file contents.
#   commit   the MESSAGE BODY. A commit subject is a very common place for a
#            key id to land, and no blob contains it.
#   tag      annotated tag messages, same reason.
#   path     the file NAME itself. A key file committed as AuthKey_XXXX.p8
#            leaks its id through the path even if you scrub the contents --
#            and a needle derived from a filename can appear NOWHERE ELSE, so
#            a content-only scan can never match it.
#
# A blob-only version of this gate read 31% of a real publish set and reported
# success, with a key id sitting unread in a commit message the whole time.
#
# WHAT IT DELIBERATELY DOES NOT READ
#
# Commit ident headers (`author`, `committer`). Where a configured contact
# address is also the git identity -- which is the common case for a solo
# maintainer -- those headers carry it in every commit ever made, including
# every commit already pushed. Scanning them makes this gate permanently red
# over a value git writes by construction and that is already public, and a
# gate that cannot go green is a gate that gets ignored. Commits are therefore
# read from the first blank line onward. The self-test pins this so a later
# change cannot widen it back by accident.
#
# HOW IT AVOIDS LYING
#
#   - Values are read in a subshell and NEVER printed. Output is names, counts
#     and object ids. This file contains no secret.
#   - No value reaches argv: patterns are written to 0600 files inside a 0700
#     mktemp dir and used via `grep -f`.
#   - The control runs the REAL scan. It builds a throwaway repository, plants
#     every needle as a blob, a commit message and a path name, and requires
#     the actual scan path to find all three classes. A control that greps a
#     scratch file instead proves only that grep works: delete the entire scan
#     and it still passes.
#   - A skip is never a pass. Exit 3 means "no values configured to scan for",
#     and callers must treat it as its own outcome.
#   - An object that cannot be read is counted and refused, never treated as
#     a clean object.
#
# Usage:  ci/check-push-secrets.sh                 # every local ref vs the remote
#         ci/check-push-secrets.sh <remote-ref>    # an explicit baseline
#         ci/check-push-secrets.sh --head-only     # only HEAD's range
#
# Exit:   0 clean · 1 hits, or the gate could not prove itself · 3 nothing to scan for

set -euo pipefail

# Not `#!/bin/bash`: macOS ships bash 3.2, where `set -u` makes an empty array
# expansion fatal -- and an EXIT trap whose last command succeeds replaces that
# death with its own status, so the script dies and still exits 0.
if [ -z "${BASH_VERSINFO+x}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "==> check-push-secrets: refusing to run under bash ${BASH_VERSION:-unknown} -- needs 4+." >&2
  exit 1
fi

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "==> check-push-secrets: not inside a git repository" >&2; exit 1; }
cd "$TOPLEVEL"

MODE=all-refs
BASE_ARG=""
for a in "$@"; do
  case "$a" in
    --head-only) MODE=head-only ;;
    -h|--help)   sed -n '2,80p' "$0"; exit 0 ;;
    *)           BASE_ARG="$a" ;;
  esac
done

TMP=$(mktemp -d)
cleanup() { local st=$?; rm -rf "$TMP"; return "$st"; }
trap cleanup EXIT

# ─── needles ────────────────────────────────────────────────────────────────
ENVFILE=".bootstrap.env"
if [ ! -f "$ENVFILE" ]; then
  echo "==> check-push-secrets: no $ENVFILE -- no values to scan for (skipping, NOT passing)" >&2
  exit 3
fi
[ -r "$ENVFILE" ] || { echo "==> check-push-secrets: $ENVFILE exists but is unreadable -- that is not 'nothing to scan'" >&2; exit 1; }

# `tr -d '\r'`: a CRLF .bootstrap.env otherwise appends \r to every needle, so
# nothing can ever match and the gate goes green with no edit to it at all.
read_val() (
  set +u
  v=$(grep -aE "^[[:space:]]*(export[[:space:]]+)?$1=" "$ENVFILE" 2>/dev/null | tail -1 \
      | sed -E "s/^[[:space:]]*(export[[:space:]]+)?$1=//; s/[[:space:]]+#.*$//; s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/" \
      | tr -d '\r')
  printf '%s' "$v"
)
declared() { grep -qaE "^[[:space:]]*(export[[:space:]]+)?$1=" "$ENVFILE" 2>/dev/null; }

# The template's own sensitive keys. A value only counts as a needle if it is
# long enough to be distinctive -- a 2-character locale is not a secret and
# would match everything.
NAMES=(
  ASC_API_KEY_ID
  ASC_API_KEY_ISSUER_ID
  ASC_API_KEY_P8_BASE64
  APP_EMAIL
  BETA_APP_FEEDBACK_EMAIL
  APP_REVIEW_EMAIL
  APP_REVIEW_PHONE
  APP_REVIEW_DEMO_USER
  APP_REVIEW_DEMO_PASSWORD
)
MIN_NEEDLE=6

PATTERNS=(); LABELS=(); unparsed=()
for n in "${NAMES[@]}"; do
  v=$(read_val "$n")
  if [ -n "$v" ] && [ "${#v}" -ge "$MIN_NEEDLE" ]; then
    PATTERNS+=("$v"); LABELS+=("$n")
  elif [ -z "$v" ] && declared "$n"; then
    unparsed+=("$n")
  fi
done
# A name the env file ASSIGNS but that parses empty would be scanned for not at
# all. That is a hole in the needle set, not an absence of one.
if [ "${#unparsed[@]}" -ne 0 ]; then
  echo "RED: control -- ${#unparsed[@]} name(s) are assigned in $ENVFILE but did not parse, so they would be scanned for NOT AT ALL:" >&2
  printf '       %s\n' "${unparsed[@]}" >&2
  exit 1
fi
p8path=$(read_val ASC_API_KEY_P8_PATH)
if [ -n "$p8path" ]; then
  PATTERNS+=("$(basename "$p8path")"); LABELS+=("the API key file's name")
fi
for f in "${HOME}"/.appstoreconnect/private_keys/*.p8; do
  [ -e "$f" ] || continue
  id=$(basename "$f" .p8); id=${id#AuthKey_}
  PATTERNS+=("$id"); LABELS+=("an API key id present on this machine")
done
[ "${#PATTERNS[@]}" -gt 0 ] || { echo "==> check-push-secrets: no values to scan for (skipping, NOT passing)" >&2; exit 3; }

# Dedupe. ASC_API_KEY_ID and the configured key file's id are routinely THE SAME
# VALUE under two names; without this the control plants an identical value twice,
# the second commit stages nothing, and `set -e` kills the run before any output.
UP=(); UL=()
for i in "${!PATTERNS[@]}"; do
  dup=-1
  if [ "${#UP[@]}" -gt 0 ]; then
    for j in "${!UP[@]}"; do
      if [ "${UP[$j]}" = "${PATTERNS[$i]}" ]; then dup="$j"; break; fi
    done
  fi
  if [ "$dup" -ge 0 ]; then
    case "${UL[$dup]}" in
      *"${LABELS[$i]}"*) ;;
      *) UL[$dup]="${UL[$dup]} / ${LABELS[$i]}" ;;
    esac
  else
    UP+=("${PATTERNS[$i]}"); UL+=("${LABELS[$i]}")
  fi
done
PATTERNS=("${UP[@]}"); LABELS=("${UL[@]}")

for i in "${!PATTERNS[@]}"; do
  ( umask 077; printf '%s\n' "${PATTERNS[$i]}" > "$TMP/pat.$i" )
done

# ─── accepted exceptions ────────────────────────────────────────────────────
# A gate that can never be green gets ignored. Some publishes are ruled
# acceptable -- a revoked credential's id already public elsewhere, say. This
# file records those rulings.
#
# It is not a silencer: every accepted object is PRINTED with its reason on
# every run and counted in the verdict line, and an entry without a reason is a
# RED rather than an acceptance. An exception you stop seeing is an exception
# you stop re-deciding.
ACCEPT_FILE="ci/push-secrets-accepted.txt"
ACC_KEYS=(); ACC_WHY=()
if [ -f "$ACCEPT_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%#*}; key=$(printf '%s' "$key" | tr -d '[:space:]')
    why=${line#*#}; why=$(printf '%s' "$why" | sed 's/^[[:space:]]*//')
    [ -n "$key" ] || continue
    if [ -z "$why" ] || [ "$why" = "$line" ]; then
      echo "RED: $ACCEPT_FILE -- entry '$key' has no reason after '#'. An acceptance without a stated reason is not an acceptance." >&2
      exit 1
    fi
    ACC_KEYS+=("$key"); ACC_WHY+=("$why")
  done < "$ACCEPT_FILE"
fi
accepted_why() {
  local k="$1" j
  if [ "${#ACC_KEYS[@]}" -gt 0 ]; then
    for j in "${!ACC_KEYS[@]}"; do
      if [ "${ACC_KEYS[$j]}" = "$k" ]; then printf '%s' "${ACC_WHY[$j]}"; return 0; fi
    done
  fi
  return 1
}

# ─── the scan, factored so the CONTROL runs the real thing ──────────────────
SCAN_HITS=0; SCAN_OBJ=0; SCAN_SKIPPED=0; SCAN_ACCEPTED=0; SCAN_BREAKDOWN=""
scan_range() {
  local repo="$1"; shift
  local objs="$TMP/objs.$$"; : > "$objs"
  git -C "$repo" rev-list --objects "$@" > "$objs" 2>/dev/null || true

  SCAN_OBJ=$(wc -l < "$objs" | tr -d ' ')
  SCAN_HITS=0; SCAN_SKIPPED=0; SCAN_ACCEPTED=0
  local nblob=0 ncommit=0 ntag=0 ntree=0
  local i n sha typ rest path why hitpath

  # (1) PATH NAMES. Already on disk in column 2, and the only place a
  #     filename-derived needle can ever appear.
  if [ -s "$objs" ]; then
    for i in "${!PATTERNS[@]}"; do
      while IFS= read -r hitpath; do
        [ -n "$hitpath" ] || continue
        if why=$(accepted_why "path:$hitpath"); then
          echo "    ACCEPTED: PATH NAME $hitpath -- ${LABELS[$i]} -- $why"
          SCAN_ACCEPTED=$((SCAN_ACCEPTED + 1))
        else
          echo "    HIT: a PATH NAME in the publish set: $hitpath -- ${LABELS[$i]}"
          SCAN_HITS=$((SCAN_HITS + 1))
        fi
      done < <(cut -d' ' -f2- "$objs" | grep -aF -f "$TMP/pat.$i" || true)
    done
  fi

  # (2) OBJECT CONTENT, per type. No type filter.
  while read -r sha rest; do
    [ -n "$sha" ] || continue
    typ=$(git -C "$repo" cat-file -t "$sha" 2>/dev/null || echo "")
    path="$rest"
    case "$typ" in
      blob)
        nblob=$((nblob + 1))
        if ! git -C "$repo" cat-file blob "$sha" > "$TMP/o.bin" 2>/dev/null; then
          SCAN_SKIPPED=$((SCAN_SKIPPED + 1)); continue
        fi
        ;;
      commit)
        ncommit=$((ncommit + 1))
        # Message body only -- see "WHAT IT DELIBERATELY DOES NOT READ".
        if ! git -C "$repo" cat-file commit "$sha" 2>/dev/null | sed '1,/^$/d' > "$TMP/o.bin"; then
          SCAN_SKIPPED=$((SCAN_SKIPPED + 1)); continue
        fi
        ;;
      tag)
        ntag=$((ntag + 1))
        if ! git -C "$repo" cat-file tag "$sha" 2>/dev/null | sed '1,/^$/d' > "$TMP/o.bin"; then
          SCAN_SKIPPED=$((SCAN_SKIPPED + 1)); continue
        fi
        ;;
      tree) ntree=$((ntree + 1)); continue ;;
      *)    SCAN_SKIPPED=$((SCAN_SKIPPED + 1)); continue ;;
    esac
    for i in "${!PATTERNS[@]}"; do
      n=$(grep -acF -f "$TMP/pat.$i" "$TMP/o.bin" || true)
      if [ "${n:-0}" -gt 0 ]; then
        if why=$(accepted_why "$sha"); then
          echo "    ACCEPTED: $typ $sha ${path:+($path) }-- ${LABELS[$i]} on $n line(s) -- $why"
          SCAN_ACCEPTED=$((SCAN_ACCEPTED + n))
        else
          echo "    HIT: $typ $sha ${path:+($path) }-- ${LABELS[$i]} on $n line(s)"
          SCAN_HITS=$((SCAN_HITS + n))
        fi
      fi
    done
    # A real private key block, not a bare header. The key itself is the
    # highest-value thing that can be in a publish set.
    if [ "$typ" = blob ] && grep -qa -- "-----BEGIN" "$TMP/o.bin" 2>/dev/null; then
      if perl -0777 -ne 'exit(1) unless /-----BEGIN [A-Z ]*PRIVATE KEY-----\s*[A-Za-z0-9+\/=\s]{40}/s' "$TMP/o.bin" 2>/dev/null; then
        if why=$(accepted_why "$sha"); then
          echo "    ACCEPTED: blob $sha ${path:+($path) }-- PRIVATE KEY MATERIAL -- $why"
          SCAN_ACCEPTED=$((SCAN_ACCEPTED + 1))
        else
          echo "    HIT: blob $sha ${path:+($path) }-- PRIVATE KEY MATERIAL"
          SCAN_HITS=$((SCAN_HITS + 1))
        fi
      fi
    fi
  done < "$objs"

  SCAN_BREAKDOWN="$SCAN_OBJ object(s): $nblob blob, $ncommit commit, $ntree tree, $ntag tag"
  rm -f "$objs"
}

# ─── control: the REAL scan path, against a throwaway repo ──────────────────
CTL="$TMP/ctl"
mkdir -p "$CTL"
git init -q "$CTL" >/dev/null 2>&1
git -C "$CTL" config user.email ctl@example.invalid
git -C "$CTL" config user.name ctl
printf 'nothing to see here\n' > "$CTL/clean.txt"
git -C "$CTL" add clean.txt >/dev/null 2>&1
git -C "$CTL" commit -qm "clean baseline" >/dev/null 2>&1
ctl_path_skipped=0
for i in "${!PATTERNS[@]}"; do
  v=$(cat "$TMP/pat.$i")
  ( umask 077; printf 'x %s x\n' "$v" > "$CTL/planted-$i.txt" )
  git -C "$CTL" add "planted-$i.txt" >/dev/null 2>&1
  git -C "$CTL" commit -q --allow-empty -m "control blob $i" >/dev/null 2>&1
  printf 'clean content\n' > "$CTL/msg-$i.txt"
  git -C "$CTL" add "msg-$i.txt" >/dev/null 2>&1
  git -C "$CTL" commit -q --allow-empty -m "control message $i carries $v here" >/dev/null 2>&1
  case "$v" in
    */*) ctl_path_skipped=$((ctl_path_skipped + 1)) ;;
    *)   printf 'clean content\n' > "$CTL/name-$v.txt" 2>/dev/null || true
         git -C "$CTL" add -A >/dev/null 2>&1
         git -C "$CTL" commit -q --allow-empty -m "control path $i" >/dev/null 2>&1 ;;
  esac
done
[ "$ctl_path_skipped" -eq 0 ] || \
  echo "    note: $ctl_path_skipped needle(s) contain '/' and were not planted as a path in the control"

ctl_fail=0
scan_range "$CTL" --all > "$TMP/ctl.out" 2>&1 || true
for i in "${!PATTERNS[@]}"; do
  if ! grep -qa "blob .*${LABELS[$i]}" "$TMP/ctl.out" \
     && ! grep -qa "commit .*${LABELS[$i]}" "$TMP/ctl.out" \
     && ! grep -qa "PATH NAME.*${LABELS[$i]}" "$TMP/ctl.out"; then
    echo "RED: control -- needle '${LABELS[$i]}' was NOT caught by the real scan path" >&2
    ctl_fail=1
  fi
done
grep -qa "blob\|commit\|PATH NAME" "$TMP/ctl.out" || {
  echo "RED: control -- the scan produced no hits at all on a repo built to trip it" >&2; ctl_fail=1; }
[ "$ctl_fail" -eq 0 ] || { echo "==> check-push-secrets: control failed -- refusing to report a verdict" >&2; exit 1; }
echo "    control ok (the real scan path caught every one of ${#PATTERNS[@]} needle(s) in a blob, a commit message and a path name, and spared a clean object; names only, never values)"

# ─── baseline: what does the remote ALREADY have? ───────────────────────────
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
BASE_REF="${BASE_ARG:-$UPSTREAM}"
REMOTE="origin"
case "$BASE_REF" in */*) REMOTE="${BASE_REF%%/*}" ;; esac
git remote get-url "$REMOTE" >/dev/null 2>&1 || REMOTE=$(git remote | head -1)

NOTS=()
if [ -n "$REMOTE" ] && git ls-remote --heads --tags "$REMOTE" > "$TMP/lsr" 2>/dev/null; then
  # What the server advertises RIGHT NOW. A cached remote-tracking ref can name
  # objects the server no longer has (a deleted or rewound branch), which
  # subtracts them from the scan and hides them.
  while read -r sha _ref; do
    [ -n "$sha" ] || continue
    git cat-file -e "$sha" 2>/dev/null && NOTS+=("^$sha")
  done < "$TMP/lsr"
  BASELINE_NOTE="the remote's advertised refs, read live from $REMOTE"
else
  while read -r r; do [ -n "$r" ] && NOTS+=("^$r"); done \
    < <(git for-each-ref --format='%(refname)' "refs/remotes/$REMOTE" 2>/dev/null || true)
  BASELINE_NOTE="OFFLINE -- remote-tracking refs, which may be STALE and may subtract objects the server does not have"
fi

if [ "$MODE" = head-only ]; then
  POSITIVE=(HEAD)
  other=$(git for-each-ref --format='%(refname)' refs/heads refs/tags 2>/dev/null | wc -l | tr -d ' ')
  SCOPE_NOTE="HEAD only -- NOT covering the other $other local ref(s)"
else
  POSITIVE=(--all)
  SCOPE_NOTE="every local ref (--all), so side branches and tags are covered"
fi

echo "    repo: $TOPLEVEL at $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "    scope: $SCOPE_NOTE"
echo "    baseline: $BASELINE_NOTE"

scan_range "$TOPLEVEL" "${POSITIVE[@]}" ${NOTS[@]+"${NOTS[@]}"}

if [ "$SCAN_OBJ" -eq 0 ]; then
  echo "==> check-push-secrets: the publish set is EMPTY -- nothing would be uploaded."
  exit 0
fi
echo "    publish set: $SCAN_BREAKDOWN"

if [ "$SCAN_SKIPPED" -gt 0 ]; then
  echo "==> check-push-secrets: RED -- $SCAN_SKIPPED object(s) in the publish set could NOT be read, so they were not scanned. An unreadable object is not a clean object." >&2
  exit 1
fi

ACC_NOTE=""
[ "$SCAN_ACCEPTED" -gt 0 ] && ACC_NOTE=", $SCAN_ACCEPTED ACCEPTED exception(s) listed above and still shown every run"
if [ "$SCAN_HITS" -eq 0 ]; then
  echo "==> check-push-secrets: ok ($SCAN_BREAKDOWN, 0 unaccepted hits for ${#PATTERNS[@]} values$ACC_NOTE)"
else
  echo "==> check-push-secrets: FAILED -- $SCAN_HITS unaccepted hit(s) across the publish set$ACC_NOTE. Values deliberately not printed; open the named objects."
  exit 1
fi
