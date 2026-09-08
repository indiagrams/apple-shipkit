#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract test for the .bootstrap.env / shell-environment precedence guard.
#
# Why this exists: until 2026-09-08 the ambient environment won SILENTLY over
# .bootstrap.env. A shell profile that exported one project's App Store Connect
# credentials (`~/.zshrc` sourcing a shared secrets file) therefore redirected
# every fork on that machine to that project's key and team — `make ship` in
# fork B authenticated as project A and would have uploaded there, with no
# warning. Reported from a real local release that picked up the smoketest
# canary's key.
#
# The guard's entire value is in refusing, so these are the properties worth
# pinning:
#
#   1. A disagreement on an account-deciding key is detected, and the message
#      names BOTH sources and BOTH values — a wrong-account diagnosis is
#      impossible without knowing which value came from where.
#   2. Agreement is NOT a conflict, and neither is a silent env or a silent
#      file. canary-local-mode.yml synthesizes .bootstrap.env FROM these same
#      env vars, so a false positive red-walls the weekly canary.
#   3. APP_NAME stays OUT of the fatal set. It names the App ID and artifacts,
#      not the destination account, and the canary pins APP_NAME=canary in the
#      file while vars.APP_NAME rides the environment on purpose.
#   4. fastlane/Fastfile's copy of the key list matches the Ruby one. The
#      duplication is deliberate (the Fastfile takes no bin/lib load-path
#      dependency), and a silent drift there re-opens the hole for every
#      hand-run lane and for `make release-dryrun`.
#   5. Enforcement actually exits non-zero. A pure query is worthless if the
#      caller proceeds anyway.
#
# Hermetic by construction: every case clears all authoritative keys first, so
# the suite behaves identically on a clean runner and on the leaked developer
# shell that motivated the guard.
#
# Runnable locally:
#   ruby test/env_precedence_test.rb

$LOAD_PATH.unshift File.expand_path("stubs", __dir__)
$LOAD_PATH.unshift File.expand_path("../bin", __dir__)
require "lib/bootstrap"

REPO_ROOT = File.expand_path("..", __dir__)
BIN_DIR   = File.join(REPO_ROOT, "bin")
FASTFILE  = File.join(REPO_ROOT, "fastlane", "Fastfile")

@failures = 0

def assert(cond, label)
  if cond
    puts "  ✓ #{label}"
  else
    puts "  ✗ #{label}"
    @failures += 1
  end
end

def assert_eq(actual, expected, label)
  if actual == expected
    puts "  ✓ #{label}"
  else
    puts "  ✗ #{label}"
    puts "      expected: #{expected.inspect}"
    puts "      actual:   #{actual.inspect}"
    @failures += 1
  end
end

# Clear every key the guard looks at (plus the ack) before applying `pairs`, so
# a developer's exported credentials cannot change an outcome.
def with_env(pairs = {})
  keys = Bootstrap::ENV_FILE_AUTHORITATIVE_KEYS + [Bootstrap::ENV_OVERRIDE_ACK, "APP_NAME"]
  saved = keys.to_h { |k| [k, ENV[k]] }
  keys.each { |k| ENV.delete(k) }
  pairs.each { |k, v| ENV[k] = v }
  yield
ensure
  saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

def cfg(values)
  Bootstrap::Config.new(values)
end

puts "\n=== detection ==="

with_env("ASC_API_KEY_ID" => "ENVKEY9999") do
  conflicts = Bootstrap.env_file_conflicts(cfg("ASC_API_KEY_ID" => "FILEKEY123"))
  assert_eq(conflicts.length, 1, "differing ASC_API_KEY_ID is a conflict")
  assert_eq(conflicts.first[:file], "FILEKEY123", "file value captured")
  assert_eq(conflicts.first[:env], "ENVKEY9999", "env value captured")
end

with_env("FASTLANE_TEAM_ID" => "TEAMENV999", "BUNDLE_ID" => "com.env.other") do
  conflicts = Bootstrap.env_file_conflicts(
    cfg("FASTLANE_TEAM_ID" => "TEAMFILE11", "BUNDLE_ID" => "com.file.mine")
  )
  assert_eq(conflicts.map { |c| c[:key] }.sort, %w[BUNDLE_ID FASTLANE_TEAM_ID],
            "every conflicting key is reported, not just the first")
end

puts "\n=== no false positives (canary shape) ==="

with_env("ASC_API_KEY_ID" => "SAME12345", "FASTLANE_TEAM_ID" => "TEAM123456") do
  conflicts = Bootstrap.env_file_conflicts(
    cfg("ASC_API_KEY_ID" => "SAME12345", "FASTLANE_TEAM_ID" => "TEAM123456")
  )
  assert_eq(conflicts, [], "agreeing values are not a conflict (canary writes the file from the env)")
end

with_env do
  conflicts = Bootstrap.env_file_conflicts(cfg("ASC_API_KEY_ID" => "FILEKEY123"))
  assert_eq(conflicts, [], "silent env is not a conflict (the normal local case)")
end

with_env("ASC_API_KEY_ID" => "ENVKEY9999") do
  assert_eq(Bootstrap.env_file_conflicts(cfg({})), [],
            "silent file is not a conflict (the CI case — no .bootstrap.env)")
end

with_env("APP_NAME" => "SmokeApp") do
  conflicts = Bootstrap.env_file_conflicts(cfg("APP_NAME" => "canary"))
  assert_eq(conflicts, [], "APP_NAME divergence is tolerated (canary pins canary/SmokeApp)")
end

assert(!Bootstrap::ENV_FILE_AUTHORITATIVE_KEYS.include?("APP_NAME"),
       "APP_NAME is not in the account-deciding key set")

puts "\n=== message names both sources and both values ==="

msg = Bootstrap.env_file_conflict_message(
  [{ key: "ASC_API_KEY_ID", file: "FILEKEY123", env: "ENVKEY9999" }]
)
assert(msg.include?("FILEKEY123"), "message contains the .bootstrap.env value")
assert(msg.include?("ENVKEY9999"), "message contains the shell value")
assert(msg.include?(".bootstrap.env"), "message names the file source")
assert(msg.include?("shell env"), "message names the shell source")
assert(msg.include?("unset ASC_API_KEY_ID"), "message gives a copy-pasteable unset")
assert(msg.include?("ASC_API_KEY_P8_BASE64"), "unset covers the key material that rides along")
assert(msg.include?(Bootstrap::ENV_OVERRIDE_ACK), "message names the deliberate-override escape hatch")

puts "\n=== fastlane/Fastfile key list must not drift ==="

fastfile_src = File.read(FASTFILE, encoding: "UTF-8")
listed = fastfile_src[/^ENV_FILE_AUTHORITATIVE_KEYS\s*=\s*%w\[(.*?)\]/m]
assert(!listed.nil?, "Fastfile defines ENV_FILE_AUTHORITATIVE_KEYS")
if listed
  fastfile_keys = Regexp.last_match(1).split
  assert_eq(fastfile_keys, Bootstrap::ENV_FILE_AUTHORITATIVE_KEYS,
            "Fastfile list == Bootstrap::ENV_FILE_AUTHORITATIVE_KEYS")
end
assert(fastfile_src.include?("_assert_env_matches_fork_config!"),
       "asc_api_key still calls the guard (before_all's chokepoint for every lane)")

puts "\n=== enforcement exits non-zero ==="

def run_guard(env)
  script = <<~RUBY
    require "lib/bootstrap"
    Bootstrap.assert_no_env_file_conflicts!(
      Bootstrap::Config.new("ASC_API_KEY_ID" => "FILEKEY123")
    )
    puts "PROCEEDED"
  RUBY
  out = IO.popen(env, ["ruby", "-I", BIN_DIR, "-e", script], err: [:child, :out], &:read)
  [out, $?.exitstatus]
end

out, status = run_guard("ASC_API_KEY_ID" => "ENVKEY9999")
assert_eq(status, 1, "conflict exits 1 before any Apple call")
assert(!out.include?("PROCEEDED"), "conflict does not fall through to the caller")
assert(out.include?("FILEKEY123") && out.include?("ENVKEY9999"),
       "refusal prints both values")

out, status = run_guard("ASC_API_KEY_ID" => "ENVKEY9999", Bootstrap::ENV_OVERRIDE_ACK => "true")
assert_eq(status, 0, "acked override proceeds")
assert(out.include?("PROCEEDED"), "acked override reaches the caller")
assert(out.include?("ENVKEY9999"), "acked override still says which value it used")

out, status = run_guard("ASC_API_KEY_ID" => "FILEKEY123")
assert_eq(status, 0, "agreeing env proceeds")

puts
if @failures.zero?
  puts "All env-precedence assertions passed."
  exit 0
else
  puts "#{@failures} assertion(s) FAILED."
  exit 1
end
