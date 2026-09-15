#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression test for bin/setup-github.sh — the read-append-assert branch-protection
# write.
#
# WHY THIS EXISTS, AND WHY IT IS SHAPED THE WAY IT IS.
#
# The defect this pins is the one whose failure mode is silent. `bin/setup-github.sh`
# used to recompute the required-status-checks array from the platform matrix and PUT
# the whole `/protection` object. Nothing went red when it ran: a fork-added required
# job kept running and kept reporting, protection simply listed eight contexts where
# nine were expected, and a pull request with that job red became mergeable again. The
# check that stops gating looks exactly like the check that is gating.
#
# A test for a silent failure has to be positive. "Nothing blew up" is what the bug
# looks like, so every case below asserts on a value: the exact POST body computed for
# a before-list that is short by one, the exact exit code and stderr when the post-write
# read comes back short, and the preserved presence of a context the script has never
# heard of.
#
# THE SCRIPT UNDER TEST IS NEVER RUN UNTIL IT IS SAFE TO RUN IT. The pre-fix script's
# only protection code path is a destructive live PUT, so executing it "to see what it
# does" would perform the very write this suite exists to prevent. The static guard below
# therefore runs FIRST and reads the source as text: it fails when a
# `gh api -X PUT "repos/$REPO/branches/main/protection"` occurs outside a branch gated on
# a 404 probe, and it fails when the script advertises no SETUP_GITHUB_DRY_RUN. While
# either static assertion fails, the behavioural cases are SKIPPED with a FAIL line
# saying why. Red for this suite means "did not even run the script", deliberately.
#
# THE gh SHIM IS THE THIRD ASSERTION. Every behavioural case puts a scratch `gh` first on
# PATH that appends its argv to a log and exits 1. After each case the log must be empty.
# A stub that replaced a read but left a write live would show up here as a logged argv
# rather than as a passing test, and a `gh` that leaked through from the real PATH would
# fail the case outright.
#
# Runnable locally, no gem, no framework, matching test/parser_test.rb:
#   ruby test/setup_github_test.rb
#
# Wired into bootstrap-doctor-matrix.yml's `setup-github-regression` job.

require "open3"
require "tmpdir"
require "json"
require "rbconfig"

ROOT   = File.expand_path("..", __dir__)
SCRIPT = File.join(ROOT, "bin", "setup-github.sh")
REPO   = "example-org/example-fork"

# The eight contexts bin/setup-github.sh derives from the platform matrix on this tree
# (both generator manifests committed, PLATFORMS defaulting to ios,macos). Spelled here
# rather than scraped from the script, so that a change to the matrix shows up as a
# failure to explain rather than as a stub that silently follows the code.
TEMPLATE_CHECKS = [
  "app (iOS device)",
  "app (iOS Simulator)",
  "app (Tuist iOS device)",
  "app (Tuist iOS Simulator)",
  "app (macOS)",
  "app (Tuist macOS)",
  "swiftlint",
  "swiftformat"
].freeze

# A fork-added ninth, as a fork would name its own required job (spaces included).
FORK_CHECK = "fork added check"

@failures = 0

def assert(cond, label)
  if cond
    puts "  ✓ #{label}"
  else
    puts "  ✗ #{label}"
    @failures += 1
  end
  cond
end

def assert_eq(actual, expected, label)
  if actual == expected
    puts "  ✓ #{label}"
    true
  else
    puts "  ✗ #{label}"
    puts "    expected: #{expected.inspect}"
    puts "    actual:   #{actual.inspect}"
    @failures += 1
    false
  end
end

# ─── Static guard ────────────────────────────────────────────────────────────
#
# Reads the script as text. Never executes it.

source = File.read(SCRIPT, encoding: "UTF-8")
lines  = source.lines

# Bash `if`/`fi` depth walk from a gate line, returning the index range the block spans.
# `elif` is not matched (the `if` there is not preceded by start-of-line, `;` or space)
# and neither is the `fi` inside a word such as `verify`.
def if_block_range(lines, start_idx)
  depth = 0
  idx   = start_idx
  while idx < lines.length
    line = lines[idx]
    depth += line.scan(/(?:\A|;|\s)if\s/).length
    depth -= line.scan(/(?:\A|;|\s)fi(?:\s|;|\z)/).length
    return (start_idx..idx) if depth <= 0 && idx > start_idx

    idx += 1
  end
  (start_idx..(lines.length - 1))
end

PUT_PROTECTION = %r{-X\s+PUT\s+"repos/\$REPO/branches/main/protection"}
FOUR_OH_FOUR   = /(?:\A|;|\s)if\s.*404/

put_lines = lines.each_index.select { |i| lines[i] =~ PUT_PROTECTION }

gated_ranges = lines.each_index
                    .select { |i| lines[i] =~ FOUR_OH_FOUR }
                    .map { |i| if_block_range(lines, i) }

ungated_puts = put_lines.reject { |i| gated_ranges.any? { |r| r.cover?(i) } }

puts "bin/setup-github.sh — static guard (the script is not executed while this is red):"

static_put_ok = assert ungated_puts.empty?,
                       "SG bin/setup-github.sh: performs an unconditional PUT /protection" \
                       "#{ungated_puts.empty? ? '' : " — line(s) #{ungated_puts.map { |i| i + 1 }.join(', ')}"}"

static_dry_ok = assert source.include?("SETUP_GITHUB_DRY_RUN"),
                       "SG bin/setup-github.sh: no SETUP_GITHUB_DRY_RUN support"

static_post_ok = assert source.include?("required_status_checks/contexts"),
                        "SG bin/setup-github.sh: writes through the additive contexts endpoint"

static_extra_ok = assert source.include?("SETUP_GITHUB_EXTRA_CHECKS"),
                         "SG bin/setup-github.sh: takes a fork-added extra-checks list"

static_ok = static_put_ok && static_dry_ok && static_post_ok && static_extra_ok

unless static_ok
  puts
  puts "  ✗ SG behavioural cases SKIPPED: the script's only protection path is a live " \
       "destructive write, so running it would perform the write this suite exists to prevent"
  puts
  puts "#{@failures} failure(s)"
  exit 1
end

# ─── Behavioural cases ───────────────────────────────────────────────────────

# Runs the script inside a sandbox whose PATH begins with a `gh` that logs and fails.
# Returns [stdout, stderr, exitstatus, gh_log].
def run_script(env)
  Dir.mktmpdir("setup-github-test") do |dir|
    shim = File.join(dir, "gh")
    log  = File.join(dir, "gh-argv.log")
    File.write(shim, <<~SH)
      #!/bin/sh
      # Any invocation is a failure of the stub contract: under dry run with stubs the
      # script must not reach the network at all.
      printf '%s\\n' "$*" >> "#{log}"
      exit 1
    SH
    File.chmod(0o755, shim)

    base = {
      "PATH" => "#{dir}:#{ENV.fetch('PATH')}",
      "SETUP_GITHUB_DRY_RUN" => nil,
      "SETUP_GITHUB_STUB_BEFORE" => nil,
      "SETUP_GITHUB_STUB_AFTER" => nil,
      "SETUP_GITHUB_STUB_PROTECTION_STATUS" => nil,
      "SETUP_GITHUB_EXTRA_CHECKS" => nil
    }
    stdout, stderr, status = Open3.capture3(base.merge(env), "bash", SCRIPT, REPO, chdir: ROOT)
    gh_log = File.exist?(log) ? File.read(log, encoding: "UTF-8") : ""
    return [stdout, stderr, status.exitstatus, gh_log]
  end
end

def json_array(list)
  JSON.generate(list)
end

# The body the script printed on its `DRY RUN: would POST …` line, parsed.
def posted_contexts(stdout)
  line = stdout.lines.find { |l| l.include?("DRY RUN: would POST") }
  return nil unless line

  JSON.parse(line[/\{.*\}\s*\z/].to_s)["contexts"]
end

puts
puts "bin/setup-github.sh — dry-run behaviour against stubbed reads:"

# (a) The before-list is the eight template checks and the fork names its ninth.
#     The computed POST body must contain EXACTLY the missing context — not the whole
#     array, which is the shape of the bug.
out, err, code, ghlog = run_script(
  "SETUP_GITHUB_DRY_RUN" => "1",
  "SETUP_GITHUB_STUB_PROTECTION_STATUS" => "200",
  "SETUP_GITHUB_STUB_BEFORE" => json_array(TEMPLATE_CHECKS),
  "SETUP_GITHUB_STUB_AFTER" => json_array(TEMPLATE_CHECKS + [FORK_CHECK]),
  "SETUP_GITHUB_EXTRA_CHECKS" => FORK_CHECK
)
puts "(a) missing context is computed and posted alone"
assert out.include?("DRY RUN: would POST"), "(a) a POST is planned"
assert_eq posted_contexts(out), [FORK_CHECK], "(a) POST body contexts are exactly the missing one"
assert out.include?("required contexts: 9 (expected 9)"), "(a) the count line reports nine"
assert_eq code, 0, "(a) exit 0"
assert_eq ghlog, "", "(a) no real gh invocation"
puts err unless err.empty?

# (b) The live array already carries the fork check plus a context this script has never
#     heard of. Preserving `foo` is the property this fix exists for: the old code recomputed the array
#     from its own idea of the matrix and dropped everything it did not author.
before_b = TEMPLATE_CHECKS + [FORK_CHECK, "foo"]
out, _err, code, ghlog = run_script(
  "SETUP_GITHUB_DRY_RUN" => "1",
  "SETUP_GITHUB_STUB_PROTECTION_STATUS" => "200",
  "SETUP_GITHUB_STUB_BEFORE" => json_array(before_b),
  "SETUP_GITHUB_EXTRA_CHECKS" => FORK_CHECK
)
puts "(b) a context the script does not know about survives"
assert !out.include?("DRY RUN: would POST"), "(b) nothing to post"
assert out.include?("- foo"), "(b) the unknown context is still in the final list"
assert out.include?("required contexts: 10 (expected 10)"), "(b) the count includes it"
assert_eq code, 0, "(b) exit 0"
assert_eq ghlog, "", "(b) no real gh invocation"

# (c) The assertion has teeth. A post-write read that comes back short by one must fail
#     the run, loudly, with all three lists in the message.
out, err, code, ghlog = run_script(
  "SETUP_GITHUB_DRY_RUN" => "1",
  "SETUP_GITHUB_STUB_PROTECTION_STATUS" => "200",
  "SETUP_GITHUB_STUB_BEFORE" => json_array(TEMPLATE_CHECKS + [FORK_CHECK]),
  "SETUP_GITHUB_STUB_AFTER" => json_array(TEMPLATE_CHECKS),
  "SETUP_GITHUB_EXTRA_CHECKS" => FORK_CHECK
)
puts "(c) a short post-write read fails the run"
assert err.include?("protection assert failed:"), "(c) stderr names the assertion"
assert err.include?("before="), "(c) stderr shows before"
assert err.include?("after="),  "(c) stderr shows after"
assert err.include?("want="),   "(c) stderr shows want"
assert_eq code, 1, "(c) exit 1"
assert !out.include?("required contexts: 9 (expected 9)"), "(c) no success line is printed"
assert_eq ghlog, "", "(c) no real gh invocation"

# (d) Idempotence. The union is already satisfied, so a re-run must be a no-op that still
#     asserts the count — the property every re-run relies on.
out, _err, code, ghlog = run_script(
  "SETUP_GITHUB_DRY_RUN" => "1",
  "SETUP_GITHUB_STUB_PROTECTION_STATUS" => "200",
  "SETUP_GITHUB_STUB_BEFORE" => json_array(TEMPLATE_CHECKS + [FORK_CHECK])
)
puts "(d) an already-correct array is a no-op that still asserts"
assert !out.include?("DRY RUN: would POST"), "(d) nothing to post"
assert out.include?("required contexts: 9 (expected 9)"), "(d) nine in, nine out"
assert_eq code, 0, "(d) exit 0"
assert_eq ghlog, "", "(d) no real gh invocation"

# (e) First-time creation. A repository with no protection at all has nothing to preserve,
#     so the full PUT is the only case where it is allowed — and it must be reachable only
#     from here.
out, _err, code, ghlog = run_script(
  "SETUP_GITHUB_DRY_RUN" => "1",
  "SETUP_GITHUB_STUB_PROTECTION_STATUS" => "404",
  "SETUP_GITHUB_EXTRA_CHECKS" => FORK_CHECK
)
puts "(e) no protection yet — the full PUT is the creation path"
assert out.include?("DRY RUN: would PUT repos/#{REPO}/branches/main/protection"),
       "(e) the creation PUT is planned"
assert !out.include?("DRY RUN: would POST"), "(e) no additive POST on the creation path"
assert_eq code, 0, "(e) exit 0"
assert_eq ghlog, "", "(e) no real gh invocation"

# (f) Every other live write in the script is routed through the same dry-run wrapper, so
#     a dry run is total rather than partial. The repo-settings PATCH is the other one.
out, _err, code, ghlog = run_script(
  "SETUP_GITHUB_DRY_RUN" => "1",
  "SETUP_GITHUB_STUB_PROTECTION_STATUS" => "200",
  "SETUP_GITHUB_STUB_BEFORE" => json_array(TEMPLATE_CHECKS + [FORK_CHECK])
)
puts "(f) the dry run covers every write, not only the protection one"
assert out.include?("DRY RUN: would PATCH repos/#{REPO}"), "(f) the repo-settings write is dry-run too"
assert_eq code, 0, "(f) exit 0"
assert_eq ghlog, "", "(f) no real gh invocation"

puts
if @failures.zero?
  puts "all setup-github checks passed"
  exit 0
else
  puts "#{@failures} failure(s)"
  exit 1
end
