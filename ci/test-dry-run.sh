#!/usr/bin/env bash
# Contract test for `bin/ship.rb --dry-run` and the release lane's skip flags.
#
# WHY THIS EXISTS
#
# `--dry-run` translated into exactly one lane option, `skip_upload:true`, while
# the lane defaulted `skip_tag` independently. So a dry run ran step 6/6 for
# real: `git tag <tag> && git push origin <tag>`. A pushed tag is the one side
# effect of that lane which outlives the run — deleting it is not free once
# anyone has fetched it, and on a repo where tags drive releases it starts
# downstream automation for a build that was never uploaded. Then the success
# banner, bold and green and printed after fastlane's quieter "Skipping
# TestFlight upload" notices had scrolled past, claimed the upload anyway
# (apple-shipkit#301, found by a consumer project that had to write its own
# `override_lane :release` to make `--dry-run` safe).
#
# WHAT IT ACTUALLY EXERCISES, AND WHAT IT STUBS
#
# It runs the REAL bin/ship.rb — copied, not reimplemented — inside a throwaway
# tree, with a fake `bundle` on PATH that records the argv it was handed and
# exits 0. That makes the two things under test observable without a build, a
# signature or an upload: the flags ship.rb passes, and the banner it prints for
# a given outcome.
#
# Two stubs, both narrow and both named here rather than hidden:
#
#   * `Spaceship::ConnectAPI.token` is preset, so `Bootstrap.ensure_asc_token!`
#     returns at its first line. Token construction is local JWT work, not a
#     network call, and it is not the subject — but reaching the subject requires
#     getting past it. This is a stub the harness owns; test/stubs/spaceship.rb
#     stays empty on purpose ("any test that actually reaches Spaceship will fail
#     loudly with NameError rather than silently exercising a mock that agrees
#     with itself") and is deliberately not weakened for this.
#   * `RELEASE_BUILD_NUMBER` is set, which `Bootstrap::Version.next_build_number`
#     honours at its first line, so no ASC query happens.
#
# The ASC_API_KEY_* / FASTLANE_TEAM_ID / BUNDLE_ID variables are CLEARED for the
# child. A developer with them exported — the very shell #291 exists to refuse —
# would otherwise have this harness die at that guard instead of measuring
# anything, and clearing them also proves the two features coexist.
#
# The lane half cannot be run without a real build, so it is measured a different
# way: the two assignment lines are read OUT OF fastlane/Fastfile and evaluated,
# with the four option shapes every caller in this repository actually uses. That
# asserts the real source line's behaviour rather than a copy of it, and it is
# what pins the invariant for callers that never go through bin/ship.rb.
#
# Runnable locally, from the repository root:
#   ci/test-dry-run.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=""
cleanup() { [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

failures=0
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
bad()  { printf '    ✗ %s\n' "$*" >&2; failures=$((failures + 1)); }

# ─── the throwaway kit ────────────────────────────────────────────────────────

step "0/4 build a throwaway tree around the REAL bin/ship.rb"
WORK="$(mktemp -d)"
KIT="$WORK/kit"
mkdir -p "$KIT/bin/lib" "$KIT/app" "$KIT/stubs" "$KIT/fakebin"

cp "$REPO_ROOT/bin/ship.rb" "$KIT/bin/ship.rb"
cp "$REPO_ROOT"/bin/lib/*.rb "$KIT/bin/lib/"
# The real manifest: read_marketing_version parses it, and a hand-written one
# could drift from what the command actually expects to find.
cp "$REPO_ROOT/app/project.yml" "$KIT/app/project.yml"
printf 'not-a-real-key\n' > "$KIT/asc.p8"

cat > "$KIT/.bootstrap.env" <<EOF
APP_NAME=DryRunApp
BUNDLE_ID=com.example.dryrun
DISPLAY_NAME=Dry Run App
APP_EMAIL=dryrun@example.invalid
GENERATOR=xcodegen
RELEASE_MODE=local
PLATFORMS=ios,macos
FASTLANE_TEAM_ID=DRYRUN1234
ASC_API_KEY_ID=DRYRUNKEY1
ASC_API_KEY_ISSUER_ID=dryrun-issuer-uuid
ASC_API_KEY_P8_PATH=$KIT/asc.p8
GH_ORG=example
GH_APP_REPO=dryrun
EOF

cat > "$KIT/stubs/spaceship.rb" <<'EOF'
# Narrow stub: a preset token makes Bootstrap.ensure_asc_token! return at its
# first line. See ci/test-dry-run.sh's header for why this is owned here rather
# than added to test/stubs/spaceship.rb.
module Spaceship
  module ConnectAPI
    class << self
      attr_accessor :token
    end
    self.token = :dry_run_harness_token
  end
end
EOF

# The fake fastlane driver: records argv, succeeds, uploads nothing, tags nothing.
cat > "$KIT/fakebin/bundle" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/bundle-argv.log"
exit 0
EOF
chmod +x "$KIT/fakebin/bundle"

( cd "$KIT" && git init -q -b main . \
  && git add -A \
  && git -c user.email=dry@run.invalid -c user.name="dry run" commit -qm "fixture" ) \
  || { bad "could not build the fixture git repo"; exit 1; }
ok "throwaway kit at \$WORK/kit, with the real ship.rb and lib/"

run_ship() { # run_ship <label> [extra argv...]
  : > "$WORK/bundle-argv.log"
  ( cd "$KIT" \
    && env -u ASC_API_KEY_ID -u ASC_API_KEY_ISSUER_ID -u ASC_API_KEY_P8_BASE64 \
           -u ASC_API_KEY_P8_PATH -u FASTLANE_TEAM_ID -u BUNDLE_ID -u APP_NAME \
       PATH="$KIT/fakebin:$PATH" \
       RUBYLIB="$KIT/stubs" \
       RELEASE_BUILD_NUMBER=7 \
       ruby "$KIT/bin/ship.rb" "$@" ) >"$WORK/$1.out" 2>&1
  printf '%s' "$?"
}

# ─── 1: the dry run passes BOTH skips ─────────────────────────────────────────

step "1/4 --dry-run hands the lane both skips, so no tag can be pushed"
code="$(run_ship dry --dry-run)"
[ "$code" = "0" ] || bad "bin/ship.rb --dry-run exited $code: $(tail -3 "$WORK/dry.out" | tr '\n' ' ')"
argv="$(cat "$WORK/bundle-argv.log")"
[ -n "$argv" ] || bad "ship.rb never invoked the fastlane driver (argv log empty)"
case "$argv" in
  *skip_upload:true*) ok "argv carries skip_upload:true" ;;
  *)                  bad "argv is missing skip_upload:true — got: $argv" ;;
esac
case "$argv" in
  *skip_tag:true*) ok "argv carries skip_tag:true — this is the #301 defect" ;;
  *)               bad "argv is missing skip_tag:true, so the lane would push a real tag: $argv" ;;
esac

# ─── 2: the banner does not claim what did not happen ─────────────────────────

step "2/4 the dry-run banner claims no upload and no tag"
if grep -q "binaries uploaded to App Store Connect" "$WORK/dry.out"; then
  bad "the dry-run banner still claims binaries were uploaded"
else
  ok "the banner does not claim an upload"
fi
if grep -qE "Tag .* pushed" "$WORK/dry.out"; then
  bad "the dry-run banner still claims a tag was pushed"
else
  ok "the banner does not claim a pushed tag"
fi
grep -q "Dry run succeeded" "$WORK/dry.out" \
  && ok "the banner names itself a dry run" \
  || bad "the banner does not identify itself as a dry run"
grep -q "No upload, no tag" "$WORK/dry.out" \
  && ok "the banner states both omissions" \
  || bad "the banner does not state what was skipped"
grep -q "make verify" "$WORK/dry.out" \
  && bad "the dry-run banner still points at make verify, which has nothing to verify" \
  || ok "it does not send the reader to make verify"

# ─── 3: a real run is unchanged ───────────────────────────────────────────────

step "3/4 without --dry-run nothing is skipped and the banner is the old one"
code="$(run_ship real)"
[ "$code" = "0" ] || bad "bin/ship.rb exited $code: $(tail -3 "$WORK/real.out" | tr '\n' ' ')"
argv="$(cat "$WORK/bundle-argv.log")"
case "$argv" in
  *skip_upload*|*skip_tag*) bad "a real release must pass neither skip: $argv" ;;
  *)                        ok "argv carries neither skip flag" ;;
esac
grep -q "Local release succeeded" "$WORK/real.out" \
  && ok "the real-release banner is unchanged" \
  || bad "the real-release banner changed: $(tail -3 "$WORK/real.out" | tr '\n' ' ')"
grep -q "binaries uploaded to App Store Connect" "$WORK/real.out" \
  && ok "it still reports the upload, where that is true" \
  || bad "the real-release banner no longer reports the upload"

# ─── 4: the lane's own invariant, evaluated off its real source lines ────────

step "4/4 the lane couples skip_tag to skip_upload for EVERY caller"
ruby - "$REPO_ROOT/fastlane/Fastfile" <<'RUBY'
src  = File.read(ARGV[0], encoding: "UTF-8")
up   = src[/^\s*skip_upload\s*=.*$/]
tagl = src[/^\s*skip_tag\s*=.*$/]
abort "    ✗ no skip_upload assignment found in the Fastfile" if up.nil?
abort "    ✗ no skip_tag assignment found in the Fastfile"    if tagl.nil?

# Every option shape a caller in this repository actually uses, and what
# skip_tag must be for each. The canary row is the one that keeps the coupling
# one-way: canary-local-mode.yml ships FOR REAL and passes skip_tag:true alone,
# so a two-way coupling would silently stop its uploads.
cases = [
  [{ skip_upload: true },                  true,  "bin/ship.rb --dry-run (skip_upload alone)"],
  [{ skip_tag: true },                     true,  "canary: real upload, no tag (skip_tag alone)"],
  [{ skip_upload: true, skip_tag: true },  true,  "release.yml dry run / make release-dryrun"],
  [{},                                     false, "a real release"]
]

failed = 0
cases.each do |options, want, label|
  skip_upload = nil
  skip_tag    = nil
  eval(up)    # rubocop:disable Security/Eval -- the point is to run the REAL line
  eval(tagl)  # rubocop:disable Security/Eval
  if skip_tag == want
    puts "    ✓ #{label}: skip_upload=#{skip_upload.inspect} -> skip_tag=#{skip_tag.inspect}"
  else
    warn "    ✗ #{label}: skip_tag=#{skip_tag.inspect}, want #{want.inspect}"
    failed += 1
  end
end

# The claim at the end of the lane must not be unconditional either.
#
# Anchored on the WHOLE if/else shape, not just "an `if dry_run` appears
# somewhere above the live claim": the lane has a second `if dry_run` earlier
# (the changelog branch), so the loose form matched with the closing gate
# deleted and asserted nothing. Verified by mutating a copy — loose matched
# both, this matches only the gated one.
unless src.match?(
  /if dry_run\n\s*UI\.success\([^\n]*dry run finished[^\n]*\n\s*else\n\s*UI\.success\([^\n]*is live on TestFlight/
)
  warn "    ✗ the lane's closing \"is live on TestFlight\" success is not gated on dry_run"
  failed += 1
else
  puts "    ✓ the lane's closing success message is gated on dry_run"
end

exit(failed.zero? ? 0 : 1)
RUBY
[ $? -eq 0 ] || failures=$((failures + 1))

printf '\n'
if [ "$failures" -eq 0 ]; then
  echo "All dry-run assertions passed."
else
  echo "$failures dry-run assertion group(s) FAILED."
  exit 1
fi
