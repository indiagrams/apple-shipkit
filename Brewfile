# iOS + macOS template — dev tools. Install with `brew bundle`.
# Or run `make bootstrap` (also runs lefthook + xcodegen + bundle install).

# Build / project generation
brew "xcodegen"        # app/project.yml → app/App.xcodeproj
cask "tuist"          # app/Project.swift → app/App.xcodeproj (Tuist alternative; see #38)
brew "swiftlint"       # Swift lint
brew "swiftformat"     # Swift auto-format (companion to swiftlint)
brew "xcbeautify"      # nicer xcodebuild logs
brew "xcresultparser"  # parse .xcresult bundles in CI

# Git workflow
brew "shellcheck"      # ci/check-shell.sh — bash -n + shellcheck over every tracked *.sh
brew "lefthook"        # pre-push hook → ci/local-check.sh --fast
brew "gh"              # PR / release CLI

# Release pipeline
brew "ruby@3.3"        # pinned Ruby for fastlane (see .ruby-version + .tool-versions);
                       # avoids the unversioned brew `ruby` symlink moving with each major release
brew "fastlane"        # signs iOS + macOS, uploads to TestFlight + App Store metadata

# Optional: only needed if you generate macOS app icons via ci/gen-macos-icons.swift
# (the CILanczosScaleTransform-based script ships in this template).
# brew "imagemagick"    # uncomment if you do screenshot diffing
