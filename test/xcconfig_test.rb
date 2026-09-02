#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract test for bin/lib/xcconfig.rb — the one xcconfig reader.
#
# Why this exists: before that module, two consumers read app/Identity.xcconfig
# with two different hand-rolled readers, and both were wrong.
# bin/preflight-identity.rb decided "non-empty" with an `=[ \t]*\S` match,
# which accepted `BUNDLE_ID = // temporarily disabled` — a value Xcode resolves
# to the empty string, because `//` opens a comment at any position.
# ci/local-release-check.sh grepped app/project.yml's
# `PRODUCT_BUNDLE_IDENTIFIER:` line, which since the identity move carries the
# unresolved reference `$(BUNDLE_ID)` rather than a value. Each was correct
# about the input it was written against and wrong about the next one.
#
# One body is the fix; this fixture set is what makes it a fix rather than
# another reader. Every expected value below was OBSERVED, not reasoned about:
# the semantic rows come from `xcodebuild -showBuildSettings` on Xcode 26.1.1
# (17B100) with XcodeGen 2.46.0, reading back probe keys appended to an
# identity xcconfig. Do NOT "correct" a row here to match an implementation —
# re-measure against Xcode and change both.
#
# Output / exit contract:
#
#   Line                                    | Meaning
#   ----------------------------------------+---------------------------------
#   ✓ <label>                               | one observed row agrees
#   ✗ <label> then expected:/actual:        | the parser disagrees with Xcode
#   FAIL xcconfig - : <LoadError message>   | bin/lib/xcconfig.rb is absent
#   xcconfig_test: N checks, M failures     | always the last line
#
#   Exit 0 = every row agrees. Exit 1 = at least one row disagrees, or the
#   module could not be loaded at all.
#
# What this test CANNOT see: whether Xcode still behaves this way (the rows are
# a recording of one Xcode version, not a live oracle); SDK-conditional
# `KEY[sdk=…]` assignments, where it asserts only that the base assignment wins,
# which is all a text parser can know; and a real build's `$(inherited)` chain,
# which reaches outside the xcconfig file entirely.
#
# The live-file cases drive app/Identity.xcconfig through the CLI only, and
# assert that each of the four required keys resolves non-empty — never a
# literal value, so a fork that has run bin/rename.sh still passes. They never
# read or print app/Local.xcconfig and never assert on DEVELOPMENT_TEAM.
#
# Runnable locally:
#   ruby test/xcconfig_test.rb
#
# Wired into bootstrap-doctor-matrix.yml's `xcconfig-regression` job.
#
# Ruby stdlib only — and the parser itself has no `require` at all, asserted
# below. That job sets `bundler-cache: false` on the strength of it, and
# bin/preflight-identity.rb runs on a bare runner before `bundle install`.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT   = File.expand_path("..", __dir__)
PARSER = File.join(ROOT, "bin", "lib", "xcconfig.rb")
LIVE   = File.join(ROOT, "app", "Identity.xcconfig")

# The four keys app/Identity.xcconfig owns. Duplicated here on purpose rather
# than read out of the file under test — a test that derived its list from its
# subject would assert whatever the subject happened to say.
LIVE_KEYS = %w[BUNDLE_ID APP_PRODUCT_NAME DISPLAY_NAME COPYRIGHT].freeze

# Clearing the locale is what makes the © case a real regression test: with
# LANG unset Ruby defaults Encoding.default_external to US-ASCII, and a parser
# that read the file without an explicit encoding would raise ArgumentError
# instead of printing.
NO_LOCALE = { "LC_ALL" => nil, "LANG" => nil, "LC_CTYPE" => nil }.freeze

# The module has to load before anything can be asserted about it. A LoadError
# is a FAILURE of this test, not a crash of it, so it stays legible in a
# transcript.
begin
  require_relative "../bin/lib/xcconfig"
rescue LoadError => e
  puts "FAIL xcconfig - : #{e.message}"
  puts "xcconfig_test: 0 checks, 1 failures"
  exit 1
end

@checks   = 0
@failures = 0

def assert_eq(actual, expected, label)
  @checks += 1
  if actual == expected
    puts "  ✓ #{label}"
  else
    puts "  ✗ #{label}"
    puts "    expected: #{expected.inspect}"
    puts "    actual:   #{actual.inspect}"
    @failures += 1
  end
end

# Value-free assertion: used wherever printing the actual would print something
# read out of a fork's live tree.
def assert(condition, label)
  @checks += 1
  if condition
    puts "  ✓ #{label}"
  else
    puts "  ✗ #{label}"
    @failures += 1
  end
end

# A throwaway tree per case. Include cases need real relative paths on disk, so
# a Tempfile per fixture is not enough; block form so nothing survives a
# failure.
def with_tree(files)
  Dir.mktmpdir("xcconfig-test") do |root|
    files.each do |name, body|
      path = File.join(root, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body, encoding: "UTF-8")
    end
    yield root
  end
end

# Drives the CLI as a real subprocess under the interpreter running this test,
# so the exit code observed is the one a shell caller would see.
def cli(*argv, env: {})
  stdout, stderr, status = Open3.capture3({}.merge(env), RbConfig.ruby, PARSER, *argv)
  [stdout, stderr, status.exitstatus]
end

# ─── The Xcode-observed rows ─────────────────────────────────────────────────
#
# One file, because that is how Xcode read them during the probe. Interior
# whitespace in PROBE_SPACES is load-bearing; the tabs in PROBE_TAB are written
# as \t so no editor can helpfully expand them.
MAIN = <<~CFG
  // Identity-style header. The next line is app/Identity.xcconfig's own
  // comment, which contains an `=` — a .env-shaped parser turns it into a
  // key, and that is the point:
  // PRODUCT_NAME = $(APP_PRODUCT_NAME) in each manifest
  APP_PRODUCT_NAME = HelloApp
  PROBE_REF = $(APP_PRODUCT_NAME) Pro
  PROBE_QUOTED = "quoted value"
  PROBE_EQUALS = a=b
  PROBE_SPACES = two  spaces   kept
  PROBE_NOSPACE=tight
  PROBE_TAB\t=\ttabbed
  PROBE_COND = base
  PROBE_COND[sdk=iphoneos*] = ios-only
  PROBE_INHERIT = $(inherited) extra
  PROBE_EMPTYPAREN = $(UNDEFINED_VAR)x
  PROBE_TRAILING = value // note
  PROBE_DISABLED = // disabled
  PROBE_SLASHSLASH = //
  PROBE_URL = https://example.com/x
  PROBE_SLASH = /
  PROBE_AB = a/b
  PROBE_CYCLE_A = $(PROBE_CYCLE_B)
  PROBE_CYCLE_B = $(PROBE_CYCLE_A)
  #include? "Missing-File.xcconfig"
CFG

puts "xcconfig — the rows observed on Xcode 26.1.1:"

with_tree("Main.xcconfig" => MAIN) do |root|
  f = File.join(root, "Main.xcconfig")
  assert_eq Xcconfig.value(f, "PROBE_REF"),        "HelloApp Pro",       "`$(APP_PRODUCT_NAME) Pro` expands from the resolved set"
  assert_eq Xcconfig.value(f, "PROBE_QUOTED"),     '"quoted value"',     "`\"quoted value\"` keeps its quotes — they are literal characters"
  assert_eq Xcconfig.value(f, "PROBE_EQUALS"),     "a=b",                "`a=b` splits on the FIRST `=` only"
  assert_eq Xcconfig.value(f, "PROBE_SPACES"),     "two  spaces   kept", "interior whitespace preserved, ends trimmed"
  assert_eq Xcconfig.value(f, "PROBE_NOSPACE"),    "tight",              "`KEY=value` with no spaces around `=`"
  assert_eq Xcconfig.value(f, "PROBE_TAB"),        "tabbed",             "tabs are valid whitespace around `=`"
  assert_eq Xcconfig.value(f, "PROBE_COND"),       "base",               "`KEY[sdk=iphoneos*]` is SDK-scoped and ignored; the base assignment wins"
  assert_eq Xcconfig.value(f, "PROBE_INHERIT"),    " extra",             "`$(inherited) extra` → ` extra`, leading space kept"
  assert_eq Xcconfig.value(f, "PROBE_EMPTYPAREN"), "x",                  "`$(UNDEFINED_VAR)x` → `x`, an undefined reference is empty"
  assert_eq Xcconfig.value(f, "PROBE_TRAILING"),   "value",              "`value // note` → `value`, the comment is cut"
  assert_eq Xcconfig.value(f, "PROBE_DISABLED"),   "",                   "`// disabled` → \"\" — the hole in the old predicate, and the whole reason for the cut"
  assert_eq Xcconfig.value(f, "PROBE_SLASHSLASH"), "",                   "a bare `//` → \"\""
  assert_eq Xcconfig.value(f, "PROBE_URL"),        "https:",             "`https://example.com/x` → `https:` — `//` opens a comment at ANY position"
  assert_eq Xcconfig.value(f, "PROBE_SLASH"),      "/",                  "a lone `/` is a real value"
  assert_eq Xcconfig.value(f, "PROBE_AB"),         "a/b",                "a single `/` inside a value is a real value"

  assert_eq Xcconfig.value(f, "NEVER_ASSIGNED"),   nil,                  "a never-assigned key is nil, distinct from \"\""
  assert_eq Xcconfig.value(f, "PRODUCT_NAME"),     nil,                  "a `//` comment line containing `=` defines nothing"
  assert_eq Xcconfig.value(f, "APP_PRODUCT_NAME"), "HelloApp",           "`#include? \"Missing-File.xcconfig\"` is silent — the file still resolves"
  assert  Xcconfig.value(f, "PROBE_CYCLE_A").is_a?(String),              "a `$(A)`→`$(B)`→`$(A)` expansion cycle terminates at the depth guard"
end

# ─── Includes: position, last-wins across the boundary, hard miss, cycle ─────

puts
puts "xcconfig — #include semantics:"

with_tree("Main.xcconfig" => %(K = first\nK = second\n#include? "Inc.xcconfig"\n),
          "Inc.xcconfig"  => %(K = from-include\n)) do |root|
  assert_eq Xcconfig.value(File.join(root, "Main.xcconfig"), "K"), "from-include",
            "last assignment wins ACROSS an include placed after two local assignments"
end

with_tree("Main.xcconfig" => %(#include? "Inc.xcconfig"\nK = after\n),
          "Inc.xcconfig"  => %(K = from-include\n)) do |root|
  assert_eq Xcconfig.value(File.join(root, "Main.xcconfig"), "K"), "after",
            "an include is position-sensitive: placed FIRST, the local assignment after it wins"
end

with_tree("Main.xcconfig" => %(K = kept\n#include "Definitely-Missing.xcconfig"\n)) do |root|
  raised = nil
  begin
    Xcconfig.value(File.join(root, "Main.xcconfig"), "K")
  rescue Xcconfig::MissingInclude => e
    raised = e
  end
  assert !raised.nil?, "a hard `#include` of a missing file raises Xcconfig::MissingInclude, not a silent empty"
  assert raised && raised.message.include?("Definitely-Missing.xcconfig"),
         "the MissingInclude message names the include that could not be found"
end

with_tree("A.xcconfig" => %(#include "B.xcconfig"\n),
          "B.xcconfig" => %(#include "A.xcconfig"\n)) do |root|
  raised = nil
  begin
    Xcconfig.value(File.join(root, "A.xcconfig"), "K")
  rescue Xcconfig::MissingInclude => e
    raised = e
  end
  assert raised && raised.message.include?("cycle"),
         "an include cycle (A→B→A) raises MissingInclude naming a cycle"
end

# ─── Xcconfig.own: what a file's OWN text assigns, no #include followed ──────
#
# `value` answers "what would Xcode resolve here", which follows `#include?`.
# That is the right question for a build and the WRONG question for a leak
# check. app/Identity.xcconfig ends with `#include? "Local.xcconfig"`, so on
# every machine that has the gitignored file `Xcconfig.value(identity,
# "DEVELOPMENT_TEAM")` returns the LOCAL team. If bin/preflight-identity.rb's
# warning ("a Team ID defined in the TRACKED file is a Team ID in git") asked
# `value`, it would fire on every developer machine about a value that is not
# tracked at all — a false security warning, which trains its reader to ignore
# the true one. `own` is the second question, asked of the same one parser body
# rather than of a second reader.

puts
puts "xcconfig — Xcconfig.own (the file's own assignments; includes recognised, not followed):"

assert Xcconfig.respond_to?(:own),
       "Xcconfig.own exists — the tracked-Team-ID check needs \"what does THIS file say\", not \"what would Xcode resolve\""

if Xcconfig.respond_to?(:own)
  with_tree("Main.xcconfig" => %(K = mine\nT = // disabled\nR = $(K)\n#include? "Inc.xcconfig"\n),
            "Inc.xcconfig"  => %(K = theirs\nONLY_THEIRS = yes\n)) do |root|
    f = File.join(root, "Main.xcconfig")

    assert_eq Xcconfig.own(f)["K"], "mine",
              "own does NOT follow the include — `value` would say `theirs` (last-wins across the boundary)"
    assert_eq Xcconfig.value(f, "K"), "theirs",
              "…and `value` on the same file DOES say `theirs`, so the two questions are observably different"
    assert_eq Xcconfig.own(f)["ONLY_THEIRS"], nil,
              "a key that only the INCLUDED file assigns is absent from own — this is the Local.xcconfig case"
    assert_eq Xcconfig.own(f)["T"], "",
              "own applies the same `//` cut as load: `// disabled` is \"\", so a commented-out value is not a leak"
    assert_eq Xcconfig.own(f)["R"], "$(K)",
              "own returns the RAW assignment, unexpanded — the same shape the replaced predicate tested"
  end

  with_tree("Main.xcconfig" => %(K = kept\n#include "Definitely-Missing.xcconfig"\n)) do |root|
    raised = nil
    begin
      Xcconfig.own(File.join(root, "Main.xcconfig"))
    rescue Xcconfig::MissingInclude => e
      raised = e
    end
    assert raised.nil?,
           "own does not raise on a hard-include miss: nothing was asked of the included file (`value` still raises — asserted above)"
  end
else
  puts "  (skipped: Xcconfig.own is not defined, so the assertions below cannot run)"
end

# ─── CLI contract ────────────────────────────────────────────────────────────

puts
puts "xcconfig — CLI contract (exit 0 value / exit 3 undefined-or-empty / exit 2 usage):"

with_tree("Main.xcconfig" => MAIN) do |root|
  f = File.join(root, "Main.xcconfig")

  out, _err, code = cli(f, "PROBE_REF")
  assert_eq [out, code], ["HelloApp Pro\n", 0], "CLI prints the resolved value and exits 0"

  _out, err, code = cli(f, "NOPE")
  assert_eq code, 3, "CLI exits 3 on a key that was never assigned"
  assert err.include?("NOPE") && err.include?("undefined"), "CLI stderr names the key and says `undefined`"

  _out, err, code = cli(f, "PROBE_DISABLED")
  assert_eq code, 3, "CLI exits 3 on `// disabled` — the comment-only value is empty, not a value"
  assert err.include?("PROBE_DISABLED") && err.include?("empty"), "CLI stderr names the key and says `empty`"
end

with_tree("Only.xcconfig" => %(K = $(UNDEFINED)\n)) do |root|
  _out, err, code = cli(File.join(root, "Only.xcconfig"), "K")
  assert_eq code, 3, "CLI exits 3 when the value is only `$(UNDEFINED)` — assigned, resolves to nothing"
  assert err.include?("K") && err.include?("empty"), "the `$(UNDEFINED)`-only failure is reported as `empty`, not `undefined`"
end

with_tree("Main.xcconfig" => %(K = kept\n#include "Definitely-Missing.xcconfig"\n)) do |root|
  _out, err, code = cli(File.join(root, "Main.xcconfig"), "K")
  assert code != 0 && code != 3, "CLI on a hard-include miss exits non-zero and NOT 3 — it is an error, not an empty value"
  assert err.include?("MissingInclude") && err.include?("Definitely-Missing.xcconfig"),
         "the CLI propagates a NAMED MissingInclude naming the file"
end

_out, err, code = cli(LIVE)
assert_eq code, 2, "CLI with fewer than two arguments exits 2 (usage), never 0"
assert err.match?(/usage/i), "the usage message says `usage`"

# ─── The live tracked file, through the CLI only ─────────────────────────────
#
# Value-free on purpose. A fork that has run bin/rename.sh has four different
# values here and must still pass; what is asserted is that each of the four
# keys the preflight requires resolves to something non-empty through the same
# reader the preflight and the release check use.

puts
puts "xcconfig — app/Identity.xcconfig, read through the CLI (never Local.xcconfig):"

LIVE_KEYS.each do |key|
  out, _err, code = cli(LIVE, key)
  assert code.zero? && !out.chomp.empty?, "the live #{key} exits 0 with a non-empty value"
end

out, _err, code = cli(LIVE, "COPYRIGHT", env: NO_LOCALE)
assert code.zero? && out.b.include?("\xC2\xA9".b),
       "COPYRIGHT keeps its © (bytes c2 a9) with LC_ALL/LANG/LC_CTYPE cleared"

_out, err, code = cli(LIVE, "DEFINITELY_NOT_A_KEY")
assert_eq code, 3, "an undefined key in the live file exits 3"
assert err.include?("DEFINITELY_NOT_A_KEY"), "the live-file failure names the key"

# ─── The stdlib-only promise the regression job makes on this file's behalf ──

puts
puts "xcconfig — dependency discipline:"

assert File.file?(PARSER), "bin/lib/xcconfig.rb exists at the path every consumer will name"
assert_eq File.read(PARSER, encoding: "UTF-8").lines.grep(/\A\s*require\b/).map(&:strip), [],
          "bin/lib/xcconfig.rb has ZERO require lines — bin/preflight-identity.rb runs before `bundle install`"

puts
puts "xcconfig_test: #{@checks} checks, #{@failures} failures"
exit(@failures.zero? ? 0 : 1)
