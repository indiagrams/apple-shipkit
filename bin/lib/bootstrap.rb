# frozen_string_literal: true

# Shared library for `bin/doctor.rb` (read-only) and `bin/bootstrap-fork.rb`
# (idempotent driver). Reads `.bootstrap.env`, validates config, exposes a
# pipeline of 19 step classes. CI mode runs 18 steps with default
# PLATFORMS=ios,macos; local mode runs 18. Each step has a `check`
# (returns bool, no side effects)
# and a `do_it` (idempotent: safe to re-run on partial state).
#
# Doctor mode just calls every `check` and reports.
# Bootstrap mode calls `check || do_it` per step and stops on first failure.
#
# Steps that can't be automated (Apple disallows POST /apps + API key creation,
# GitHub disallows programmatic PAT creation) fail loud in `do_it` with
# explicit web-UI instructions.

require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "securerandom"
require "shellwords"
require "tmpdir"

module Bootstrap
  REPO_ROOT = Pathname.new(__dir__).join("..", "..").expand_path
  ENV_FILE  = REPO_ROOT.join(".bootstrap.env")

  # The 5 GH Secrets the release pipeline needs. Order: stable for doctor.
  REQUIRED_SECRETS = %w[
    KEYCHAIN_PASSWORD
    ASC_API_KEY_ID
    ASC_API_KEY_ISSUER_ID
    ASC_API_KEY_P8_BASE64
    FASTLANE_TEAM_ID
  ].freeze

  # Raised when an App Store Connect API call is rejected because a required
  # Apple agreement (Program License Agreement, Paid Applications Agreement,
  # or freshly-updated terms) is unsigned or expired. Apple gates the ENTIRE
  # ASC API behind an in-effect agreement, so this blocks every call
  # account-wide — cert mint, build lookup, upload — until the Account Holder
  # accepts it in the ASC web UI. No API or automation can accept it.
  # Surfaced 2026-07-11 when the Saturday canary went red across all cells at
  # the compute-release-tag step. The message is the actionable runbook.
  class AscAgreementError < StandardError
    # Apple raises this as a generic Spaceship::UnexpectedResponse (no typed
    # class to rescue on), so detection is by message. Both phrases appear in
    # the real error: "A required agreement is missing or has expired. - This
    # request requires an in-effect agreement that has not been signed…".
    def self.match?(err)
      err.message.to_s =~ /(required|in-effect) agreement|agreement (is missing|has expired|has not been signed)/i
    end

    def initialize(original_message = nil)
      detail = original_message ? "\n\n  ASC said: #{original_message.to_s.strip[0, 300]}" : ""
      super(<<~MSG.chomp + detail)
        App Store Connect rejected the request: a required Apple agreement is missing or has expired.
        This blocks ALL ASC API calls for the account until it is accepted — no API or automation can do it.

        Fix (Account Holder only, ~2 min):
          1. Sign in at https://appstoreconnect.apple.com
          2. Accept the pending banner on the home page, AND check
             Business -> Agreements, Tax, and Banking for a pending agreement.
          3. Also check https://developer.apple.com/account (Membership) for a
             Program License Agreement banner.
        Apple periodically updates these; acceptance unblocks every ship (the
        canary AND your real app).
      MSG
    end
  end

  # ─── Config loader ──────────────────────────────────────────────────────────

  class Config
    REQUIRED_ALWAYS = %w[
      APP_NAME BUNDLE_ID DISPLAY_NAME APP_EMAIL GENERATOR RELEASE_MODE
      FASTLANE_TEAM_ID ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID ASC_API_KEY_P8_PATH
      GH_ORG GH_APP_REPO
    ].freeze

    REQUIRED_CI_ONLY = %w[
      KEYCHAIN_PASSWORD_FILE
    ].freeze

    OPTIONAL = %w[ICON_1024_PATH ASC_APP_SKU ASC_APP_NAME PLATFORMS SUBMIT_FOR_REVIEW].freeze

    attr_reader :values

    def self.load!
      env_file = ENV_FILE
      unless env_file.exist?
        UI.fail!(<<~MSG)
          .bootstrap.env not found at #{env_file}.

          Copy the example and fill in your values:
            cp .bootstrap.env.example .bootstrap.env
            $EDITOR .bootstrap.env

          See docs/BOOTSTRAP.md for what each field means and where to source it.
        MSG
      end
      new(parse(env_file))
    end

    def self.parse(path)
      values = {}
      path.each_line.with_index do |line, idx|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        key, _, val = line.partition("=")
        UI.fail!(".bootstrap.env line #{idx + 1}: missing '='") if val.nil? || key.strip.empty?
        val = val.strip
        if val.start_with?("'") || val.start_with?('"')
          # Quoted value. Find the matching closing quote; the value is
          # exactly what's between the two quotes. Anything after the
          # closing quote (typically `  # trailing comment`) is discarded.
          # We deliberately do NOT honor backslash escapes here — `.bootstrap.env`
          # values are paths, ids, and short strings, never multi-line literals.
          quote_char = val[0]
          closing = val.index(quote_char, 1)
          val = closing ? val[1...closing] : val
        elsif (comment_at = val.index(/(?:^|\s)#/))
          # Unquoted value with an inline comment. Strip everything from the
          # first whitespace-hash onward (dotenv convention). Bare '#' inside
          # an unquoted value (e.g. URL fragments) is preserved because it
          # has no preceding whitespace. The (?:^|\s) form also matches a
          # value that's purely a comment (`KEY=  # only-a-comment`) — strip
          # to the empty string.
          # The .bootstrap.env.example template ships every fillable field
          # with an inline `# placeholder` comment; without this strip, a
          # forker who fills `BUNDLE_ID=com.foo.bar` while leaving the
          # trailing `# iOS + macOS share the same bundle id.` comment
          # would have that comment text mashed onto the bundle id, breaking
          # every downstream Apple/GH probe.
          val = val[0...comment_at].rstrip
        end
        values[key.strip] = val
      end
      values
    end

    def initialize(values)
      @values = values
    end

    def [](key)
      @values[key].to_s
    end

    def set?(key)
      v = @values[key]
      !v.nil? && !v.strip.empty?
    end

    def expand_path(key)
      raw = self[key]
      return nil if raw.empty?
      Pathname.new(raw).expand_path
    end

    def validate!
      mode = release_mode
      unless %w[ci local].include?(mode)
        UI.fail!(".bootstrap.env: RELEASE_MODE must be 'ci' or 'local' (got: #{mode.inspect})")
      end
      validate_platforms!
      required = REQUIRED_ALWAYS + (mode == "ci" ? REQUIRED_CI_ONLY : [])
      missing = required.reject { |k| set?(k) }
      return if missing.empty?

      # Common onboarding trap: users transcribe the unsuffixed name
      # (MATCH_PASSWORD, KEYCHAIN_PASSWORD, GH_PAT) instead of the path
      # form (MATCH_PASSWORD_FILE, etc.) that .bootstrap.env expects.
      # The unsuffixed name is what fastlane/gh internally consume —
      # natural to type, wrong to set here. If the user has the path-less
      # variant present, point them at the rename.
      hints = []
      missing.each do |key|
        next unless key.end_with?("_FILE")
        unsuffixed = key.sub(/_FILE\z/, "")
        next unless set?(unsuffixed)
        hints << "  - rename `#{unsuffixed}=` to `#{key}=` (the *_FILE suffix denotes a path; bootstrap reads the file and exposes #{unsuffixed} to subprocesses)"
      end

      hint_block = hints.empty? ? "" : "\n\nHint:\n#{hints.join("\n")}"

      UI.fail!(<<~MSG)
        .bootstrap.env is missing required fields (RELEASE_MODE=#{mode}):
        #{missing.map { |k| "  - #{k}" }.join("\n")}#{hint_block}

        Edit .bootstrap.env and re-run.
      MSG
    end

    def release_mode
      m = self["RELEASE_MODE"]
      m.empty? ? "ci" : m
    end

    # Returns the active platforms as an array of strings.
    # PLATFORMS=ios          → %w[ios]
    # PLATFORMS=macos        → %w[macos]
    # PLATFORMS=ios,macos    → %w[ios macos]
    # PLATFORMS unset/empty  → %w[ios macos] (default: both, current behavior)
    def platforms
      raw = self["PLATFORMS"].strip
      return %w[ios macos] if raw.empty?
      raw.split(",").map(&:strip).reject(&:empty?)
    end

    def platform_enabled?(platform)
      platforms.include?(platform.to_s)
    end

    def ios?;   platform_enabled?("ios");   end
    def macos?; platform_enabled?("macos"); end

    private

    def validate_platforms!
      valid = %w[ios macos]
      bad = platforms.reject { |p| valid.include?(p) }
      return if bad.empty? && !platforms.empty?
      if platforms.empty?
        UI.fail!(".bootstrap.env: PLATFORMS cannot be empty. Use 'ios', 'macos', or 'ios,macos'.")
      end
      UI.fail!(<<~MSG)
        .bootstrap.env: PLATFORMS contains invalid value(s): #{bad.inspect}
        Valid values: 'ios', 'macos', or comma-separated like 'ios,macos'.
      MSG
    end

    public

    def ci_mode?;    release_mode == "ci";    end
    def local_mode?; release_mode == "local"; end

    def repo_slug
      "#{self["GH_ORG"]}/#{self["GH_APP_REPO"]}"
    end

  end

  # ─── UI helpers ─────────────────────────────────────────────────────────────

  module UI
    GREEN  = "\e[32m"
    RED    = "\e[31m"
    YELLOW = "\e[33m"
    DIM    = "\e[2m"
    BOLD   = "\e[1m"
    RESET  = "\e[0m"

    module_function

    def tty?
      $stdout.tty?
    end

    def colorize(text, color)
      tty? ? "#{color}#{text}#{RESET}" : text
    end

    def ok(text); colorize("✓ #{text}", GREEN); end
    def miss(text); colorize("✗ #{text}", RED); end
    def warn(text); colorize("⚠ #{text}", YELLOW); end
    def dim(text); colorize(text, DIM); end
    def bold(text); colorize(text, BOLD); end

    def fail!(msg)
      $stderr.puts colorize("ERROR: #{msg}", RED)
      exit 1
    end

    def section(text)
      puts
      puts bold(text)
      puts colorize("─" * text.length, DIM)
    end

    def step_header(num, total, name)
      puts colorize("[#{num}/#{total}] #{name}", BOLD)
    end
  end

  # ─── Shell + tool helpers ───────────────────────────────────────────────────

  module Sh
    module_function

    # Run a command; raise on non-zero exit.
    def run!(*cmd, env: {}, cwd: REPO_ROOT)
      Dir.chdir(cwd) do
        out, err, status = Open3.capture3(env, *cmd)
        unless status.success?
          UI.fail!("command failed (exit #{status.exitstatus}):\n  #{cmd.join(' ')}\nstdout: #{out}\nstderr: #{err}")
        end
        out
      end
    end

    # Run a command; capture output regardless of exit. Returns [stdout, success?]
    def run(*cmd, env: {}, cwd: REPO_ROOT)
      Dir.chdir(cwd) do
        out, _err, status = Open3.capture3(env, *cmd)
        [out, status.success?]
      end
    end

    # Quiet boolean check.
    def ok?(*cmd, env: {}, cwd: REPO_ROOT)
      _out, success = run(*cmd, env: env, cwd: cwd)
      success
    end
  end

  # ─── Step base class ────────────────────────────────────────────────────────

  class Step
    # Each subclass may override MODES + PLATFORMS to restrict applicability:
    #   class LocalKeychainCerts < Step; MODES = %w[local]; end   # local only
    #   class MakeIcons < Step; PLATFORMS = %w[macos]; end        # macOS only
    # Default: run in any mode and any platform combination.
    MODES = %w[ci local].freeze
    PLATFORMS = %w[ios macos].freeze

    attr_reader :config

    def initialize(config)
      @config = config
    end

    # Step is applicable iff (a) the active mode is in MODES AND
    # (b) at least one of the active platforms is in PLATFORMS.
    def applicable?(mode, active_platforms)
      return false unless self.class.const_get(:MODES).include?(mode)
      step_platforms = self.class.const_get(:PLATFORMS)
      (step_platforms & active_platforms).any?
    end

    # Subclasses override.
    def name; self.class.name.split("::").last; end
    def category; "programmatic"; end
    # check returns one of:
    #   :done            — already in desired state, skip do_it
    #   :pending         — not in desired state, run do_it
    #   [:blocked, msg]  — human-gated, do_it will fail loud with msg
    def check; raise NotImplementedError; end
    def do_it; raise NotImplementedError; end
  end

  # ─── Concrete steps ─────────────────────────────────────────────────────────

  class CheckAppleCreds < Step
    def name; "Apple credentials"; end
    def category; "preflight"; end

    def check
      p8 = config.expand_path("ASC_API_KEY_P8_PATH")
      return [:blocked, "ASC_API_KEY_P8_PATH file does not exist: #{p8}"] unless p8 && p8.file?

      # Probe ASC API by requesting current user
      require "spaceship"
      pem_path = write_p8(p8)
      token = Spaceship::ConnectAPI::Token.create(
        key_id:    config["ASC_API_KEY_ID"],
        issuer_id: config["ASC_API_KEY_ISSUER_ID"],
        filepath:  pem_path
      )
      Spaceship::ConnectAPI.token = token
      apps = Spaceship::ConnectAPI::App.all(limit: 1)
      :done
    rescue StandardError => e
      [:blocked, "ASC API probe failed: #{e.class.name}: #{e.message}"]
    end

    def do_it
      # No automation possible — credentials must be valid.
      UI.fail!("Apple credentials invalid. Fix .bootstrap.env then re-run.")
    end

    private

    def write_p8(src)
      # If src is .p8 PEM, return path. (Spaceship reads PEM from filepath.)
      src.to_s
    end
  end

  class CheckGHCreds < Step
    def name; "GitHub credentials"; end
    def category; "preflight"; end

    def check
      return :done if config.local_mode? # gh CLI not used at ship time in local mode
      # CI mode uses `gh` CLI for setting up branch protection, GH Secrets,
      # and dispatching release.yml. The CLI's auth is separate from anything
      # in .bootstrap.env — set up once via `gh auth login`. Probe it.
      out, ok = Sh.run("gh", "auth", "status")
      return :done if ok
      [:blocked, "gh CLI is not authenticated. Run `gh auth login` then re-try.\n  (output: #{out.lines.first(2).join.strip})"]
    end

    def do_it
      UI.fail!("GitHub credentials invalid. Run `gh auth login` then re-run.")
    end
  end

  class RenameStub < Step
    def name; "Rename HelloApp → #{config['APP_NAME']}"; end

    def check
      # Done iff: shared swift file exists AND no leftover HelloApp / com.example.helloapp
      # references in source tree (excluding vendor, .git, .planning, build).
      shared = REPO_ROOT.join("app", "Shared", "#{config['APP_NAME']}.swift")
      shared.file? ? :done : :pending
    end

    def do_it
      args = [
        "bin/rename.sh",
        config["APP_NAME"], config["BUNDLE_ID"], config["DISPLAY_NAME"],
        "--email=#{config['APP_EMAIL']}",
        "--generator=#{config['GENERATOR']}",
        "--platforms=#{config.platforms.join(',')}",
        "--team-id=#{config['FASTLANE_TEAM_ID']}"
      ]
      Sh.run!(*args)
      Sh.run!("bin/verify-rename.sh")
    end
  end


  class BrewBootstrap < Step
    def name; "Toolchain (brew + bundler + xcodegen/tuist + lefthook)"; end

    def check
      return :pending unless Sh.ok?("bundle", "check")
      tool = config["GENERATOR"] == "tuist" ? "tuist" : "xcodegen"
      Sh.ok?("which", tool) && Sh.ok?("which", "lefthook") ? :done : :pending
    end

    def do_it
      Sh.run!("make", "bootstrap")
    end
  end

  class InitialPush < Step
    def name; "Initial commit + push"; end

    def check
      out, ok = Sh.run("git", "ls-remote", "--heads", "origin", "main")
      return :pending unless ok && !out.strip.empty?
      # main exists on origin. Has rename landed?
      out2, _ = Sh.run("git", "diff", "--stat", "origin/main", "--", "app/Shared")
      out2.strip.empty? ? :done : :pending
    end

    def do_it
      _out, dirty = Sh.run("git", "diff", "--quiet")
      Sh.run!("git", "add", "-A") unless dirty
      Sh.run!("git", "-c", "user.email=#{config['APP_EMAIL']}", "-c", "user.name=#{config['APP_NAME']} bootstrap",
              "commit", "-m", "Bootstrap fork: rename HelloApp -> #{config['APP_NAME']}") unless dirty
      Sh.run!("git", "push", "-u", "origin", "main")
    end
  end

  # Surfaced when the GitHub repo is private AND the owning account is on
  # the free plan. GitHub gates branch protection (and required status
  # checks, required reviews, enforce-admins, linear-history, etc.) behind
  # paid plans for private repos. Public repos get all of it for free.
  # Three actionable resolutions; user picks one based on their constraints.
  # Wrapped to ~80 cols for terminal readability.
  def self.branch_protection_free_private_msg(repo_slug)
    <<~MSG.chomp
      GitHub branch protection unavailable: this repo is PRIVATE on the free plan.
        GitHub gates branch protection on private repos behind paid plans.
        Three options:
          A) Make the repo public (free, branch protection works immediately):
               gh repo edit #{repo_slug} --visibility public --accept-visibility-change-consequences
          B) Upgrade to GitHub Pro ($4/mo gives private repos branch protection):
               https://github.com/settings/billing/plans
          C) Accept no protection (template ships fine; you lose the
             "no direct pushes to main" + "CI must pass before merge" gate).
             Fine for solo work; teams want A or B.
    MSG
  end

  class BranchProtection < Step
    def name; "GitHub branch protection on main"; end

    def check
      # Probe for the protection's enforce_admins value. Three reasons to
      # treat the result specially:
      #   1. No protection at all (HTTP 404) — first-time fork, hasn't run yet
      #      → return :pending so do_it can run setup-github.sh.
      #   2. Protection exists but enforce_admins doesn't match the current
      #      RELEASE_MODE → return :pending so do_it re-applies. Lets a forker
      #      switch ci ↔ local later by editing .bootstrap.env + re-running
      #      `make bootstrap-fork`; without this drift detection,
      #      BranchProtection would stay :done and the protection config would
      #      silently mismatch the mode.
      #   3. HTTP 403 + "Upgrade to GitHub Pro" — repo is PRIVATE and the
      #      account is on the free plan, which doesn't include branch
      #      protection. The PUT in setup-github.sh would 403 here, so we
      #      preempt with a :warn and DON'T try (saving the user the confusing
      #      mid-bootstrap-fork failure). The :warn surfaces three actionable
      #      paths: make repo public (free), upgrade to Pro ($4/mo), or accept
      #      the trade-off (no main-branch gate). Detection: GET also returns
      #      403 + the same Upgrade-to-GitHub-Pro message body — `gh api` puts
      #      the JSON response in stdout even on non-zero exit, so we can
      #      match the message without capturing stderr separately.
      out, ok = Sh.run("gh", "api",
                       "repos/#{config.repo_slug}/branches/main/protection",
                       "--jq", ".enforce_admins.enabled")
      if !ok && out.include?("Upgrade to GitHub Pro")
        return [:warn, Bootstrap.branch_protection_free_private_msg(config.repo_slug)]
      end
      return :pending unless ok
      current = out.strip == "true"
      desired = config.ci_mode?
      current == desired ? :done : :pending
    end

    def do_it
      Sh.run!("bin/setup-github.sh")
    end
  end

  class GHSecrets < Step
    MODES = %w[ci].freeze

    # GH Actions repo Variables (not Secrets) required by both release.yml +
    # pr.yml. Workflows read these via `${{ vars.APP_NAME }}` /
    # `${{ vars.BUNDLE_ID }}` at workflow-level env blocks. Distinct from
    # secrets because they're non-sensitive identity strings the user
    # purposely wants visible in logs (e.g. so a workflow failure cleanly
    # shows which app+bundle triggered). They MUST be set for CI-mode
    # release.yml to compute the release tag (release.yml fails fast with
    # `vars.BUNDLE_ID is not set on this repo` if missing); pr.yml falls
    # back to 'HelloApp' literals when unset, which won't match a renamed
    # fork's scheme/xcodeproj — so PR CI also breaks silently without these.
    REQUIRED_VARIABLES = %w[APP_NAME BUNDLE_ID].freeze

    def name; "Set 5 GH Secrets + 2 GH Variables on app repo"; end

    def check
      out, ok = Sh.run("gh", "secret", "list", "--repo", config.repo_slug)
      return :pending unless ok
      secrets_present = out.lines.map { |l| l.split(/\s+/).first }.compact
      return :pending unless REQUIRED_SECRETS.all? { |s| secrets_present.include?(s) }

      out, ok = Sh.run("gh", "variable", "list", "--repo", config.repo_slug)
      return :pending unless ok
      vars_present = out.lines.map { |l| l.split(/\s+/).first }.compact
      REQUIRED_VARIABLES.all? { |v| vars_present.include?(v) } ? :done : :pending
    end

    def do_it
      # Generate or load the keychain password.
      keychain_pw = ensure_random_password("KEYCHAIN_PASSWORD_FILE", 32)

      p8 = config.expand_path("ASC_API_KEY_P8_PATH").read
      p8_base64 = Base64.strict_encode64(p8)

      secrets = {
        "KEYCHAIN_PASSWORD"             => keychain_pw,
        "ASC_API_KEY_ID"                => config["ASC_API_KEY_ID"],
        "ASC_API_KEY_ISSUER_ID"         => config["ASC_API_KEY_ISSUER_ID"],
        "ASC_API_KEY_P8_BASE64"         => p8_base64,
        "FASTLANE_TEAM_ID"              => config["FASTLANE_TEAM_ID"]
      }

      secrets.each do |key, val|
        IO.popen(["gh", "secret", "set", key, "--repo", config.repo_slug], "w") { |io| io.write(val) }
        UI.fail!("gh secret set #{key} failed") unless $?.success?
      end

      # Set the workflow-level repo Variables. These are non-sensitive and
      # accept `--body` directly (vs secrets which read from stdin to avoid
      # leaking through process listings). `gh variable set` is idempotent:
      # re-running overwrites the prior value silently, so this is safe to
      # re-invoke (e.g. after the user changes APP_NAME / BUNDLE_ID in
      # `.bootstrap.env` and re-runs `make bootstrap-fork`).
      variables = {
        "APP_NAME"  => config["APP_NAME"],
        "BUNDLE_ID" => config["BUNDLE_ID"]
      }

      variables.each do |key, val|
        UI.fail!("#{key} is empty in .bootstrap.env; cannot set as GH variable") if val.to_s.strip.empty?
        Sh.run!("gh", "variable", "set", key, "--body", val, "--repo", config.repo_slug)
      end
    end

    private


    def ensure_random_password(env_key, length)
      path = config.expand_path(env_key)
      UI.fail!("#{env_key} not set in .bootstrap.env") unless path
      if path.file? && !path.read.strip.empty?
        return path.read.strip
      end
      FileUtils.mkdir_p(path.dirname)
      pw = SecureRandom.base64(length).gsub(/[^A-Za-z0-9]/, "")[0, length]
      path.write(pw)
      File.chmod(0o600, path.to_s)
      pw
    end
  end


  class RegisterAppId < Step
    def name; "Register Bundle ID in Apple Developer Portal"; end

    def check
      require "spaceship"
      Bootstrap.ensure_asc_token!(config)
      Spaceship::ConnectAPI::BundleId.find(config["BUNDLE_ID"]) ? :done : :pending
    rescue StandardError => e
      [:blocked, "ASC probe failed: #{e.message}"]
    end

    def do_it
      env = asc_env(config)
      Sh.run!("bundle", "exec", "fastlane", "register_app_id", env: env)
    end
  end

  class VerifyAscApp < Step
    def name; "Verify ASC App record exists"; end
    def category; "human-gated"; end

    def check
      require "spaceship"
      Bootstrap.ensure_asc_token!(config)
      Spaceship::ConnectAPI::App.find(config["BUNDLE_ID"]) ? :done : [:blocked, asc_creation_msg]
    rescue StandardError => e
      [:blocked, "ASC probe failed: #{e.message}"]
    end

    def do_it
      UI.fail!(asc_creation_msg)
    end

    private

    # Human-readable label of the active platforms — for display in the
    # ASC creation hint. Mirrors bin/rename.sh's PLATFORMS_LABEL.
    def platforms_label
      ios   = config.ios?
      macos = config.macos?
      return "iOS + macOS" if ios && macos
      return "iOS"         if ios
      return "macOS"       if macos
      "iOS + macOS"  # defensive: shouldn't happen given Config.validate_platforms!
    end
    def asc_creation_msg
      <<~MSG
        ASC App record for #{config['BUNDLE_ID']} not found.

        The App Store Connect API does not allow POST /apps. Create the App
        record once via the web UI:

          1. Open https://appstoreconnect.apple.com/apps  →  + (New App)
          2. Platforms:        #{platforms_label}
             Name:             #{config['ASC_APP_NAME'].to_s.empty? ? config['DISPLAY_NAME'] : config['ASC_APP_NAME']}
             Primary Language: English (U.S.)
             Bundle ID:        #{config['BUNDLE_ID']}
             SKU:              #{config['ASC_APP_SKU'].to_s.empty? ? '(any unique string)' : config['ASC_APP_SKU']}
             User Access:      Full Access
          3. Re-run `make bootstrap` — this step will pass.
      MSG
    end
  end



  class Icon1024 < Step
    def name; "Replace 1024 icon"; end

    def icon_target
      REPO_ROOT.join("app", "iOS", "Assets.xcassets", "AppIcon.appiconset", "Icon-1024.png")
    end

    def check
      unless config.set?("ICON_1024_PATH")
        return [:warn, "ICON_1024_PATH unset; the template hammer icon will ship. Required for App Store review (not TestFlight)."]
      end
      src = config.expand_path("ICON_1024_PATH")
      return [:blocked, "ICON_1024_PATH does not exist: #{src}"] unless src.file?
      return :pending unless icon_target.file?
      Digest::SHA256.file(src).hexdigest == Digest::SHA256.file(icon_target).hexdigest ? :done : :pending
    end

    def do_it
      src = config.expand_path("ICON_1024_PATH")
      FileUtils.cp(src, icon_target)
    end
  end

  class MakeIcons < Step
    PLATFORMS = %w[macos].freeze
    def name; "Regenerate macOS icon set + .icns"; end

    def check
      return :done unless config.set?("ICON_1024_PATH") # optional gate
      icns = REPO_ROOT.join("app", "macOS", "Assets.xcassets", "AppIcon.appiconset", "icon_512x512@2x.png")
      icons_target_mtime = icns.file? ? icns.mtime : Time.at(0)
      icon_src = REPO_ROOT.join("app", "iOS", "Assets.xcassets", "AppIcon.appiconset", "Icon-1024.png")
      icons_target_mtime >= icon_src.mtime ? :done : :pending
    end

    def do_it
      Sh.run!("make", "icons")
    end
  end

  class ScanMetadata < Step
    def name; "App Store metadata text files"; end

    def metadata_dir; REPO_ROOT.join("fastlane", "metadata", "en-US"); end
    def review_dir;   REPO_ROOT.join("fastlane", "metadata", "review_information"); end
    def root_dir;     REPO_ROOT.join("fastlane", "metadata"); end

    # Maps review_information/<file>.txt → corresponding APP_REVIEW_* env
    # var. When the env var is set non-empty (typically exported from your
    # shell profile, .envrc, or 1Password CLI), the tracked
    # placeholder file is allowed to keep its TODO — Fastfile's
    # `read_review_field` uses env first, file second. This keeps doctor
    # from nagging about TODO placeholders that are deliberately tracked.
    REVIEW_FIELD_ENV = {
      "first_name.txt"    => "APP_REVIEW_FIRST_NAME",
      "last_name.txt"     => "APP_REVIEW_LAST_NAME",
      "email_address.txt" => "APP_REVIEW_EMAIL",
      "phone_number.txt"  => "APP_REVIEW_PHONE",
      "notes.txt"         => "APP_REVIEW_NOTES"
    }.freeze

    # Same env-skip pattern for org-stable App Store metadata fields
    # (en-US/*.txt URLs + copyright.txt). Fastfile's `asc_field` lambda
    # reads ENV first; when set, the tracked file placeholder is
    # acceptable. Maps from {en-US/<file>, copyright.txt} → ASC_* env var.
    EN_US_FIELD_ENV = {
      "marketing_url.txt" => "ASC_MARKETING_URL",
      "privacy_url.txt"   => "ASC_PRIVACY_URL",
      "support_url.txt"   => "ASC_SUPPORT_URL"
    }.freeze

    COPYRIGHT_FIELD_ENV = "ASC_COPYRIGHT"

    # `example.com` placeholder detection for the URL files. The template
    # ships `https://example.com[/path]` in every URL .txt; Apple's deliver
    # accepts these but they're clearly placeholder leaks, so we flag them
    # alongside the explicit TODO/REPLACE_ME markers.
    PLACEHOLDER_PATTERN = /\bTODO\b|REPLACE_ME|com\.example\.helloapp|HelloApp|\bexample\.com\b|\+10000000000/i

    def check
      todos = []
      [metadata_dir, review_dir].each do |dir|
        next unless dir.directory?
        Dir.glob(dir.join("*.txt")).each do |f|
          basename = File.basename(f)
          env_name = case dir
                     when review_dir   then REVIEW_FIELD_ENV[basename]
                     when metadata_dir then EN_US_FIELD_ENV[basename]
                     end
          next if env_name && !ENV[env_name].to_s.strip.empty?
          content = File.read(f)
          if content.match?(PLACEHOLDER_PATTERN)
            todos << Pathname.new(f).relative_path_from(REPO_ROOT).to_s
          elsif content.strip.empty?
            todos << "#{Pathname.new(f).relative_path_from(REPO_ROOT)} (empty)"
          end
        end
      end
      # copyright.txt lives at metadata/, not under en-US/ or
      # review_information/. Scan it separately so the env-skip path
      # for ASC_COPYRIGHT works the same as the en-US URL fields.
      copyright = root_dir.join("copyright.txt")
      if copyright.file? && ENV[COPYRIGHT_FIELD_ENV].to_s.strip.empty?
        content = File.read(copyright)
        if content.match?(PLACEHOLDER_PATTERN)
          todos << Pathname.new(copyright).relative_path_from(REPO_ROOT).to_s
        elsif content.strip.empty?
          todos << "#{Pathname.new(copyright).relative_path_from(REPO_ROOT)} (empty)"
        end
      end
      return :done if todos.empty?
      msg = +"#{todos.length} files need attention before App Store review:\n  - #{todos.join("\n  - ")}"
      # If BUNDLE_ID is set to something non-placeholder + ASC API creds are
      # configured, the user is plausibly adopting an existing live app. Surface
      # `make adopt` so they don't overwrite their live App Store listing.
      # Greenfield forks (BUNDLE_ID is the placeholder) just edit the files.
      bundle_id = config["BUNDLE_ID"].to_s
      if !bundle_id.empty? && bundle_id != "com.example.helloapp" && ENV["ASC_API_KEY_ID"]
        msg << "\n\n  If your fork is adopting a LIVE App Store app, do NOT just edit these files —"
        msg << "\n  running `make submit` would overwrite your real App Store listing with"
        msg << "\n  the local placeholders. Instead, run `make adopt` first to pull your"
        msg << "\n  existing ASC metadata + screenshots down to disk. See docs/ADOPTING-EXISTING-APP.md."
      end
      [:warn, msg]
    end

    def do_it
      # No-op; check returns :warn or :done, never :pending.
    end
  end

  # G11 — App Privacy Form publish-state check.
  #
  # Apple requires every app submitted to the App Store to declare its data
  # collection practices via the "App Privacy" form in App Store Connect
  # (https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).
  # The form covers: what data the app collects, why (analytics, advertising,
  # app functionality, etc.), whether each data type is linked to user
  # identity, and whether any of it is used for tracking. IDFA usage is one
  # of dozens of dimensions — declaring IDFA alone doesn't satisfy the form.
  #
  # The schema (`AppDataUsage` records grouped by `AppDataUsageCategory` x
  # `AppDataUsagePurposes` x `AppDataUsageDataProtection`) is complex,
  # changes with Apple's annual privacy-policy iterations, and must match
  # the actual SDKs your app links against — mismatches trigger App Review
  # rejection ("the app's privacy information indicates X but your binary
  # uses Y"). Plumbing it through dotenv would invite drift; we instead
  # surface the form's publish-state as a doctor warning so first-time
  # shippers know they need to fill it manually in the ASC web UI.
  #
  # Suppression: `ASC_APP_PRIVACY_ACK=true` env var (typically exported
  # from your shell profile after you've published the form once) silences
  # the warning even when the API reports unpublished — useful for offline
  # validation runs or scenarios where Apple's API briefly flakes.
  class AppPrivacyForm < Step
    def name; "App Privacy form published in ASC"; end
    def category; "human-gated"; end

    def check
      return :done if ENV["ASC_APP_PRIVACY_ACK"].to_s.strip.downcase == "true"
      require "spaceship"
      Bootstrap.ensure_asc_token!(config)
      app = Spaceship::ConnectAPI::App.find(config["BUNDLE_ID"])
      return [:warn, "ASC App record not found (covered by VerifyAscApp); App Privacy check skipped."] unless app
      state = Spaceship::ConnectAPI::AppDataUsagesPublishState.get(app_id: app.id)
      if state.nil?
        return [:warn, app_privacy_msg("Could not resolve App Privacy publish-state (Apple API returned no record).")]
      end
      return :done if state.published
      [:warn, app_privacy_msg("App Privacy form is unpublished (last published: #{state.last_published || 'never'}).")]
    rescue NameError => e
      # AppDataUsagesPublishState only present in fastlane >= 2.224; older
      # forks pinned to earlier gem versions get a soft warning + skip
      # rather than a hard crash.
      [:warn, "spaceship AppDataUsagesPublishState not available in this fastlane version (#{e.message[0, 100]}); upgrade Gemfile pin if you want App Privacy form auto-check."]
    rescue Spaceship::UnexpectedResponse => e
      # Apple renamed the App Privacy API surface in Apr-May 2026 — the
      # `dataUsagePublishState` and `dataUsages` relationships on the App
      # resource were removed in favor of (per Apple's developer forums)
      # versioned subresources that spaceship hasn't shipped support for
      # yet (fastlane 2.234.0 still uses the old path). When we get this
      # specific 4xx, the probe is dead but the form itself is reachable
      # via the ASC web UI; surface a clearer remediation than the raw
      # Apple error.
      if e.message.include?("dataUsagePublishState") || e.message.include?("dataUsages")
        [:warn, app_privacy_msg("App Privacy publish-state probe is broken (Apple renamed the API; current spaceship gem hasn't caught up).")]
      else
        [:warn, "App Privacy probe failed: #{e.message[0, 200]}"]
      end
    rescue StandardError => e
      [:warn, "App Privacy probe failed: #{e.message[0, 200]}"]
    end

    def do_it
      # No-op; check returns :warn or :done, never :pending.
    end

    private

    def app_privacy_msg(reason)
      <<~MSG.strip
        #{reason}
          Fill the App Privacy form in App Store Connect before submitting for review:
            https://appstoreconnect.apple.com/apps  →  your app  →  App Privacy  →  Edit
          Most template forks declare "Data Not Collected" (no analytics SDK, no ads,
          no IDFA, no third-party trackers); Apple validates against your binary's
          actual SDK usage, so mismatches trigger rejection.
          Suppress this check after publishing: export ASC_APP_PRIVACY_ACK=true
          (typically in your shell profile / .envrc).
      MSG
    end
  end

  class XcodeQuarantine < Step
    def name; "Xcode.app quarantine xattr"; end

    XCODE = "/Applications/Xcode.app".freeze

    def check
      # Skip cleanly on hosts that don't have Xcode at the canonical location
      # (Linux CI, command-line-tools-only Macs, alternate Xcode install paths).
      # The check is advisory anyway — a missing Xcode.app surfaces elsewhere
      # via BrewBootstrap / xcodebuild failures, not here.
      return :done unless File.exist?(XCODE)

      # Top-level xattr scan only — one syscall, ~1ms. The canonical place where
      # `com.apple.quarantine` lives is on Xcode.app itself, set by macOS when
      # the .xip archive (xcodes-cli, manual Apple Developer downloads) was
      # extracted. Recursive `xattr -lr` on Xcode.app takes 30+ seconds
      # (12+ GB tree) which is unacceptable for a doctor check. If quarantine
      # is hidden on a nested file with no top-level bit, `make screenshots`
      # still handles it via the runner-bundle strip from ci/take-screenshots.sh.
      out = `xattr #{XCODE.shellescape} 2>/dev/null`.to_s
      return :done unless out.include?("com.apple.quarantine")
      [:warn, quarantine_msg]
    end

    def do_it
      # No-op; advisory only. The actual fix needs sudo (Xcode.app is owned by
      # root:wheel) — running it silently from a project-local script would
      # violate scope (mutates a machine-wide app outside this fork) and would
      # need a sudo password prompt mid-doctor. The advisory surfaces the
      # one-line fix; the user decides whether to run it.
    end

    private

    def quarantine_msg
      <<~MSG.strip
        /Applications/Xcode.app carries com.apple.quarantine xattr.
          `make screenshots` works around it automatically (strips + ad-hoc re-signs
          the UI test runner before launch via ci/take-screenshots.sh), so this is
          NOT blocking. But Gatekeeper may reject other dev-tool launches
          (command-line builds, third-party Xcode plugins, ad-hoc binaries).
          To clear permanently (one-time, ~5 sec, requires sudo):
            sudo xattr -dr com.apple.quarantine /Applications/Xcode.app
          Most often appears when Xcode was installed via xcodes-cli or a manually
          downloaded .xip archive; App Store installs don't carry the bit.
      MSG
    end
  end

  class DefaultKeychain < Step
    def name; "Default keychain set"; end

    def check
      # Linux runners have no Keychain Services — skip cleanly.
      return :done unless RUBY_PLATFORM.include?("darwin")

      # `security default-keychain -d user` prints the path on success; on
      # failure prints `SecKeychainCopyDomainDefault user: A default keychain
      # could not be found.` to stderr and exits 1. The MISSING-default state
      # surfaces silently for normal macOS use (Keychain Access, Wi-Fi auth,
      # browser saved passwords all work without a default — they walk the
      # search list) but breaks the `security cms -D -i <profile>` decode
      # that fastlane's sigh runs internally on every freshly-minted
      # provisioning profile. Caller-visible failure: `make ship` aborts at
      # sigh step with `Failure to decode <profile>. Exit: 1: security: cert
      # import failed: A default keychain could not be found.`
      #
      # Most common cause: a prior `security delete-keychain` removed a
      # keychain that was marked as the user-default (fastlane's setup_ci
      # sets its temp keychain as default via `default_keychain: true`).
      # Deleting it leaves the user with no default until they re-set one.
      # Less common: corrupted preferences in ~/Library/Preferences/.
      _out, ok = Sh.run("security", "default-keychain", "-d", "user")
      return :done if ok
      [:warn, missing_default_msg]
    end

    def do_it
      # No-op. Mutating user-keychain state stays user-controlled — same
      # policy as XcodeQuarantine + FastlaneTmpKeychain. The fix is a
      # single command (no sudo, ~1ms) and we surface it inline; the user
      # decides whether to run. We deliberately don't `do_it` because:
      #   1. If login.keychain-db is missing or corrupted, blindly setting
      #      it as default would leave the user with a broken default
      #      pointing at a non-existent or unreadable file — worse than
      #      the current state where Keychain Services walks the search
      #      list and works for read paths.
      #   2. The user may have intentionally unset the default (some
      #      hardened-mac setups deliberately have no default to force
      #      explicit -k keychain-path arguments on every security call).
      #      Auto-setting it would silently undo that choice.
    end

    private

    def missing_default_msg
      <<~MSG.strip
        No default keychain set in user domain.
          fastlane's sigh (called by `make ship`) decodes provisioning profiles
          via `security cms -D -i <profile>`, which REQUIRES a default keychain
          to be set. Without one, sigh fails with `Failure to decode <profile>.
          Exit: 1: security: cert import failed: A default keychain could not
          be found.` — `make ship` aborts before any signing happens.
          Most common cause: a prior `security delete-keychain` (e.g. cleaning
          up a leaked fastlane temp keychain via the FastlaneTmpKeychain advisory)
          removed the keychain that was set as default. Apps that walk the
          search list (Keychain Access, browser saved passwords, Wi-Fi auth)
          keep working — only tools that probe SecKeychainCopyDomainDefault
          notice. fastlane's sigh is one of those tools.
          To fix (one-time, ~1ms, no sudo):
            security default-keychain -d user -s ~/Library/Keychains/login.keychain-db
          login.keychain-db is the standard macOS default; restoring it is the
          textbook recovery. If you've never had a login keychain (rare on
          consumer Macs) or want a different default, point -s at any existing
          .keychain-db file in your search list. Re-run `make ship` after.
      MSG
    end
  end

  class FastlaneTmpKeychain < Step
    def name; "Leaked fastlane temp keychains"; end

    def check
      # Linux runners have no Keychain Services — skip cleanly.
      return :done unless RUBY_PLATFORM.include?("darwin")

      # Parse `security list-keychains -d user` output. Format is one
      # whitespace-indented quoted path per line:
      #     "/Users/prakash/Library/Keychains/login.keychain-db"
      #     "/Users/prakash/Library/Keychains/fastlane_tmp_keychain-db"
      # Filter for fastlane's temp-keychain naming pattern. fastlane
      # action setup_ci (fastlane-2.234.0, actions/setup_ci.rb:60-71)
      # uses `match_keychain` action with name "fastlane_tmp_keychain"
      # which lands as `~/Library/Keychains/fastlane_tmp_keychain-db`
      # in the user keychain search list.
      out = `security list-keychains -d user 2>/dev/null`.to_s
      leaked = out.scan(/"([^"]*fastlane_tmp_keychain[^"]*)"/).flatten
      return :done if leaked.empty?

      [:warn, leak_msg(leaked)]
    end

    def do_it
      # No-op. `security delete-keychain` is destructive — it removes the
      # keychain from the user search list AND deletes the on-disk file.
      # A leaked fastlane temp keychain typically holds no real state
      # (throwaway CI signing identities, wiped on legitimate cleanup),
      # but we surface the one-liner and let the user run it. The advisory
      # nature mirrors XcodeQuarantine's policy of not mutating shared
      # macOS state outside this fork's scope.
    end

    private

    def leak_msg(paths)
      list = paths.map { |p| "    - #{p}" }.join("\n")
      <<~MSG.strip
        #{paths.length} fastlane temp keychain(s) leaked into your user keychain search list:
        #{list}
          These are normally created by `setup_ci` during CI-mode fastlane runs and
          cleaned up on process exit. A leaked keychain on your local Mac means a
          prior fastlane invocation was killed (Ctrl-C, SIGKILL, OOM, crash) before
          its `at_exit` cleanup ran. Apps that scan all keychains for credentials
          (Google Drive, 1Password, iCloud Keychain, browser auth dialogs) then
          repeatedly prompt for the temp keychain's password.
          To clear permanently (one-time, ~1 sec, no sudo):
            security delete-keychain ~/Library/Keychains/fastlane_tmp_keychain-db
          IMPORTANT — restore default keychain afterward:
            security default-keychain -d user -s ~/Library/Keychains/login.keychain-db
          fastlane's setup_ci sets its temp keychain as the user default via
          `default_keychain: true`. `delete-keychain` removes it from the search
          list AND deletes the file but leaves the user with NO default — which
          breaks `security cms -D` (used by sigh during `make ship`) and causes
          `make ship` to abort at the sigh step. The DefaultKeychain doctor step
          will catch this independently, but the two-step cleanup avoids that
          loop entirely. Safe to delete — these keychains hold throwaway CI
          signing identities, never real secrets. The next legitimate fastlane CI
          run recreates one on demand and cleans it up on exit.
      MSG
    end
  end

  class ScanScreenshots < Step
    def name; "App Store screenshots"; end

    def screenshot_dir; REPO_ROOT.join("fastlane", "screenshots", "en-US"); end

    def check
      return [:warn, "No fastlane/screenshots/en-US/ — capture via `ci/take-screenshots.sh` before App Store review (not TestFlight)."] unless screenshot_dir.directory?
      pngs = Dir.glob(screenshot_dir.join("*.png"))
      return [:warn, "No screenshots in #{screenshot_dir.relative_path_from(REPO_ROOT)} — capture via `ci/take-screenshots.sh` before App Store review."] if pngs.empty?
      :done
    end

    def do_it
      # No-op; check returns :warn or :done.
    end
  end

  class RemoteMatches < Step
    def name; "GH_APP_REPO matches origin git remote"; end
    def category; "preflight"; end

    def check
      out, ok = Sh.run("git", "remote", "get-url", "origin")
      return [:warn, "no origin remote yet (initial push hasn't happened — that's fine)"] unless ok
      url = out.strip
      expected = "https://github.com/#{config.repo_slug}.git"
      expected_ssh = "git@github.com:#{config.repo_slug}.git"
      return :done if url == expected || url == expected_ssh
      [:blocked, <<~MSG]
        .bootstrap.env GH_APP_REPO=#{config['GH_APP_REPO']} (#{config.repo_slug})
        but git remote points at: #{url}

        Fix one or the other:
          - update GH_ORG/GH_APP_REPO in .bootstrap.env, or
          - run: git remote set-url origin #{expected}
      MSG
    end

    def do_it
      UI.fail!("git remote and .bootstrap.env GH_APP_REPO disagree; fix manually.")
    end
  end

  class LocalKeychainCerts < Step
    MODES = %w[local].freeze
    def name; "Local keychain has signing identities"; end

    # Required by all forks regardless of platforms — Apple Distribution is the
    # signing identity for both iOS .ipa and macOS .pkg/.app archives, and
    # Apple Development covers device + Mac development signing.
    REQUIRED_IDENTITIES_ALWAYS = [
      "Apple Distribution",
      "Apple Development"
    ].freeze

    # Required only when shipping macOS — used by productbuild to sign the
    # .pkg installer wrapper.
    REQUIRED_IDENTITIES_MACOS = [
      "3rd Party Mac Developer Installer"
    ].freeze

    # Maps the human identity name (as it appears in `security find-identity`)
    # to fastlane cert's --type argument. Auto-mint flow uses these to invoke
    # the right fastlane cert call per missing identity.
    IDENTITY_TO_CERT_TYPE = {
      "Apple Distribution"                => "apple_distribution",
      "Apple Development"                 => "apple_development",
      "3rd Party Mac Developer Installer" => "mac_installer_distribution"
    }.freeze

    def required_identities
      ids = REQUIRED_IDENTITIES_ALWAYS.dup
      ids.concat(REQUIRED_IDENTITIES_MACOS) if config.macos?
      ids
    end

    # Returns the matching `security find-identity -v` lines from the user's
    # login keychain. Each line is e.g.
    #   '  1) BD06...A78 "Apple Distribution: Person Name (A1B2C3D4E5)"'
    #
    # Note we deliberately do NOT pass `-p codesigning` here, because that
    # filter excludes installer-signing identities (3rd Party Mac Developer
    # Installer is for `productbuild`, not for code signing). Without -p,
    # find-identity returns valid identities for ANY policy — code-signing,
    # installer-signing, mail-signing, etc. -v alone keeps the validity
    # check (filters out expired or private-key-missing identities). We
    # match by name in the caller, so policy mixing here is fine.
    def keychain_lines
      out, _ok = Sh.run("security", "find-identity", "-v",
                        File.expand_path("~/Library/Keychains/login.keychain-db"))
      out.lines
    end

    # Pulls the LAST `(XXXXXXXXXX)` 10-char alphanumeric token from an
    # identity line. For
    #   '  1) BD06...A78 "Apple Distribution: Person Name (A1B2C3D4E5)"'
    # returns "A1B2C3D4E5". We use scan-and-pick-last because the line ends
    # in `"` (not `)`), so a `\)\s*$`-anchored pattern wouldn't fire.
    #
    # Caveat: Apple's "Created via API" cert names use the same `(XXXXXXXXXX)`
    # shape but the token is the API key id, NOT the team id. We can't tell
    # the two apart from `find-identity` output alone — that's why
    # team_mismatched_identities is permissive on lines containing
    # "Created via API".
    def extract_team_id(line)
      line.scan(/\(([A-Z0-9]{10})\)/).last&.first
    end

    # Identities whose name doesn't appear at all in the keychain. These
    # require fresh minting (or manual install).
    def missing_identities
      lines = keychain_lines
      required_identities.reject do |name|
        lines.any? { |line| line.include?(name) }
      end
    end

    # Identities present BUT whose certs are all clearly for non-matching
    # teams. Conservative logic — only flagged when:
    #   1. At least one cert with the right name exists (else: missing, not mismatched)
    #   2. None of those certs has a parenthesized team id matching FASTLANE_TEAM_ID
    #   3. None is "Created via API" (ambiguous — we can't verify the team)
    # Catches the consultant / multi-team scenario without false-positiving on
    # API-minted certs that may be for the right team.
    def team_mismatched_identities
      expected = config["FASTLANE_TEAM_ID"]
      return [] if expected.nil? || expected.empty?

      lines = keychain_lines
      required_identities.select do |name|
        type_lines = lines.select { |line| line.include?(name) }
        next false if type_lines.empty?               # missing, not mismatched
        next false if type_lines.any? { |line| extract_team_id(line) == expected }
        next false if type_lines.any? { |line| line.include?("Created via API") }
        true
      end
    end

    def check
      return :done if config.ci_mode?
      missing = missing_identities
      mismatched = team_mismatched_identities
      return :done if missing.empty? && mismatched.empty?
      # :pending (with rich message) — bootstrap-fork's do_it auto-mints
      # the missing/mismatched identities via fastlane cert. Doctor renders
      # the message so the user knows what's going to happen and can opt
      # for one of the manual paths if they prefer.
      [:pending, build_message(missing, mismatched)]
    end

    # do_it (called by `make bootstrap-fork` and `make mint-local-certs`)
    # auto-mints any missing OR mismatched-team identities by shelling out to
    # the fastlane mint_local_certs lane. Idempotent — fastlane cert itself
    # detects existing valid certs and skips minting duplicates, so re-running
    # is safe even if the keychain state changed since `make doctor` ran.
    def do_it
      needed = (missing_identities + team_mismatched_identities).uniq
      return if needed.empty?

      cert_types = needed.map { |id| IDENTITY_TO_CERT_TYPE.fetch(id) }
      UI.section "Minting #{needed.length} local-mode signing identit#{needed.length == 1 ? 'y' : 'ies'}"
      needed.each_with_index do |id, i|
        puts "  #{i + 1}. #{id}  (fastlane cert --type #{cert_types[i]})"
      end

      env = Bootstrap.asc_env(config)
      Sh.run!("bundle", "exec", "fastlane", "mint_local_certs",
              "types:#{cert_types.join(',')}",
              env: env)
    end

    private

    def build_message(missing, mismatched)
      parts = []

      if missing.any?
        parts << "Login keychain is missing #{missing.length} signing identit#{missing.length == 1 ? 'y' : 'ies'}:"
        missing.each do |id|
          parts << "  - #{id}  (fastlane cert --type #{IDENTITY_TO_CERT_TYPE.fetch(id)})"
        end
      end

      if mismatched.any?
        parts << "" if missing.any?
        expected = config["FASTLANE_TEAM_ID"]
        parts << "Found certs for #{mismatched.length} identit#{mismatched.length == 1 ? 'y' : 'ies'} but none for team #{expected}:"
        mismatched.each { |id| parts << "  - #{id}" }
        parts << "(your keychain has certs from other teams. xcodebuild will fail at"
        parts << " ship time without a team-#{expected} cert.)"
      end

      parts << ""
      parts << "Easiest fix — auto-mints + installs each identity into your login keychain:"
      parts << "  make mint-local-certs"
      parts << ""
      parts << "(or just run `make bootstrap-fork`; it auto-mints these too.)"
      parts << ""
      parts << "Manual alternatives:"
      parts << "  Xcode → Settings → Accounts → (your team) → Manage Certificates → +"
      parts << "  Apple Developer Portal → Certificates → + (then double-click the .cer)"

      # macOS-only escape hatch: if every problem is a Mac-only identity, the
      # user can drop macOS shipping by setting PLATFORMS=ios — saves them
      # from minting a cert they don't need.
      affected = (missing + mismatched).uniq
      mac_only = affected.all? { |id| REQUIRED_IDENTITIES_MACOS.include?(id) } && affected.any?
      if mac_only
        parts << ""
        parts << "Or, if you don't need to ship macOS yet:"
        parts << "  set PLATFORMS=ios in .bootstrap.env (skips Mac signing entirely)"
      end

      parts.join("\n") + "\n"
    end
  end

  # ─── Pipeline ───────────────────────────────────────────────────────────────

  class Runner
    # Single source of truth. Each Step subclass sets MODES = %w[ci]
    # / %w[local] / both (default). Runner filters at construction time.
    PIPELINE = [
      CheckAppleCreds,
      CheckGHCreds,
      RemoteMatches,
      RenameStub,
      BrewBootstrap,
      Icon1024,              # tree mutations land before InitialPush
      MakeIcons,
      InitialPush,
      BranchProtection,
      GHSecrets,             # ci-only
      RegisterAppId,
      VerifyAscApp,
      LocalKeychainCerts,    # local-only
      ScanMetadata,          # informational
      ScanScreenshots,
      AppPrivacyForm,        # informational; queries ASC for App Privacy publish state
      XcodeQuarantine,       # informational; advisory-only check for com.apple.quarantine xattr on Xcode.app
      FastlaneTmpKeychain,   # informational; advisory-only check for leaked setup_ci temp keychains
      DefaultKeychain        # informational; advisory-only check that user-domain default keychain is set
    ].freeze

    def initialize(config)
      @config = config
      mode = config.release_mode
      @steps = PIPELINE
        .map { |klass| klass.new(config) }
        .select { |step| step.applicable?(mode, config.platforms) }
    end

    def doctor
      @config.validate!
      UI.section "Configuration"
      puts "  app:     #{@config['APP_NAME']} (#{@config['BUNDLE_ID']})"
      puts "  mode:    RELEASE_MODE=#{UI.bold @config.release_mode}"
      puts "  apple:   team #{@config['FASTLANE_TEAM_ID']}, ASC key #{@config['ASC_API_KEY_ID']}"
      gh_line = "  gh:      app=#{@config.repo_slug}"
      puts gh_line

      UI.section "Pipeline status"
      results = []
      blockers = []  # collected for the action-required tail message
      @steps.each_with_index do |step, idx|
        result = step.check
        case result
        when :done
          puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.ok step.name}"
          results << :done
        when :pending
          puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.miss step.name}#{UI.dim ' — will run on bootstrap-fork'}"
          results << :pending
        when Array
          severity, msg = result
          if severity == :warn
            puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.warn step.name}"
            puts msg.lines.map { |l| "      #{UI.dim l.chomp}" }.join("\n")
            results << :warn
          elsif severity == :pending
            # Pending-with-message: doctor explains the fix; bootstrap-fork's
            # do_it auto-runs and resolves it. Rendered like :pending (red ✗
            # + dim "will auto-fix on bootstrap-fork") plus the rich message
            # so the user can ALSO fix it manually if they want
            # (e.g. `make mint-local-certs`, `PLATFORMS=ios` escape hatch, etc).
            puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.miss step.name}#{UI.dim ' — will auto-fix on bootstrap-fork'}"
            puts msg.lines.map { |l| "      #{UI.dim l.chomp}" }.join("\n")
            results << :pending
          else
            # Blocked: visually separate from :warn (advisory) by using the
            # red ✗ glyph + a "needs fix" suffix, and from :pending by
            # rendering the underlying error message at full intensity
            # (not dim) so it pulls the eye.
            puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.miss step.name}#{UI.bold ' — needs fix'}"
            puts msg.lines.map { |l| "      #{l}" }.join
            results << :blocked
            blockers << "#{idx + 1}. #{step.name}"
          end
        end
      end

      UI.section "Summary"
      done    = results.count(:done)
      pending = results.count(:pending)
      blocked = results.count(:blocked)
      warned  = results.count(:warn)
      cells = ["#{UI.ok "#{done} done"}"]
      cells << UI.miss("#{pending} pending") if pending > 0
      cells << UI.warn("#{warned} advisory") if warned > 0
      cells << UI.miss("#{blocked} blocked") if blocked > 0
      puts "  #{cells.join('    ')}"

      if blocked > 0
        puts
        puts UI.bold "Action required: fix the ✗ blocked items above, then re-run `make doctor`:"
        blockers.each { |b| puts UI.dim("  • #{b}") }
        if warned > 0
          puts
          puts UI.dim("(#{warned} advisory ⚠ items above are App-Store-review-only and don't block TestFlight.)")
        end
        exit 2
      elsif pending > 0
        puts
        puts UI.bold "Run `make bootstrap-fork` to close the ✗ pending items, or `make all` for the full forker journey (bootstrap-fork → ship → verify)."
        puts UI.dim("(#{warned} advisory ⚠ items above are App-Store-review-only and don't block TestFlight.)") if warned > 0
        exit 0
      else
        puts
        puts UI.bold "All bootstrap steps complete. Run `make ship` to trigger a release."
        puts UI.dim("(#{warned} advisory ⚠ items above are App-Store-review-only and don't block TestFlight.)") if warned > 0
        exit 0
      end
    end

    def bootstrap
      @config.validate!
      total = @steps.length
      @steps.each_with_index do |step, idx|
        UI.step_header(idx + 1, total, step.name)
        result = step.check
        case result
        when :done
          puts "  #{UI.ok 'already done'}"
        when :pending
          step.do_it
          puts "  #{UI.ok 'done'}"
        when Array
          severity, msg = result
          if severity == :warn
            puts "  #{UI.warn msg.lines.first.chomp}"
          elsif severity == :pending
            # Auto-fixable: bootstrap-fork runs do_it (which mints/restores
            # state programmatically). Distinct from :blocked which is
            # human-gated and aborts.
            step.do_it
            puts "  #{UI.ok 'done'}"
          else
            UI.fail!(msg)
          end
        end
      end
      puts
      puts UI.bold "✅ Bootstrap complete."
      puts
      puts "What just happened on #{@config.repo_slug}:"
      puts "  - #{@config['APP_NAME']} (#{@config['BUNDLE_ID']}) project files committed"
      puts "  - Pushed directly to main (no GitHub PR opened — bootstrap-fork pushes straight)"
      if @config.ci_mode?
        puts
        puts %(GitHub Actions starts a workflow named "PR" (file: .github/workflows/pr.yml))
        puts %(on every push, including this one. It is a CI sanity check, NOT a Pull Request,)
        puts %(and does not gate `make ship`. Both run independently.)
      end
      puts
      puts "Next: #{UI.bold 'make ship'} to trigger the release pipeline."
      puts "      #{UI.bold 'make verify'} 5-15 min after ship to confirm TestFlight ingestion."
    end
  end

  # ─── Module-level helpers used by multiple steps ────────────────────────────

  module_function

  def Bootstrap.ensure_asc_token!(config)
    return if Spaceship::ConnectAPI.token
    p8_path = config.expand_path("ASC_API_KEY_P8_PATH")
    Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
      key_id:    config["ASC_API_KEY_ID"],
      issuer_id: config["ASC_API_KEY_ISSUER_ID"],
      filepath:  p8_path.to_s
    )
  end

  # Create the Spaceship ASC token from ASC_API_KEY_* env vars — the CI path,
  # where no .bootstrap.env exists yet (release.yml exports the creds before
  # invoking bin scripts). Idempotent. Accepts ASC_API_KEY_P8_PATH (a PEM
  # file) or ASC_API_KEY_P8_BASE64 (base64 PEM, decoded to a 0600 tmpfile).
  # Mirrors bin/compute-release-tag.rb's env branch so both share one path.
  def setup_asc_token_from_env!
    require "spaceship"
    return if Spaceship::ConnectAPI.token

    %w[ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID].each do |k|
      raise "#{k} env var not set (and no .bootstrap.env present)." if ENV[k].to_s.empty?
    end

    p8_path = ENV["ASC_API_KEY_P8_PATH"]
    if p8_path.to_s.empty?
      b64 = ENV["ASC_API_KEY_P8_BASE64"]
      raise "neither ASC_API_KEY_P8_PATH nor ASC_API_KEY_P8_BASE64 set." if b64.to_s.empty?

      require "base64"
      require "tmpdir"
      p8_path = File.join(Dir.tmpdir, "asc_api_key_#{ENV.fetch('ASC_API_KEY_ID')}_verify.p8")
      File.write(p8_path, Base64.decode64(b64))
      File.chmod(0o600, p8_path)
    end

    Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
      key_id:    ENV.fetch("ASC_API_KEY_ID"),
      issuer_id: ENV.fetch("ASC_API_KEY_ISSUER_ID"),
      key:       File.read(p8_path),
    )
  end

  # Minimal account-wide ASC probe. Apple gates the entire ASC API behind an
  # in-effect agreement, so App.all trips the same rejection that would
  # otherwise surface deep in compute-release-tag / cert mint / upload — but
  # here we translate it to an actionable AscAgreementError. Caller must have
  # set the Spaceship token first (ensure_asc_token! or setup_asc_token_from_env!).
  # Returns nil on success; re-raises non-agreement errors unchanged.
  def verify_asc_agreements!
    require "spaceship"
    Spaceship::ConnectAPI::App.all(limit: 1)
    nil
  rescue StandardError => e
    raise AscAgreementError.new(e.message) if AscAgreementError.match?(e)

    raise
  end


  def asc_env(config)
    {
      "ASC_API_KEY_ID"          => config["ASC_API_KEY_ID"],
      "ASC_API_KEY_ISSUER_ID"   => config["ASC_API_KEY_ISSUER_ID"],
      "ASC_API_KEY_P8_BASE64"   => Base64.strict_encode64(config.expand_path("ASC_API_KEY_P8_PATH").read),
      "FASTLANE_TEAM_ID"        => config["FASTLANE_TEAM_ID"],
      # RELEASE_MODE is preserved as a `bin/ship.rb` knob (route lane locally
      # vs trigger CI workflow), but the release lane itself no longer
      # branches on it — both modes go through the same sigh-based code
      # path since v1.6 (#158). We still propagate it here so any future
      # lane logic that wants to know the invocation context can read it.
      "RELEASE_MODE"            => config.release_mode,
      "FASTLANE_HIDE_CHANGELOG" => "1",
      "FASTLANE_SKIP_UPDATE_CHECK" => "1"
    }
  end

end
