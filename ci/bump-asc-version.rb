#!/usr/bin/env ruby
# ci/bump-asc-version.rb — bump the App Store version_string for both
# iOS and macOS records on App Store Connect, and select the matching
# TestFlight build for each.
#
# Run via ci/bump-asc-version.sh (which sources .bootstrap.env and uses brew Ruby).
# Direct invocation:
#   bundle exec ruby ci/bump-asc-version.rb v0.0.11
#
# Idempotent: skips bump/attach steps that are already at the target.
#
# Configuration:
#   APP_BUNDLE_ID env var — defaults to "com.example.helloapp" (rename for your
#   project; rename via bin/rename.sh).

require 'spaceship'
require 'base64'

if ARGV.empty?
  warn "Usage: ruby ci/bump-asc-version.rb <vX.Y.Z>"
  exit 2
end

# Strip the configured release-tag prefix, then fall back to a bare `v` so a tag
# cut before a prefix change still resolves. See Bootstrap::Version.tag_prefix.
_pfx = ENV.fetch("RELEASE_TAG_PREFIX", "v")
_raw = ARGV[0].to_s
target = (!_pfx.empty? && _raw.start_with?(_pfx)) ? _raw[_pfx.length..] : _raw.sub(/^v/, '')

token = Spaceship::ConnectAPI::Token.create(
  key_id:    ENV.fetch("ASC_API_KEY_ID"),
  issuer_id: ENV.fetch("ASC_API_KEY_ISSUER_ID"),
  key:       Base64.strict_decode64(ENV.fetch("ASC_API_KEY_P8_BASE64"))
)
Spaceship::ConnectAPI.token = token

bundle_id = ENV.fetch("APP_BUNDLE_ID", "com.example.helloapp")
app = Spaceship::ConnectAPI::App.find(bundle_id) \
  or abort "error: app #{bundle_id} not found on ASC"

puts "App: #{app.name} (#{app.id})"
puts "Target version: #{target}"

[Spaceship::ConnectAPI::Platform::IOS,
 Spaceship::ConnectAPI::Platform::MAC_OS].each do |plat|
  puts "\n=== #{plat} ==="

  v = app.get_edit_app_store_version(platform: plat)
  unless v
    puts "  warn: no edit-state version exists. Create one in ASC web UI first."
    next
  end

  if v.version_string == target
    puts "  version already at #{target} — skipping bump"
  else
    puts "  bumping #{v.version_string} → #{target}…"
    Spaceship::ConnectAPI.patch_app_store_version(
      app_store_version_id: v.id,
      attributes: { versionString: target }
    )
    v = app.get_edit_app_store_version(platform: plat)
    puts "  bumped (id=#{v.id})"
  end

  builds = app.get_builds(includes: 'preReleaseVersion').select do |b|
    pre = b.pre_release_version
    pre && pre.version == target && pre.platform == plat.to_s
  end

  if builds.empty?
    puts "  warn: no TestFlight build at v#{target} for #{plat} — upload one with"
    puts "        fastlane release tag:v#{target}"
    next
  end

  build = builds.max_by { |b| b.uploaded_date.to_s }
  puts "  build: bundleVersion=#{build.version} uploaded=#{build.uploaded_date}"

  current = Spaceship::ConnectAPI.get_app_store_version(
    app_store_version_id: v.id, includes: 'build'
  ).to_models.first

  if current.build && current.build.id == build.id
    puts "  build already attached"
  else
    puts "  attaching build…"
    current.select_build(build_id: build.id)
    puts "  attached"
  end
end

puts "\n✓ Done. ASC versions bumped + builds attached."
puts "  Next: re-run upload_metadata + upload_screenshots to refresh per-version"
puts "  fields, then ios/mac submit_for_review when ready."
