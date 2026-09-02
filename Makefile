# Developer entry points for the iOS + macOS template.
#
# Forking your own app from this template? The path is:
#
#   1. gh repo create my-app --template indiagrams/apple-shipkit --public --clone
#   2. cd my-app && make bootstrap   # one-time dev-env setup (brew + ruby gems + xcodegen + git hooks)
#   3. make init                     # scaffolds .bootstrap.env (auto-fills GH_ORG/GH_APP_REPO from origin)
#   4. $EDITOR .bootstrap.env        # fill in APP_NAME, BUNDLE_ID, Apple credentials, RELEASE_MODE
#   5. make all                      # doctor → bootstrap-fork → ship → verify (the full forker journey)
#
# Maintaining this template? `make check` runs the local CI check, lefthook
# wires it onto every push, and `make doctor` validates `.bootstrap.env` end
# to end without mutating any state.

# Pin Ruby to .ruby-version so every recipe in this Makefile uses the same
# Ruby that `bundle install` ran under during `make bootstrap`. Without
# this, brew's unversioned `/opt/homebrew/opt/ruby` symlink moves with each
# major Ruby release (May 2026: bumped 3.3 → 4.0), so a forker who ran
# `make bootstrap` under Ruby 3.3 then later ran `make screenshots` under
# Ruby 4.0 would hit `Could not find fastlane-2.230.0, ... in locally
# installed gems` because bundler under 4.0 looks at vendor/bundle/ruby/4.0.0/
# while gems are at vendor/bundle/ruby/3.3.0/. Reading .ruby-version makes
# the pin auto-track the project's declared Ruby; the wildcard guard means
# forks not using brew Ruby (system Ruby, asdf, mise, rtx, rbenv) see no
# behavior change.
#
# Why $(_BUNDLE) and not bare `bundle`: GNU make has a "single-line recipe
# optimization" that calls execvp() directly (bypassing /bin/sh) for simple
# recipe lines with no shell metachars. The `export PATH := ...` directive
# only affects PATH for shell-mediated invocations; direct execvp uses the
# make process's parent env PATH unchanged. On a forker's machine where the
# parent shell PATH has /usr/bin (system Ruby 2.6 + Bundler 1.17.2) before
# /opt/homebrew/opt/ruby@3.3/bin, bare `bundle install` resolves to
# /usr/bin/bundle = system Bundler 1.17.2, which writes a flat
# vendor/bundle/ layout (Bundler 1.x style) with extensions compiled for
# Ruby 2.6 ABI. Then every subsequent `bundle check` from Bundler 4.x +
# Ruby 3.3 reports "missing gems" because it's looking in
# vendor/bundle/ruby/3.3.0/ which doesn't exist. Absolute-path $(_BUNDLE)
# bypasses the PATH lookup entirely and routes the call through the
# brew-Ruby bundle shim's shebang (#!/path/to/ruby@3.3/bin/ruby), which
# guarantees Bundler 4.x + Ruby 3.3 do the install with the modern
# vendor/bundle/ruby/3.3.0/ layout. Forks not using brew Ruby fall back
# to bare `bundle` (the else branch) — their version manager's shim
# handles the resolution correctly.
_RUBY_VER := $(shell cat .ruby-version 2>/dev/null || echo 3.3)
_RUBY_MM := $(shell echo $(_RUBY_VER) | awk -F. '{ print $$1 "." $$2 }')
_RUBY_BIN := /opt/homebrew/opt/ruby@$(_RUBY_MM)/bin
ifneq ($(wildcard $(_RUBY_BIN)/ruby),)
  export PATH := $(_RUBY_BIN):$(PATH)
  _BUNDLE := $(_RUBY_BIN)/bundle
else
  _BUNDLE := bundle
endif
# Per-fork configuration lives in each clone's in-repo `.bootstrap.env` (gitignored,
# `.bootstrap.env.example` is the schema). Ruby drivers under bin/ read it directly
# via Bootstrap::Config.load!; fastlane lanes read it via `_fork_config` helper
# in fastlane/Fastfile.
#
# To share values across multiple forks on the same machine (cross-fork ASC API
# key, team ID, App Review contact info), use any of:
#   - direnv .envrc per fork directory
#   - shell profile exports (~/.zshrc, ~/.bashrc)
#   - 1Password CLI / pass / etc. piped into the shell
#   - per-invocation: APP_REVIEW_FIRST_NAME="Foo" make submit
# The template deliberately does NOT auto-source any file outside the fork —
# baking a specific filesystem layout into the template was confusing forkers
# and silently leaking per-fork keys (BUNDLE_ID etc.) across fork boundaries.

.PHONY: all go bootstrap check check-ios check-macos check-sim build generate icons screenshots release-dryrun setup-github phase-checklist milestone-checklist help init doctor bootstrap-fork ship verify submit mint-local-certs clean-revoked-certs revoke-orphan-certs format format-check _check-bundle

help:
	@echo "Targets:"
	@echo "  bootstrap        One-time dev-env setup after clone (brew bundle, lefthook install, xcodegen, bundle install). Distinct from bootstrap-fork."
	@echo "  check            Same as: ci/local-check.sh --fast (iOS device build)"
	@echo "  check-ios        iOS device build (primary signal)"
	@echo "  check-sim        iOS Simulator build (backup signal)"
	@echo "  check-macos      macOS build"
	@echo "  generate         Regenerate app/App.xcodeproj from app/project.yml"
	@echo "  icons            Regenerate macOS AppIcon.iconset + AppIcon.icns from 1024 source"
	@echo "  screenshots      Capture App Store screenshots (iOS + macOS) to fastlane/screenshots/"
	@echo "  release-dryrun   fastlane release tag:v0.0.0 skip_upload:true skip_tag:true"
	@echo "  setup-github     Apply branch protection settings to current repo"
	@echo "  init             Scaffold .bootstrap.env from .bootstrap.env.example, auto-fill GH_ORG/GH_APP_REPO from origin remote"
	@echo "  all              One-shot: doctor → bootstrap-fork → ship → verify (the full forker journey)"
	@echo "  doctor           Read .bootstrap.env, validate Apple+GH credentials, print pipeline status"
	@echo "  bootstrap-fork   Idempotent fork-bootstrap: certs, ASC bundle id, GH branch protection, etc. Reads .bootstrap.env."
	@echo "  ship             Trigger release.yml workflow_dispatch + tail until the run completes"
	@echo "  verify           Confirm the latest tagged build appeared in App Store Connect"
	@echo "  submit           Stage (default) or auto-submit the latest TestFlight build for App Store review across PLATFORMS. Toggle via SUBMIT_FOR_REVIEW in .bootstrap.env."
	@echo "  mint-local-certs Auto-mint missing local-mode signing identities into the login keychain via fastlane cert. Idempotent."
	@echo "  clean-revoked-certs  Audit login.keychain vs Apple's valid-cert list, delete revoked locals (usage: make clean-revoked-certs [DRY_RUN=1] [YES=1])"
	@echo "  revoke-orphan-certs  Audit Apple's signing-cert list (distribution + development) vs login.keychain, revoke Apple-side orphans whose private keys live nowhere (usage: make revoke-orphan-certs [DRY_RUN=1] [YES=1])"
	@echo "  phase-checklist  Print the GSD canonical per-phase checklist (usage: make phase-checklist N=3.1)"
	@echo "  milestone-checklist  Print the GSD milestone wrap-up checklist (usage: make milestone-checklist M=1)"

# `brew bundle` may have just installed ruby@3.3 for the first time on a fresh
# machine. The $(_BUNDLE) variable was resolved at Makefile-PARSE time (via
# $(wildcard ...) above), which pre-dates the install — so on a host where the
# parent shell PATH already had system Ruby 2.6 but no brew Ruby yet,
# $(_BUNDLE) froze as plain `bundle`. Running that here resolves through PATH
# to /usr/bin/bundle = system Bundler 1.17.2 on Ruby 2.6.10, which refuses to
# install modern gems with "public_suffix-7.0.5 requires ruby version >= 3.2".
# Surfaced 2026-05-11 on a fresh macOS host that hadn't seen ruby@3.3 before.
#
# Re-execing $(MAKE) for the bundle install re-parses the Makefile from
# scratch with /opt/homebrew/opt/ruby@3.3/bin/ruby now visible to
# $(wildcard ...), so _BUNDLE picks up the absolute brew-Ruby path and the
# install resolves to Bundler 4.x + Ruby 3.3. Harmless ~50ms no-op on
# machines where ruby@3.3 was already installed at the outer make's parse
# time. The internal `_bootstrap-bundle` target is the re-exec landing zone.
bootstrap:
	brew bundle
	lefthook install
	cd app && xcodegen generate
	@$(MAKE) _bootstrap-bundle

_bootstrap-bundle:
	$(_BUNDLE) install

format:
	swiftformat app/

format-check:
	swiftformat --lint app/

check:
	ci/local-check.sh --fast

check-ios:
	ci/local-check.sh --fast

check-sim:
	ci/local-check.sh --owner-app-sim

check-macos:
	ci/local-check.sh --owner-app

generate:
	cd app && xcodegen generate

icons:
	swift ci/gen-macos-icons.swift \
	  app/macOS/Resources/AppIcon-source-1024.png \
	  app/macOS/Assets.xcassets/AppIcon.appiconset \
	  app/macOS/Resources/AppIcon.icns

screenshots: _check-bundle
	@ci/take-screenshots.sh

release-dryrun: _check-bundle
	@$(_BUNDLE) exec fastlane release tag:v0.0.0 skip_upload:true skip_tag:true

setup-github:
	bin/setup-github.sh

init:
	@bin/init-bootstrap-env.sh

doctor: _check-bundle
	@$(_BUNDLE) exec ruby bin/doctor.rb

bootstrap-fork: _check-bundle
	@$(_BUNDLE) exec ruby bin/bootstrap-fork.rb

ship: _check-bundle
	@$(_BUNDLE) exec ruby bin/ship.rb

verify: _check-bundle
	@$(_BUNDLE) exec ruby bin/verify-testflight.rb

submit: _check-bundle
	@$(_BUNDLE) exec ruby bin/submit.rb

adopt: _check-bundle ## Pull metadata + screenshots from a live ASC app (existing-app forks)
	@$(_BUNDLE) exec ruby bin/adopt.rb

mint-local-certs: _check-bundle
	@$(_BUNDLE) exec ruby bin/mint-local-certs.rb

clean-revoked-certs: _check-bundle
	@$(_BUNDLE) exec ruby bin/clean-revoked-certs.rb $(if $(YES),--yes,) $(if $(DRY_RUN),--dry-run,)

revoke-orphan-certs: _check-bundle
	@$(_BUNDLE) exec ruby bin/revoke-orphan-certs.rb $(if $(YES),--yes,) $(if $(DRY_RUN),--dry-run,)

# Guard for bundle-using targets above. Fails fast with an actionable hint
# when ruby gems aren't installed yet (typical on a fresh fork before
# `make bootstrap` has run). Without this guard, `make doctor` would crash
# with a Bundler::GemNotFound stack trace before the user has any chance to
# learn what went wrong.
_check-bundle:
	@$(_BUNDLE) check >/dev/null 2>&1 || { \
	  printf "\nRuby gems aren't installed yet. Run one of:\n\n"; \
	  printf "    bundle install            # install just the ruby gems\n"; \
	  printf "    make bootstrap            # full dev-env setup (brew + lefthook + xcodegen + bundle)\n\n"; \
	  exit 1; \
	}

all: doctor bootstrap-fork ship verify
go: all

phase-checklist:
	@if [ -z "$(N)" ]; then echo "usage: make phase-checklist N=<phase>  (e.g. N=3.1)"; exit 2; fi
	@bin/phase-runbook.sh $(N)

milestone-checklist:
	@if [ -z "$(M)" ]; then echo "usage: make milestone-checklist M=<milestone>  (e.g. M=1)"; exit 2; fi
	@bin/phase-runbook.sh --milestone $(M)
