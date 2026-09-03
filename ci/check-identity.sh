#!/bin/bash
# ci/check-identity.sh — refuse to build against an incomplete app identity.
#
# WHY THIS EXISTS
#
# The app's identity — bundle id, product name, display name, copyright —
# lives in app/Identity.xcconfig, and both generators reference it as
# $(VAR). Neither generator checks that a referenced variable exists: a
# missing key resolves to the empty string, `xcodegen generate` and
# `tuist generate` both exit 0, and the macOS build succeeds with an empty
# CFBundleIdentifier. Nothing on that path is red until the .app refuses to
# launch.
#
# bin/preflight-identity.rb is the check. XcodeGen runs it itself through
# app/project.yml's `options.preGenCommand`, but that hook is skipped under
# `xcodegen --use-cache`, and Tuist has no pre-generation hook at all — a
# guard embedded in Project.swift is skipped whenever the manifest cache is
# warm, which is to say whenever only the xcconfig changed, the one case the
# guard is for. So the check also runs here, as plain text, before either
# generator: from ci/local-check.sh, and from pr.yml's config job so every
# matrix cell — both generators, all platforms — is gated by the same run.
#
# Ruby stdlib only; no bundle install needed. Any argument is passed through
# (`--require-team` makes an unresolvable DEVELOPMENT_TEAM a failure too —
# not for CI, where the required cells build unsigned and the gitignored
# app/Local.xcconfig is never present).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

echo "==> Identity preflight"

if ! command -v ruby >/dev/null 2>&1; then
  echo "  FAIL ruby not on PATH — bin/preflight-identity.rb needs any Ruby >= 2.6" >&2
  echo "FAILED: could not check app/Identity.xcconfig." >&2
  exit 1
fi

ruby bin/preflight-identity.rb "$@"
status=$?
if [ "$status" -eq 0 ]; then
  echo "passed"
  exit 0
fi

echo "FAILED: app/Identity.xcconfig is not complete (exit $status) — see the line above." >&2
exit "$status"
