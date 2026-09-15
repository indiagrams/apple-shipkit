#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression test for bin/dump-failure-screenshots.sh's exit contract.
#
# Why this exists: the header said the script ALWAYS exits 0, "so a missing
# screenshot must not mask the test failure itself". It exits 1 on a usage
# error and when no .xcresult exists at the path. A CI step that trusted the
# header and ran it after a test step that failed before writing its bundle
# got a second, unrelated red. The header now states the real contract.
#
# The contract pinned here, and kept in step with the header:
#   - no path given                    -> 1
#   - no .xcresult at the path         -> 1
#   - a bundle with no failed tests    -> 0
#   - failed tests but no PNGs         -> 0
#   - a failed test with a PNG         -> 0, and the PNG is renamed to its own name
#
# A header check also fails if the `Exit:` block stops naming both non-zero
# cases, so the comment cannot drift back into promising "always 0".
#
# `xcrun` is stubbed on PATH; python3 is the only real dependency.
#
# Runnable locally:
#   ruby test/dump_failure_screenshots_test.rb
#
# Wired into bootstrap-doctor-matrix.yml's `dump-failure-screenshots-regression` job.

require "open3"
require "tmpdir"
require "fileutils"

SCRIPT = File.expand_path("../bin/dump-failure-screenshots.sh", __dir__)
@failures = 0

def check(name, got, want)
  if got == want
    puts "ok   #{name}"
  else
    @failures += 1
    puts "FAIL #{name}\n     want: #{want.inspect}\n     got:  #{got.inspect}"
  end
end

UUID = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"

def stubbed(tests_json:, export_png: false)
  Dir.mktmpdir("dump-shots-") do |dir|
    File.write(File.join(dir, "tests.json"), tests_json)
    stub = File.join(dir, "xcrun")
    File.write(stub, <<~SH)
      #!/usr/bin/env bash
      # xcrun xcresulttool get test-results tests ... | export attachments --output-path <dir> ...
      if [[ "$2" == "get" ]]; then cat "#{dir}/tests.json"; exit 0; fi
      if [[ "$2" == "export" ]]; then
        out=""; prev=""
        for a in "$@"; do [[ "$prev" == "--output-path" ]] && out="$a"; prev="$a"; done
        #{export_png ? %(printf 'png' > "$out/#{UUID}.png"; echo 'File: #{UUID}.png, suggested name: "final-state_0_#{UUID}.png"') : 'true'}
        exit 1
      fi
      exit 1
    SH
    File.chmod(0o755, stub)
    yield dir, { "PATH" => "#{dir}:#{ENV['PATH']}" }
  end
end

def run(env, *args)
  out, err, status = Open3.capture3(env, "bash", SCRIPT, *args)
  [status.exitstatus, out + err]
end

code, = run({}, *[])
check "no path given exits 1", code, 1

code, = run({}, "/nonexistent/Result.xcresult")
check "no .xcresult at the path exits 1", code, 1

none = '{"testNodes":[{"nodeType":"Test Case","result":"Passed","nodeIdentifier":"A/testA()"}]}'
failed = '{"testNodes":[{"nodeType":"Test Case","result":"Failed","nodeIdentifier":"A/testB()"}]}'

stubbed(tests_json: none) do |dir, env|
  bundle = File.join(dir, "R.xcresult"); FileUtils.mkdir_p(bundle)
  code, text = run(env, bundle, File.join(dir, "out"))
  check "a bundle with no failed tests exits 0", code, 0
  check "  and says so", text.include?("no failed tests in this bundle"), true
end

stubbed(tests_json: failed) do |dir, env|
  bundle = File.join(dir, "R.xcresult"); FileUtils.mkdir_p(bundle)
  code, text = run(env, bundle, File.join(dir, "out"))
  check "failed tests but no PNGs exits 0", code, 0
  check "  and says so", text.include?("no PNG attachments"), true
end

stubbed(tests_json: failed, export_png: true) do |dir, env|
  bundle = File.join(dir, "R.xcresult"); FileUtils.mkdir_p(bundle)
  out = File.join(dir, "out")
  code, = run(env, bundle, out)
  check "a failed test with a PNG exits 0", code, 0
  check "  and the PNG is renamed to its own name", File.exist?(File.join(out, "A-testB", "final-state.png")), true
end

# The header must name both non-zero cases, so it cannot drift back to "always 0".
exit_block = File.read(SCRIPT, encoding: "UTF-8")[/^# Exit:.*?(?=^#\s*$|^# To get)/m].to_s
check "header's Exit block does not promise always 0", exit_block.match?(/always 0/i), false
check "header's Exit block names the usage error", exit_block.match?(/usage error/i), true
check "header's Exit block names the missing bundle", exit_block.match?(/no \.xcresult exists/i), true

if @failures.zero?
  puts "\nAll dump-failure-screenshots assertions passed."
else
  puts "\n#{@failures} dump-failure-screenshots assertion(s) failed."
  exit 1
end
