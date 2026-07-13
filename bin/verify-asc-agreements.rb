#!/usr/bin/env ruby
# frozen_string_literal: true

# Preflight: confirm the App Store Connect account has an in-effect agreement
# BEFORE the release pipeline does any real work (toolchain bootstrap, project
# generation, cert minting, build, upload).
#
# Apple gates the ENTIRE ASC API behind a signed, non-expired agreement
# (Program License Agreement, Paid Applications Agreement, or freshly-updated
# terms). When one lapses, every ASC call fails account-wide — and without
# this preflight the failure surfaces deep inside compute-release-tag.rb (or
# later, mid-cert-mint) as a one-line generic error. This probes ASC up front
# and, on the agreement gate, prints an actionable runbook naming the exact
# ASC screens the Account Holder must visit. Mirrors canary-trigger.yml's
# "Verify dispatch PAT is valid" preflight (apple-shipkit #248) for the ASC side.
#
# Auth resolution mirrors bin/compute-release-tag.rb:
#   - .bootstrap.env present (local shippers, canary's synthesized env) →
#     Bootstrap::Config + ensure_asc_token!.
#   - .bootstrap.env absent (CI: release.yml exports ASC_API_KEY_* before this
#     runs) → Bootstrap.setup_asc_token_from_env!.
#
# The probe is account-wide (App.all limit:1) — it needs no BUNDLE_ID and trips
# the same agreement gate every downstream ASC call would.
#
# Usage: bundle exec ruby bin/verify-asc-agreements.rb
#
# Exit:
#   0  an agreement is in effect (ASC API reachable)
#   1  agreement missing/expired (actionable runbook printed), or auth error

require_relative "lib/bootstrap"

require "spaceship"

if Bootstrap::ENV_FILE.exist?
  config = Bootstrap::Config.load!
  config.validate!
  Bootstrap.ensure_asc_token!(config)
else
  Bootstrap.setup_asc_token_from_env!
end

begin
  Bootstrap.verify_asc_agreements!
  puts Bootstrap::UI.ok("App Store Connect agreements are in effect (ASC API reachable).")
  exit 0
rescue Bootstrap::AscAgreementError => e
  warn Bootstrap::UI.miss("App Store Connect agreement check failed.")
  warn e.message
  exit 1
rescue StandardError => e
  # Not the agreement gate — surface the raw error (auth, network, etc.) so it
  # isn't silently swallowed, but keep the exit contract.
  warn Bootstrap::UI.miss("App Store Connect preflight could not complete: #{e.class}: #{e.message[0, 300]}")
  exit 1
end
