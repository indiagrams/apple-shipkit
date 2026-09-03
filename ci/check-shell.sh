#!/usr/bin/env bash
#
# ci/check-shell.sh — every tracked shell script must parse, and must survive
# ShellCheck at warning severity.
#
# (Note the capital S above. A comment line whose first word is `shellcheck` is
# parsed as a directive, so prose that happens to wrap onto one becomes a syntax
# error. This gate caught exactly that in its own header on its first run.)
#
# WHY THIS EXISTS
#
# This template's release path is shell. `local-release-check.sh` alone is ~470
# lines of signing, packaging and re-signing, and a fork's CI can be green
# across every job while a script in that path is syntactically broken -- because
# nothing ever ran it. The `app (...)` cells build the app; they do not source
# `bin/rename.sh` or execute the ship path. A PR that breaks a shell script
# outright therefore merges clean and fails later, on someone's release.
#
# `bash -n` is the floor: it catches a script that cannot even be parsed, which
# is the failure that should never reach main. shellcheck at `warning` catches
# the class above that -- the constructs that run but do the wrong thing:
#
#   SC2164  `cd foo` without `|| exit`. In a GUARD script this is the worst
#           case: cd fails, the script keeps going in the wrong directory, and
#           then checks -- and passes -- files that are not the ones it exists
#           to check.
#   SC1087  `$var[...]` reads as array indexing rather than "expand var, then a
#           literal bracket". Ambiguous today, wrong the moment someone makes
#           `var` an array.
#   SC2046  unquoted command substitution that word-splits.
#
# Severity is capped at `warning` deliberately. `info` and `style` are reported
# for visibility but do not fail: they are dominated by SC2012 (`ls | grep`) and
# SC1091 (cannot follow `source`), neither of which is a defect here, and a gate
# that cries wolf gets disabled.
#
# ci/lib/ is checked with `-s bash` rather than exempted. Those files are sourced
# libraries with no shebang, and they are pinned byte-for-byte by
# `ci/lib/SHA256SUMS` across this template and every consumer -- so adding a
# `# shellcheck shell=bash` directive to them would force a re-pin in every
# downstream repo for a comment. Passing the shell on the command line gets the
# same coverage and touches nothing.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "  FAIL shellcheck is not installed." >&2
  echo "       brew install shellcheck   (it is in the Brewfile)" >&2
  echo "       Not skipping: this gate exists because nothing else runs these scripts." >&2
  exit 1
fi

# Read into an array without `mapfile`: that is bash 4+, and macOS still ships
# bash 3.2 as /bin/bash, so a runner without a newer bash on PATH would fail
# here rather than in the checks below.
SCRIPTS=()
while IFS= read -r _f; do
  [ -n "$_f" ] && SCRIPTS+=("$_f")
done < <(git ls-files '*.sh')
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  echo "  FAIL no tracked *.sh files found -- this gate went blind." >&2
  exit 1
fi

echo "==> Shell script check (${#SCRIPTS[@]} tracked scripts)"
fail=0

# 1. Parse. A script that does not parse cannot be reasoned about at all.
syntax_bad=0
for f in "${SCRIPTS[@]}"; do
  if ! err="$(bash -n "$f" 2>&1)"; then
    echo "  FAIL $f does not parse:" >&2
    echo "$err" | sed 's/^/         /' >&2
    syntax_bad=$((syntax_bad + 1))
    fail=1
  fi
done
[ "$syntax_bad" -eq 0 ] && echo "  ok   all ${#SCRIPTS[@]} scripts parse (bash -n)"

# 2. shellcheck at warning severity. -s bash covers the shebang-less sourced
#    libraries in ci/lib/ without editing them; see the header.
if out="$(shellcheck -s bash --severity=warning -f gcc "${SCRIPTS[@]}" 2>&1)" && [ -z "$out" ]; then
  echo "  ok   shellcheck clean at warning severity"
else
  if [ -n "$out" ]; then
    echo "  FAIL shellcheck found error/warning-level problems:" >&2
    echo "$out" | sed 's/^/         /' >&2
    fail=1
  fi
fi

# 3. Advisory only -- reported so it stays visible, never fails the build.
advisory="$(shellcheck -s bash --severity=style -f gcc "${SCRIPTS[@]}" 2>/dev/null | wc -l | tr -d ' ')"
echo "  note $advisory info/style finding(s), not gated (see this script's header)"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: a tracked shell script is broken or has a warning-level defect." >&2
  echo "Nothing else in CI executes these scripts, so this is the only place it shows up." >&2
  exit 1
fi
echo "passed"
exit 0
