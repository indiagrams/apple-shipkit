# frozen_string_literal: true

# bin/lib/xcconfig.rb — the one reader for app/Identity.xcconfig.
#
# WHY THIS EXISTS
#
# Identity now lives in an xcconfig, and Xcode reads that file natively. Every
# other consumer in this template has to read it with something, and each one
# that grows its own reader is correct about the value it was written against
# and wrong about the next one. Two were live at the same time before this
# module:
#
#   1. bin/preflight-identity.rb decided "non-empty" with an anchored
#      `=[ \t]*\S` match. In xcconfig `//` opens a comment at ANY position in
#      a value, so `BUNDLE_ID = // temporarily disabled` resolves to the empty
#      string in Xcode — the key is simply absent from -showBuildSettings —
#      while that predicate matched the first `/` and exited 0. The gate
#      accepted the exact input it exists to refuse, reached by the most
#      natural way of disabling a line.
#
#   2. ci/local-release-check.sh derived the bundle id by grepping
#      app/project.yml's `PRODUCT_BUNDLE_IDENTIFIER:` line. Once the manifest
#      carries `$(BUNDLE_ID)` instead of a literal — which is what the identity
#      move made it carry — that grep yields the unresolved reference as if it
#      were a value, the `-z` emptiness guard beside it can never fire, and on
#      the manual-signing path the string becomes the `provisioningProfiles`
#      dict key, so `exportArchive` fails only after a full signed archive.
#
# The replacement for a bad reader is not a better reader. It is ONE parser,
# with a fixture set measured against the real toolchain rather than against
# any reader in the tree, and every consumer calling it — the shell ones by
# shelling out rather than growing a third.
#
# THE SEMANTICS REPRODUCED, ALL OBSERVED RATHER THAN ASSUMED
#
# The expected values in test/xcconfig_test.rb were read back with
# `xcodebuild -showBuildSettings` on Xcode 26.1.1 (17B100) with XcodeGen
# 2.46.0, from probe keys appended to an identity xcconfig — not reasoned
# about from Apple's documentation, which does not specify most of this.
#
#   - the LAST assignment wins, including across `#include` boundaries, in
#     file order — so an include is position-sensitive
#   - `//` opens a comment at ANY position in a value: `K = value // note` is
#     `value`, `K = // disabled` and `K = //` are BOTH the empty string, and
#     `K = https://example.com/x` is `https:`. A lone `/` and `a/b` are values,
#     which is why the cut is on `//` and nothing tighter — a copyright line
#     may legitimately carry a slash.
#   - quotes are literal characters, not delimiters: `K = "q"` is `"q"`
#   - the split is on the FIRST `=` only: `K = a=b` is `a=b`
#   - `KEY[sdk=iphoneos*]` conditional assignments are SDK-scoped. A text
#     parser cannot know which SDK you meant, so they are IGNORED and the base
#     assignment wins — see "what this cannot see" below.
#   - `$(VAR)` expands from the resolved set, an undefined reference is empty,
#     and `$(inherited)` is empty in an xcconfig-only context
#   - `#include?` of a missing file is silent; a hard `#include` of a missing
#     file, and an include cycle, are NAMED errors
#
# CONTRACT
#
#   Xcconfig.value(path, key)  ->  String  the resolved value
#                                  ""      assigned, but empty or comment-only
#                                  nil     never assigned
#                                  raises  Xcconfig::MissingInclude
#
#   The ""-versus-nil distinction is load-bearing: "the key is there but Xcode
#   reads nothing" and "the key is not there" are different defects and get
#   different messages. Callers that only need a gate must treat BOTH as
#   failure, which is what bin/preflight-identity.rb does.
#
#   Xcconfig.own(path)         ->  Hash    { "KEY" => raw }, this file's OWN
#                                          assignments, no `#include` followed
#                                          and no `$(VAR)` expanded
#
#   `own` is a different QUESTION, not a different parser: "what does this file
#   say" rather than "what would Xcode resolve here". app/Identity.xcconfig
#   ends with `#include? "Local.xcconfig"`, the gitignored file carrying
#   DEVELOPMENT_TEAM, so a check asking "is a Team ID sitting in a TRACKED
#   file" must not follow the include — `value` would return the local team on
#   every developer machine and report a leak that is not there. A warning that
#   is wrong every time is one nobody reads the day it is right. See the
#   method's own comment.
#
#   CLI: ruby bin/lib/xcconfig.rb <file> <KEY>
#
#   Exit | Meaning                                      | Message names
#   -----+----------------------------------------------+--------------------------
#   0    | resolved to a non-empty value                | — (prints the value)
#   2    | fewer than two arguments                     | the usage line
#   3    | the key is undefined, or resolves to empty   | the key and the file
#   1    | a hard `#include` miss, an include cycle, or | the include, or the path
#        | an unreadable path (Errno) — never silent    |
#
#   Exit 3 reuses bin/preflight-identity.rb's meaning ("a required value is
#   missing or empty") so a shell caller can treat the two the same way. Exit 2
#   is "no verdict": "the tool was called wrong" can never be read as "the
#   value was checked".
#
# WHAT THIS CANNOT SEE. It is a text parser, not a build. It cannot resolve
# `KEY[sdk=…]` — during the probe the conditional key read `base` for the macOS
# target and the conditional value for `-sdk iphoneos`, and nothing in the file
# says which build you meant, so the conditional line is skipped rather than
# guessed at. It cannot see a real build's `$(inherited)` chain, which reaches
# into the project and target levels above this file. And it does not know the
# build settings Xcode injects, so `$(SRCROOT)` and friends resolve to empty
# here. Anything that depends on those must go through
# `xcodebuild -showBuildSettings` — the way bin/take-readme-screenshots.sh
# reads the bundle id out of a generated project — not through this module.
#
# Ruby stdlib only, and specifically ZERO `require` lines, not even a stdlib
# one. bin/preflight-identity.rb `require_relative`s this file and runs on a
# bare runner before `bundle install`, in app/project.yml's `preGenCommand` and
# in pr.yml's `config` job; test/xcconfig_test.rb asserts the zero-require
# property so it cannot rot, and bootstrap-doctor-matrix.yml's
# `xcconfig-regression` job keeps `bundler-cache: false` on the strength of it.
#
# `File.read(path, encoding: "UTF-8")` is mandatory and never `File.read(path)`:
# COPYRIGHT carries `©` (U+00A9), and with LANG unset — a bare container,
# `env -i`, launchd — Ruby defaults Encoding.default_external to US-ASCII and a
# non-ASCII byte raises ArgumentError out of a regex match instead of producing
# a verdict. The contract test drives the CLI with LC_ALL/LANG/LC_CTYPE cleared.
#
# The `if $PROGRAM_NAME == __FILE__` tail at the bottom makes this file both a
# library and a command, so bash callers can shell out to it instead of growing
# another reader.

module Xcconfig
  # An assignment line. Group 2 is the optional `[sdk=…]` condition — it is
  # captured only so it can be recognised and skipped. The key charset excludes
  # `=`, which is what makes `K = a=b` split on the first `=`. Anchored at the
  # start of the line, which is why a `//` comment line containing an `=`
  # defines nothing.
  ASSIGN  = /\A[ \t]*([A-Za-z_][A-Za-z0-9_]*)([ \t]*\[[^\]]*\])?[ \t]*=(.*)\z/
  # `#include "X"` and `#include? "X"`. Group 1 is the `?` — present means the
  # include is optional, and a missing file is a no-op.
  INCLUDE = /\A[ \t]*#include(\?)?[ \t]+"([^"]+)"/

  # Raised for a hard `#include` of a file that is not there, and for an
  # include cycle. Both are conditions under which Xcode would not build; a
  # reader that returned what it managed to read instead would be the
  # silent-empty defect this module exists to remove.
  MissingInclude = Class.new(StandardError)

  # The resolved raw assignments of `path`, `{ "KEY" => raw_string }`.
  #
  # Includes are inlined AT THEIR POSITION and merged over what came before, so
  # last-assignment-wins holds across the boundary in file order — observed:
  # `K = first` / `K = second` / `#include? "Inc"` (setting `from-include`)
  # resolves to `from-include`, and the same include placed first loses to a
  # later local assignment.
  #
  # `seen` is the include stack, used for the cycle guard. Paths are absolute,
  # and an include is resolved relative to the file that includes it — never to
  # the process CWD, which differs between XcodeGen's preGenCommand (app/),
  # fastlane (fastlane/) and CI (the repository root).
  #
  # `follow_includes: false` (see `own` below) recognises an include line — so
  # it can never be mistaken for an assignment — and does not read it. A hard
  # miss is then not an error, because nothing was asked of the included file.
  def self.load(path, seen = [], follow_includes: true)
    path = File.expand_path(path)
    raise MissingInclude, "include cycle at #{path} (via #{seen.join(' -> ')})" if seen.include?(path)

    values = {}
    File.read(path, encoding: "UTF-8").each_line do |line|
      line = line.chomp

      if (m = INCLUDE.match(line))
        if follow_includes
          inc = File.expand_path(m[2], File.dirname(path))
          if File.file?(inc)
            values.merge!(load(inc, seen + [path]))
          elsif m[1].nil?
            raise MissingInclude, %(#{path}: #include "#{m[2]}" not found at #{inc})
          end
        end
        next
      end

      # m[2] is the `[sdk=…]` condition; a conditional assignment is SDK-scoped
      # and this parser has no SDK, so it is skipped rather than guessed at.
      next unless (m = ASSIGN.match(line)) && m[2].nil?

      # The `//` cut happens HERE, before anything else sees the value. It is
      # the whole of the fix to the preflight's old predicate, and putting it in
      # one place is what stops a consumer disagreeing with the gate about what
      # "the value" is.
      values[m[1]] = m[3].sub(%r{//.*}, "").strip
    end
    values
  end

  # `$(VAR)` and `$(inherited)` expansion against an already-resolved set.
  #
  # A reference to a key that was never assigned expands to the empty string,
  # matching Xcode (`$(UNDEFINED_VAR)x` resolved to `x`). `$(inherited)` is
  # empty in an xcconfig-only context (`$(inherited) extra` resolved to
  # ` extra`, leading space kept — which is why the `strip` above happens
  # before expansion, not after).
  #
  # The depth guard is not decoration: `A = $(B)` / `B = $(A)` is a legal pair
  # of lines a forker can write, and without the guard this recurses until the
  # stack dies. Past depth 10 the raw string is returned unexpanded, so the
  # caller sees `$(...)` rather than a crash or a wrong value.
  def self.expand(values, raw, depth = 0)
    return raw if depth > 10

    raw.gsub(/\$\(([A-Za-z_][A-Za-z0-9_]*)\)/) do
      name = Regexp.last_match(1)
      name == "inherited" ? "" : expand(values, values.fetch(name, ""), depth + 1)
    end
  end

  # What this file's OWN text assigns, `{ "KEY" => raw_string }`, with no
  # `#include` followed and no `$(VAR)` expansion. The same `//` cut and strip
  # as `load`, because it IS `load` — one body, one set of semantics.
  #
  # This is a DIFFERENT QUESTION from `value`, and the difference is the reason
  # the method exists. `value` answers "what would Xcode resolve here", which
  # follows `#include?`. bin/preflight-identity.rb's Team-ID warning asks "is a
  # Team ID sitting in a file that is IN GIT", which is about one file's text.
  # app/Identity.xcconfig ends with `#include? "Local.xcconfig"`, so on every
  # machine that has the gitignored file, `value(identity, "DEVELOPMENT_TEAM")`
  # returns the LOCAL team — measured on a fixture pair whose main file assigns
  # no team and which resolved through the include to the included one. A leak
  # check asking `value` would fire on every developer machine about a value
  # that is not tracked.
  #
  # Not for build questions. If you want to know what a target will actually
  # see, you want `value`, or `xcodebuild -showBuildSettings`.
  def self.own(path)
    load(path, [], follow_includes: false)
  end

  # The resolved value of `key` in `path`, as Xcode would read it.
  # nil = never assigned. "" = assigned, but empty, comment-only, or resolving
  # through undefined references to nothing.
  def self.value(path, key)
    values = load(path)
    values.key?(key) ? expand(values, values[key]) : nil
  end
end

# CLI mode: ruby bin/lib/xcconfig.rb app/Identity.xcconfig BUNDLE_ID
#
# This is what bash consumers call instead of writing another reader. It
# deliberately does NOT rescue MissingInclude: a broken include is an error
# with a name, and turning it into exit 3 would make it indistinguishable from
# "that key is empty".
if $PROGRAM_NAME == __FILE__
  if ARGV.length < 2
    warn "usage: ruby #{$PROGRAM_NAME} <xcconfig-file> <KEY>"
    exit 2
  end

  path, key = ARGV
  resolved = Xcconfig.value(path, key)
  if resolved.nil? || resolved.empty?
    warn "xcconfig: #{key} is #{resolved.nil? ? 'undefined' : 'empty'} in #{path}"
    exit 3
  end
  puts resolved
end
