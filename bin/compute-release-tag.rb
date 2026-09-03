#!/usr/bin/env ruby
# frozen_string_literal: true

# Print `v<MARKETING>+<BUILD>` for the next ship to stdout.
#
# Used by:
#   - bin/ship.rb (local mode) to compute the tag the fastlane release
#     lane will push.
#   - .github/workflows/release.yml's "Compute release version" step
#     to produce a deterministic, ASC-aware tag instead of the legacy
#     `v$YYYY.$WW.$run_number` CalVer.
#
# Requires .bootstrap.env (real shippers) or env-var-only auth (CI: the
# release.yml step exports ASC_API_KEY_* and BUNDLE_ID before invoking
# this script). When the .bootstrap.env file is absent we fall back to
# pure-env mode for CI compatibility.
#
# Override hooks (env vars):
#   RELEASE_MARKETING_VERSION  — skip project-file read, use this as
#                                marketing version. Used by the canary.
#   RELEASE_BUILD_NUMBER       — skip ASC query, use this integer as the
#                                build number. Used by CI when the
#                                workflow wants github.run_number-based
#                                determinism.
#
# Exit:
#   0  on success (tag printed to stdout)
#   1  on any error (message to stderr; nothing on stdout)

require_relative "lib/bootstrap"
require_relative "lib/version_resolver"

# Resolve bundle_id and ASC creds. Two paths:
#   - .bootstrap.env present (local-mode shippers, canary's synthesized
#     env): full Bootstrap::Config pipeline.
#   - .bootstrap.env absent (CI release.yml before its synthesizer
#     step): use env vars directly.
bundle_id = nil
if Bootstrap::ENV_FILE.exist?
  config = Bootstrap::Config.load!
  config.validate!
  bundle_id = config["BUNDLE_ID"]
  # Version.tag_prefix reads ENV; the setting lives in .bootstrap.env. Publish it
  # so a plain `ruby bin/compute-release-tag.rb` and `make ship` agree on the
  # prefix. config.release_tag_prefix already gives the process env precedence.
  ENV["RELEASE_TAG_PREFIX"] = config.release_tag_prefix

  # Skip the ASC token setup entirely when RELEASE_BUILD_NUMBER short-
  # circuits the ASC query. Useful in CI environments that want
  # deterministic build numbers tied to github.run_number rather than
  # ASC state.
  Bootstrap.ensure_asc_token!(config) if ENV["RELEASE_BUILD_NUMBER"].to_s.strip.empty?
else
  bundle_id = ENV["BUNDLE_ID"]
  if bundle_id.to_s.empty?
    warn "compute-release-tag.rb: BUNDLE_ID env var not set and no .bootstrap.env present."
    exit 1
  end

  if ENV["RELEASE_BUILD_NUMBER"].to_s.strip.empty?
    %w[ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID].each do |k|
      next unless ENV[k].to_s.empty?

      warn "compute-release-tag.rb: #{k} env var not set; either set RELEASE_BUILD_NUMBER or provide ASC creds."
      exit 1
    end

    p8_path = ENV["ASC_API_KEY_P8_PATH"]
    if p8_path.to_s.empty?
      b64 = ENV["ASC_API_KEY_P8_BASE64"]
      if b64.to_s.empty?
        warn "compute-release-tag.rb: neither ASC_API_KEY_P8_PATH nor ASC_API_KEY_P8_BASE64 set."
        exit 1
      end
      require "base64"
      require "tmpdir"
      p8_path = File.join(Dir.tmpdir, "asc_api_key_#{ENV.fetch('ASC_API_KEY_ID')}_compute.p8")
      File.write(p8_path, Base64.decode64(b64))
      File.chmod(0o600, p8_path)
    end

    Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
      key_id: ENV.fetch("ASC_API_KEY_ID"),
      issuer_id: ENV.fetch("ASC_API_KEY_ISSUER_ID"),
      key: File.read(p8_path),
    )
  end
end

begin
  puts Bootstrap::Version.compute_release_tag(bundle_id)
rescue StandardError => e
  warn "compute-release-tag.rb: #{e.message}"
  exit 1
end
