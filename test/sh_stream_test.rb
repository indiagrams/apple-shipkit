#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression test for Bootstrap::Sh.stream.
#
# Why this exists: `make ship` on a real release produced a THIRTEEN LINE log.
# Not a truncated one — thirteen lines was everything ship.rb printed itself,
# and nothing at all from the fastlane run those lines were describing. The
# same was true of a FAILED ship, which is the case where that output is the
# only thing worth having; diagnosing one meant reconstructing events from
# fastlane's report.xml and the App Store Connect API instead.
#
# The cause was `Sh.run`, which wraps Open3.capture3: it returns only when the
# command exits, discards stderr, and hands back a string that ship.rb's
# success branch then dropped on the floor. Nothing was broken about the
# redirect. The output never left the Ruby process.
#
# `Sh.stream` is the fix, and this pins its contract:
#   - stdout AND stderr are both captured (fastlane writes to both)
#   - success and failure are reported accurately
#   - output survives a FAILING command
#   - output reaches a redirect, which is what `make ship > ship.log` is
#   - output is written AS IT ARRIVES, not buffered until exit
#
# The last four assertions run against `Sh.run` as a CONTROL. If a future
# refactor makes capture3 satisfy them too, these tests stop discriminating
# and the control turns them red rather than letting them pass vacuously.
#
# Runnable locally:
#   ruby test/sh_stream_test.rb
#
# Wired into bootstrap-doctor-matrix.yml's `stream-regression` job.

$LOAD_PATH.unshift File.expand_path("../bin", __dir__)
require "lib/bootstrap"
require "tempfile"
require "stringio"

@failures = 0

def assert(cond, label)
  if cond
    puts "  ✓ #{label}"
  else
    puts "  ✗ #{label}"
    @failures += 1
  end
end

puts "Sh.stream regression tests:"

# ─── Both streams, and an accurate exit status ───────────────────────────────
out, ok = Bootstrap::Sh.stream("bash", "-c", "echo to-stdout; echo to-stderr >&2", io: StringIO.new)
assert out.include?("to-stdout"), "captures stdout"
assert out.include?("to-stderr"), "captures stderr (capture3 dropped this entirely)"
assert ok == true,                "reports success for an exit-0 command"

# ─── A failing command still yields its output ───────────────────────────────
# This is the case the 13-line log destroyed: a ship that fails and explains
# nothing.
out, ok = Bootstrap::Sh.stream("bash", "-c", "echo dying-words >&2; exit 3", io: StringIO.new)
assert ok == false,                  "reports failure for a non-zero exit"
assert out.include?("dying-words"),  "keeps output written by a FAILING command"

# ─── Output reaches a redirect ───────────────────────────────────────────────
Tempfile.create("shiplog") do |f|
  Bootstrap::Sh.stream("bash", "-c", "echo line-in-log; echo err-in-log >&2", io: f)
  f.flush
  body = File.read(f.path)
  assert body.include?("line-in-log"), "stdout reaches a redirect (`make ship > ship.log`)"
  assert body.include?("err-in-log"),  "stderr reaches a redirect"
end

# ─── Output is live, not buffered until exit ─────────────────────────────────
# Read the file while the child is still running. A capture3-shaped
# implementation has written nothing at this point; a streaming one has.
# The READER runs in the thread, not the command — so nothing races the
# subprocess and the command is left to exit on its own.
Tempfile.create("shiplive") do |f|
  marker = "early-line-#{Process.pid}"
  mid_run = nil
  reader = Thread.new do
    sleep 2
    f.flush
    mid_run = File.read(f.path)
  end
  Bootstrap::Sh.stream("bash", "-c", "echo #{marker}; sleep 5", io: f)
  reader.join
  assert mid_run.to_s.include?(marker), "output is written as it arrives, not buffered until exit"
end

# ─── CONTROL: the old behaviour must FAIL what the new one passes ────────────
# Without this, every assertion above could be satisfied by an implementation
# that changed nothing, and the suite would be decoration.
out, = Bootstrap::Sh.run("bash", "-c", "echo old-stdout; echo old-stderr >&2")
assert !out.include?("old-stderr"), "control: Sh.run drops stderr, so the stderr assertions discriminate"
Tempfile.create("oldlog") do |f|
  Bootstrap::Sh.run("bash", "-c", "echo this-goes-nowhere")
  assert File.read(f.path).empty?, "control: Sh.run writes nothing to a redirect, so the redirect assertions discriminate"
end

if @failures.zero?
  puts "\nAll 10 Sh.stream regression tests passed."
  exit 0
else
  puts "\n#{@failures} test(s) failed."
  exit 1
end
