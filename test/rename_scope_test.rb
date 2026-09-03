#!/usr/bin/env ruby
# frozen_string_literal: true

# Scope guard for bin/rename.sh.
#
# Why this exists, stated as the defect it prevents rather than as a rule.
#
# This template's identity — bundle id, product name, display name, copyright —
# lives in ONE tracked file, app/Identity.xcconfig, read by one parser
# (bin/lib/xcconfig.rb) and by both generators as $(VAR). Every one of those
# values used to be written by a sed sweep inside bin/rename.sh instead.
#
# A rename script that still substitutes identity AFTER the config-based scheme
# lands does not merely duplicate work: it silently re-introduces the
# two-sources-of-truth problem that file removed, and it does so on the ONE code
# path a forker runs before anything in this repository has ever been built. A
# fork created that way would carry an identity nothing in the tree agrees about,
# with every existing gate green — because every existing gate reads
# app/Identity.xcconfig, which the sweep would have written correctly on its way
# past. Nothing in this repository could have seen it.
#
# So this file asserts the SCOPE of bin/rename.sh in both directions:
#
#   NEGATIVE — the script contains none of the four literals that belonged to the
#     retired steps (bundle id, display-name placeholder, app-name sweep token,
#     Team ID placeholder). Each literal is asserted SEPARATELY so one
#     reintroduction proves one branch rather than four, and each failure names
#     the 1-based line numbers of every hit.
#
#   POSITIVE — the script DOES still contain the email and slug literals, and
#     does still declare the two substitution steps that consume them. Without
#     this half every negative assertion above is satisfied by an EMPTY FILE,
#     which is this project's dominant defect class (a check whose pass condition
#     is met regardless of what it claims to detect). The shape is copied from
#     test/identity_test.rb:301-309, where `preGenCommand` must EXIST and must
#     omit `--config`.
#
#   EXCLUSION — the slug step is scoped, and the scoping carries a greppable
#     marker plus the named list of sites that must keep pointing at the TEMPLATE
#     repository. This half exists because the unscoped sweep already caused
#     damage in a downstream fork of this template: its AGENTS.md row read
#     "open an upstream issue at <the fork's own slug>" where this repository's
#     reads `indiagrams/apple-shipkit`. The sweep rewrote the one pointer that
#     tells a forker where to send fixes upstream, and no gate saw it. This
#     assertion is what stops the mechanism from doing it again.
#
# FAILURE-LINE CONTRACT — this file adopts test/identity_test.rb:36-44's shape,
# NOT test/parser_test.rb's, and the choice is stated here because this plan's
# three negative controls grep for it. Every failed assertion prints ONE line,
# no leading whitespace:
#
#     FAIL <group> <path>: <message>
#
# where <group> is R1..R3 and <path> is the file the assertion is about.
#
# GREP-GATE HYGIENE. The vocabulary below (`HelloApp`, `com.example.helloapp`,
# the two placeholders) is discussed in prose throughout this repository —
# CHANGELOG.md and this very header legitimately contain
# it. A repo-wide grep would therefore need a self-exclusion list, which is where
# the hole gets drilled. Every assertion below reads ONE explicit, frozen file.
# THIS FILE IS DELIBERATELY NOT IN THAT LIST, so no self-exclusion is needed and
# no hole can be drilled here — the same rule test/identity_test.rb:46-54 states.
#
# The literals are spelled HERE, as frozen constants, and are never read out of
# bin/rename.sh. A test that took its vocabulary from the artifact under test
# would accept whatever that artifact happened to say, which is not a test.
#
# WHAT IS READ. The WORKING-TREE copy of bin/rename.sh, on purpose: the three
# negative controls in this plan mutate that copy and restore it, and a test that
# read `git show HEAD:bin/rename.sh` could not be driven red by them. That the
# file is TRACKED is asserted separately, so "the working copy is clean" and "the
# file is in the repository" are two claims with two assertions.
#
# Ruby core only, and in fact ZERO require-family lines — that is the basis for
# the `rename-scope-regression` job's `bundler-cache: false`. Every shell-out is an explicit
# argv array, never a shell string. There is no broad rescue anywhere in here.
#
# Runnable locally, from the repository root or from test/. Run it under BOTH
# pinned interpreters; on this machine ambient `ruby` IS 3.3, so the second path
# is spelled out:
#   /opt/homebrew/opt/ruby@3.3/bin/ruby test/rename_scope_test.rb
#   /opt/homebrew/opt/ruby@4.0/bin/ruby test/rename_scope_test.rb
#
# CI caller: the `rename-scope-regression` job in
# .github/workflows/bootstrap-doctor-matrix.yml, wired there in the same commit
# that trims the script. It is ubuntu-latest with `bundler-cache: false`, which
# this file's zero require-family lines are what keep honest.
#
# THAT JOB IS NOT A REQUIRED STATUS CHECK on `main`, and this comment says so
# rather than letting a reader assume otherwise: required contexts are live
# GitHub state, not anything in this repository, and adding one is a maintainer
# action. Until it is added, this suite reports and does not block.
#
# WHAT A GREEN BADGE THERE DOES NOT MEAN: this suite reads text. It says the
# script no longer SPELLS an identity literal; it does not run the script and
# says nothing about whether a rename it performs is correct.

ROOT = File.expand_path("..", __dir__)

# ─── the subject ─────────────────────────────────────────────────────────────
RENAME_SH = "bin/rename.sh"

# ─── R1 vocabulary — the four literals that retired with their steps ─────────
# The eight substitution steps this script used to run, and what became of each:
# A (<year>) retired because the year lives inside COPYRIGHT
# in app/Identity.xcconfig; B (bundle id) retired; E and G (the display-name
# placeholder pair) retired; F (the unbounded HelloApp sweep) retired; H (the
# Team ID) retired. C (email) and D (slug) survive and are R2's subject.
#
# Matched case-INSENSITIVELY. The template's other spelling of the bundle id is
# lowercase, and a case-sensitive `include?` ticked straight past exactly that in
# this repository once already (03-REVIEW IN-05, observed passing 24/24 with the
# lowercase form present).
RETIRED_LITERALS = [
  "com.example.helloapp",       # Step B — the template bundle id
  "__GSD_DISPLAY_PLACEHOLDER__", # Steps E/G — the display-name relay
  "HelloApp",                    # Step F — the unbounded app-name sweep token
  "TEAM_ID_PLACEHOLDER"          # Step H — the Apple Team ID placeholder
].freeze

# ─── R2 vocabulary — the two literals that must SURVIVE ──────────────────────
# Criterion 2 names prose, email and slug. These are the FROM sides of the two
# steps that stay, and the step declarations that consume them. Both are spelled
# here rather than derived, and both are what make R1 non-vacuous: an empty file
# satisfies every R1 assertion and fails every one of these.
SURVIVING_LITERALS = [
  "maintainers@indiagram.com",
  "indiagrams/apple-shipkit"
].freeze

# The two `step` declarations, anchored at line start after leading blanks, so a
# literal surviving only inside a comment cannot satisfy this half.
SURVIVING_STEPS = {
  "the email substitution step" =>
    /^[ \t]*step "Substituting maintainers@indiagram\.com/,
  "the slug substitution step" =>
    /^[ \t]*step "Substituting indiagrams\/apple-shipkit/
}.freeze

# ─── R3 vocabulary — the slug step's scope ───────────────────────────────────
# The greppable marker the trim introduces, and the sites whose every occurrence
# of the template slug names the TEMPLATE and must therefore survive a rename.
# The list is deliberately short: a site earns a place here only when EVERY
# occurrence of the template slug in it names the template, so that a count
# comparison across the slug step is a sound assertion for that file.
SLUG_EXCLUSION_MARKER = "GSD-SLUG-EXCLUSION"
SLUG_KEEP_TEMPLATE_SITES = [
  "AGENTS.md",
  "Makefile"
].freeze

# ─── harness (test/identity_test.rb:161-194, adopted unchanged) ──────────────

@failures = 0
@checks   = 0

def assert(condition, group, path, label)
  @checks += 1
  if condition
    puts "  ✓ #{group} #{path}: #{label}"
  else
    # One line, always. A message that put the group on one line and the path on
    # another would make every control that greps `^FAIL R1 bin/rename.sh`
    # vacuous, which is the defect this whole phase exists to avoid.
    puts "FAIL #{group} #{path}: #{label.to_s.gsub(/\s*\n\s*/, ' ')}"
    @failures += 1
  end
end

# UTF-8 pinned, never inherited. bin/rename.sh carries ✓, ✗, ⚠ and ─ in its own
# output helpers and box-drawing comments; with LANG unset Ruby defaults
# Encoding.default_external to US-ASCII and a non-ASCII byte raises out of the
# match instead of exiting 0 or 1. Two separate reads of tracked text in this
# template have raised exactly this way on a machine with no locale set, so the
# encoding is pinned rather than inherited.
def read_utf8(relative)
  File.read(File.join(ROOT, relative), encoding: "UTF-8")
end

# Argv array only — a shell string would let a path with a space or a
# metacharacter change what is executed.
def run(argv)
  out = IO.popen(argv, "r", err: [:child, :out], chdir: ROOT, &:read)
  [out.to_s, $?.exitstatus]
end

# 1-based line numbers in `text` for which the block is true.
def line_numbers(text)
  text.lines.each_with_index.filter_map { |line, i| i + 1 if yield(line) }
end

def suffix(hits)
  hits.empty? ? "" : " — found at line(s) #{hits.join(', ')}"
end

# ─── existence and tracking, before anything reads the file ──────────────────

puts "R1 — #{RENAME_SH} spells none of the retired steps' literals:"

rename_path   = File.join(ROOT, RENAME_SH)
rename_exists = File.file?(rename_path)
assert rename_exists, "R1", RENAME_SH,
       "exists as a regular file, so its scope can be asserted at all"

tracked_out, tracked_exit = run(%w[git ls-files --] + [RENAME_SH])
assert tracked_exit.zero? && !tracked_out.strip.empty?, "R1", RENAME_SH,
       "is tracked (git ls-files names it; exit=#{tracked_exit}, " \
       "output=#{tracked_out.strip.inspect})"

# A missing file must FAIL every assertion below, never skip them into a silent
# pass. `text` is the empty string in that case and the existence assertion above
# has already reported the real defect — but the POSITIVE half (R2) is what turns
# an empty subject into failures rather than into a clean run.
text = rename_exists ? read_utf8(RENAME_SH) : ""

# ─── R1: the negative half, one assertion per retired literal ────────────────

RETIRED_LITERALS.each do |literal|
  needle = literal.downcase
  hits   = line_numbers(text) { |line| line.downcase.include?(needle) }
  assert hits.empty?, "R1", RENAME_SH,
         "contains no `#{literal}` literal in any letter case#{suffix(hits)}"
end

# ─── R2: the positive half — without it, an empty file passes R1 ─────────────

puts
puts "R2 — #{RENAME_SH} still personalizes email and slug (so R1 is not vacuous):"

SURVIVING_LITERALS.each do |literal|
  hits = line_numbers(text) { |line| line.include?(literal) }
  assert !hits.empty?, "R2", RENAME_SH,
         "still contains the `#{literal}` literal, which is the FROM side of a " \
         "step criterion 2 KEEPS#{hits.empty? ? ' — found at no line' : suffix(hits)}"
end

SURVIVING_STEPS.each do |label, pattern|
  hits = line_numbers(text) { |line| line.match?(pattern) }
  assert !hits.empty?, "R2", RENAME_SH,
         "still declares #{label} (/#{pattern.source}/), not merely the literal in a " \
         "comment#{hits.empty? ? ' — matched at no line' : suffix(hits)}"
end

# ─── R3: the slug step's scope, and the sites it must never rewrite ──────────

puts
puts "R3 — the slug step is scoped, and names the sites that keep pointing upstream:"

marker_hits = line_numbers(text) { |line| line.include?(SLUG_EXCLUSION_MARKER) }
assert !marker_hits.empty?, "R3", RENAME_SH,
       "carries the `#{SLUG_EXCLUSION_MARKER}` marker, so the slug step's scope is " \
       "greppable rather than implicit#{marker_hits.empty? ? ' — found at no line' : suffix(marker_hits)}"

# An ARRAY ELEMENT, not merely a mention. The prose above the array names every
# one of these paths too, so a `line.include?(site)` test is satisfied by the
# comment alone and stays green with the array emptied — the pass condition met
# regardless of what it claims to detect, which is the defect class this file
# exists to refuse. Driven red against exactly that mutation: with the element
# removed and the comment left standing, the weaker form exited 0. The element
# form matches a line that is only the path, which inside a bash array literal
# is what an entry looks like.
SLUG_KEEP_TEMPLATE_SITES.each do |site|
  element = /\A[ \t]*#{Regexp.escape(site)}[ \t]*\z/
  hits = line_numbers(text) { |line| element.match?(line.chomp) }
  assert !hits.empty?, "R3", RENAME_SH,
         "lists `#{site}` as an ELEMENT of SLUG_KEEP_TEMPLATE_PATHS, so its slug " \
         "count is snapshotted across the slug step#{hits.empty? ? ' — found at no line' : suffix(hits)}"
end

# ─── verdict ─────────────────────────────────────────────────────────────────

puts
if @failures.zero?
  puts "All #{@checks} rename-scope assertions passed."
  exit 0
else
  puts "#{@failures} of #{@checks} rename-scope assertion(s) failed."
  exit 1
end
