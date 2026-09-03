#!/usr/bin/env ruby
# frozen_string_literal: true

# `make submit` driver — stage and (optionally) submit the latest TestFlight
# build for App Store review across the platforms configured in PLATFORMS.
#
# Two-stage cadence:
#
#   `SUBMIT_FOR_REVIEW=false` (default in `.bootstrap.env.example`)
#     Stages the version: creates the App Store version record if missing,
#     attaches the newest VALID build, uploads screenshots + metadata, and
#     fills export-compliance answers, but does NOT click "Submit for
#     Review". The version sits in App Store Connect's "Prepare for
#     Submission" state — review the prepared listing in the web UI, then
#     click Submit yourself. Recommended for first releases until you trust
#     your screenshots / metadata / CHANGELOG pipeline.
#
#   `SUBMIT_FOR_REVIEW=true`
#     Stages + auto-submits. Version goes straight to "Waiting for Review".
#     Recommended once you trust the pipeline.
#
# Per-invocation override (env wins over `.bootstrap.env`):
#   SUBMIT_FOR_REVIEW=true  make submit   # one-off auto-submit
#   SUBMIT_FOR_REVIEW=false make submit   # one-off stage when env says true
#
# Single-platform override (when both are configured):
#   PLATFORMS=ios   make submit
#   PLATFORMS=macos make submit
#
# Pre-flight gates:
#   - PLATFORMS resolves to ≥1 platform
#   - fastlane/screenshots/en-US/ has ≥1 PNG/JPG for each active platform
#   - fastlane/metadata/en-US/ exists
#
# GH Release side-effect (#175): only fires on the real submit path
# (SUBMIT_FOR_REVIEW=true). Staging is reversible; creating a "submitted"
# Release for a version that may never get submitted would be misleading.
#
# Usage:  bundle exec ruby bin/submit.rb
#
# Exit:
#   0 success (all configured platforms staged or submitted)
#   1 invocation / preflight error
#   2 fastlane lane failed for at least one platform

require_relative "lib/bootstrap"

config = Bootstrap::Config.load!
config.validate!

# ─── Resolve effective platforms (PLATFORMS env wins over config) ────────────
raw_platforms = ENV["PLATFORMS"].to_s.strip.empty? ? config.platforms.join(",") : ENV["PLATFORMS"]
platforms = raw_platforms.split(",").map(&:strip).reject(&:empty?)
valid = %w[ios macos]
bad = platforms - valid
unless bad.empty?
  Bootstrap::UI.fail!("PLATFORMS must be a subset of #{valid.inspect} (got #{bad.inspect})")
end
if platforms.empty?
  Bootstrap::UI.fail!("PLATFORMS resolved to empty. Set PLATFORMS in .bootstrap.env or pass PLATFORMS=ios|macos.")
end

# ─── Resolve auto-submit toggle (env wins over config; default false) ────────
def truthy?(v)
  %w[true 1 yes].include?(v.to_s.strip.downcase)
end

raw_submit = ENV.key?("SUBMIT_FOR_REVIEW") ? ENV["SUBMIT_FOR_REVIEW"] : config["SUBMIT_FOR_REVIEW"]
auto_submit = truthy?(raw_submit)

# ─── Pre-flight: screenshots + metadata exist ────────────────────────────────
unless Dir.exist?("fastlane/metadata/en-US")
  Bootstrap::UI.fail!("fastlane/metadata/en-US/ missing. Fill in metadata text files before submitting.")
end

screenshots_dir = "fastlane/screenshots/en-US"
unless Dir.exist?(screenshots_dir)
  Bootstrap::UI.fail!("#{screenshots_dir}/ missing. Run `make screenshots` first.")
end

# Per-platform screenshot existence. iOS + macOS screenshots live in
# separate top-level dirs to keep deliver from cross-uploading (fastlane's
# deliver action globs ALL files under its `screenshots_path` and assigns
# display types from PNG dimensions — when iOS + macOS share one parent,
# Apple's API rejects with "Display Type Not Allowed" because a 1440×900
# macOS PNG has no valid iOS display type and vice versa).
#   - iOS:   fastlane/screenshots/en-US/
#   - macOS: fastlane/Mac_screenshots/en-US/
mac_dir = "fastlane/Mac_screenshots/en-US"
platforms.each do |p|
  if p == "macos"
    hits = Dir.glob(File.join(mac_dir, "*.{png,jpg,jpeg,PNG,JPG,JPEG}"))
    if hits.empty?
      Bootstrap::UI.fail!("No macOS screenshots in #{mac_dir}/. Run `make screenshots` (or place files in `#{mac_dir}/`) first.")
    end
  else
    hits = Dir.glob(File.join(screenshots_dir, "*.{png,jpg,jpeg,PNG,JPG,JPEG}"))
    if hits.empty?
      Bootstrap::UI.fail!("No iOS screenshots in #{screenshots_dir}/. Run `make screenshots` (or place files in `#{screenshots_dir}/`) first.")
    end
  end
end

# ─── Read marketing version for the preflight summary ────────────────────────
def read_marketing_version
  if File.exist?("app/project.yml")
    if (m = File.read("app/project.yml").match(/^\s*MARKETING_VERSION\s*:\s*["']?([^"'\s#]+)/))
      return m[1]
    end
  end
  if File.exist?("app/Project.swift")
    if (m = File.read("app/Project.swift").match(/"MARKETING_VERSION"\s*:\s*"([^"]+)"/))
      return m[1]
    end
  end
  nil
end

marketing = read_marketing_version

# ─── Pre-flight summary ──────────────────────────────────────────────────────
puts
puts Bootstrap::UI.bold("About to #{auto_submit ? 'SUBMIT' : 'STAGE'} #{config['APP_NAME']} (#{config['BUNDLE_ID']}):")
puts "  marketing version: #{marketing || '(could not read from project file)'}"
puts "  platforms:         #{platforms.join(', ')}"
puts "  mode:              #{auto_submit ? 'submit_for_review=true (auto-submit)' : 'submit_for_review=false (stage only)'}"
if auto_submit
  puts "  GH Release:        will be created at v#{marketing}+<latest-build> if `gh` CLI is available"
  puts "                     (set RELEASE_SKIP_GH_RELEASE=true to disable)"
else
  puts "  GH Release:        skipped (only created on actual submit, not staging)"
end
puts
unless auto_submit
  puts Bootstrap::UI.dim("Staging only. After this completes:")
  puts Bootstrap::UI.dim("  1. Open https://appstoreconnect.apple.com/apps and review the prepared version")
  puts Bootstrap::UI.dim("  2. Click \"Submit for Review\" yourself when ready")
  puts Bootstrap::UI.dim("  3. To auto-submit on future runs, set SUBMIT_FOR_REVIEW=true in .bootstrap.env")
  puts
end

# ─── Pre-flight: version record exists, with a build attached ────────────────
#
# deliver writes metadata INTO an existing editable App Store version; it does
# not create one, and nothing else in this pipeline does either (`bootstrap_asc`
# verifies the *App* record, not a version). So the first `make submit` after a
# marketing bump failed with deliver retrying "Cannot find edit app store
# version" until it gave up.
#
# Neither deliver call passes `build_number`, so no build was attached either.
# That produced the worse failure of the two: a green "staged" run whose version
# had build=NONE and therefore could not be submitted at all -- visible only by
# querying ASC, never from the exit code.
#
# Both are prerequisites rather than metadata, so they are settled here, before
# any lane runs. Idempotent: an existing version is reused, an already-attached
# build is left alone, so re-running `make submit` is safe.
if marketing.nil? || marketing.to_s.strip.empty?
  Bootstrap::UI.fail!("Could not read MARKETING_VERSION from app/project.yml or app/Project.swift.")
end

require "spaceship"
Bootstrap.ensure_asc_token!(config)
asc_app = Spaceship::ConnectAPI::App.find(config["BUNDLE_ID"])
Bootstrap::UI.fail!("ASC App record not found for #{config['BUNDLE_ID']}.") unless asc_app

asc_platform_of = { "ios" => "IOS", "macos" => "MAC_OS" }.freeze
# States whose metadata deliver can still write. READY_FOR_SALE is the common
# miss: a released train is closed, and the fix is a marketing bump, not a retry.
editable_states = %w[
  PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED INVALID_BINARY
].freeze

puts Bootstrap::UI.bold("→ App Store version records (#{marketing})")
platforms.each do |p|
  plat = asc_platform_of.fetch(p)

  versions = Spaceship::ConnectAPI.get_app_store_versions(
    app_id: asc_app.id, filter: {}, includes: "build", limit: 50
  ).to_models
  v = versions.find { |x| x.platform == plat && x.version_string == marketing }

  if v.nil?
    v = Spaceship::ConnectAPI.post_app_store_version(
      app_id: asc_app.id, attributes: { versionString: marketing, platform: plat }
    ).to_models.first
    puts Bootstrap::UI.ok("  #{p}: created version #{marketing}")
  elsif !editable_states.include?(v.app_store_state)
    Bootstrap::UI.fail!(
      "#{p}: version #{marketing} is #{v.app_store_state}, which deliver cannot edit. " \
      "If it is READY_FOR_SALE the train is closed -- bump MARKETING_VERSION."
    )
  else
    puts Bootstrap::UI.ok("  #{p}: version #{marketing} exists (#{v.app_store_state})")
  end

  if v.build&.version
    puts Bootstrap::UI.ok("  #{p}: build #{v.build.version} already attached")
    next
  end

  builds = Spaceship::ConnectAPI.get_builds(
    filter: { app: asc_app.id }, includes: "preReleaseVersion", limit: 50, sort: "-uploadedDate"
  ).to_models
  b = builds.find do |x|
    pv = x.pre_release_version
    pv && pv.platform == plat && pv.version == marketing &&
      x.processing_state == "VALID" && !x.expired
  end
  if b.nil?
    Bootstrap::UI.fail!("#{p}: no VALID unexpired build for #{marketing}. Run `make ship` first.")
  end
  Spaceship::ConnectAPI.patch_app_store_version_with_build(
    app_store_version_id: v.id, build_id: b.id
  )
  puts Bootstrap::UI.ok("  #{p}: attached build #{b.version}")
end
puts

# ─── Dispatch per platform ───────────────────────────────────────────────────
lane = auto_submit ? "submit_for_review" : "stage_for_review"
failed = []
env = Bootstrap.asc_env(config)

platforms.each do |p|
  fastlane_platform = (p == "macos" ? "mac" : p)
  puts Bootstrap::UI.bold("→ fastlane #{fastlane_platform} #{lane}")
  ok = system(env, "bundle", "exec", "fastlane", fastlane_platform, lane)
  if ok
    puts Bootstrap::UI.ok("  #{p} #{auto_submit ? 'submitted' : 'staged'}.")
  else
    failed << p
    puts Bootstrap::UI.warn("  #{p} #{lane} failed.")
  end
  puts
end

if failed.empty?
  puts Bootstrap::UI.bold("✅ All configured platforms #{auto_submit ? 'submitted' : 'staged'}.")
  if auto_submit
    puts "App Store Connect will now route the version through review (typically 24-48h)."
  else
    puts "Open App Store Connect to review and click Submit when ready."
  end
  exit 0
else
  Bootstrap::UI.fail!("Failed for: #{failed.join(', ')}. See fastlane output above for details.")
end
