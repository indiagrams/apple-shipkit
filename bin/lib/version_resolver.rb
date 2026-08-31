# frozen_string_literal: true

# Bootstrap::Version — resolves the next release tag.
#
# Tag format: `v<MARKETING>+<BUILD>` (e.g. `v1.0.0+5`).
#
#   MARKETING is the human-meaningful version users see in App Store /
#             TestFlight ("Version 1.0.0"). Read from app/project.yml
#             (xcodegen) or app/Project.swift (tuist) — whichever is
#             present. Bumped intentionally by editing the project file
#             and committing. Stable across many ships.
#
#   BUILD     is a per-ship counter ASC requires to be unique per
#             marketing version. Resolved from ASC right before each
#             ship: `max(existing builds for MARKETING) + 1`. If no prior
#             builds exist for this marketing version, BUILD is 1.
#
# Why this format:
#   - One TestFlight "Version X" bucket per marketing version (instead
#     of a new bucket every ship). Matches how every shipped iOS app
#     organizes its TestFlight UI (Slack, Spotify, Instagram, …).
#   - App Store submission flow becomes unambiguous: "submit version
#     1.0.0 with build 5".
#   - The `+<BUILD>` suffix is preserved through the tag → fastlane →
#     local-release-check.sh pipeline so the binary's CFBundleVersion
#     matches what the tag promises.
#
# Backwards compatibility:
#   - Old tags `v2026.19.1357` (no `+`) still parse: marketing=full
#     string, build resolved from RELEASE_BUILD_NUMBER env.
#   - Canary tags `v0.YYYY.WW-canary-N-gen` still parse: marketing
#     stripped at first `-`, build from env.
#
# Override hooks:
#   RELEASE_MARKETING_VERSION  — overrides the project-file read.
#                                Used by canary-local-mode.yml to set
#                                a per-week marketing version
#                                (e.g. `0.2026.19`) on a shared bundle
#                                without touching project.yml.
#   RELEASE_BUILD_NUMBER       — overrides the ASC resolver. Used in CI
#                                contexts where ASC may be unreachable
#                                or where deterministic numbering is
#                                preferred (e.g. github.run_number).

require "spaceship"

module Bootstrap
  module Version
    PROJECT_YML  = "app/project.yml"
    PROJECT_SWIFT = "app/Project.swift"

    # Reads MARKETING_VERSION from the active project file. Returns the
    # raw string (e.g. "1.0.0", "0.0.1", "2026.5.0"). Project files in
    # both generators set the same field name; xcodegen reads YAML,
    # tuist reads a Swift dict literal — both regex-friendly.
    #
    # Resolution order:
    #   1. RELEASE_MARKETING_VERSION env (canary override)
    #   2. app/project.yml MARKETING_VERSION (xcodegen)
    #   3. app/Project.swift "MARKETING_VERSION": "..." (tuist)
    #
    # When both project files exist (template default), prefer
    # project.yml — they're filesystem-mirrored (PR #164) so they should
    # match, but we pick a stable winner.
    def self.read_marketing_version(repo_root: Dir.pwd)
      return ENV["RELEASE_MARKETING_VERSION"] unless ENV["RELEASE_MARKETING_VERSION"].to_s.strip.empty?

      yml_path = File.join(repo_root, PROJECT_YML)
      if File.exist?(yml_path)
        from_yml = File.read(yml_path).match(/^\s*MARKETING_VERSION\s*:\s*["']?([^"'\s#]+)["']?/)
        return from_yml[1] if from_yml
      end

      swift_path = File.join(repo_root, PROJECT_SWIFT)
      if File.exist?(swift_path)
        from_swift = File.read(swift_path).match(/"MARKETING_VERSION"\s*:\s*"([^"]+)"/)
        return from_swift[1] if from_swift
      end

      raise "Bootstrap::Version: could not read MARKETING_VERSION from #{PROJECT_YML} or #{PROJECT_SWIFT} (cwd=#{repo_root})"
    end

    # Returns the next CFBundleVersion to use.
    #
    # Queries ASC for EVERY build of the app — deliberately not just those at
    # `marketing_version` — and returns max(build_number) + 1.
    #
    # WHY NOT SCOPED TO THE MARKETING VERSION
    #
    # It was, and that is wrong the moment anything has been released. Apple
    # requires CFBundleVersion to exceed what was previously uploaded for that
    # platform, and once a version is live that comparison spans the app's whole
    # history, not the current train. Scoping to the marketing version means a
    # bump resets the count to 1 and the upload is refused:
    #
    #     This bundle is invalid. The value for key CFBundleVersion [1] in the
    #     Info.plist file must contain a higher version than that of the
    #     previously uploaded version [7]
    #
    # Observed downstream: after releasing 0.1.0 (build 7) and bumping to 0.1.1,
    # the resolver returned 1. iOS accepted it — its 0.1.0 had never been
    # released, so a new train may start at 1 — and macOS refused it, in the same
    # `make ship`. One command, two platforms, two answers, and the difference
    # was release status rather than anything about the build.
    #
    # A global max is correct in both cases: it is always greater than anything
    # uploaded, for either platform, in any train. It does NOT change which
    # TestFlight bucket a build lands in — that is CFBundleShortVersionString,
    # which is unaffected.
    #
    # `marketing_version` is retained in the signature for callers and for the
    # RELEASE_BUILD_NUMBER override path; it no longer filters the query.
    #
    # Caller must have called Bootstrap.ensure_asc_token! first.
    #
    # bundle_id is treated as authoritative. If ASC has no App record
    # for it, returns 1 — the first ship of a fresh app.
    # The arithmetic half of `next_build_number`, split out so it is testable
    # without an App Store Connect account. Takes CFBundleVersion strings as ASC
    # returns them and yields the next number to use.
    #
    # Non-numeric and empty entries coerce to 0 rather than raising: a build
    # whose version cannot be parsed must not be able to drag the next number
    # DOWN, and must not crash a release either.
    def self.next_build_after(version_strings)
      (Array(version_strings).map { |v| v.to_s.to_i }.max || 0) + 1
    end

    def self.next_build_number(bundle_id, marketing_version)
      return ENV["RELEASE_BUILD_NUMBER"].to_i unless ENV["RELEASE_BUILD_NUMBER"].to_s.strip.empty?

      app = Spaceship::ConnectAPI::App.find(bundle_id)
      return 1 unless app

      builds = Spaceship::ConnectAPI::Build.all(
        app_id: app.id,
        sort: "-uploadedDate",
        limit: 200,
      )

      # `b.version` on the Build resource is CFBundleVersion (the build number);
      # CFBundleShortVersionString is `app_version`. Both iOS and macOS uploads
      # get separate Build records with potentially-equal CFBundleVersion
      # values, so this maxes by integer value rather than counting records.
      #
      # Integer max, not a sort: ASC returns versions as strings, and "10"
      # sorts below "9" lexicographically.
      next_build_after(builds.map(&:version))
    rescue Spaceship::AccessForbiddenError, Spaceship::UnauthorizedAccessError => e
      # Apple gates the whole ASC API behind an in-effect agreement; when it
      # lapses, surface the actionable runbook instead of a raw denial.
      raise Bootstrap::AscAgreementError.new(e.message) if defined?(Bootstrap::AscAgreementError) && Bootstrap::AscAgreementError.match?(e)

      raise "Bootstrap::Version: ASC denied access while resolving build number — #{e.message[0, 200]}"
    rescue StandardError => e
      # The agreement error arrives as a generic Spaceship::UnexpectedResponse
      # (not AccessForbidden), so catch it here too and translate; re-raise
      # everything else unchanged.
      raise Bootstrap::AscAgreementError.new(e.message) if defined?(Bootstrap::AscAgreementError) && Bootstrap::AscAgreementError.match?(e)

      raise
    end

    # Compose the full release tag. Caller must have ensured the ASC
    # token is set (or set RELEASE_BUILD_NUMBER env to skip the ASC
    # query path).
    def self.compute_release_tag(bundle_id, repo_root: Dir.pwd)
      marketing = read_marketing_version(repo_root: repo_root)
      build = next_build_number(bundle_id, marketing)
      "v#{marketing}+#{build}"
    end

    # Parse a tag (with or without leading `v`) into [marketing, build].
    # Build is nil when the tag has no `+` suffix (legacy tags).
    #
    #   parse_tag("v1.0.0+5")             → ["1.0.0", "5"]
    #   parse_tag("v2026.19.1357")        → ["2026.19.1357", nil]
    #   parse_tag("v0.2026.19-canary-7")  → ["0.2026.19", nil]
    def self.parse_tag(tag)
      body = tag.to_s.sub(/^v/, "")
      if body.include?("+")
        marketing, build = body.split("+", 2)
        [marketing, build]
      else
        [body.split("-", 2).first, nil]
      end
    end
  end
end
