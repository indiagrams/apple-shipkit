#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression test for the TYPE of the `platform:` argument at every `deliver`
# call site in fastlane/Fastfile.
#
# Why this exists: `fastlane ios upload_screenshots` could not run AT ALL. It
# died in 1.1 seconds, before any network call, with
#
#   [!] 'platform' value must be a String! Found Symbol instead.
#
# because the lane passed `platform: :ios` -- a Symbol. deliver's own option
# declares no `type:` (deliver/lib/deliver/options.rb), so FastlaneCore's
# ConfigItem defaults `is_string: true` and rejects anything that is not a
# String at config-parse time.
#
# THE ASYMMETRY IS THE DEFECT. Every other deliver call site in the same file
# already passed a String -- `platform.to_s` from the two helpers, and the
# literal "osx" in the macOS screenshot lane twenty lines below. The iOS
# screenshot lane was the one Symbol in the file, and its own macOS twin got it
# right, which is exactly why no reviewer caught it by reading the neighbours.
#
# It was reachable on the DOCUMENTED path, which is what made it worth a gate
# rather than a one-line fix: ci/take-screenshots.sh and ci/bump-asc-version.sh
# both invoke the lane, and docs/SCREENSHOTS.md tells a forker to run it. A
# fork following the documentation hit a lane that had never worked.
#
# Note what this test deliberately does NOT flag: `do_upload_metadata(platform:
# :ios)` and `do_submit_for_review(platform: :ios, ...)` pass Symbols quite
# legitimately, because those helpers call `.to_s` before reaching deliver. The
# subject is the deliver call sites themselves, not every `platform:` in the
# file -- a test pointed at the wider population would report four false
# positives and be turned off.
#
# Runnable locally:
#   ruby test/deliver_platform_type_test.rb

FASTFILE = File.expand_path("../fastlane/Fastfile", __dir__)

@failures = 0

def assert(condition, label, detail = nil)
  if condition
    puts "  ✓ #{label}"
  else
    @failures += 1
    puts "  ✗ #{label}"
    puts "      #{detail}" if detail
  end
end

# Collect every `platform:` argument that can REACH deliver. Two shapes, and
# the second is the one a narrower scan misses:
#
#   (1) lexically inside a `deliver(` argument list;
#   (2) inside a hash assigned to a variable that is later splatted in as
#       `deliver(**that_variable)`.
#
# Shape (2) is not hypothetical -- `deliver_args = asc_metadata_args.merge(...)`
# is built ~20 lines above its `deliver(**deliver_args)`, and a Symbol written
# there reaches deliver identically. A scan that only walked `deliver(` blocks
# would report this file clean while one of its platform values sat outside the
# population entirely.
#
# Both shapes are enumerated FROM THE FILE, never from a list written here, so
# a new call site is covered the day it is added rather than the day someone
# remembers to add it.
def balanced_block(lines, start_index)
  depth = 0
  out = []
  lines[start_index..].each_with_index do |line, offset|
    depth += line.count("(") - line.count(")")
    out << { line: start_index + offset + 1, text: line }
    break if depth <= 0
  end
  out
end

def platform_args_reaching_deliver(source)
  lines = source.lines
  blocks = []

  # (1) direct `deliver(` call sites
  lines.each_with_index do |line, i|
    blocks.concat(balanced_block(lines, i)) if line =~ /\bdeliver\(/
  end

  # (2) hashes splatted in as `deliver(**name)` -- find the names, then their
  #     assignments. Derived from the file, so it follows a rename.
  splatted = source.scan(/\bdeliver\(\*\*(\w+)/).flatten.uniq
  splatted.each do |name|
    lines.each_with_index do |line, i|
      blocks.concat(balanced_block(lines, i)) if line =~ /^\s*#{Regexp.escape(name)}\s*=/
    end
  end

  blocks.filter_map do |entry|
    m = entry[:text].match(/^\s*platform:\s*(.+?),?\s*$/)
    { line: entry[:line], value: m[1] } if m
  end.uniq { |a| a[:line] }.sort_by { |a| a[:line] }
end

source = File.read(FASTFILE, encoding: "UTF-8")
args = platform_args_reaching_deliver(source)

puts "deliver_platform_type_test"
puts "  platform: values reaching deliver = #{args.length} (lines #{args.map { |a| a[:line] }.join(', ')})"

# NON-VACUITY GUARD. A scanner that matches nothing passes every assertion
# below without having looked at anything, which is indistinguishable from a
# clean file. The Fastfile has two screenshot lanes, iOS and macOS, so anything
# under two means the scanner stopped seeing its subject.
assert(args.length >= 4,
       "the scan reached both direct and splatted call sites (else it asserts nothing)",
       "found #{args.length}: #{args.inspect}")

args.each do |arg|
  assert(!arg[:value].start_with?(":"),
         "fastlane/Fastfile:#{arg[:line]} passes a String to deliver's platform:",
         "found the Symbol #{arg[:value]} -- deliver rejects it at config-parse " \
         "time with \"'platform' value must be a String! Found Symbol instead.\"")
end

puts
if @failures.zero?
  puts "All #{args.length + 1} deliver platform-type assertions passed."
  exit 0
else
  puts "#{@failures} assertion(s) failed."
  exit 1
end
