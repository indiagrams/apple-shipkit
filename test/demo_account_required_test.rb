#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression test for Bootstrap::ReviewDetail.flag_to_restore.
#
# Why this exists: deliver's `review_information()` omits empty review fields
# from its appStoreReviewDetail PATCH -- correct, and what the Fastfile's `" "`
# sentinel depends on -- but then finishes with an `else` branch that WRITES
# `demo_account_required = false` rather than omitting it. So a fork with no
# APP_REVIEW_DEMO_USER / _PASSWORD configured gets the flag derived from values
# deliver deliberately did not send, landing on top of the credentials App Store
# Connect still stores.
#
# Observed downstream on tunnelless: 0.1.0 was approved with
# demoAccountRequired: true, and the first `make submit` for 0.1.1 produced
# false on BOTH platforms while the inherited credentials stayed in place. A
# record that says "here is a demo account, and it is not required" is one
# nobody chose. It is invisible from the exit code and from deliver's log.
#
# The rule under test: restore the flag only when deliver changed it WITHOUT
# changing the credentials it derives from. A genuine credential change means
# deliver's derivation is honest and must stand.
#
# Runnable locally:
#   ruby test/demo_account_required_test.rb

$LOAD_PATH.unshift File.expand_path("../bin", __dir__)
require "lib/review_detail"

R = Bootstrap::ReviewDetail

@failures = 0

def assert_eq(actual, expected, label)
  if actual == expected
    puts "  ✓ #{label}"
  else
    @failures += 1
    puts "  ✗ #{label}\n      expected: #{expected.inspect}\n      actual:   #{actual.inspect}"
  end
end

def detail(required:, name: "review@example.com", password: "hunter2")
  { required: required, name: name, password: password }
end

puts "flag_to_restore"

# --- the actual bug: creds retained, flag silently flipped ---
assert_eq R.flag_to_restore(before: detail(required: true), after: detail(required: false)),
          true, "true -> false with unchanged creds is restored"

# --- the same shape in the other direction ---
assert_eq R.flag_to_restore(before: detail(required: false), after: detail(required: true)),
          false, "false -> true with unchanged creds is restored"

# --- honest derivations must survive ---
assert_eq R.flag_to_restore(
  before: detail(required: false, name: "", password: ""),
  after:  detail(required: true,  name: "review@example.com", password: "hunter2")
), nil, "creds newly supplied -> deliver's true stands"

assert_eq R.flag_to_restore(
  before: detail(required: true),
  after:  detail(required: false, name: "", password: "")
), nil, "creds actually cleared -> deliver's false stands"

assert_eq R.flag_to_restore(
  before: detail(required: true, password: "old"),
  after:  detail(required: false, password: "new")
), nil, "password rotated -> derivation stands even though the flag moved"

# --- nothing to do ---
assert_eq R.flag_to_restore(before: detail(required: true), after: detail(required: true)),
          nil, "unchanged flag needs no restore"
assert_eq R.flag_to_restore(
  before: detail(required: false, name: "", password: ""),
  after:  detail(required: false, name: "", password: "")
), nil, "no demo account at all, flag steady -> no restore"

# --- a version with no review detail yet ---
assert_eq R.flag_to_restore(before: nil, after: detail(required: false)),
          nil, "no snapshot before -> nothing to preserve"
assert_eq R.flag_to_restore(before: detail(required: true), after: nil),
          nil, "unreadable detail after -> no blind write"

# --- nil/empty credential coercion: ASC omits empty strings as null ---
assert_eq R.creds_equal?({ name: nil, password: nil }, { name: "", password: "" }),
          true, "nil and empty credentials compare equal"
assert_eq R.flag_to_restore(
  before: { required: true, name: nil, password: nil },
  after:  { required: false, name: "", password: "" }
), true, "nil->empty is not a credential change, so the flag is restored"

# --- snapshot() normalizes an ASC model, and passes nil through ---
Stub = Struct.new(:demo_account_required, :demo_account_name, :demo_account_password)
assert_eq R.snapshot(Stub.new(true, "a@b.c", "pw")),
          { required: true, name: "a@b.c", password: "pw" }, "snapshot maps an ASC model"
assert_eq R.snapshot(Stub.new(false, nil, nil)),
          { required: false, name: "", password: "" }, "snapshot coerces nil creds to empty"
assert_eq R.snapshot(nil), nil, "snapshot(nil) is nil"

if @failures.zero?
  puts "\nAll 14 demo_account_required regression tests passed."
  exit 0
else
  puts "\n#{@failures} test(s) failed."
  exit 1
end
