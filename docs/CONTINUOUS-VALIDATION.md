# Continuous Validation via a Downstream Smoketest

The signing pipeline in this template (`fastlane release` lane,
`ci/local-release-check.sh`, `.github/workflows/release.yml`,
`.github/workflows/canary-local-mode.yml`) is exercised **weekly** by a
public reference fork:

> [`indiagrams/ios-macos-smoketest`](https://github.com/indiagrams/ios-macos-smoketest)

The canary sweep runs once weekly on a single cron, with three sequential cells:

- **Saturdays 07:00 UTC** — apple-shipkit's `canary-trigger.yml` orchestrates a 3-cell sequential matrix against the smoketest:
  1. dispatch `release.yml` with `generator=xcodegen` → exercises **CI-mode** shipping with the mint-fresh-cert pattern (cert minted into a controlled keychain on the runner, revoked in an `if: always()` post-step).
  2. dispatch `release.yml` with `generator=tuist` → same as above but against the Tuist project manifest.
  3. dispatch `canary-local-mode.yml` → exercises **local-mode** shipping (sigh-based App Store profiles minted via API key, signing certs minted fresh into a controlled keychain, β cert SHA-1 pinning via `DeveloperCertificates[0]` from the .mobileprovision). Internally runs both generators sequentially.

  Net runtime ~35–40 min; net Apple-team cert delta = 0 per run (every mint paired with a revoke).
- (was: separate Saturday + Sunday crons through #221; consolidated to a single Saturday cron in #222 for simpler operational rhythm).

Either canary going red means the pipeline has broken somewhere between
fastlane, match (CI-mode only), Apple's signing infrastructure, the ASC API,
and the macos-15 image — usually before any active fork hits the same
breakage in their own release window.

## Why a separate fork instead of CI on the template itself

CI on the template repo only exercises **build** — not signing, not upload,
not TestFlight ingestion. That's deliberate: the template ships without an
ASC API key, without a certs repo, without TestFlight access. A real release
pipeline needs all three. The smoketest provides them in a public,
inspectable form so:

- Forkers can read its `release.yml` actions tab to see real green runs (and
  the gotchas in failed runs).
- Patterns + fixes are discovered against a real Apple ecosystem, not a
  mocked one.
- The template's two release workflows (`release.yml`, `canary-local-mode.yml`)
  are provably executable — the same file shape the smoketest runs against.

## What's been validated end-to-end

The smoketest's phase 4-7 work (April-May 2026) discovered and fixed sixteen
distinct shipping-pipeline failure modes between "looks like it should work"
and "actually pushes a build to TestFlight" (G14 covers the local-mode path
specifically; the rest are CI-mode):

| # | Failure mode | Fix landed in |
|---|---|---|
| G1 | Mac Installer Distribution cert not present (separate cert type from Apple Distribution; fastlane match's `cert` action mis-routes to DISTRIBUTION limit bucket) | `bin/mint-installer-cert.rb` + `bin/import-installer-to-match.rb` |
| G2 | `setup-ruby@v1` requires explicit `ruby-version` when no `.ruby-version` file is in tree | `release.yml` pins `ruby-version: '3.3'` |
| G3 | xcodebuild "No Accounts: Add a new account in Accounts settings" — `automatic` signing path tries to log into Apple ID | `ci/local-release-check.sh` passes `-authenticationKeyPath` + `-authenticationKeyID` + `-authenticationKeyIssuerID` to xcodebuild for API-key auth |
| G4 | fastlane match `Could not install WWDR certificate` after a 5-minute hang on macos-15 (known issue: [fastlane/fastlane#20960](https://github.com/fastlane/fastlane/issues/20960)) | `release.yml` pre-installs `AppleWWDRCAG6.cer` into the system keychain via curl + `security add-trusted-cert` |
| G5 | xcodebuild asset compilation fails with "No simulator runtime version available to use with iphonesimulator SDK version 22A3362" — `Xcode_16.app` = Xcode 16.0 with iOS 18.0 SDK but no matching iOS Simulator runtime on the runner | `release.yml` uses runner default Xcode (16.4) instead of pinning Xcode_16.app |
| G6 | exportArchive `Cloud signing permission error` + `No profiles for com.example.helloapp were found` — `signingStyle=automatic` ExportOptions plist triggers Apple's cloud-signing endpoint which can't auth with API key only | `ci/local-release-check.sh` patches ExportOptions plist to `signingStyle=manual` + `provisioningProfiles` dict using match's emitted profile names; `release` lane in Fastfile threads `RELEASE_IOS_PROFILE_NAME` / `RELEASE_MACOS_PROFILE_NAME` env vars to the script |
| G7 | codesign + productbuild fail with `The timestamp service is not available.` (transient `timestamp.apple.com` blip) | `ci/local-release-check.sh` adds `with_timestamp_retry` helper — wraps codesign / productbuild calls, retries up to 5 times with linear backoff (5/10/15/20s) on the specific timestamp-service-unavailable error |
| G8 | altool upload rejects with `Validation failed (409) SDK version issue. This app was built with the iOS 18.5 SDK. All iOS and iPadOS apps must be built with the iOS 26 SDK or later, included in Xcode 26 or later`. Apple began enforcing iOS 26 SDK minimum for ASC uploads in 2026; macos-15 runner default is Xcode 16.4 (iOS 18.5 SDK) — too old | `release.yml` picks the highest-numbered `/Applications/Xcode_26*.app` on the runner and `xcode-select`s it; fail-loud listing of available Xcodes if no 26+ family is installed |
| G9 | macOS exportArchive errors `No signing certificate "Mac Installer Distribution" found`. The `.app` inside an MAS `.pkg` is signed with Apple Distribution; the `.pkg` wrapper itself needs a separate cert (Apple's "3rd Party Mac Developer Installer"). `fastlane match`'s `cert` action mis-routes `mac_installer_distribution` requests to the DISTRIBUTION limit bucket and reports phantom limits | Mint via Spaceship API directly (`bin/mint-installer-cert.rb`); push to certs repo via `Match::Importer.import_cert` (`bin/import-installer-to-match.rb`); add a 3rd `match mac_installer_distribution --readonly` call in the release lane; `plutil`-patch `installerSigningCertificate = '3rd Party Mac Developer Installer'` into the macOS ExportOptions plist |
| G10 | iOS UI tests fail to compile with `Call to main actor-isolated global function 'setupSnapshot(...)' in a synchronous nonisolated context`. Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`) + SnapshotHelper's `@MainActor` declarations + non-isolated test setUp/test methods. Latent in this template too — `pr.yml` runs `xcodebuild build`, not `test`, so the bug never surfaced through the main pipeline | Annotate the test class `@MainActor` (same pattern already used in `app/MacOSUITests/AppStoreScreenshotTests.swift`) |
| G11 | `app_store_connect_api_key` action raises `OpenSSL::PKey::ECError: invalid curve name` from `Spaceship::ConnectAPI::Token.create` when invoked through fastlane's lane manager on macos-15 + Ruby 3.3.11 + OpenSSL 3.6.x — even though the same `Token.create` call with identical args succeeds when invoked directly via `bundle exec ruby`. Hits both `key_content` + `is_key_content_base64: true` paths. Possibly a regression in fastlane 2.233.x's `gsub('\n', "\n")` + lane-context handling | Decode the .p8 to a tmpfile inside the `asc_api_key` helper, then call the action with `key_filepath:` instead of `key_content:` + `is_key_content_base64`. The file path code path bypasses the buggy gsub-then-base64-decode branch |
| G12 | `MATCH_GIT_BASIC_AUTHORIZATION` 404s on the certs repo after delete + recreate. Fine-grained GitHub PATs are pinned to a *repo's database ID*, not its name — when the certs repo is deleted and a new one with identical name is created, the new repo has a fresh ID and the existing PAT loses access. `fastlane match` then dies at the first clone with "Error cloning certificates git repo". This blocks the template's E2E refork test from running unattended (every cycle would require manual PAT scope updates via `github.com/settings/tokens`). | Don't delete the certs repo as part of the E2E loop. Reset its branches via force-push instead — the certs repo's lifecycle is logically separate from the app fork's. `bin/refork-smoketest.sh` does this by default. The repo's database ID is preserved, so the existing fine-grained PAT (correctly scoped to "Only select repositories" → certs repo) stays valid across E2E cycles. |
| G13 | xcodebuild archive fails with `Signing certificate is invalid. Signing certificate "Apple Distribution: <name>", serial number "...", is not valid for code signing. It may have been revoked or expired.` Even though `security find-identity -v` shows the cert as valid (it's not expired, has a private key). Cause: the cert is revoked at Apple's side but still locally cached. `find-identity -v` only filters expired certs, not revoked-at-Apple ones. xcodebuild's `CODE_SIGN_IDENTITY=Apple Distribution` substring-matches multiple certs; if any matching cert is revoked, the archive can fail when xcodebuild picks that one. | New `make clean-revoked-certs` target — queries ASC API for valid cert serials, diffs against local keychain certs, deletes the revoked locals after confirmation. Surgical user-state cleanup; doesn't touch the template's normal build path. Run once when you hit this; subsequent builds use only Apple-valid certs. (`bundle exec fastlane clean_revoked_certs dry_run:true` to preview.) |
| G14 | The local-mode shipping path (RELEASE_MODE=local) was 0% covered by automation through v1.4 — only validated via manual cold-fork tests at release time. Regressions in `setup_ci` mode-gating, `match`-skip gating, sigh-based App Store profile minting, β cert SHA-1 pinning (extracting `DeveloperCertificates[0]` from the .mobileprovision), ExportOptions plist patching for manual signing, and bash-3.2 `${arr[@]}`-under-`set -u` array safety would surface only when a forker tried to ship — typically weeks after the regressing commit landed. | New `.github/workflows/canary-local-mode.yml` — weekly mint→ship→verify→revoke loop in the same Apple team. Mints 3 throwaway certs (`apple_distribution` + `apple_development` + `mac_installer_distribution`), runs full local-mode `fastlane release` against TestFlight, revokes the 3 just-minted certs (`if: always()`). Net team-cert delta per run = 0; user's existing shipping certs untouched. Cache-tracked orphan recovery (`actions/cache@v5`) handles partial-failure scenarios — next run's pre-step revokes any ids the prior run's post-step missed. New `revoke_certs` (plural, idempotent) and `mint_canary_certs` (capture-ids) lanes in `fastlane/Fastfile` are the building blocks. |
| G15 | TestFlight "What to Test" annotation never persists for new builds. fastlane pilot 2.233.1's `set_changelog` path (called by `pilot(... changelog: ...)` after upload) iterates `update_localized_build_review` over an empty hash for builds with no pre-existing `BetaBuildLocalization`, then logs `Successfully set the changelog for build` without ever POSTing the localization to ASC. Affects every fresh upload (the common case for canaries; surfaces less for releases that re-upload over an existing build). Confirmed empirically across 6 canary runs (PR #135-#142) and against pilot's source (`pilot/lib/pilot/build_manager.rb:560-588`). Compounded by ASC's BetaBuildLocalization endpoint silently rejecting non-ASCII in `whatsNew` ("contains invalid characters" — pilot eats the error too). | The canary's "Annotate canary builds in TestFlight" step bypasses pilot entirely: poll for ≤10 min for ASC to register the just-uploaded builds (pilot returns from upload ~1-3 min before ASC indexes them), then PATCH the BBL via `Spaceship::ConnectAPI.patch_beta_build_localizations` if pilot's empty-creation has materialized, or POST a fresh one via `post_beta_build_localizations` if not. ASCII-only `whatsNew`. Workaround preserved as a Fastfile comment until upstream pilot is fixed. |
| G16 | macos-15-arm64-20260427+ runner image rejects WWDR-G3-issued certs at xcodebuild `exportArchive` with `Signing certificate is invalid`, even with the full cert chain (G2-G6 intermediates) pre-installed in System keychain AND login keychain via `security import -A`. The leaf cert is valid (ASC API confirms not revoked/expired; OCSP returns "good"); the chain is reachable (G3 cert SHA1 verified against the issuer URL embedded in the leaf's AIA extension); freshly-minted G6-issued certs work fine on the same runner image. Apple appears to have tightened cert validation policy in the Sequoia 15.7.4+ runner image such that legacy G3-issued certs (issued 2014-2025, valid until 2027) no longer pass exportArchive's policy check. Surfaced today on prakashrj/my-cool-app reusing indiagrams/ios-macos-smoketest-certs (G5HJYWLM9Z, G3-issued); the smoketest's last successful CI release was 2026-05-06 on an earlier runner image. | The mint-fresh-per-run approach (`canary-local-mode.yml` since v1.5, now `release.yml` since v1.6) sidesteps the issue by never reusing legacy-issued certs — every run produces a freshly-minted G6 cert, ships, then revokes it. The match-based path is gone entirely from `release.yml`. (#158) |

The smoketest also surfaced two ecosystem-level constraints:

- **Apple does not expose `POST /apps`** in the public ASC API — fastlane
  `produce` falls back to Apple ID + 2FA login for app creation. We
  deliberately don't carry those secrets in CI; the
  `bootstrap_asc` lane in `fastlane/Fastfile` verifies-or-fails-loudly with
  one-time-setup instructions for creating the App via web UI.
- **Apple's per-team certificate caps** (verified empirically 2026-05-08
  against team `A1B2C3D4E5`; community docs are stale or contradictory):
  `DISTRIBUTION` (Apple Distribution) cap = **3** / team;
  `DEVELOPMENT` (Apple Development) cap **≥ 5** / team;
  `MAC_INSTALLER_DISTRIBUTION` cap = **2** / team. At-cap mint without
  `--force` returns HTTP 409 — non-destructive; with `--force` revokes the
  oldest cert by creation date (could be your production cert — `fastlane
  cert` defaults to no `--force`, which is the safe default). The
  `revoke_cert` lane (singular, ad-hoc) and `revoke_certs` lane (plural,
  idempotent batch) in `fastlane/Fastfile` help free a slot or clean up
  canary cycles. Forks enabling `canary-local-mode.yml` need to dedicate
  one cycling slot per at-cap type via a one-time setup — revoke 1 spare
  DIST + 1 spare MAC_INSTALLER cert via `developer.apple.com/account/resources/certificates`
  (or `bundle exec fastlane revoke_certs ids:A,B`); see the v1.5 entry in
  the [CHANGELOG](../CHANGELOG.md) for context.

## How to run the smoketest pattern in your own fork

There are two opt-in canaries; pick whichever matches your fork's
`RELEASE_MODE`:

- **CI mode** (`RELEASE_MODE=ci`, match-based signing) — see
  [docs/BOOTSTRAP.md](BOOTSTRAP.md) for the certs-repo + GH Secrets
  setup. The same `release.yml` then runs on `workflow_dispatch` and
  whenever you tag a release; `canary-trigger.yml` (template-only)
  dispatches it weekly against the smoketest from upstream.
- **Local mode** (`RELEASE_MODE=local`, sigh-based, no match) — apple-shipkit's `canary-trigger.yml` already dispatches `canary-local-mode.yml` on the smoketest as part of its Saturday sweep. To run the same canary against your own fork on a schedule, fork apple-shipkit, set `SMOKETEST_DISPATCH_PAT` + `DISCORD_CANARY_WEBHOOK` secrets on it, point `TARGET_REPO` at your fork, and configure the five GH Secrets on the target fork (`ASC_API_KEY_ID`, `ASC_API_KEY_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`, `FASTLANE_TEAM_ID`, `KEYCHAIN_PASSWORD`). Plus the v1.5 one-time cert-slot dedication from the cert-caps bullet above. For an ad-hoc one-shot, just `gh workflow run canary-local-mode.yml --repo <your-fork>` (no apple-shipkit infrastructure required). **PAT expiry**: pick **1 year** (GitHub's max for fine-grained PATs) at mint time — the default is 30 days, after which the Saturday cron goes red with `HTTP 401: Bad credentials` from the dispatch API call. `canary-trigger.yml`'s preflight surfaces an actionable rotation runbook when this happens, but rotation is still a manual step (no way to refresh a PAT programmatically). Calendar reminder for ~11 months out is wise.

Either way, the workflow runs against your fork's bundle ID + ASC app
record + signing identity — same shape as the smoketest.
