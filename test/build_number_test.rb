#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression test for Bootstrap::Version.next_build_after.
#
# Why this exists: `next_build_number` used to query ASC for builds AT THE
# CURRENT MARKETING VERSION and return max + 1. That is correct only while
# nothing has shipped. Apple requires CFBundleVersion to exceed what was
# previously uploaded for the platform, and once a version is released that
# comparison spans the app's whole history rather than the current train.
#
# So bumping the marketing version reset the count to 1 and the upload was
# refused:
#
#     This bundle is invalid. The value for key CFBundleVersion [1] in the
#     Info.plist file must contain a higher version than that of the
#     previously uploaded version [7]
#
# Observed downstream after releasing 0.1.0 (build 7) and bumping to 0.1.1: the
# resolver returned 1. iOS ACCEPTED it — its 0.1.0 had never been released, so
# a new train may start at 1 — and macOS REFUSED it, in the same `make ship`.
# One command, two platforms, two answers. That asymmetry is what makes the bug
# easy to miss: a fork that has not released yet never sees it.
#
# The fix is a global max, and this pins the arithmetic. The ASC query itself
# is not covered here — it needs an account — so the numeric half was split out
# to be testable on its own.
#
# Runnable locally:
#   ruby test/build_number_test.rb
#
# Wired into bootstrap-doctor-matrix.yml's `build-number-regression` job.

# stubs/ first: version_resolver requires "spaceship" at load time for the ASC
# query, which the arithmetic under test never reaches. See test/stubs/spaceship.rb.
$LOAD_PATH.unshift File.expand_path("stubs", __dir__)
$LOAD_PATH.unshift File.expand_path("../bin", __dir__)
require "lib/bootstrap"
require "lib/version_resolver"

@failures = 0

def assert_eq(actual, expected, label)
  if actual == expected
    puts "  ✓ #{label}"
  else
    puts "  ✗ #{label}"
    puts "    expected: #{expected.inspect}"
    puts "    actual:   #{actual.inspect}"
    @failures += 1
  end
end

N = Bootstrap::Version

puts "Build number regression tests:"

# --- the ordinary case ---
assert_eq N.next_build_after(%w[1 2 3]),  4, "one past the highest"
assert_eq N.next_build_after(%w[7]),      8, "single prior build"

# --- THE BUG. These are the numbers from the real failure. ---
# Builds across BOTH marketing versions: 0.1.0 reached build 8, then the
# marketing version bumped to 0.1.1. Scoped to 0.1.1 the list is empty and the
# old code returned 1, which macOS refused because 0.1.0 build 7 was live.
assert_eq N.next_build_after(%w[1 2 3 4 5 6 7 8]), 9,
          "spans marketing versions — a bump must not reset to 1"
assert_eq N.next_build_after([]), 1,
          "a genuinely fresh app still starts at 1"

# --- ordering ---
# ASC returns versions as strings. A lexicographic max would pick "9" over
# "10" and hand back 10 — a number already used.
assert_eq N.next_build_after(%w[9 10]), 11, "numeric max, not lexicographic"
assert_eq N.next_build_after(%w[10 9]), 11, "input order does not matter"
assert_eq N.next_build_after(%w[2 100 30]), 101, "multi-digit ordering"

# --- junk must never drag the next number DOWN ---
# A build whose version will not parse must not crash a release, and must not
# be treated as larger or smaller than reality allows.
assert_eq N.next_build_after(["7", nil, ""]), 8, "nil and empty coerce to 0"
assert_eq N.next_build_after(%w[7 abc]),      8, "non-numeric coerces to 0"
assert_eq N.next_build_after(nil),            1, "nil input is treated as empty"

# --- integers as well as strings ---
assert_eq N.next_build_after([7, 8]), 9, "accepts integers too"

if @failures.zero?
  puts "\nAll 11 build number regression tests passed."
  exit 0
else
  puts "\n#{@failures} test(s) failed."
  exit 1
end
