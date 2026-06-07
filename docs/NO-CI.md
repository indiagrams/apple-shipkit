# Local-only mode (no GitHub Actions, ship from your laptop)

If your fork ships from your laptop — not from CI — you can run the entire release pipeline without GitHub Actions involvement. (CI mode itself no longer requires a certs repo or `fastlane match` either, as of v1.6 — both modes now sign with sigh-fetched App Store profiles. The remaining axis of choice is _where_ `make ship` runs.)

This is the default mode shipped by `.bootstrap.env.example` since v1.3.0. Forks just need a Mac with Xcode 26 and an Apple Developer account ($99/yr).

## What changes in local-only mode

| | CI mode | Local-only mode |
|---|---|---|
| Where `make ship` runs | GitHub Actions runner (macos-15) | Your Mac |
| Code signing | Fresh certs minted into a controlled keychain per run, revoked on `always()` | Login Keychain (auto-minted by `bootstrap-fork`) |
| Required GH Secrets | 5 (`KEYCHAIN_PASSWORD`, `ASC_API_KEY_ID`, `ASC_API_KEY_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`, `FASTLANE_TEAM_ID`) | 0 |
| Bootstrap pipeline length | 18 steps | 18 steps (same — v1.6 collapsed the difference) |
| Branch protection | required CI checks set by `bin/setup-github.sh` (count varies by PLATFORMS + committed generator manifests — typically 8) | None (configure manually if you want) |
| Required certs repo | no (dropped in v1.6) | no |
| Auto-minted signing certs | yes — release.yml mints fresh per run on the runner | yes — `bootstrap-fork` mints into your login Keychain (see "Cert provisioning" below) |

Local-only mode is appropriate for:

- **Solo indie shipping** — you trust your own laptop, no team workflow
- **Personal apps** — no need to gate merges on CI
- **Apps where running a release on a hosted runner is unwanted overhead** — single dev, single machine, occasional ships

CI mode is the right default for everyone else (multi-dev, security-sensitive, or any case where local laptop drift would be a liability — see [docs/CONTINUOUS-VALIDATION.md](CONTINUOUS-VALIDATION.md) for why CI mode + the canary pattern matters).

## How to enable local-only mode

### 1. `RELEASE_MODE=local` in `.bootstrap.env`

This is the **default** as of v1.3.0 — `make init` scaffolds `.bootstrap.env.example` with `RELEASE_MODE=local`. If you started before v1.3 and have `RELEASE_MODE=ci`, just flip it:

```bash
# .bootstrap.env (the fields you'll actually fill in)
RELEASE_MODE=local
APP_NAME=YourApp
BUNDLE_ID=com.yourorg.yourapp
DISPLAY_NAME='Your App'
APP_EMAIL=you@example.com
GENERATOR=xcodegen
PLATFORMS=ios,macos
FASTLANE_TEAM_ID=A1B2C3D4E5                    # 10-char alphanumeric from Apple Developer → Membership
ASC_API_KEY_ID=ABC1234567                      # 10-char from ASC → Users and Access → Integrations
ASC_API_KEY_ISSUER_ID=12345678-abcd-...        # UUID from same page
ASC_API_KEY_P8_PATH=~/.config/secrets/AuthKey_ABC1234567.p8
ICON_1024_PATH=                                # leave blank for the placeholder; set later for App Store
ASC_APP_SKU=yourapp-001                        # any unique-to-you string (cosmetic; in ASC reports)
ASC_APP_NAME='Your App'                        # display name on the App Store

# Auto-filled by `make init` from your git remote — usually no edit needed:
GH_ORG=your-username
GH_APP_REPO=your-app

# CI-only field — leave blank for local-only mode:
KEYCHAIN_PASSWORD_FILE=
```
`make doctor` detects `RELEASE_MODE=local` and skips the CI-only step (`GHSecrets`).

### 2. Cert provisioning

Local mode signs from certs in your login Keychain. The pipeline needs:

- **Apple Distribution** — for both iOS .ipa and macOS .pkg/.app archives
- **Apple Development** — for device + Mac development signing
- **3rd Party Mac Developer Installer** — only when shipping macOS, signs the .pkg installer wrapper

`bootstrap-fork`'s `LocalKeychainCerts` step **auto-mints any missing identities** via `fastlane cert` (uses your `ASC_API_KEY_*` to authenticate; lands the cert + private key in your login Keychain). Idempotent — already-valid certs are reused, not duplicated.

Three ways to drive this:

```bash
# Option A — full forker journey, mints certs as part of bootstrap-fork
make all                  # doctor → bootstrap-fork → ship → verify

# Option B — just the certs, run before `make ship`
make mint-local-certs     # auto-mints any missing identities, then exits

# Option C — manual via Xcode (if you prefer GUI)
# Xcode → Settings → Accounts → (your team) → Manage Certificates → +
# Pick "Apple Distribution" / "Apple Development" / "Mac Installer Distribution"
```

If your keychain has certs from other Apple Developer teams (e.g. you're consulting for multiple clients), `make doctor` detects the mismatch and surfaces it with the team ID it found vs. the team ID it expected. `make mint-local-certs` then mints fresh certs for `FASTLANE_TEAM_ID`.

### 3. Disable the PR + release workflows (optional)

The template ships with `.github/workflows/{pr,release}.yml`. They work in local mode too (PR builds verify the project compiles), but you can remove them if you don't want any GH Actions presence:

**Option A — delete them**

```bash
rm .github/workflows/pr.yml
rm .github/workflows/release.yml
git add .github/workflows
git commit -m "chore: remove CI workflows for local-only mode"
git push
```

You lose PR-time build/test signal, but `make ship` still works locally because it shells into `bundle exec fastlane release` directly (no Actions dependency).

**Option B — keep them but turn off branch protection**

Branch protection requires the 7 CI checks to pass before merging. Without CI, those checks never run → PRs can never merge. Disable via:

```bash
gh api -X DELETE repos/$GH_ORG/$GH_APP_REPO/branches/main/protection
```

Or in the GitHub web UI: Settings → Branches → main → Delete rule.

### 4. Skip `make setup-github`

`bin/setup-github.sh` configures the required CI checks (count varies by PLATFORMS + committed generator manifests — typically 8). In local-only mode, don't run it — or remove it from your local `make all` flow if you wired it in.

## What `make ship` does in local-only mode

The same `make ship` command works on your Mac as on CI. It:

1. Reads `.bootstrap.env`
2. Detects `RELEASE_MODE=local` → runs `bundle exec fastlane release` directly on your Mac, signing with the certs already in your login Keychain. (CI mode runs the same sigh-based release lane on a runner with fresh per-run certs; since v1.6 both paths converge on a single lane — `RELEASE_MODE` only routes _where_ the lane runs.)
3. Archives + exports iOS .ipa + macOS .pkg
4. Runs `fastlane pilot` to upload to TestFlight (with the `pilot_with_retry` 3-attempt exponential-backoff wrapper added in v1.2.0)
5. Pushes a `vYYYY.WW.<run_number>` tag

`<run_number>` in local mode is sourced from a local counter (`fastlane/.local_run_number`) since there's no GitHub `${{ github.run_number }}` to use.

## Skipping macOS

If you're shipping iPhone-only and don't want to mint a Mac Installer Distribution cert, set `PLATFORMS=ios` in `.bootstrap.env`. `make doctor` skips the macOS-specific cert check, `make ship` skips the .pkg build/upload, and CI on PRs (if you keep the workflow) runs only the iOS jobs.

You can flip back later: change `PLATFORMS=ios,macos`, re-run `make bootstrap-fork`. The Mac Installer cert auto-mints on the next `make all` / `make bootstrap-fork`.

## When to switch back to CI mode

You'll want CI mode if any of these become true:

- A second human starts contributing
- You ship from multiple machines
- You want PR-time test signal (xcodebuild + xcodebuild test on every PR)
- You want hermetic per-release signing — CI mode mints fresh signing certs on a clean macos-15 runner per release and revokes them after `always()`, so no laptop keychain drift can affect what ships

(With `canary-local-mode.yml` already in the template, **continuous validation is no longer a CI-mode-only feature** — local-mode forks get it via the Saturday canary; see § "Continuous validation in local mode" below.)

The switch is reversible: change `RELEASE_MODE=ci`, populate `KEYCHAIN_PASSWORD_FILE`, run `make bootstrap-fork` (it provisions the 5 required GH Secrets — `KEYCHAIN_PASSWORD`, `ASC_API_KEY_ID`, `ASC_API_KEY_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`, `FASTLANE_TEAM_ID`), restore the workflows + branch protection. No certs repo, no PAT, no `MATCH_PASSWORD` — those went away in v1.6.

## Continuous validation in local mode

Local mode is no longer a "no canary" mode. The template ships
`.github/workflows/canary-local-mode.yml`, which runs on
`workflow_dispatch` only — no `schedule:` trigger of its own. The
weekly Sat 07:00 UTC cron lives entirely in apple-shipkit's
`canary-trigger.yml`, which dispatches `canary-local-mode.yml` on
the smoketest as one of its three sequential canary cells. Forks
that want their own local-mode canary either:

- **Manual / ad-hoc**: `gh workflow run canary-local-mode.yml --repo <your-fork>` whenever you want a one-shot validation. No additional setup beyond the standard 5 GH Secrets enumerated below.
- **Scheduled**: fork apple-shipkit, point `canary-trigger.yml`'s `TARGET_REPO` at your fork, configure `SMOKETEST_DISPATCH_PAT` (a fine-grained PAT on your fork with `Actions: Read and write`), and let the apple-shipkit-fork's Saturday cron dispatch into your fork's `canary-local-mode.yml`. **Pick 1-year expiration when minting the PAT** (GitHub's max for fine-grained tokens); the default 30 days will fail the cron on the first Saturday after the 30-day mark with `HTTP 401: Bad credentials`. `canary-trigger.yml`'s preflight surfaces the rotation runbook in the failed run's logs.

When the canary runs, it mints 3 throwaway signing certs into a controlled
keychain on the GH runner, runs full `fastlane release` (sigh-based App
Store profiles, no match), uploads to TestFlight, then revokes the 3
just-minted certs on `always()`. Net Apple-team cert delta per run = 0;
your existing shipping certs are never touched.

Prerequisites for enabling on your fork:

1. Configure 5 GitHub Secrets on the fork — `ASC_API_KEY_ID`,
   `ASC_API_KEY_ISSUER_ID`, `ASC_API_KEY_P8_BASE64`, `FASTLANE_TEAM_ID`,
   `KEYCHAIN_PASSWORD`. Optional: `DISCORD_CANARY_WEBHOOK` for failure
   notifications.
2. Run the v1.5 one-time cert-slot dedication: revoke 1 spare DIST + 1
   spare MAC_INSTALLER cert per team (~30 sec via
   [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
   or `bundle exec fastlane revoke_certs ids:A,B`). This dedicates one
   cycling slot per at-cap type so the canary can mint without hitting
   Apple's per-team caps. See [docs/CONTINUOUS-VALIDATION.md](CONTINUOUS-VALIDATION.md)
   for the empirical caps (DIST=3, DEV≥5, MAC_INSTALLER=2).
3. (Scheduled path only) fork apple-shipkit and configure
   `SMOKETEST_DISPATCH_PAT` + `TARGET_REPO` to point at your fork.

That's it. Saturday morning runs ship a clean canary build to TestFlight
under your bundle ID + ASC app, verifying the entire local-mode shipping
pipeline weekly.

If you also enable CI-mode `release.yml` shippers on the same Apple team, note that each CI release run also occupies one DIST slot (and, when shipping macOS, one MAC_INSTALLER slot) for the lifetime of the run before revoking on `always()`. With the per-team caps above, simultaneous CI ships + canary runs + local-mode mints can collide on slot availability — plan for the total churn across local + CI + canary, not any single path in isolation.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `make doctor` step 12 (`Local keychain has signing identities`) is `:pending` even after `make mint-local-certs` | Keychain access denied (Apple's keychain prompts) | Check `Console.app` for keychain prompts; click Allow when fastlane asks. Re-run. |
| `make doctor` step 12 says "Found certs … but none for team X" | Your keychain has certs from a different team | `make mint-local-certs` mints a fresh cert for the right team. The wrong-team certs remain in your keychain (use Keychain Access to remove if desired). |
| `fastlane cert` fails with "Could not create another …, reached the maximum" | Apple's per-team cert quota is full (DIST=3, DEV≥5, MAC_INSTALLER=2 — verified empirically May 2026; see [docs/CONTINUOUS-VALIDATION.md](CONTINUOUS-VALIDATION.md)). Remember CI-mode `release.yml` also briefly holds a DIST (+ MAC_INSTALLER on macOS ships) slot per run before revoking on `always()`, so heavy local + CI traffic can race. | `bundle exec fastlane list_certs` to enumerate, `bundle exec fastlane revoke_cert id:<id>` (singular) or `revoke_certs ids:A,B,C` (plural batch, idempotent) to revoke unused ones, then re-run. |
| `make ship` fails uploading to TestFlight | Transient ASC / altool flake | The `pilot_with_retry` wrapper retries 3× with exponential backoff. If all 3 fail, check the smoketest's [G1–G15 catalog](CONTINUOUS-VALIDATION.md). |
| `make all` aborts at doctor | Genuine `:blocked` step (e.g., ASC App record missing) | The blocker requires a manual one-time human step Apple's API doesn't allow. Doctor's tail names which step + what to do. |

## See also

- [`docs/BOOTSTRAP.md`](BOOTSTRAP.md) — full `.bootstrap.env` reference
- [`docs/APPLE-PREREQS.md`](APPLE-PREREQS.md) — Apple Developer account setup (ASC API key, team IDs, the one human-gated ASC App record step)
- [`docs/ROLLBACK.md`](ROLLBACK.md) — undoing a TestFlight build, a git tag, or a partial bootstrap-fork
- [`bin/lib/bootstrap.rb`](../bin/lib/bootstrap.rb) — `Step::MODES` constant tells you which steps are CI-only / local-only / both
