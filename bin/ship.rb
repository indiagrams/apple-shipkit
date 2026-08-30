#!/usr/bin/env ruby
# frozen_string_literal: true

# Trigger a release. Behavior depends on .bootstrap.env's RELEASE_MODE:
#
#   ci    — triggers .github/workflows/release.yml on the configured app repo,
#           then polls until completion. Idempotent:
#             - if a release run is already in progress on origin/main, tail it
#             - if origin/main HEAD already has a release tag, exit 0
#             - --force overrides both checks
#
#   local — runs `bundle exec fastlane release tag:vMARKETING+BUILD` on this
#           machine. Marketing version is read from app/project.yml or
#           app/Project.swift (whichever exists); build number is resolved
#           from ASC as `max(existing builds at this marketing version) + 1`,
#           so each ship lands as a new build under the current "Version
#           X" bucket in TestFlight (instead of inventing a new bucket per
#           ship). Signing comes from the login keychain (Apple Distribution
#           + Apple Development + 3rd Party Mac Developer Installer must be
#           present — `make doctor` verifies). No idempotency check: the
#           fastlane release lane is itself idempotent (refuses to re-tag
#           an existing tag).
#
# Usage:  bundle exec ruby bin/ship.rb [--dry-run] [--force]
#
# Exit:
#   0 release succeeded (or was already shipped, or in-progress run completed)
#   1 invocation / I/O error
#   2 the workflow run / fastlane lane completed with conclusion != success

require "json"
require_relative "lib/bootstrap"

config  = Bootstrap::Config.load!
config.validate!

dry_run = ARGV.include?("--dry-run") ? "true" : "false"
force   = ARGV.include?("--force")

# Pre-flight summary so the human can sanity-check what's about to ship
# (right ref, right app, right mode) before any side effects. Surfaces
# config drift early — e.g. APP_NAME=SmokeApp on repo named my-cool-app
# stands out at a glance.
def fetch_main_head(repo)
  out, ok = Bootstrap::Sh.run("gh", "api", "repos/#{repo}/commits/main",
                              "--jq", '"\(.sha) \(.commit.message | split("\n")[0])"')
  return ["?", "(unknown)"] unless ok && !out.strip.empty?
  parts = out.strip.split(" ", 2)
  [parts[0], parts[1] || "(no message)"]
end

def print_preflight(config, dry_run, repo: nil, tag: nil)
  puts
  puts Bootstrap::UI.bold("About to ship #{config['APP_NAME']} (#{config['BUNDLE_ID']}):")
  if config.ci_mode?
    sha, subject = fetch_main_head(repo)
    puts "  ref:       #{repo} main @ #{sha[0, 7]} — #{subject}"
    puts "  mode:      ci → release.yml dispatches on GitHub (mints fresh certs, ships, revokes)"
  else
    head_sha, _ = Bootstrap::Sh.run("git", "rev-parse", "--short", "HEAD")
    head_msg, _ = Bootstrap::Sh.run("git", "log", "-1", "--pretty=%s")
    puts "  ref:       local HEAD @ #{head_sha.strip} — #{head_msg.strip}"
    puts "  mode:      local → fastlane release runs on this machine"
    puts "  signing:   login keychain (Apple Distribution + Apple Development + 3rd Party Mac Developer Installer)"
    puts "  tag:       #{tag}"
  end
  puts "  platforms: #{config.platforms.join(', ')}"
  puts "  dry-run:   #{dry_run}" if dry_run == "true"
  if config.ci_mode?
    puts
    puts Bootstrap::UI.dim('Note: GitHub Actions also runs a workflow named "PR" (.github/workflows/pr.yml)')
    puts Bootstrap::UI.dim("on every push. It is a CI sanity check, NOT a Pull Request, and does not")
    puts Bootstrap::UI.dim("gate this release. Both run independently.")
  end
  puts
end

# ─── Local mode: run fastlane release on this machine ─────────────────────────
if config.local_mode?
  require_relative "lib/version_resolver"
  require "spaceship"
  Bootstrap.ensure_asc_token!(config)
  begin
    tag = Bootstrap::Version.compute_release_tag(config["BUNDLE_ID"])
  rescue StandardError => e
    Bootstrap::UI.fail!("Could not compute release tag: #{e.message}")
  end
  print_preflight(config, dry_run, tag: tag)
  puts Bootstrap::UI.bold("Running fastlane release locally — tag #{tag}")
  env = Bootstrap.asc_env(config).merge("PLATFORMS" => config.platforms.join(","))
  args = ["bundle", "exec", "fastlane", "release", "tag:#{tag}"]
  args << "skip_upload:true" if dry_run == "true"

  # Sh.stream, not Sh.run: this is the longest-running command in the whole
  # tool and its output is the only record of what happened. Sh.run would
  # buffer it through capture3, drop stderr, and hand back a string this
  # branch then throws away on success — so `make ship > ship.log` captured
  # 13 lines of this script's own puts and nothing from fastlane, on a failed
  # release as readily as on a good one.
  _out, ok = Bootstrap::Sh.stream(*args, env: env)
  if ok
    puts
    puts Bootstrap::UI.bold("✅ Local release succeeded.")
    puts "Tag #{tag} pushed; binaries uploaded to App Store Connect."
    puts "Run #{Bootstrap::UI.bold 'make verify'} to confirm TestFlight ingestion (~5-15 min)."
    exit 0
  else
    # No `puts out` here — it has already been printed, in order and with
    # stderr interleaved, as it happened.
    Bootstrap::UI.fail!("fastlane release failed. The fastlane output above is the diagnosis.")
  end
end

# ─── CI mode: trigger release.yml + tail ──────────────────────────────────────
repo = config.repo_slug

def find_in_progress_run(repo)
  out, _ = Bootstrap::Sh.run("gh", "run", "list", "--workflow", "release.yml",
                              "--repo", repo, "--branch", "main", "--limit", "5",
                              "--json", "databaseId,status",
                              "--jq", '.[] | select(.status == "in_progress" or .status == "queued" or .status == "pending") | .databaseId')
  id = out.lines.first&.strip
  id && !id.empty? ? id : nil
end

def head_already_tagged?(repo)
  head_sha, ok = Bootstrap::Sh.run("gh", "api", "repos/#{repo}/commits/main", "--jq", ".sha")
  return nil unless ok
  head_sha = head_sha.strip
  return nil if head_sha.empty?
  tags_json, ok2 = Bootstrap::Sh.run("gh", "api", "repos/#{repo}/tags?per_page=20",
                                      "--jq", '[.[] | {name, sha: .commit.sha}]')
  return nil unless ok2 && !tags_json.strip.empty?
  match = JSON.parse(tags_json).find { |t| t["sha"] == head_sha }
  match ? [match["name"], head_sha] : nil
end

def trigger_new_run(repo, dry_run, platforms, generator)
  banner = "Triggering release.yml on #{repo} (dry_run=#{dry_run}, platforms=#{platforms}"
  banner += ", generator=#{generator}" unless generator.to_s.empty?
  banner += ")…"
  puts Bootstrap::UI.bold(banner)
  args = ["gh", "workflow", "run", "release.yml", "--ref", "main",
          "-f", "dry_run=#{dry_run}",
          "-f", "platforms=#{platforms}",
          "--repo", repo]
  args += ["-f", "generator=#{generator}"] unless generator.to_s.empty?
  out, ok = Bootstrap::Sh.run(*args)
  Bootstrap::UI.fail!("gh workflow run failed:\n#{out}") unless ok

  sleep 5
  20.times do
    out, _ = Bootstrap::Sh.run("gh", "run", "list", "--workflow", "release.yml",
                                "--repo", repo, "--limit", "1",
                                "--json", "databaseId,status,createdAt",
                                "--jq", ".[0].databaseId")
    id = out.strip
    return id unless id.empty?
    sleep 2
  end
  Bootstrap::UI.fail!("could not find newly-triggered run id")
end

run_id = nil

unless force
  if (existing = find_in_progress_run(repo))
    puts Bootstrap::UI.warn("Existing release run already in progress on #{repo}/main: ##{existing}")
    puts "  → https://github.com/#{repo}/actions/runs/#{existing}"
    puts "  Tailing this run instead of starting a new one. Pass --force to override."
    puts
    run_id = existing
  elsif (already = head_already_tagged?(repo))
    tag, sha = already
    puts Bootstrap::UI.ok("HEAD on #{repo}/main is already shipped as tag #{tag}")
    puts Bootstrap::UI.dim("(SHA #{sha[0, 8]}; pass --force to ship again)")
    exit 0
  end
end

print_preflight(config, dry_run, repo: repo)

run_id ||= trigger_new_run(repo, dry_run, config.platforms.join(","), config["GENERATOR"])
run_url = "https://github.com/#{repo}/actions/runs/#{run_id}"
puts "  → #{run_url}"
puts

last_status = nil
loop do
  out, _ = Bootstrap::Sh.run("gh", "run", "view", run_id, "--repo", repo,
                              "--json", "status,conclusion",
                              "--jq", '"\(.status) \(.conclusion // "-")"')
  parts = out.strip.split(" ", 2)
  status, conclusion = parts[0], parts[1]
  if status != last_status
    ts = Time.now.strftime("%H:%M:%S")
    puts "[#{ts}] #{status} #{conclusion}"
    last_status = status
  end
  if status == "completed"
    if conclusion == "success"
      puts
      puts Bootstrap::UI.bold("✅ Release succeeded.")
      puts "Tag pushed; both binaries uploaded to App Store Connect."
      puts "Run #{Bootstrap::UI.bold 'make verify'} to confirm TestFlight ingestion (~5-15 min ASC processing time)."
      exit 0
    else
      puts
      Bootstrap::UI.fail!("Release run #{run_id} concluded with: #{conclusion}\nSee #{run_url}")
    end
  end
  sleep 30
end
