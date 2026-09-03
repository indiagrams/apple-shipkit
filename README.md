# apple-shipkit

> **Release-engineering scaffolding for shipping iOS + macOS apps.**
> Code signing, GitHub Actions CI for PRs, mint-fresh certificates per CI release, TestFlight upload, App Store submission — all prewired.
> Deliberately doesn't pick a UI framework, networking stack, or persistence layer.

[![CI](https://github.com/indiagrams/apple-shipkit/actions/workflows/pr.yml/badge.svg)](https://github.com/indiagrams/apple-shipkit/actions/workflows/pr.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![Discord](https://img.shields.io/badge/Discord-join%20chat-5865F2?logo=discord&logoColor=white)](https://discord.gg/sExv9eKdA)
[![Weekly canary (CI mode)](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-trigger.yml/badge.svg)](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-trigger.yml)
[![Weekly canary (local mode)](https://github.com/indiagrams/ios-macos-smoketest/actions/workflows/canary-local-mode.yml/badge.svg)](https://github.com/indiagrams/ios-macos-smoketest/actions/workflows/canary-local-mode.yml)

<p align="center">
  <img src="docs/screenshots/ios-home.png"   alt="HelloApp template running on iOS Simulator — hammer icon, 'HelloApp' title, and 'Rename me' instruction visible" width="260">
  &nbsp;&nbsp;
  <img src="docs/screenshots/macos-home.png" alt="HelloApp template running natively on macOS — same hammer icon, title, and rename instruction"                       width="500">
</p>

> **First time shipping an iOS or Mac app?** Start with **[docs/GETTING-STARTED.md](docs/GETTING-STARTED.md)** — every prerequisite, every Apple-side click, 30–60 minutes to your first TestFlight build.
>
> **Using AI coding agents (Claude Code, Cursor, Codex, etc.) to build the app?** Start them with **[AGENTS.md](AGENTS.md)** — fork-extensibility invariants, file-ownership map, antipatterns to avoid. Vendor-neutral [agents.md](https://agents.md/) format; one file, every major agent.

---

## The five-command journey

Once `.bootstrap.env` is filled in (see [Getting Started](docs/GETTING-STARTED.md)), shipping any app from this template is five commands. Each is idempotent. Each fails loud with an actionable error message. Each is designed so the first one to break tells you exactly what to fix and where:

| | Command | What it does |
|---|---|---|
| 1 | `make doctor` | Surfaces every known onboarding hazard with one-line actionable fixes — Apple credentials, GitHub credentials, Bundle ID registration, ASC App record, signing certs, metadata placeholders, screenshot coverage, App Privacy form publish state, Xcode quarantine state. Read-only; mutates nothing. |
| 2 | `make bootstrap` | One-time dev-env setup: `brew bundle`, `bundle install`, `xcodegen`/`tuist generate`, lefthook pre-push hook. Survives a fresh host without pre-installed brew Ruby (auto re-execs after `ruby@3.3` lands on disk so `_BUNDLE` resolves to the brew shim, not stock `/usr/bin/bundle` on Ruby 2.6). |
| 3 | `make all` | `doctor → bootstrap-fork → ship → verify`. Builds + signs + uploads to TestFlight, then polls App Store Connect until both binaries process. Env-first metadata propagation through both ship and submit paths — no placeholders in flight. |
| 4 | `make screenshots` | Captures App Store screenshots (iOS + macOS) into `fastlane/screenshots/en-US/`. Survives a quarantined Xcode (auto strip + ad-hoc re-sign on the UI-test runner bundle before launch) without you needing to know what quarantine even is. |
| 5 | `make submit` | Stages (default) or auto-submits the latest TestFlight build for App Store review. 9/9 precheck green; reads your real URLs + phone from `.bootstrap.env` or shell env, not the tracked `+10000000000` / `example.com` fail-loud placeholders. |

Returning forkers running their second-or-later ship typically use just `make ship` (subset of `make all`) plus `make submit` when they want to push the build past TestFlight.

**Adopting an existing live App Store app?** Run `make adopt` ONCE after filling `.bootstrap.env` and BEFORE `make submit` — pulls existing ASC metadata + screenshots into the local tree so the first submit ships YOUR real listing, not template placeholders. See [docs/ADOPTING-EXISTING-APP.md](docs/ADOPTING-EXISTING-APP.md).

---

## Why this exists

I'm a first-time iOS developer. Before writing a feature of my actual app, I spent days researching what Apple requires to publish: signing certificates, GitHub Actions signing that mints fresh certs per release, ASC API keys, metadata specs, branch protection, and a dozen Apple-side gotchas that only surface in TestFlight.

I automated or documented every requirement I encountered. That's what this template is — the boring prep work, done.

A public canary fork ([`indiagrams/ios-macos-smoketest`](https://github.com/indiagrams/ios-macos-smoketest)) real-ships to TestFlight on two cadences: CI mode every Sunday and local mode every Saturday, both on xcodegen and tuist generators, so Apple-side regressions surface upstream within a week. Catalog at [`docs/CONTINUOUS-VALIDATION.md`](docs/CONTINUOUS-VALIDATION.md).

---

## What's prewired

The five-command journey hides:

### Signing and certificates
- **Mint-fresh CI signing certs** per release run, revoked on workflow exit. No shared certs repo. No PAT. Net Apple-team cert delta per release run is 0.
- **Local-mode signing** reuses your login Keychain identities; `make clean-revoked-certs` audits weekly against Apple's valid-cert list and deletes locals Apple already revoked (avoids 3-cert-cap surprises).
- **Cert SHA-1 pinning** (`ci/lib/resolve-dist-cert-sha.sh`). `Apple Distribution: <name>` is ambiguous when one team has multiple distribution certs. Pin via `security find-identity` + the cert in the .app's embedded provisioning profile.
- **WWDR intermediate pre-installed** on CI runners before `sigh` provisions — closes a flake where Apple's intermediate isn't trusted yet on a fresh runner.

### Build and release pipeline
- **XcodeGen** (default) or **Tuist** — both generate the same buildable project from a manifest, both validated weekly by the canary. Switch with `bin/switch-to-tuist.sh` / `bin/switch-to-xcodegen.sh`.
- **iOS device build as primary CI signal**, not Simulator. Simulator green with device red happens often (xcframework slice missing, entitlements pathway, real signing). Catch on every push, not at release time.
- **Mac `.pkg` re-sign step** that re-adds the `com.apple.security.app-sandbox` entitlement Xcode's Mac App Store profile strips (ITMS-90296 fix).
- **Full 10-size macOS `.icns` generation** (`ci/gen-macos-icons.swift`); actool only emits 4 sizes from a single catalog by default.
- **Automatic CFBundleVersion bumping**: `max(builds at marketing) + 1` resolved from ASC, never collides.
- **PlistBuddy quirks worked around**: `Set :key bool true` is a silent no-op; the template uses `Set :key true` for existing keys and `Add :key bool true` for new ones, with explicit verification.

### App Store Connect integration
- **Bundle ID auto-registered** in the Apple Developer Portal (`make doctor` step 11).
- **ASC App record verification** with an actionable pointer for the one mandatory manual step — Apple's API forbids `POST /apps`, so the doctor surfaces it instead of failing opaque.
- **Env-first metadata pipeline**: URLs, copyright, App Review contact info, demo credentials, TestFlight beta description, primary locale, categories — all read from shell env / `.envrc` (cross-fork) or `.bootstrap.env` (per-fork) before falling back to tracked `.txt` files in `fastlane/metadata/`.
- **Fail-loud placeholders**: `+10000000000` phone and `example.com` URLs in the tracked metadata fail ASC's validators on purpose, so missing config breaks at submit time, not after App Review rejection.
- **`make submit` passes full env-first metadata** through both ship and submit paths. Closes a `deliver` gem fallback that previously re-loaded URLs from disk after a clean upload (silent-overwrite bug).
- **App Privacy form publish-state checked** in `make doctor` (resilient to Apple's 2026 ASC API rename). `ASC_APP_PRIVACY_ACK=true` suppresses the warning once you've filled the form in the ASC web UI.
- **`deliver` metadata-dropping worked around**: deliver silently drops fields when given just `metadata_path`. The template reads every file itself and passes explicit hashes (`do_upload_metadata` / `do_submit_for_review` in `Fastfile`).

### Quality gates
- **`make doctor`** — 18-step read-only pipeline; surfaces every prerequisite + every advisory before a byte is built. Each step explains its own failure with a one-line fix.
- **Lefthook pre-push hook** runs `ci/local-check.sh --fast` (unsigned iOS device build) — same signal CI runs on PR.
- **PR required checks**: 8 build jobs (3 XcodeGen + 3 Tuist + 2 verify), all green for merge. Single-platform forks see fewer.
- **Branch protection** auto-configured by `bin/setup-github.sh`: squash-only merge, required reviews, force-push blocked.
- **`bin/preflight.sh`** — one-shot prerequisite checker; clone temporarily, run, get a report on what's missing and how to install it.

### Fork extensibility (added 2026-05; v1.6.1)
- **`fastlane/Fastfile.local` extension point** — forks add custom lanes (Slack hook, Crashlytics dSYM upload, Firebase App Distribution, internal-ticket bumps) in a fork-owned file that survives upstream syncs. Template Fastfile imports it at EOF; `after_all` and `error` are reserved for forks, `before_all` is template-claimed. See [`fastlane/Fastfile.local.example`](fastlane/Fastfile.local.example) for seven copy-pasteable patterns.
- **Env-driven Fastfile constants** — `APP_NAME`, `APP_IDENTIFIER`, and downstream `IOS_SCHEME` / `MACOS_SCHEME` / `IPA_NAME_PATTERN` / `PKG_NAME_PATTERN` all resolve from `.bootstrap.env` at lane-resolution time, with `ENV` override for CI. Forks no longer sed-substitute Fastfile literals during rename; the file stays byte-equivalent across template and every fork.
- **Constant project structure, identity in one xcconfig** — `pr.yml`, `ci/local-check.sh`, the Snapfiles and the Fastfile spell `app/App.xcodeproj` and `App-iOS` / `App-macOS` outright; nothing resolves a project path from a variable. The app's bundle id, product name, display name and copyright live in `app/Identity.xcconfig`, and the Team ID in gitignored `app/Local.xcconfig`. The workflow file stays byte-equivalent across template and forks for safe `cp`-mirror.
- **Fork-friendly CI timeouts** — `pr.yml` job-level cap 60min (was 15); test steps inherit the job cap so a fork's 30-min test suite doesn't hit a template-tuned ceiling. Infrastructure-only steps (build, simulator pre-boot) keep tight bounds so stuck infrastructure fails fast without constraining user test duration.
- **Single Sat 07:00 UTC canary cron** in [`canary-trigger.yml`](.github/workflows/canary-trigger.yml) — orchestrates three sequential ships (CI xcodegen → CI tuist → local-mode). Forks inherit no cron (the trigger file is template-only); each fork wires its own schedule when ready.

### Existing-app adoption
- **`make adopt`** — pulls existing App Store metadata + screenshots from ASC into the local tree before first ship. Single command, idempotent, ~30-60 sec total. Closes the catastrophic "fork the template, run `make submit`, clobber my live App Store listing with template placeholders" failure mode. Bundle ID + Team ID + ASC API creds in `.bootstrap.env` is all that's needed; the lane verifies the ASC App record exists, downloads all locales of metadata via `fastlane deliver download_metadata`, downloads all screenshots via `fastlane deliver download_screenshots`, reports the live marketing version for the user to sync into `app/project.yml`. Skipped for greenfield forks (BUNDLE_ID=`com.example.helloapp` placeholder triggers a fail-loud guard). `make doctor`'s metadata-placeholder warning surfaces the `make adopt` hint when the fingerprint matches an existing-app fork.
- **Hard-stop guard against placeholder bundle IDs** — `bin/adopt.rb` refuses to run if `BUNDLE_ID=com.example.helloapp` or if there are uncommitted changes in `fastlane/metadata` / `fastlane/screenshots`. `FORCE=true make adopt` overrides the latter for deliberate re-syncs.

### Continuous validation (against real Apple infrastructure)
- **PR-time, on any change to `bin/lib/bootstrap.rb` / `bin/doctor.rb` / `fastlane/Fastfile` / `.bootstrap.env.example` / `Makefile`**: bootstrap doctor matrix (xcodegen | tuist × ci | local — 4 cells). Catches doctor/bootstrap pipeline regressions before merge. Plus weekly hermetic regression tests (parser, bundle-guard) Mondays 07:00 UTC against runner-image drift.
- **Saturdays 07:00 UTC**: full canary sweep — apple-shipkit's `canary-trigger.yml` orchestrates 3 sequential ships on the smoketest fork against real Apple infrastructure: CI-mode xcodegen (`release.yml`), CI-mode tuist (`release.yml`), then local-mode (`canary-local-mode.yml`, which internally runs both generators). ~35–40 min total. Covers the mint-fresh CI signing pipeline, the local sigh-based signing pipeline, and both project generators. Apple-side regressions surface upstream within a week.
- **Bugs in fastlane / sigh / Apple's signing infra surface there first**, before they bite forks — patches land in this template before they hit your repo.

---

## When to use this (vs alternatives)

apple-shipkit is **release-engineering scaffolding** — the path from `Use this template` to a signed TestFlight build. It deliberately doesn't pick a UI framework, networking stack, or persistence layer.

### vs. Apple's own tooling (Xcode Distribute, Xcode Cloud)

These are the most common "you don't need this template" comebacks, and they're correct for some use cases:

| You want… | Use | Why |
|---|---|---|
| Manual one-off ship from one Mac, no team, no CI | Xcode → Organizer → Distribute App | Built-in, zero setup, free. Trade-offs: interactive every ship, certs live only in your Keychain, no reproducibility (uses your Mac's current state), no audit trail, no CI on PRs. |
| Hosted CI inside Apple's ecosystem; comfortable with vendor lock-in | [Xcode Cloud](https://developer.apple.com/xcode-cloud/) | Apple's managed CI ($14.99/mo past 25-hour free tier). Workflows configured in Xcode UI, stored in `.xcodeproj`. Trade-offs: workflows aren't portable to other CIs, predefined `ci_*.sh` hooks limit shell flexibility, log debugging is black-box. |

apple-shipkit's value lives in the gap:

- **More than Xcode Distribute**: reproducible builds (Gemfile.lock + pinned Swift/Xcode), audit-tracked (git tags + workflow logs + CHANGELOG per ship), CI-driven (PRs build real apps; ship is `gh workflow run`, not a button), ephemeral CI signing (each release run mints its own short-lived certs into a controlled keychain on the runner and revokes them on exit, instead of trusting whatever's in any one developer's Keychain).
- **Different shape from Xcode Cloud**: portable GitHub Actions YAML you can take to GitLab / CircleCI / Buildkite, full bash + ruby + fastlane flexibility, no per-minute Apple billing, debug failures locally with `make ship` or `make release-dryrun`.

You probably **don't need** apple-shipkit if you're solo, ship one app, will always ship from one Mac, and never want to leave Xcode. You probably **do** if any of those is or will be untrue — especially if you've ever lost half a day to "why does signing work on my machine but not in CI."

### vs. other Swift project templates

Different tradeoff from other iOS starters:

| You want… | Use | Why |
|---|---|---|
| Pipeline (signing + CI + TestFlight + ASC submission) prewired | **apple-shipkit** | What this template focuses on. Fastlane (sigh) + GitHub Actions (mint-fresh CI signing) + canary continuous validation. |
| UI architecture + screens + sample data | [`iOS-Clean-Architecture-MVVM`](https://github.com/kudoleh/iOS-Clean-Architecture-MVVM) (Clean + MVVM, actively maintained), [`SwiftUI-MVVM-C`](https://github.com/huynguyencong/SwiftUI-MVVM-C) (SwiftUI + Combine + Coordinator), or Apple's built-in Xcode "App" template for bare scaffolding | These ship app scaffolding (ViewModels, Coordinators, sample data). You'd bring fastlane/CI yourself. Older Swift app templates (SwiftPlate, ios-project-template, ios-mvp-template) commonly cited in this space are inactive — SwiftPlate last touched 2019 + is a framework generator (not an app scaffold); ios-project-template still references Travis CI + HockeyApp; ios-mvp-template is UIKit + Storyboards. |
| Generate a fresh project from a manifest | `tuist scaffold` | Generates project files. No signing, no CI, no release wiring. |
| Subscription bundle (RevenueCat + paywall + IAP) | [RevenueCat Quickstart](https://www.revenuecat.com/docs/getting-started/quickstart) | apple-shipkit is intentionally framework-agnostic; bring your own monetization. |
| Bare `gh repo create` from a Swift project you already have | _no template needed_ | apple-shipkit is for people who don't have the project yet, or who do but want fastlane + CI signing prewired. |

Mix-and-match is fine. Many people start with apple-shipkit for the release pipeline, then drop in a UI template's screens or a RevenueCat paywall on top.

---

## How releases work under the hood

If you want to know what `make ship` actually does, here's the 30-second version:

```
make ship
  ↓
bin/ship.rb (idempotency: skip if HEAD already tagged)
  ↓
RELEASE_MODE=local?  → bundle exec fastlane release tag:vYYYY.WW.HHMM
RELEASE_MODE=ci?     → gh workflow run release.yml (triggers GitHub Actions)
                          ↓
                       fastlane release tag:vYYYY.WW.<run-number>
                          ↓
                       1. mint fresh iOS + Mac signing certs via sigh into a
                          controlled keychain (revoked on workflow exit)
                       2. xcodebuild archive + export → .ipa (iOS) + .pkg (Mac)
                       3. altool upload → App Store Connect
                       4. git tag + push
```

Each step is its own fastlane lane in `fastlane/Fastfile`. Read the file — it's heavily commented.

---

## Repo layout

```
.
├── .github/workflows/
│   ├── pr.yml                   # 6 build jobs on every PR (3 XcodeGen + 3 Tuist)
│   ├── release.yml              # signed release pipeline (workflow_dispatch + canary-driven)
│   ├── bootstrap-doctor-matrix.yml  # weekly doctor sweep across 4 cells
│   ├── canary-trigger.yml       # weekly CI-mode ship-validation (template-only; no-op on forks)
│   ├── canary-local-mode.yml    # weekly local-mode ship-validation (cron commented; forks opt in)
│   └── migrate.yml              # gate: the rename→config migration, end to end
├── Brewfile                     # xcodegen + tuist + fastlane + lefthook + swiftlint + swiftformat
├── Makefile                     # init | doctor | bootstrap | bootstrap-fork | ship | verify | submit | screenshots | …
├── lefthook.yml                 # pre-push: ci/local-check.sh --fast
├── .bootstrap.env.example       # template config; copy to .bootstrap.env
├── bin/
│   ├── doctor.rb                # `make doctor` driver
│   ├── bootstrap-fork.rb        # `make bootstrap-fork` driver
│   ├── ship.rb                  # `make ship` driver (handles ci|local modes)
│   ├── verify-testflight.rb     # `make verify` driver
│   ├── adopt.rb                 # `make adopt` driver (existing-app forks)
│   ├── lib/bootstrap.rb         # the orchestration framework (18-step pipeline)
│   ├── rename.sh                # personalize contact address + repo slug (identity is edited by hand)
│   ├── migrate-identity.rb      # one-time: a pre-Identity.xcconfig fork → the config-based scheme
│   ├── switch-to-tuist.sh       # one-way XcodeGen → Tuist switch
│   ├── setup-github.sh          # branch protection + squash-only + required checks
│   ├── preflight.sh             # check developer-tool prerequisites
│   └── ...                      # several smaller helpers
├── ci/
│   ├── local-check.sh           # unsigned iOS device build (CI parity)
│   ├── local-release-check.sh   # signed .ipa + .pkg pipeline
│   ├── take-screenshots.sh      # iOS + macOS App Store screenshots (quarantine-tolerant)
│   ├── gen-macos-icons.swift    # 1024 PNG → 10-size .icns + iconset
│   └── lib/                     # SHA-pinned shared library
├── fastlane/
│   ├── Fastfile                 # release | bootstrap_certs | upload_metadata | submit_for_review
│   ├── Fastfile.local.example   # fork extension scaffolding (cp to Fastfile.local + edit)
│   ├── Appfile                  # bundle ID + team
│   ├── Snapfile / MacSnapfile   # screenshot capture config
│   └── metadata/                # App Store listing copy + review info
├── app/
│   ├── project.yml              # XcodeGen manifest (default generator)
│   ├── Project.swift            # Tuist manifest (alternative generator)
│   ├── Shared/                  # SwiftUI app code (cross-platform)
│   ├── iOS/                     # iOS-only resources
│   ├── macOS/                   # macOS-only resources
│   ├── UITests/                 # iOS UITest target (drives screenshots)
│   └── MacOSUITests/            # macOS UITest target
├── Tuist.swift                  # Tuist 4 workspace config
├── Gemfile                      # fastlane via brew Ruby
└── docs/                        # additional docs (see "Going deeper")
```

---

## Why these patterns (the gotchas already solved for you)

Every choice in this template came from a real production failure. The headline ones:

- **iOS device build, not Simulator, as primary CI signal.** Simulator green with device red happens often (xcframework slice missing, entitlements pathway, real signing). Catch on every push.
- **Cert SHA-1 pinning** (`ci/lib/resolve-dist-cert-sha.sh`). `Apple Distribution: <name>` is ambiguous when one team has multiple distribution certs. Pin via `security find-identity` + the cert in the .app's embedded provisioning profile.
- **macOS app-sandbox re-sign hack.** Xcode's Mac App Store profile strips `com.apple.security.app-sandbox`. TestFlight rejects with ITMS-90296. Fix: expand the .pkg, force-add sandbox to the .app's signature, repack with `productbuild` + Mac Installer Distribution cert.
- **PlistBuddy `Set :key bool true` is a silent no-op.** PlistBuddy ignores type hints on `Set`. Use `Set :key true` for existing keys, `Add :key bool true` for new ones.
- **`fastlane deliver` silently drops metadata fields** when given just `metadata_path`. Workaround: read every metadata file ourselves and pass explicit hashes (see `do_upload_metadata` / `do_submit_for_review` in `Fastfile`).
- **`make submit` needed its own env-first metadata path.** `do_upload_metadata` got it first; `do_submit_for_review` fell through to deliver's `load_from_filesystem` which silently re-loaded URLs from disk and overwrote a clean upload. Both paths now route through the shared `build_review_info` + `build_asc_metadata_args` helpers.
- **macOS screenshots must go directly into `en-US/`** (not `en-US/Mac/`) — deliver's loader globs `<lang>/*.png` and only expands `iMessage` / `appleTV` subdirectories.
- **fastlane snapshot is iOS-only.** macOS uses `xcodebuild test` + `XCTAttachment` + `extract-mac-screenshots.sh` to pull PNGs from the xcresult.
- **macOS UI-test runners can't launch under Gatekeeper quarantine.** Xcode installed via xcodes-cli / .xip carries `com.apple.quarantine`; the bit transitively lands on freshly-built `<APP>MacOSUITests-Runner.app`. `ci/take-screenshots.sh` splits `xcodebuild test` into `build-for-testing` + xattr-strip + ad-hoc-codesign + `test-without-building` so the runner launches cleanly. Transparent to users.
- **macOS icons need a postCompileScript overwrite.** actool emits a 4-size .icns regardless of catalog input; `gen-macos-icons.swift` produces the full 10-size .icns the build then overwrites with.
- **Fresh-host bootstrap survives `bundle install` before brew Ruby exists.** `make bootstrap` re-execs `$(MAKE)` for the bundle step so `_BUNDLE` resolves through the freshly-installed `/opt/homebrew/opt/ruby@3.3/bin` PATH — otherwise the install routes through stock `/usr/bin/bundle = Bundler 1.17.2 on Ruby 2.6.10` which rejects modern transitive deps.

Full catalog of CI-specific gotchas: [docs/CONTINUOUS-VALIDATION.md](docs/CONTINUOUS-VALIDATION.md).

---

## Continuous validation

[![Weekly canary (CI mode)](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-trigger.yml/badge.svg)](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-trigger.yml)
[![Weekly canary (local mode)](https://github.com/indiagrams/ios-macos-smoketest/actions/workflows/canary-local-mode.yml/badge.svg)](https://github.com/indiagrams/ios-macos-smoketest/actions/workflows/canary-local-mode.yml)

The two badges above reflect the most recent canary runs:

- **CI-mode canary** ([`canary-trigger.yml`](https://github.com/indiagrams/apple-shipkit/actions/workflows/canary-trigger.yml)) — exercises the CI-mode mint-fresh shipping path used by forks with `RELEASE_MODE=ci` (release.yml mints fresh certs per run, ships, then revokes them). Both `dispatch (xcodegen)` and `dispatch (tuist)` cells real-ship to TestFlight on the [smoketest fork](https://github.com/indiagrams/ios-macos-smoketest).
- **Local-mode canary** ([`canary-local-mode.yml` on the smoketest fork](https://github.com/indiagrams/ios-macos-smoketest/actions/workflows/canary-local-mode.yml)) — exercises the local-mode sigh-based shipping path used by forks with `RELEASE_MODE=local` (the default). Mints throwaway certs in the same Apple team, ships to TestFlight, revokes the certs on `always()` so net team-cert delta per run is 0. The workflow file lives on apple-shipkit as a template (`schedule:` block commented out); only the smoketest has it uncommented, so the badge tracks runs there.

Either badge red → at least one cell failed. Click the badge to see which cell + why. Per-cell history (xcodegen vs tuist) lives in each workflow's run-by-run breakdown.

If you fork this template and your build breaks unexpectedly, [check the smoketest's Actions tab](https://github.com/indiagrams/ios-macos-smoketest/actions) — it's probably broken there too (Monday morning for CI-mode regressions, Saturday morning for local-mode), and a fix is in flight.

---

## Going deeper

- **[AGENTS.md](AGENTS.md)** — context file for AI coding agents (Claude Code, Cursor, Codex, Aider, Gemini CLI, Devin, etc.). Critical invariants, file-ownership map, antipatterns, doc index. Read by agents before they touch the tree. [`agents.md`](https://agents.md/) format, vendor-neutral.
- **[docs/GETTING-STARTED.md](docs/GETTING-STARTED.md)** — first-time shipper walkthrough. Apple Developer enrollment, ASC API key, the full `.bootstrap.env` configuration, your first `make all`. **Start here if you've never shipped before.**
- **[docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)** — every field of `.bootstrap.env` explained; CI-mode setup; manual fallback if you want to drive the bootstrap by hand.
- **[docs/APPLE-PREREQS.md](docs/APPLE-PREREQS.md)** — Apple-side setup details, especially the ASC App record.
- **[docs/CONTINUOUS-VALIDATION.md](docs/CONTINUOUS-VALIDATION.md)** — the catalog of shipping-pipeline gotchas (G1–G14+, covering both CI and local modes). Living document; updated whenever something new is caught by either canary.
- **[docs/MAINTAINING-A-FORK.md](docs/MAINTAINING-A-FORK.md)** — what to do after the first ship: bumping versions, replacing icons, submitting to App Store review.
- **[docs/ADOPTING-EXISTING-APP.md](docs/ADOPTING-EXISTING-APP.md)** — the existing-app migration path. If your fork represents an app already live on the App Store (not greenfield), this is how to safely adopt it onto apple-shipkit's release pipeline without clobbering your live listing.
- **[docs/MIGRATING-TO-TUIST.md](docs/MIGRATING-TO-TUIST.md)** — switching from XcodeGen to Tuist after fork.
- **[docs/RELEASE-WITH-APPLE-NATIVE-TOOLS.md](docs/RELEASE-WITH-APPLE-NATIVE-TOOLS.md)** — same archive/export flow without fastlane (uses `xcrun altool` + `notarytool` + ASC API directly).
- **[docs/PRINCIPLES.md](docs/PRINCIPLES.md)** — design decisions behind the template's structure.
- **[docs/ROLLBACK.md](docs/ROLLBACK.md)** — undoing a TestFlight build, a git tag, or a partial bootstrap-fork.
- **[docs/NO-CI.md](docs/NO-CI.md)** — running the template in local-only mode (no GitHub Actions, no GH Secrets).

---

## Community

Got stuck on Apple Developer enrollment? Got a cryptic rejection code? Want to know if anyone else hit the same gotcha? **Come hang out in Discord.**

[![Discord](https://img.shields.io/badge/Discord-join%20chat-5865F2?logo=discord&logoColor=white)](https://discord.gg/sExv9eKdA)

- **Discord** — quick questions, "is this a known issue", showing off what you shipped: [discord.gg/sExv9eKdA](https://discord.gg/sExv9eKdA)
- **GitHub Issues** — actionable bugs in the template (failed `make doctor`, missing prereq check, broken script): [github.com/indiagrams/apple-shipkit/issues](https://github.com/indiagrams/apple-shipkit/issues)
- **GitHub Discussions** — design decisions, "should the template do X", longer threads: [github.com/indiagrams/apple-shipkit/discussions](https://github.com/indiagrams/apple-shipkit/discussions)

First-time shippers especially welcome. Most of the people in this template's lineage learned by getting stuck on the same things you're about to get stuck on.

---

## License

MIT — see [LICENSE](LICENSE).

See [CHANGELOG.md](CHANGELOG.md) for version history and the [Versioning](CHANGELOG.md#versioning) policy.
