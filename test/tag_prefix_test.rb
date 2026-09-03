#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract test for Bootstrap::Version.tag_prefix / parse_tag.
#
# Why this exists: a repo that is both an app and a SwiftPM package publishes
# both from one tag namespace, and SwiftPM claims every tag that parses as a
# version. Measured on tunnelless: a bare `v0.2` tag made
# `.upToNextMajor(from: "0.1.0")` resolve to 0.2.0, while `pkg-0.3.0`,
# `package/0.4.0` and `release/0.5.0` were all ignored. SwiftPM cannot be pointed
# at a non-default tag series, so the app tags move instead.
#
# The property that matters most here is the DEFAULT: unset RELEASE_TAG_PREFIX
# must behave exactly as before, or every fork's release path changes under it.
#
# Runnable locally:
#   ruby test/tag_prefix_test.rb

$LOAD_PATH.unshift File.expand_path("stubs", __dir__)
$LOAD_PATH.unshift File.expand_path("../bin", __dir__)
require "lib/bootstrap"
require "lib/version_resolver"

V = Bootstrap::Version
@failures = 0

def assert_eq(actual, expected, label)
  if actual == expected
    puts "  ✓ #{label}"
  else
    @failures += 1
    puts "  ✗ #{label}\n      expected: #{expected.inspect}\n      actual:   #{actual.inspect}"
  end
end

def with_prefix(value)
  had = ENV.key?("RELEASE_TAG_PREFIX")
  old = ENV["RELEASE_TAG_PREFIX"]
  value.nil? ? ENV.delete("RELEASE_TAG_PREFIX") : ENV["RELEASE_TAG_PREFIX"] = value
  yield
ensure
  had ? ENV["RELEASE_TAG_PREFIX"] = old : ENV.delete("RELEASE_TAG_PREFIX")
end

puts "default (unset) — must be indistinguishable from before"
with_prefix(nil) do
  assert_eq V.tag_prefix,                       "v",                  "prefix defaults to v"
  assert_eq V.parse_tag("v1.0.0+5"),            ["1.0.0", "5"],       "v1.0.0+5"
  assert_eq V.parse_tag("v2026.19.1357"),       ["2026.19.1357", nil], "legacy CalVer, no build"
  assert_eq V.parse_tag("v0.2026.19-canary-7"), ["0.2026.19", nil],   "canary tag"
  assert_eq V.parse_tag("1.0.0+5"),             ["1.0.0", "5"],       "bare tag still parses"
end

puts "\ncustom prefix"
with_prefix("app/v") do
  assert_eq V.tag_prefix,                    "app/v",         "prefix is read from the env"
  assert_eq V.parse_tag("app/v1.0.0+5"),     ["1.0.0", "5"],  "app/v1.0.0+5 round-trips"
  assert_eq V.parse_tag("app/v0.1.2+10"),    ["0.1.2", "10"], "two-digit build"
  # The reason the fallback exists: tags cut before the switch are still around.
  assert_eq V.parse_tag("v0.1.1+9"),         ["0.1.1", "9"],  "pre-switch v-tag still readable"
  assert_eq V.parse_tag("app/v2026.19.1357"), ["2026.19.1357", nil], "prefixed legacy CalVer"
end

puts "\nempty prefix — bare tags, an explicit choice rather than the default"
with_prefix("") do
  assert_eq V.tag_prefix,            "",             "empty string is honoured, not coerced to v"
  assert_eq V.parse_tag("1.0.0+5"),  ["1.0.0", "5"], "bare tag"
  assert_eq V.parse_tag("v1.0.0+5"), ["1.0.0", "5"], "v-tag still readable via the fallback"
end

puts "\nprefixes that could collide with the version body"
with_prefix("release/") do
  assert_eq V.parse_tag("release/1.0.0+5"), ["1.0.0", "5"], "slash prefix, no v"
end
with_prefix("v") do
  # "v" is both the default and a legal explicit value; must not strip twice.
  assert_eq V.parse_tag("v1.0.0+5"), ["1.0.0", "5"], "explicit v behaves like the default"
end

# The setting lives in .bootstrap.env, but Version.tag_prefix reads ENV — so the
# value has to be plumbed from one to the other, and then into the fastlane
# subprocess. The first version of this feature did neither: ship.rb computed
# `app/v0.1.2+10` and handed it to a fastlane process that still thought the
# prefix was "v", leaving the tag unstripped and every artifact name built from
# it. These are the assertions that would have caught that.
puts "\nconfig plumbing"
cfg = Bootstrap::Config.new("RELEASE_TAG_PREFIX" => "app/v")
with_prefix(nil) do
  assert_eq cfg.release_tag_prefix, "app/v", ".bootstrap.env value is read"
end
with_prefix("release/") do
  assert_eq cfg.release_tag_prefix, "release/", "process env beats .bootstrap.env"
end
with_prefix(nil) do
  assert_eq Bootstrap::Config.new({}).release_tag_prefix, "v", "absent everywhere defaults to v"
  assert_eq Bootstrap::Config.new("RELEASE_TAG_PREFIX" => "").release_tag_prefix, "",
            "explicit empty in the file is honoured, not coerced to v"
end
with_prefix("") do
  assert_eq cfg.release_tag_prefix, "", "explicit empty in env is honoured"
end

# asc_env is what reaches the fastlane subprocess.
assert_eq Bootstrap.method(:asc_env).source_location.nil?, false, "asc_env exists"
asc_env_src = File.read(File.expand_path("../bin/lib/bootstrap.rb", __dir__))
assert_eq asc_env_src.include?('"RELEASE_TAG_PREFIX"      => config.release_tag_prefix'), true,
          "asc_env propagates RELEASE_TAG_PREFIX to fastlane"

if @failures.zero?
  puts "\nAll 23 tag prefix tests passed."
  exit 0
else
  puts "\n#{@failures} test(s) failed."
  exit 1
end
