# frozen_string_literal: true

source "https://rubygems.org"

# Pinned for reproducibility. Loose ~> 2.224 = 2.224 ≤ x < 3.0.
# The Fastfile handles G11 (the 2.233.x OpenSSL::PKey::ECError) via the
# key_filepath workaround in asc_api_key, so 2.233+ is OK functionally,
# but pinning gives CI a stable upper bound until we explicitly bump.
# See docs/CONTINUOUS-VALIDATION.md → G11.
gem "fastlane", "~> 2.234"
