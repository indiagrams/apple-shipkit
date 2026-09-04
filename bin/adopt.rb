#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/adopt.rb — `make adopt` driver
#
# Pulls metadata + screenshots from a live ASC App record into the local
# fastlane/ tree. Use on forks adopting an app that's already in the App Store
# BEFORE running `make submit`, which would otherwise upload local placeholder
# metadata and clobber the live App Store listing.
#
# This driver does the preflight checks that don't belong inside fastlane:
#   1. .bootstrap.env exists and is loadable
#   2. BUNDLE_ID is not the template placeholder
#   3. No uncommitted changes in fastlane/metadata or fastlane/screenshots
#      (since the download will overwrite — protect work in flight)
#
# Then exec()s fastlane's adopt_existing_app lane.
#
# Idempotent — re-running re-syncs from ASC. Existing local files overwritten.

require "pathname"

REPO_ROOT = Pathname.new(File.expand_path("..", __dir__))

def fail!(msg)
  warn "[adopt] #{msg}"
  exit 1
end

# Read .bootstrap.env (per-fork). Same parser as Fastfile's _fork_config —
# kept inline (not requiring a shared lib) so this driver doesn't need
# arbitrary load-path setup; the Makefile invokes it via `bundle exec ruby`.
env_path = REPO_ROOT.join(".bootstrap.env")
unless env_path.file?
  fail!(
    "Missing .bootstrap.env. Run `make init` first to scaffold it, then fill " \
    "in APP_NAME, BUNDLE_ID, FASTLANE_TEAM_ID, and ASC_API_KEY_* fields."
  )
end

config = {}
File.read(env_path, encoding: "UTF-8").each_line do |line|
  line = line.strip
  next if line.empty? || line.start_with?("#")
  k, v = line.split("=", 2)
  next unless k && v
  v = v.sub(/\s+#.*\z/, "").gsub(/\A['"]|['"]\z/, "")
  config[k.strip] = v.strip
end

# ENV wins over file when set (lets shell exports / .envrc / CI env block
# override the per-fork file for one-off invocations).
get = ->(key) { ENV[key].to_s.empty? ? config[key] : ENV[key] }

required = %w[APP_NAME BUNDLE_ID FASTLANE_TEAM_ID ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID]
missing = required.reject { |k| !get.call(k).to_s.empty? }
if missing.any?
  fail!(
    "Missing required env vars: #{missing.join(', ')}.\n" \
    "Set them in .bootstrap.env, or export from your shell / .envrc.\n" \
    "See docs/BOOTSTRAP.md for the field reference."
  )
end

bundle_id = get.call("BUNDLE_ID")
if bundle_id == "com.example.helloapp"
  fail!(
    "BUNDLE_ID is the template placeholder 'com.example.helloapp'.\n" \
    "Set it to your real bundle id in .bootstrap.env first.\n" \
    "If your fork is greenfield (new app, no existing App Store app), don't " \
    "run adopt — `make doctor` + `make all` is the greenfield path."
  )
end

# Git-clean check on fastlane/metadata + fastlane/screenshots — overwriting
# would lose uncommitted work. FORCE=true skips the check (for users who
# explicitly want to re-sync over local edits).
status = `git -C "#{REPO_ROOT}" status --porcelain -- fastlane/metadata fastlane/screenshots 2>/dev/null`.strip
if !status.empty? && ENV["FORCE"] != "true"
  warn "[adopt] Uncommitted changes detected in fastlane/metadata or fastlane/screenshots:"
  status.lines.first(15).each { |l| warn "  #{l.chomp}" }
  warn ""
  warn "[adopt] Adoption would overwrite these. Choose one:"
  warn "  • Commit:        git add fastlane/ && git commit"
  warn "  • Stash:         git stash push -- fastlane/metadata fastlane/screenshots"
  warn "  • Force-overwrite: FORCE=true make adopt"
  exit 1
end

puts "[adopt] Pulling ASC state for bundle id '#{bundle_id}' on team #{get.call('FASTLANE_TEAM_ID')}…"
puts ""

# exec replaces the current process — fastlane's exit code becomes ours.
# Pass through SKIP_METADATA / SKIP_SCREENSHOTS env vars (already in ENV;
# the lane reads them via ENV.fetch).
exec("bundle", "exec", "fastlane", "adopt_existing_app")
