#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/preflight-identity.rb — refuse to generate a project against an
# incomplete identity, and NAME the variable that is missing, before either
# generator runs.
#
# WHY THIS EXISTS
#
# app/Identity.xcconfig is the tracked source of truth for BUNDLE_ID,
# APP_PRODUCT_NAME, DISPLAY_NAME and COPYRIGHT. Nothing in XcodeGen or Tuist
# asserts that a variable a manifest references actually exists. If a key is
# missing from a present Identity.xcconfig, `$(BUNDLE_ID)` resolves to the
# empty string, BOTH generators exit 0 and write a project, and the macOS
# build then succeeds with an empty CFBundleIdentifier (observed on Xcode
# 26.1.1 with XcodeGen 2.46.0 and Tuist 4.205.0). Every exit code on that
# path is 0 and the defect surfaces as an unlaunchable .app.
#
# Two places call this, because neither alone covers both generators:
#   - app/project.yml's `options.preGenCommand` — XcodeGen runs it before
#     spec validation with CWD = app/. Skipped under `xcodegen --use-cache`.
#   - ci/check-identity.sh — the plain-text run in pr.yml's config job and in
#     ci/local-check.sh. Tuist has no pre-generation hook, and a guard
#     embedded in Project.swift is skipped whenever the manifest cache is
#     warm, so this is the Tuist path's only coverage.
#
# Exit-code contract:
#
#   Exit | Meaning                                              | Message must name
#   -----+------------------------------------------------------+---------------------------------------------
#   0    | every required variable present and non-empty        | — (prints `identity preflight ok`)
#   1    | unknown or malformed argv                            | the offending argument and the usage line
#   2    | app/Identity.xcconfig not found, or present but not | the resolved absolute path and the CWD;
#        | resolvable because a hard `#include` in it is missing | for an include, the include and where it
#        | or the includes cycle                                | was looked for
#   3    | one or more required variables missing or empty      | every missing variable, comma-separated
#   4    | --require-team given and the team is unresolvable    | DEVELOPMENT_TEAM and app/Local.xcconfig
#
# Exit 2 versus exit 3: not found is a distinct outcome from a failed check
# and gets a distinct code, so "the file was never there" can never be read
# as "the file was checked".
#
# Usage:
#   ruby bin/preflight-identity.rb                  # from the repository root (CI)
#   ruby ../bin/preflight-identity.rb               # from app/ — XcodeGen's preGenCommand
#   ruby bin/preflight-identity.rb --require-team   # additionally require a resolvable DEVELOPMENT_TEAM
#   ruby bin/preflight-identity.rb --config PATH    # check PATH instead of app/Identity.xcconfig (fixtures only)
#
# WHY THE VALUE COMES FROM bin/lib/xcconfig.rb AND NOT FROM A PREDICATE HERE
#
# This file used to decide "non-empty" with an anchored `=[ \t]*\S` match. In
# xcconfig `//` opens a comment at ANY position in a value, so
# `BUNDLE_ID = // temporarily disabled` resolves to the empty string in Xcode —
# the key is absent from -showBuildSettings entirely — while that predicate
# matched the first `/` and this gate exited 0. It accepted the exact input it
# exists to refuse, reached by the most natural way of disabling a line.
#
# The fix is not a tighter predicate. `//` is one of half a dozen xcconfig
# rules a reader has to get right, and ci/local-release-check.sh needs the
# VALUE rather than a yes/no, so a predicate here would have left that script
# with a reader of its own. bin/lib/xcconfig.rb is the single body both call,
# and its rows were measured against `xcodebuild -showBuildSettings` rather
# than against either caller. It also does two things the predicate could not:
# it follows `#include?`, so a variable supplied by an included file counts,
# and it distinguishes "never assigned" from "assigned but empty" — this gate
# treats both as missing, which is what the predicate did.
#
# Ruby stdlib only. No gem, no Gemfile entry, and exactly one `require`-family
# line — `require_relative "lib/xcconfig"`, a relative load of a sibling file
# in this repository which itself has ZERO `require` lines, not even a stdlib
# one (test/xcconfig_test.rb asserts that, so it cannot rot). Nothing outside
# Ruby core is loaded on any path, so this still runs on a bare runner before
# `bundle install`.

# The single load. `__dir__`-relative, so it resolves the same from the
# repository root (CI), from app/ (XcodeGen's preGenCommand) and from anywhere
# else a caller happens to stand.
require_relative "lib/xcconfig"

# Paths are resolved from __dir__, never from the CWD. XcodeGen's preGenCommand
# runs with CWD = app/ (both `cd app && xcodegen generate` and
# `xcodegen generate -s app/project.yml`); CI runs from the repository root.
# One constant is correct under both, and there is no positional path
# argument for a caller to get wrong.
IDENTITY_XCCONFIG = File.expand_path("../app/Identity.xcconfig", __dir__)
LOCAL_XCCONFIG = File.expand_path("../app/Local.xcconfig", __dir__)

# The required list is a frozen constant, duplicated deliberately, and is NEVER
# read out of the file under test. A gate that derived its required list from
# its subject would accept whatever the subject happened to say.
REQUIRED_VARS = %w[BUNDLE_ID APP_PRODUCT_NAME DISPLAY_NAME COPYRIGHT].freeze

# The team variable is checked only under --require-team; see the flag below
# for the reason it is not part of REQUIRED_VARS.
TEAM_VAR = "DEVELOPMENT_TEAM"

# Every failure line carries this prefix so it is greppable out of a
# generator's interleaved output.
FAIL_PREFIX = "IDENTITY PREFLIGHT FAILED:"

USAGE = <<~USAGE
  usage: ruby bin/preflight-identity.rb [--require-team] [--config PATH]
    --require-team   also require DEVELOPMENT_TEAM to resolve from app/Local.xcconfig (exit 4 if not)
    --config PATH    check PATH instead of app/Identity.xcconfig; prints a banner to stderr on every use
    -h, --help       print this usage and exit 0
USAGE

# Every failure path is explicit and loud. There is no broad rescue anywhere in
# this file: a silently tolerated error here means a project generated against
# an empty identity, which is exactly the defect this file exists to prevent.
def fail_with(code, message)
  warn "#{FAIL_PREFIX} #{message}"
  exit code
end

# --- argv -------------------------------------------------------------------
# Exactly two flags are accepted. Unknown argv is rejected, never ignored: a
# typo'd flag must not look like a successful run.

require_team = false
config_override = nil
argv = ARGV.dup
until argv.empty?
  arg = argv.shift
  case arg
  when "--require-team"
    # Opt-in, and NOT passed by app/project.yml's preGenCommand or by
    # ci/check-identity.sh in pr.yml. The six required `app (…)` status
    # contexts build unsigned — pr.yml passes CODE_SIGN_IDENTITY="",
    # CODE_SIGNING_REQUIRED=NO and CODE_SIGNING_ALLOWED=NO on all three
    # build steps — and GitHub runners have no app/Local.xcconfig because
    # it is gitignored. A team check inside the hook would therefore fail
    # every one of those six required contexts on every pull request. Do
    # not "fix" this by making it default.
    require_team = true
  when "--config"
    path = argv.shift
    if path.nil? || path.empty? || path.start_with?("--")
      warn "#{FAIL_PREFIX} --config requires a PATH argument\n#{USAGE}"
      exit 1
    end
    unless config_override.nil?
      warn "#{FAIL_PREFIX} --config given more than once\n#{USAGE}"
      exit 1
    end
    config_override = File.expand_path(path)
  when "-h", "--help"
    puts USAGE
    exit 0
  else
    warn "#{FAIL_PREFIX} unknown argument #{arg.inspect}\n#{USAGE}"
    exit 1
  end
end

config = config_override || IDENTITY_XCCONFIG

# Loud on every use, so an overridden run can never be mistaken for a default
# one in a log.
unless config_override.nil?
  warn "IDENTITY PREFLIGHT: ==== --config OVERRIDE IN EFFECT ===="
  warn "IDENTITY PREFLIGHT: default config #{IDENTITY_XCCONFIG} was NOT checked"
  warn "IDENTITY PREFLIGHT: checking override #{config_override} instead"
end

# --- exit 2: the file is not there ------------------------------------------
#
# File.file?, not File.exist?: a directory — or a socket, or a fifo — at that
# path passes File.exist?, and the read below then raises Errno::EISDIR out of
# the parser. Ruby exits 1 with a backtrace, and 1 is the code this contract
# spends on malformed argv, so a caller branching on the code reads "your
# config path is a directory" as "you called me wrong". Reproduced with
# `--config app` under both pinned interpreters. A non-regular path is "not
# found" for this gate's purposes, and the message says which kind it was.

unless File.file?(config)
  state = if File.directory?(config)
            "is a directory, not a file"
          elsif File.exist?(config)
            "is not a regular file"
          else
            "not found"
          end
  fail_with 2, "#{config} #{state} (cwd: #{Dir.pwd}). " \
               "app/Identity.xcconfig is the tracked identity source of truth; " \
               "generation must not proceed without it."
end

# --- exit 3: a required variable is missing or present-but-empty -------------
# `Xcconfig.value` returns nil for a key that was never assigned and "" for one
# that is assigned but empty, comment-only, or resolving through undefined
# references to nothing. A gate treats both as missing.
#
# Collect every miss before reporting, so one run names all of them rather
# than only the first.

begin
  missing = REQUIRED_VARS.reject do |key|
    value = Xcconfig.value(config, key)
    !value.nil? && !value.empty?
  end
rescue Xcconfig::MissingInclude => e
  # A hard `#include` that is not there, or an include cycle. The parser raises
  # rather than returning what it managed to read, deliberately: "your include
  # is broken" must never arrive as "that key is empty". So it maps onto exit 2
  # — the config could not be READ — and never onto exit 3, and a caller
  # branching on the code is not told a variable is missing from a file that
  # was never resolvable in the first place. Xcode refuses this file too.
  fail_with 2, "#{config} could not be resolved: #{e.message}. " \
               "Fix the #include, or make it optional (`#include?`, which is silent when the " \
               "file is absent), before generating."
end

unless missing.empty?
  fail_with 3, "#{config} is missing required variable(s): #{missing.join(", ")}. " \
               "Each must be defined with a non-empty value; a missing key resolves to the " \
               "empty string and both generators would exit 0 with an empty CFBundleIdentifier."
end

# --- exit 4: --require-team and the team does not resolve --------------------
# Local.xcconfig is the sibling of whichever config is being checked
# (app/Local.xcconfig by default), which is exactly the file
# `#include? "Local.xcconfig"` in Identity.xcconfig reads. It is read directly
# here rather than through the include, so the two questions below stay
# separable — see the comment on `tracked_team`.

if require_team
  local = config_override.nil? ? LOCAL_XCCONFIG : File.expand_path("Local.xcconfig", File.dirname(config))

  # TWO DIFFERENT QUESTIONS, and asking the wrong one here is a false security
  # warning on every developer machine.
  #
  # This branch asks the leak question: is a Team ID sitting in a file that is
  # IN GIT? That is about one file's own text. `Xcconfig.value` answers the
  # other question — what would Xcode resolve DEVELOPMENT_TEAM to here — and
  # Identity.xcconfig ends with `#include? "Local.xcconfig"`, so on every
  # machine that has the gitignored file `value` would return the LOCAL team
  # and this branch would announce a tracked-file leak that does not exist.
  # `Xcconfig.own` does not follow includes, and is the question actually being
  # asked. Raw and unexpanded, matching the predicate it replaces.
  tracked_team = Xcconfig.own(config)[TEAM_VAR]

  if !tracked_team.nil? && !tracked_team.empty?
    # Satisfies the check, but a Team ID defined in the tracked file is a
    # Team ID in git — the exact leak the gitignored Local.xcconfig exists
    # to prevent.
    warn "IDENTITY PREFLIGHT WARNING: #{TEAM_VAR} is defined in #{config}, " \
         "which is tracked. The Team ID belongs in gitignored app/Local.xcconfig only."
  else
    local_team = begin
                   File.file?(local) ? Xcconfig.value(local, TEAM_VAR) : nil
                 rescue Xcconfig::MissingInclude => e
                   fail_with 2, "#{local} could not be resolved: #{e.message}."
                 end
    unless !local_team.nil? && !local_team.empty?
      # This message has to exist because Xcode's own behaviour is useless
      # here: on iOS it says `requires a development team` (names the concept,
      # not the variable or the file); on macOS it says NOTHING AT ALL — the
      # build succeeds with `Signing Identity: "Sign to Run Locally"`
      # (observed on Xcode 26.1.1). Neither names DEVELOPMENT_TEAM or the file
      # that should have defined it. This one does.
      # Same File.file? discipline as the exit-2 branch: a directory named
# Local.xcconfig must not read as a file that failed its check.
state = if File.file?(local)
          "present but does not define #{TEAM_VAR} with a non-empty value"
        elsif File.directory?(local)
          "a directory, not a file"
        elsif File.exist?(local)
          "not a regular file"
        else
          "not found"
        end
      fail_with 4, "#{TEAM_VAR} is unresolvable: app/Local.xcconfig (#{local}) is #{state}. " \
                   "`make bootstrap-fork` writes app/Local.xcconfig (gitignored) from " \
                   "FASTLANE_TEAM_ID in .bootstrap.env; on a clone that has not run it, create it " \
                   "by hand containing `#{TEAM_VAR} = <your Team ID>`. " \
                   "Note that Xcode would not report this on macOS (the build succeeds with an ad-hoc signature)."
    end
  end
end

puts "identity preflight ok"
exit 0
