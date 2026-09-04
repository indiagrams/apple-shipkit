#!/usr/bin/env ruby
# frozen_string_literal: true

# Every read of a file in this tree must state its encoding, and this test is
# what makes that a rule rather than a habit.
#
# WHY THIS EXISTS
#
# Ruby decides the encoding of a file it reads from the environment. With LANG
# and LC_ALL unset -- normal on a fresh machine, inside a cron job, inside a bare
# container -- Encoding.default_external is US-ASCII, so a read with no explicit
# encoding hands back a String tagged US-ASCII whose bytes are not. The read
# itself is silent. The next strip, the next concatenation, or the next regex
# raises ArgumentError or Encoding::CompatibilityError, and the operator gets a
# backtrace where a named refusal belonged.
#
# That is not a hypothetical for this template. It is the shipped configuration:
#
#   .bootstrap.env.example carries 53 lines with non-ASCII bytes, and
#   bin/init-bootstrap-env.sh copies it VERBATIM to .bootstrap.env. So every fork
#   starts from a file that trips it, and Bootstrap::Config.parse is the read
#   every entry point goes through -- `make doctor` and `make bootstrap-fork`
#   both died there, with a backtrace, before any step ran. The `strip` that
#   raises runs BEFORE the comment-skip, so commenting the line out did not help.
#   Reproduced under both a cleared and a set locale, and against both the shipped
#   example file and a pure-ASCII copy of it: the crash needs the non-ASCII bytes
#   AND the missing locale, and either one alone is green. A control that varied
#   only one of them would have proved nothing.
#
# Every suite here ran green throughout, because every CI runner sets a locale.
# That is precisely why a source-level gate is worth having: the runtime cannot
# see this, and the operator's machine can.
#
# Fixing one reported site at a time does not hold -- the next unpinned read is
# simply the next crash. So this file demands a stated verdict for EVERY read of
# a file in the tracked tree: pinned, binary, or an entry in EXEMPTIONS carrying
# a written reason. A read with no verdict fails.
#
# HOW IT AVOIDS TURNING ITSELF GREEN
#
# This is a scanner whose subject is the syntax its own source would otherwise
# have to contain, so a literal pattern here would match itself and quietly
# change what the gate reports. Every pattern below is ASSEMBLED FROM FRAGMENTS
# at runtime and no call form is ever spelled out -- not in code, not in a
# comment, not in an exemption reason -- and even this file's own reader goes
# through File.method rather than a literal call. There is NO self-exclusion
# entry: this file is enumerated exactly like every other, and group E5 MEASURES
# that it yields zero candidates. Self-exclusion would be a permanent hole;
# a measurement is not.
#
# FAILURE-LINE CONTRACT. One line per failure, no leading whitespace:
#
#     FAIL <group> <path>: <message>
#
#   E1  every candidate call site carries a verdict
#   E2  every exemption still matches exactly one real site
#   E3  non-vacuity: the enumeration and the candidate set are not empty
#   E4  the dynamic discriminator: real code, real bytes, locale cleared
#   E5  this file yields no candidates, and does so without excluding itself
#
# DEPENDENCIES: Ruby core only. The job that runs it uses bundler-cache: false,
# so a gem here would break it.

ROOT = File.expand_path("..", __dir__)

# --- fragments -----------------------------------------------------------
# Nothing below is ever written as a whole token. Receiver, separator, verb and
# paren are only ever composed at runtime, which is what keeps this file out of
# its own candidate set for a reason that can be measured rather than asserted.
SEP   = "."
OPEN  = "("
UTF8  = "UTF" + "-8"
ENC_K = "encod" + "ing"

RECEIVERS   = %w[File IO].freeze
TEXT_VERBS  = %w[read readlines foreach open].freeze
BIN_VERBS   = %w[binread binreadlines].freeze
STREAM_VERB = %w[each line].join("_")

def call_forms(verbs)
  RECEIVERS.product(verbs).map { |recv, verb| recv + SEP + verb + OPEN }
end

TEXT_CALLS   = call_forms(TEXT_VERBS).freeze
BIN_CALLS    = call_forms(BIN_VERBS).freeze
STREAM_CALL  = (SEP + STREAM_VERB).freeze
ENC_ARGUMENT = (ENC_K + ":").freeze
# A mode string naming an encoding after a colon, a binary mode, and a
# write/append mode. Assembled, never spelled.
MODE_WITH_ENC = /["'][rwa][b+]*:[A-Za-z0-9_-]+/.freeze
MODE_BINARY   = /["'][rwa][+]*b[+]*["']/.freeze
MODE_WRITE    = /["'][wa][b+]*["']/.freeze

# --- the private reader --------------------------------------------------
# This gate must read files, and must do so without spelling a call form.
# File.method(:...) produces the same Method object the literal call would, so
# the behaviour is identical and the source text is not a match.
READER = File.method(("op" + "en").to_sym)

def slurp(abs)
  READER.call(abs, "r:" + UTF8, &:read)
end

# --- assertions ----------------------------------------------------------
@checks   = 0
@failures = 0

def assert(condition, group, path, label)
  @checks += 1
  if condition
    puts "  ok #{group} #{path}: #{label}"
  else
    # One line, always. A message that put the group on one line and the path on
    # another would make every grep for a specific failure vacuous.
    puts "FAIL #{group} #{path}: #{label.to_s.gsub(/\s*\n\s*/, ' ')}"
    @failures += 1
  end
end

def no_verdict(message)
  # Refusing a verdict is not the same as passing. Exit 2, never 0.
  puts "FAIL E3 -: cannot run -- #{message}"
  puts
  puts "encoding gate CANNOT RUN: #{message}"
  exit 2
end

# --- the exemption table -------------------------------------------------
# Keyed by path plus a CONTENT ANCHOR, never by line number: a line number goes
# stale the moment anything above it moves, and a stale key silently stops
# matching, which is a hole rather than a failure. Group E2 asserts every entry
# matches EXACTLY ONE candidate in the current tree -- zero is stale, more than
# one is ambiguous, and both fail.
#
# Every reason below was measured under a cleared locale on Ruby 3.3 and 4.0,
# not reasoned about.
EXEMPTIONS = [
  {
    path:   "bin/lib/bootstrap.rb",
    anchor: "out_err",
    reason: "Not a file read. This iterates the combined-output handle yielded by " \
            "Open3.popen2e, so the encoding comes from the child spawn rather than from a " \
            "path on disk, and no encoding argument is accepted here. Measured under a " \
            "cleared locale: the iteration, the echo to the caller's IO and the append to " \
            "the capture buffer all complete without raising. Worth knowing rather than " \
            "hiding: the buffer this returns is tagged US-ASCII and reports valid_encoding? " \
            "false, so a caller that later matches a regex against it would raise. That is a " \
            "separate question about process output, not about reading a tracked file."
  },
  {
    path:   "test/sh_stream_test.rb",
    anchor: "body",
    reason: "The subject under test is stream buffering, and this test writes the bytes it " \
            "later reads back into its own temporary file, so it controls them and they are " \
            "pure ASCII. Pinning here would change what is being measured rather than fix " \
            "anything."
  },
  {
    path:   "test/sh_stream_test.rb",
    anchor: "mid_run",
    reason: "Same temporary file, same test-controlled ASCII bytes, mid-run assertion."
  },
  {
    path:   "test/sh_stream_test.rb",
    anchor: "empty?",
    reason: "Same temporary file, same test-controlled ASCII bytes; this is the control " \
            "assertion proving the redirect assertions discriminate."
  }
].freeze

# --- enumeration ---------------------------------------------------------
# git ls-files, as an argv array through IO.popen -- never a shell string, and
# never a shell `git grep`, because quoting silently changes a candidate set. An
# exit code other than zero, or an empty list, is a reason to refuse a verdict
# rather than to report a clean tree.
listing = begin
  IO.popen(%w[git ls-files -z], chdir: ROOT, err: File::NULL, &:read)
rescue SystemCallError => e
  no_verdict("git ls-files could not run in #{ROOT}: #{e.message}")
end
no_verdict("git ls-files exited #{$?&.exitstatus.inspect} in #{ROOT}") unless $?&.success?

tracked = listing.to_s.split("\0").reject(&:empty?).sort
no_verdict("git ls-files listed no tracked files in #{ROOT}") if tracked.empty?

RUBYISH = ->(rel) { rel.end_with?(".rb") || rel == "fastlane/Fastfile" }
scanned = tracked.select { |rel| RUBYISH.call(rel) }

# --- the candidate scan --------------------------------------------------
Candidate = Struct.new(:rel, :line_no, :text)

candidates = []
unreadable = []
scanned.each do |rel|
  abs = File.join(ROOT, rel)
  next unless File.file?(abs)

  content = begin
    slurp(abs)
  rescue SystemCallError => e
    unreadable << [rel, e.message]
    next
  end

  content.lines.each_with_index do |text, idx|
    hit = TEXT_CALLS.any? { |form| text.include?(form) } ||
          BIN_CALLS.any?  { |form| text.include?(form) } ||
          text.include?(STREAM_CALL)
    candidates << Candidate.new(rel, idx + 1, text.chomp) if hit
  end
end

# --- E3: non-vacuity, BEFORE any iteration over the collections ----------
# An `each` over an empty collection asserts nothing and reports success, so
# these come first rather than last.
assert scanned.length >= 20, "E3", "-",
       "the enumeration found #{scanned.length} Ruby-ish tracked files (floor 20); an " \
       "empty or tiny enumeration would make every assertion below vacuous"
assert candidates.length >= 15, "E3", "-",
       "the scan found #{candidates.length} candidate call sites (floor 15); a scan that " \
       "found none would pass silently while checking nothing"
%w[bin/lib/bootstrap.rb bin/adopt.rb fastlane/Fastfile test/encoding_test.rb].each do |known|
  assert scanned.include?(known), "E3", known,
         "known-positive path is present in the enumeration; if it were absent, a clean " \
         "result about it would mean only that nobody looked"
end
assert candidates.any? { |c| c.rel == "bin/lib/bootstrap.rb" }, "E3", "bin/lib/bootstrap.rb",
       "the file carrying the parser every entry point uses yields at least one candidate; " \
       "zero would mean the patterns stopped matching reality"
assert unreadable.empty?, "E3", "-",
       "every enumerated file was readable (#{unreadable.map(&:first).join(', ')})"

# --- E2: exemption integrity, before they are trusted as verdicts --------
exempt_lines = {}
EXEMPTIONS.each do |entry|
  matches = candidates.select { |c| c.rel == entry[:path] && c.text.include?(entry[:anchor]) }
  assert matches.length == 1, "E2", entry[:path],
         "exemption anchored on '#{entry[:anchor]}' matches exactly one candidate (found " \
         "#{matches.length}); zero means the exemption is STALE and has become a silent " \
         "hole, more than one means it is ambiguous and covers a site nobody read"
  assert !entry[:reason].to_s.strip.empty?, "E2", entry[:path],
         "exemption anchored on '#{entry[:anchor]}' carries a written reason"
  matches.each { |m| exempt_lines[[m.rel, m.line_no]] = entry }
end

# --- E1: every candidate carries a verdict -------------------------------
candidates.each do |c|
  verdict =
    if exempt_lines.key?([c.rel, c.line_no])
      "exempt"
    elsif BIN_CALLS.any? { |form| c.text.include?(form) } || c.text.match?(MODE_BINARY)
      "binary"
    elsif c.text.include?(ENC_ARGUMENT) || c.text.match?(MODE_WITH_ENC)
      "pinned"
    elsif c.text.match?(MODE_WRITE)
      # Measured on both interpreters with LANG, LC_ALL and LC_CTYPE all cleared:
      # the WRITE side does not raise. Ruby does not transcode a String to the
      # default external encoding on the way out; it emits the String's own bytes.
      # The falsifiable half of this class is the READ.
      "write"
    end

  assert !verdict.nil?, "E1", c.rel,
         verdict ? "line #{c.line_no} carries the verdict #{verdict}" :
         "line #{c.line_no} reads a file with the encoding inherited from the environment " \
         "and no stated verdict. With the locale unset that String is tagged US-ASCII and " \
         "the next strip, concatenation or regex raises. Give the call an explicit encoding, " \
         "use the binary form for key material, or add an EXEMPTIONS entry in " \
         "test/encoding_test.rb with a measured reason: #{c.text.strip}"
end

# --- E5: this file is scanned, and yields nothing, without excluding itself
own = candidates.select { |c| c.rel == "test/encoding_test.rb" }
assert own.empty?, "E5", "test/encoding_test.rb",
       "the gate's own source yields zero candidates (found #{own.length}: " \
       "#{own.map(&:line_no).join(', ')}). It is enumerated like every other file and there " \
       "is no self-exclusion entry anywhere in this file; it is clean because every pattern " \
       "is composed from fragments at runtime and no call form is ever spelled out. A " \
       "scanner that had to exclude itself would carry a permanent hole"
assert EXEMPTIONS.none? { |e| e[:path] == "test/encoding_test.rb" }, "E5", "test/encoding_test.rb",
       "there is no exemption entry for this file, so E5 above is a measurement rather than " \
       "a consequence of opting out"

# --- E4: the dynamic discriminator ---------------------------------------
# Source text is not behaviour. This spawns a locale-cleared child that loads the
# real library and runs the REAL parser against the REAL tracked example dotenv --
# the file bin/init-bootstrap-env.sh copies verbatim into every fork, and the
# exact pair (those bytes, that missing locale) that used to raise. It needs no
# .bootstrap.env, no secret and no Xcode, so it is safe in a bare checkout.
#
# The child rescues Exception and prints a sentinel either way, so a LoadError or
# a missing file surfaces as a named failure instead of as an exception with zero
# FAIL lines -- easy to walk into here, because the subject of this gate IS a crash.
child_script = <<~CHILD
  require "pathname"
  puts "EXT=" + Encoding.default_external.to_s
  begin
    require File.expand_path("bin/lib/bootstrap.rb", Dir.pwd)
    keys = Bootstrap::Config.parse(Pathname.new(".bootstrap.env.example")).length
    puts "PARSE=ok keys=" + keys.to_s
  rescue Exception => e
    puts "PARSE=raised " + e.class.to_s + ": " + e.message.lines.first.to_s.strip
  end
CHILD

ruby_bin = File.join(RbConfig::CONFIG["bindir"], RbConfig::CONFIG["ruby_install_name"])
cleared  = { "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil }
child_out = begin
  IO.popen([cleared, ruby_bin, "-e", child_script], chdir: ROOT, err: [:child, :out], &:read).to_s
rescue SystemCallError => e
  "SPAWN_FAILED #{e.message}"
end

ext_line   = child_out.lines.find { |l| l.start_with?("EXT=") }.to_s.strip
parse_line = child_out.lines.find { |l| l.start_with?("PARSE=") }.to_s.strip

# Assert the discriminator is LIVE before asserting the result. On a machine whose
# Ruby reports UTF-8 with the locale cleared, "it did not raise" is trivially true
# and proves nothing.
discriminator_live = ext_line == "EXT=US-ASCII"
assert discriminator_live, "E4", "-",
       "the locale-cleared child reports #{ext_line.empty? ? '(no EXT line at all)' : ext_line}, " \
       "and this discriminator is only meaningful when that is US-ASCII; anything else means " \
       "the assertion below proves nothing and must be repaired, not believed"
assert !parse_line.empty?, "E4", "-",
       "the locale-cleared child produced a PARSE verdict line (got: " \
       "#{child_out.strip.lines.last.to_s.strip.inspect}); no verdict means the child died " \
       "before reporting, and a silent pass there would be exactly the failure this gate exists " \
       "to catch"
if discriminator_live && !parse_line.empty?
  assert parse_line.start_with?("PARSE=ok"), "E4", "bin/lib/bootstrap.rb",
         "with LANG, LC_ALL and LC_CTYPE all cleared, the real parser reads the real tracked " \
         ".bootstrap.env.example -- the file every fork starts from -- and completes: #{parse_line}"
end

# --- verdict -------------------------------------------------------------
puts
puts "candidates=#{candidates.length} files=#{scanned.length} exemptions=#{EXEMPTIONS.length}"
if @failures.zero?
  puts "All #{@checks} encoding assertions passed."
  exit 0
else
  puts "#{@failures} of #{@checks} encoding assertion(s) failed."
  exit 1
end
