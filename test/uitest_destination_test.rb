#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression test for bin/uitest-destination.sh's default simulator name.
#
# Why this exists: with SIMULATOR_NAME unset the script names the last iPhone
# `xcrun simctl list devices available` prints. Its capture stopped at the
# FIRST opening parenthesis, so "iPhone SE (3rd generation)" came out as
# "iPhone SE", a simulator nobody has, and xcodebuild failed before a single
# test ran. On a hosted macos-15 runner that model is the LAST iPhone listed,
# so the default was the broken name on every run.
#
# The contract pinned here:
#   - a parenthesised model name is captured whole
#   - a plain model name is unchanged
#   - SIMULATOR_NAME still wins
#   - an empty simulator list still falls back to "iPhone 16"
#   - a remembered OFFLINE phone is still never chosen as a device
#
# A CONTROL runs the pre-fix capture over the same fixture and must produce
# the truncated name. If the fixture ever stops telling the two apart, the
# control turns this red rather than letting the real assertions pass
# vacuously.
#
# `xcrun` is stubbed on PATH, so this runs on any machine, Linux included.
#
# Runnable locally:
#   ruby test/uitest_destination_test.rb
#
# Wired into bootstrap-doctor-matrix.yml's `uitest-destination-regression` job.

require "open3"
require "tmpdir"
require "fileutils"

SCRIPT = File.expand_path("../bin/uitest-destination.sh", __dir__)
@failures = 0

def check(name, got, want)
  if got == want
    puts "ok   #{name}"
  else
    @failures += 1
    puts "FAIL #{name}\n     want: #{want.inspect}\n     got:  #{got.inspect}"
  end
end

# The tail of a real hosted macos-15 runner's `simctl list devices available`.
RUNNER_SIMCTL = <<~LIST
  == Devices ==
  -- iOS 18.6 --
      iPhone 16 Pro (291E4B86-C951-41A7-8327-84BF0304D0A9) (Shutdown)
      iPhone 16 Pro Max (9F3D563E-AF8A-4089-B32E-3ADADEB067F0) (Shutdown)
      iPhone 16e (1ECD563C-BBBB-42E5-9A9F-648809113BF6) (Shutdown)
      iPhone 16 (2911FD29-A09E-4A81-BEA7-99A616FB7FC8) (Shutdown)
      iPhone 16 Plus (CFF67BF1-533D-480D-9A76-F1EADAD339C7) (Shutdown)
      iPhone SE (3rd generation) (48B2DA2E-AF18-4E36-BB25-B25969A4EBCF) (Shutdown)
      iPad mini (A17 Pro) (0E5C0C39-5C8B-4B0E-9C39-2B0F8C3A1D11) (Shutdown)
LIST

PLAIN_LAST = <<~LIST
  -- iOS 18.6 --
      iPhone SE (3rd generation) (48B2DA2E-AF18-4E36-BB25-B25969A4EBCF) (Shutdown)
      iPhone 16 Plus (CFF67BF1-533D-480D-9A76-F1EADAD339C7) (Booted)
LIST

# A Mac with no phone plugged in that remembers one it once paired with.
NO_DEVICE_XCTRACE = <<~LIST
  == Devices ==
  Build Mac (00006001-000A1B2C3D4E5F60)
  == Devices Offline ==
  jp's iPhone (18.6) (00008110-000123456789801E)
  == Simulators ==
  iPhone 16 Simulator (18.6) (2911FD29-A09E-4A81-BEA7-99A616FB7FC8)
LIST

def run_script(simctl:, xctrace:, env: {})
  Dir.mktmpdir("uitest-dest-") do |dir|
    File.write(File.join(dir, "simctl.txt"), simctl)
    File.write(File.join(dir, "xctrace.txt"), xctrace)
    stub = File.join(dir, "xcrun")
    File.write(stub, <<~SH)
      #!/usr/bin/env bash
      case "$1" in
        simctl)  cat "#{dir}/simctl.txt" ;;
        xctrace) cat "#{dir}/xctrace.txt" ;;
        *)       exit 1 ;;
      esac
    SH
    File.chmod(0o755, stub)
    clean = { "SIMULATOR_NAME" => nil, "FORCE_SIMULATOR" => nil, "PATH" => "#{dir}:#{ENV['PATH']}" }
    out, err, status = Open3.capture3(clean.merge(env), "bash", SCRIPT)
    raise "script exited #{status.exitstatus}: #{err}" unless status.success?

    out.chomp
  end
end

check "parenthesised model captured whole",
      run_script(simctl: RUNNER_SIMCTL, xctrace: NO_DEVICE_XCTRACE),
      "platform=iOS Simulator,name=iPhone SE (3rd generation)"

check "plain model unchanged",
      run_script(simctl: PLAIN_LAST, xctrace: NO_DEVICE_XCTRACE),
      "platform=iOS Simulator,name=iPhone 16 Plus"

check "SIMULATOR_NAME wins",
      run_script(simctl: RUNNER_SIMCTL, xctrace: NO_DEVICE_XCTRACE, env: { "SIMULATOR_NAME" => "iPhone 16 Pro" }),
      "platform=iOS Simulator,name=iPhone 16 Pro"

check "empty simulator list falls back to iPhone 16",
      run_script(simctl: "== Devices ==\n", xctrace: NO_DEVICE_XCTRACE),
      "platform=iOS Simulator,name=iPhone 16"

check "offline phone is never chosen",
      run_script(simctl: RUNNER_SIMCTL, xctrace: NO_DEVICE_XCTRACE, env: {}).start_with?("platform=iOS Simulator"),
      true

# CONTROL: the pre-fix capture over the same fixture must truncate. If it does
# not, the fixture no longer discriminates and the assertions above prove nothing.
old_capture, = Open3.capture2("sed", "-nE", 's/^[[:space:]]*(iPhone[^(]*)\(.*/\1/p', stdin_data: RUNNER_SIMCTL)
old_last = old_capture.lines.map { |l| l.sub(/[[:space:]]*\z/, "") }.last
check "CONTROL: the pre-fix capture truncates the runner's last iPhone", old_last, "iPhone SE"

if @failures.zero?
  puts "\nAll uitest-destination assertions passed."
else
  puts "\n#{@failures} uitest-destination assertion(s) failed."
  exit 1
end
