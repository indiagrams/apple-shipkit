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
#            a content-only scan can never match it. Paths are read from the
#            ENTRIES of every tree object in the publish set, not from
#            `rev-list --objects`' path column: that column names each blob
#            once, under the first path it was seen at, so a value-named file
#            whose bytes the remote already has (an EMPTY file is the common
#            case) has no row there. A version that read the column printed
#            "ok" over exactly that: the remote holding an empty .gitkeep and
#            one unpushed commit adding an empty keys/AuthKey_<id>.p8.
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
#     every needle as a blob, a commit message, a path name and a path name
#     over bytes already in the repository, each plant with unique bytes, and
#     requires the actual scan path to find EVERY leg (AND, not OR). A control
#     that greps a scratch file instead proves only that grep works: delete the
#     entire scan and it still passes. A control whose legs are ORed proves
#     less than it says: a leg that never fires is carried by the others.
#   - A PATH hit is accepted by the sha of the TREE that carries the entry,
#     never by the path's name -- the name IS a configured value, and a
#     `path:<name>` key would write it into the tracked acceptance file.
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

# ─── the tree walker: every ENTRY NAME of every new tree, as a full path ────
# Reads a `git cat-file --batch` stream of the publish set's TREE objects on
# stdin (raw tree bytes: "<mode> <name>\0<20-byte sha>" per entry) and a file of
# root tree shas (one per new commit), and writes two parallel files: the full
# path of every entry, and the sha of the tree that carries it. Only trees in
# the publish set are descended into -- an unchanged subtree is already on the
# remote and so is every name inside it. A tree no new commit's root reaches
# (a tag on a tree, a dangling ref) is still walked, from itself.
cat > "$TMP/treepaths.pl" <<'PERL'
use strict; use warnings;
my ($roots_file, $names_out, $trees_out) = @ARGV;
binmode STDIN;
my %kids;
while (defined(my $hdr = <STDIN>)) {
  chomp $hdr;
  my @h = split / /, $hdr;
  next if @h < 3;                                   # "<sha> missing"
  my ($sha, $type, $size) = @h;
  my $buf = '';
  if ($size > 0) { (read(STDIN, $buf, $size) // 0) == $size or die "short read on $sha\n"; }
  read(STDIN, my $nl, 1);
  next unless $type eq 'tree';
  my $pos = 0;
  while ($pos < length $buf) {
    my $sp  = index($buf, ' ', $pos);
    my $nul = index($buf, "\0", $sp);
    my $mode  = substr($buf, $pos, $sp - $pos);
    my $name  = substr($buf, $sp + 1, $nul - $sp - 1);
    my $child = unpack('H40', substr($buf, $nul + 1, 20));
    $pos = $nul + 21;
    push @{ $kids{$sha} }, [$mode, $child, $name];
  }
}
open my $on, '>', $names_out or die "$names_out: $!";
open my $ot, '>', $trees_out or die "$trees_out: $!";
my %seen;
sub walk {
  my @q = ([$_[0], $_[1]]);
  while (my $it = shift @q) {
    my ($t, $p) = @$it;
    next if $seen{"$t $p"}++;
    next unless $kids{$t};
    for my $k (@{ $kids{$t} }) {
      my ($mode, $child, $name) = @$k;
      (my $path = $p . $name) =~ s/[\r\n]/?/g;      # one line per entry, whatever the name holds
      print $on "$path\n"; print $ot "$t\n";
      push @q, [$child, "$path/"] if $mode eq '40000' && $kids{$child};
    }
  }
}
open my $r, '<', $roots_file or die "$roots_file: $!";
while (<$r>) { chomp; walk($_, '') if length; }
close $r;
my %reached = map { (split / /, $_)[0] => 1 } keys %seen;
for my $t (sort keys %kids) { walk($t, '(tree ' . substr($t, 0, 7) . ')/') unless $reached{$t}; }
close $on; close $ot;
PERL

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
  acc_lineno=0
  while IFS= read -r line; do
    acc_lineno=$((acc_lineno + 1))
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%#*}; key=$(printf '%s' "$key" | tr -d '[:space:]')
    why=${line#*#}; why=$(printf '%s' "$why" | sed 's/^[[:space:]]*//')
    [ -n "$key" ] || continue
    # The `path:<name>` key form is GONE, and a stale one must not read as an
    # unknown key that quietly matches nothing. The line number is named, never
    # the key: a path key's text IS a configured value, which is the whole
    # reason the form was removed.
    case "$key" in
      path:*)
        echo "RED: $ACCEPT_FILE line $acc_lineno -- this entry uses the removed 'path:<name>' key form, so it no longer suppresses anything and the hit it was written for is RED again." >&2
        echo "     A PATH NAME hit is now accepted by the SHA OF THE TREE that carries the entry, which every run prints beside the hit. Replace the entry with that sha and its reason." >&2
        echo "     The form was removed because the key's own text is a configured value, and this file is tracked: writing it here publishes what the gate exists to catch." >&2
        exit 1 ;;
    esac
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

  # (1) PATH NAMES -- the only place a filename-derived needle can ever appear.
  #     NOT read from rev-list's path column (see the header): the ENTRIES of
  #     every new tree, one `cat-file --batch` for all of them, with full paths
  #     built from the new commits' root trees.
  local hitline lineno treesha
  : > "$TMP/paths.names"; : > "$TMP/paths.trees"
  if [ -s "$objs" ]; then
    cut -d' ' -f1 "$objs" \
      | git -C "$repo" cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
      | awk '$2 == "tree" { print $1 }' > "$TMP/treeshas" || true
    git -C "$repo" rev-list --no-commit-header --format='%T' "$@" > "$TMP/roots" 2>/dev/null || true
    if [ -s "$TMP/treeshas" ]; then
      git -C "$repo" cat-file --batch < "$TMP/treeshas" 2>/dev/null \
        | perl "$TMP/treepaths.pl" "$TMP/roots" "$TMP/paths.names" "$TMP/paths.trees"
    fi
    for i in "${!PATTERNS[@]}"; do
      while IFS= read -r hitline; do
        [ -n "$hitline" ] || continue
        lineno=${hitline%%:*}; hitpath=${hitline#*:}
        treesha=$(sed -n "${lineno}p" "$TMP/paths.trees")
        if why=$(accepted_why "$treesha"); then
          echo "    ACCEPTED: PATH NAME $hitpath (tree $treesha) -- ${LABELS[$i]} -- $why"
          SCAN_ACCEPTED=$((SCAN_ACCEPTED + 1))
        else
          echo "    HIT: a PATH NAME in the publish set: $hitpath (tree $treesha) -- ${LABELS[$i]}"
          SCAN_HITS=$((SCAN_HITS + 1))
        fi
      done < <(grep -naF -f "$TMP/pat.$i" "$TMP/paths.names" || true)
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
      tree) ntree=$((ntree + 1)); continue ;;   # entries were read by the path leg's tree walk
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
declare -A CTL_PATH_PLANTED=()
mkdir -p "$CTL"
git init -q "$CTL" >/dev/null 2>&1
git -C "$CTL" config user.email ctl@example.invalid
git -C "$CTL" config user.name ctl
printf 'nothing to see here\n' > "$CTL/clean.txt"
git -C "$CTL" add clean.txt >/dev/null 2>&1
git -C "$CTL" commit -qm "clean baseline" >/dev/null 2>&1
# Every plant has UNIQUE bytes: two plants with identical bytes are ONE blob,
# listed once, and a leg can quietly never fire. One path plant per needle
# deliberately repeats an already-committed blob (clean.txt's bytes) under a
# value-named path -- the shape the first-path column could never show.
#
# A value containing '/' is planted as a NESTED path, so the path legs are
# proven for it too. A value the filesystem refuses -- one longer than a path
# component may be, say a base64 key blob -- cannot be planted at all: that
# needle is EXEMPT from the path legs only, counted and named on the control
# line. The plants are guarded, because an unguarded failure here kills the
# control with no verdict, and its error text would carry the value.
CTL_PATH_EXEMPT=0
for i in "${!PATTERNS[@]}"; do
  v=$(cat "$TMP/pat.$i")
  ( umask 077; printf 'blob plant %s: x %s x\n' "$i" "$v" > "$CTL/planted-$i.txt" )
  git -C "$CTL" add "planted-$i.txt" >/dev/null 2>&1
  git -C "$CTL" commit -q --allow-empty -m "control blob $i" >/dev/null 2>&1
  printf 'message plant %s\n' "$i" > "$CTL/msg-$i.txt"
  git -C "$CTL" add "msg-$i.txt" >/dev/null 2>&1
  git -C "$CTL" commit -q --allow-empty -m "control message $i carries $v here" >/dev/null 2>&1
  # ⚠ The 2>/dev/null is on the SUBSHELL, not the redirections. Bash reports a
  # FAILED redirection on the stderr in force when it is performed, so
  # `printf > "$CTL/name-$i-$v.txt" 2>/dev/null` still printed "File name too
  # long" -- with the value in the filename, and so in the error text.
  if ( umask 077
       mkdir -p "$(dirname "$CTL/name-$i-$v.txt")" || exit 1
       printf 'path plant %s\n' "$i" > "$CTL/name-$i-$v.txt" || exit 1
       mkdir -p "$(dirname "$CTL/dup-$i-$v.txt")" || exit 1
       printf 'nothing to see here\n' > "$CTL/dup-$i-$v.txt" || exit 1 ) 2>/dev/null; then
    git -C "$CTL" add -A >/dev/null 2>&1
    git -C "$CTL" commit -q --allow-empty -m "control path $i" >/dev/null 2>&1
    CTL_PATH_PLANTED[$i]=1
  else
    CTL_PATH_EXEMPT=$((CTL_PATH_EXEMPT + 1))
  fi
done

ctl_fail=0
scan_range "$CTL" --all > "$TMP/ctl.out" 2>&1 || true
ctl_has() { grep -a "$1" "$TMP/ctl.out" | grep -qaF -- "-- $2"; }
ctl_exempt() { [ -z "${CTL_PATH_PLANTED[$1]+x}" ]; }
for i in "${!PATTERNS[@]}"; do
  need=2; caught=0; missed=""
  if ctl_has "HIT: blob "   "${LABELS[$i]}"; then caught=$((caught + 1)); else missed="$missed blob;"; fi
  if ctl_has "HIT: commit " "${LABELS[$i]}"; then caught=$((caught + 1)); else missed="$missed commit message;"; fi
  if ! ctl_exempt "$i"; then
    need=4
    if ctl_has "PATH NAME in the publish set: name-$i-" "${LABELS[$i]}"; then caught=$((caught + 1)); else missed="$missed PATH NAME;"; fi
    if ctl_has "PATH NAME in the publish set: dup-$i-"  "${LABELS[$i]}"; then caught=$((caught + 1)); else missed="$missed PATH NAME over already-published bytes;"; fi
  fi
  # AND across the legs: a needle caught in only SOME of the places it can be
  # published is a needle the gate is blind to somewhere.
  if [ "$caught" -ne "$need" ]; then
    echo "RED: control -- needle '${LABELS[$i]}' was caught in $caught of $need leg(s); missed:${missed} -- every leg must fire (AND), not any one (OR)" >&2
    ctl_fail=1
  fi
done
grep -qa "blob\|commit\|PATH NAME" "$TMP/ctl.out" || {
  echo "RED: control -- the scan produced no hits at all on a repo built to trip it" >&2; ctl_fail=1; }
! grep -qa "HIT: .*clean\.txt" "$TMP/ctl.out" || { echo "RED: control -- the clean object was reported as a hit" >&2; ctl_fail=1; }
[ "$ctl_fail" -eq 0 ] || { echo "==> check-push-secrets: control failed -- refusing to report a verdict" >&2; exit 1; }
EXEMPT_NOTE=""
[ "$CTL_PATH_EXEMPT" -eq 0 ] || EXEMPT_NOTE="; ${CTL_PATH_EXEMPT} needle(s) could not be planted as a path (too long for a path component, or an illegal byte) and are exempt from the path legs only"
echo "    control ok (the real scan path caught every one of ${#PATTERNS[@]} needle(s) in a blob, a commit message, a path name AND a path name over already-published bytes, and spared a clean object$EXEMPT_NOTE; names only, never values)"

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
