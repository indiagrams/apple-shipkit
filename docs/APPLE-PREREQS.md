# Apple Account Prerequisites

What you need from Apple to use this template, broken down by what you actually plan to do.

## Three tiers of Apple account

### 1. Apple ID (free, required to download Xcode)

- Sign up: <https://appleid.apple.com>
- Used to download Xcode from the Mac App Store and to sign into Xcode for personal-team development signing.

### 2. Free Apple Developer account (free, optional)

- Sign in to Xcode (Xcode → Settings → Accounts → "+" → Apple ID) with your Apple ID and Xcode automatically enrolls you in the free developer tier.
- Lets you sideload your app to your own physical iPhone/iPad for testing.
- Provisioning profiles expire every 7 days (you re-build to refresh).
- No paid subscription required.

### 3. Apple Developer Program ($99 USD/year, required to ship)

- Enroll: <https://developer.apple.com/programs/>
- Required for:
  - App Store distribution
  - TestFlight builds
  - Push notifications, iCloud, Sign in with Apple, certain entitlements
  - Long-lived (1-year) provisioning profiles
- Individual or Organization tier — Organization needs a D-U-N-S number (free; takes a few business days).

## What this template specifically needs

| Capability | Apple ID | Free dev | Paid program |
|------------|----------|----------|--------------|
| Open the project in Xcode | ✓ | — | — |
| Build for iOS Simulator | ✓ | — | — |
| Build for macOS | ✓ | — | — |
| Run on a physical iPhone | — | ✓ | — |
| Submit to TestFlight | — | — | ✓ |
| Submit to App Store | — | — | ✓ |
| Use the fastlane release pipeline (`fastlane release`) | — | — | ✓ |
| Push notifications, iCloud, etc. | — | — | ✓ |

If you're just exploring the template, an Apple ID + free developer signing is enough. The paid program is only needed when you're ready to publish.

## Apple-side setup checklist (when ready to ship)

Once you've enrolled in the Apple Developer Program:

- [ ] Note your **Team ID** — visible at <https://developer.apple.com/account/> under Membership Details. 10-character alphanumeric string like `ABCDE12345`. Put it in `.bootstrap.env` as `FASTLANE_TEAM_ID`. `make bootstrap-fork` copies it into the **gitignored** `app/Local.xcconfig` as `DEVELOPMENT_TEAM = <your Team ID>`; on a clone that has not run it, create that one line by hand. It is per-clone signing configuration rather than per-fork identity, which is why it lives outside `app/Identity.xcconfig`. It never goes into a tracked file — `app/Identity.xcconfig` pulls `Local.xcconfig` in with `#include?`, and `ruby bin/preflight-identity.rb --require-team` names it if it is missing.
- [ ] Create the app record on App Store Connect — <https://appstoreconnect.apple.com> → My Apps → "+". Use the bundle ID you set via `bin/rename.sh`.
- [ ] Generate an **App Store Connect API key** (recommended for fastlane non-interactive uploads):
  - <https://appstoreconnect.apple.com/access/integrations/api> → Team Keys → "+"
  - Role: App Manager (or higher)
  - Download the `.p8` private key — **download is one-time only**, save it carefully.
  - Note the **Key ID** and **Issuer ID** shown alongside.
- [ ] **Register your build Mac** — <https://developer.apple.com/account/resources/devices/list> → "+" → macOS. Needed before the first macOS archive on a brand-new team; see Common gotchas below for why, and for which identifier to use.
- [ ] Place the `.p8` file **outside the repo** (e.g., `~/.appstoreconnect/`). The template's `.gitignore` blocks `*.p8`, but accidents happen.
- [ ] Configure fastlane to read the API key from your local secrets path. See `fastlane/Fastfile` for the expected env vars.

## Code-signing artifacts — DO NOT commit

The `.gitignore` already blocks the common ones, but be aware:

| File | Why it matters | Where to keep it |
|------|---------------|------------------|
| `*.p8` | App Store Connect API private key | `~/.appstoreconnect/` |
| `*.mobileprovision` | Provisioning profiles (manual signing) | `~/Library/MobileDevice/Provisioning Profiles/` (Xcode manages) |
| `*.cer`, `*.p12` | Distribution certificates. Three types are needed for full ship: **Apple Distribution** (codesign for the .app), **Apple Development** (provisioning), **3rd Party Mac Developer Installer** (signs the `.pkg` wrapper around macOS apps via `productbuild`). Local mode auto-mints these into the login keychain via `make mint-local-certs` (also runs as part of `make bootstrap-fork`). CI mode (`release.yml`, v1.6+) mints them fresh on the runner per release and revokes on `always()` — there is no certs repo and no `match` step. Per-team caps verified empirically May 2026: DIST=3, DEV≥5, MAC_INSTALLER=2. | macOS Keychain (local mode) / minted on the runner per run (CI mode) |
| `.bootstrap.env` | Local fork config (paths, identifiers; secrets stay outside repo) | repo root, gitignored |

If you accidentally commit any of these, treat it as a credential leak: revoke the key/cert immediately on Apple's side, then `git rm --cached` + force-rotate.

## Common gotchas

- **Free tier won't notarize.** macOS apps distributed outside the App Store need notarization, which requires the paid program.
- **Team membership ≠ ownership.** If you're added to someone else's Apple Developer team as a member, you can sign builds but may not have App Store Connect access. Coordinate with your team's Account Holder.
- **D-U-N-S number lookup is free.** If Apple says you need to "obtain" one for an Organization enrollment, use the free Apple lookup tool — don't pay D&B for one.
- **Apple ID without 2FA can't be added to a developer team** (Apple requirement). Enable 2FA before enrollment.
- **A brand-new team can't archive macOS until a Mac is registered.** When signing automatically — i.e. without `RELEASE_MACOS_PROFILE_NAME` + `RELEASE_MACOS_CERT_SHA1` pinned — `xcodebuild archive` provisions a Mac *development* profile before export re-signs for the App Store, and Apple requires a Mac development profile to contain at least one registered device. iOS profiles can be created with zero devices; macOS ones cannot. On a team with no devices the archive fails with `Your team has no devices from which to generate a provisioning profile` followed by `couldn't find any Mac App Development provisioning profiles`. Register the build Mac (see the checklist above). The pinned manual-signing path doesn't hit this, because the profile already exists.
- **The macOS Provisioning UDID is not the Hardware UUID.** On Apple Silicon these are two different values and only the Provisioning UDID is accepted:
  ```bash
  system_profiler SPHardwareDataType | awk -F': ' '/Provisioning UDID/{print $2}'
  ```
  Registering the Hardware UUID instead (what `ioreg -c IOPlatformExpertDevice` reports as `IOPlatformUUID`) *appears* to work — the archive starts succeeding, because the team now holds at least one device — and then fails much later, at the first `xcodebuild test` or run on that Mac, with `Provisioning profile ... doesn't include the currently selected device`. Two different requirements, both surfacing as "provisioning profile" errors.

## Per-team certificate quotas (verified empirically)

Apple's per-team cert caps, probed via the ASC API on 2026-05-08 against
team `A1B2C3D4E5` (community docs are stale or contradictory):

| Cert type | Cap | Notes |
|---|---|---|
| Apple Distribution | **3** | Used for codesigning `.app` bundles. Minted per-run by `release.yml` (CI mode, v1.6+) or once into the login keychain by `make mint-local-certs` (local mode). |
| Apple Development | **≥ 5** | Provisioning + dev signing. We didn't probe the upper bound; the canary and `release.yml` each mint 1 per run with no observed cap hit. |
| 3rd Party Mac Developer Installer | **2** | Used by `productbuild` to sign `.pkg` wrappers for macOS apps. Lower than DIST — Mac shippers commonly hit this first. |
| Developer ID Application G2 | (separate, untested) | Apple's notarization-bound cert for direct distribution outside the App Store. Not exercised by this template. |

At-cap mint without `--force` returns HTTP 409 (non-destructive). At-cap
mint **with** `--force` revokes the OLDEST cert by creation date — could
be your production cert. `fastlane cert` defaults to no `--force` (safe).
The `revoke_cert` lane (singular) and `revoke_certs` lane (plural,
idempotent batch) in `fastlane/Fastfile` help free a slot.

### Dedicate cycling slots if at-cap (required for release.yml + canary)

If your team is at-cap on Distribution (3/3) or Mac Installer (2/2),
revoke 1 spare cert per constrained type once via the developer portal
— this dedicates a cycling slot for the canary AND for `release.yml`
runs. Without a cycling slot, a `make ship` run hits HTTP 409 at the
mint step (and so does the Saturday canary).

This applies to every fork running v1.6+. Earlier (v1.5) cycling-slot
guidance only mentioned the canary because the release path then went
through `match` against a certs repo; v1.6 release.yml mints fresh per
run, so the same slot pressure applies to actual releases.

```bash
# Via Apple Developer portal (~30 sec)
# https://developer.apple.com/account/resources/certificates
# Revoke 1 spare DIST cert + 1 spare MAC_INSTALLER cert.

# Or via fastlane (if you know the cert ids):
bundle exec fastlane revoke_certs ids:CERT_ID_1,CERT_ID_2
```

Both the canary and `release.yml` then mint into the freed slots per
run and revoke on `always()`. Net team-cert delta per run = 0; your
existing shipping certs are never touched. See
[docs/CONTINUOUS-VALIDATION.md](CONTINUOUS-VALIDATION.md) for the full
architecture.

## Reference

- Apple Developer Program enrollment FAQ: <https://developer.apple.com/support/enrollment/>
- App Store Connect API: <https://developer.apple.com/documentation/appstoreconnectapi>
- fastlane App Store Connect API docs: <https://docs.fastlane.tools/app-store-connect-api/>
