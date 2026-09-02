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
#   2    | app/Identity.xcconfig not found                      | the resolved absolute path and the CWD
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
# Ruby stdlib only. No gem, no Gemfile entry, no `require` at all, so it runs
# on a bare runner before `bundle install`.

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

# Pin UTF-8 rather than inheriting the locale. With LANG unset — a bare
# container, `env -i`, launchd — Ruby's default external encoding is US-ASCII
# and the © in COPYRIGHT raises ArgumentError out of the regex match instead
# of producing a verdict.
def read_utf8(path)
  File.read(path, encoding: "UTF-8")
end

# Anchored, non-empty-value match. Regexp.escape so a key name can never be
# read as a pattern. The trailing \S is load-bearing: `BUNDLE_ID =` with
# nothing after the equals sign must NOT match, because that is precisely the
# case Xcode silently treats as the empty string.
def defines_non_empty?(text, key)
  text.match?(/^[ \t]*#{Regexp.escape(key)}[ \t]*=[ \t]*\S/)
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

unless File.exist?(config)
  fail_with 2, "#{config} not found (cwd: #{Dir.pwd}). " \
               "app/Identity.xcconfig is the tracked identity source of truth; " \
               "generation must not proceed without it."
end

# --- exit 3: a required variable is missing or present-but-empty -------------
# Collect every miss before reporting, so one run names all of them rather
# than only the first.

identity_text = read_utf8(config)
missing = REQUIRED_VARS.reject { |key| defines_non_empty?(identity_text, key) }

unless missing.empty?
  fail_with 3, "#{config} is missing required variable(s): #{missing.join(", ")}. " \
               "Each must be defined with a non-empty value; a missing key resolves to the " \
               "empty string and both generators would exit 0 with an empty CFBundleIdentifier."
end

# --- exit 4: --require-team and the team does not resolve --------------------
# The team is resolved the way the build resolves it — from the RESOLVED set,
# not from Identity.xcconfig alone. Local.xcconfig is the sibling of whichever
# config is being checked (app/Local.xcconfig by default), which is exactly what
# `#include? "Local.xcconfig"` in Identity.xcconfig will read.

if require_team
  local = config_override.nil? ? LOCAL_XCCONFIG : File.expand_path("Local.xcconfig", File.dirname(config))

  if defines_non_empty?(identity_text, TEAM_VAR)
    # Satisfies the check, but a Team ID defined in the tracked file is a
    # Team ID in git — the exact leak the gitignored Local.xcconfig exists
    # to prevent.
    warn "IDENTITY PREFLIGHT WARNING: #{TEAM_VAR} is defined in #{config}, " \
         "which is tracked. The Team ID belongs in gitignored app/Local.xcconfig only."
  else
    team_resolved = File.exist?(local) && defines_non_empty?(read_utf8(local), TEAM_VAR)
    unless team_resolved
      # This message has to exist because Xcode's own behaviour is useless
      # here: on iOS it says `requires a development team` (names the concept,
      # not the variable or the file); on macOS it says NOTHING AT ALL — the
      # build succeeds with `Signing Identity: "Sign to Run Locally"`
      # (observed on Xcode 26.1.1). Neither names DEVELOPMENT_TEAM or the file
      # that should have defined it. This one does.
      state = File.exist?(local) ? "present but does not define #{TEAM_VAR} with a non-empty value" : "not found"
      fail_with 4, "#{TEAM_VAR} is unresolvable: app/Local.xcconfig (#{local}) is #{state}. " \
                   "Create app/Local.xcconfig (gitignored) containing `#{TEAM_VAR} = <your Team ID>` — " \
                   "`bin/rename.sh --team-id=…` and `make bootstrap-fork` write it for you. " \
                   "Note that Xcode would not report this on macOS (the build succeeds with an ad-hoc signature)."
    end
  end
end

puts "identity preflight ok"
exit 0
