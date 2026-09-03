# Adopting an existing App Store app

Are you already shipping an iOS or macOS app to the App Store and want to migrate the release engineering to apple-shipkit?

This guide covers the **existing-app** path. For greenfield (new app, fresh Bundle ID), use [GETTING-STARTED.md](GETTING-STARTED.md) instead.

## The risk you're avoiding

The template ships with placeholder App Store metadata in `fastlane/metadata/en-US/*.txt` (description, keywords, etc.) and placeholder screenshots in `fastlane/screenshots/`. If you fork the template and immediately run `make submit`, the placeholder content gets **uploaded** to your live ASC App record — **overwriting** your real App Store description, keywords, screenshots.

Users browsing the App Store would see `TODO: replace with your App Store description` within minutes. This is bad.

`make adopt` solves this: it pulls down your existing ASC state to your local tree **before** you ship, so when `make submit` later runs, it uploads **your** real metadata (now on disk) instead of placeholders.

## Prerequisites

Same as greenfield, with one key difference:

- ✓ Apple Developer Program membership ($99/yr)
- ✓ ASC API key (.p8 file + key ID + issuer ID)
- ✓ Bundle ID **already registered** for your live app (not a fresh one)
- ✓ ASC App record **already exists** for that Bundle ID

The template's `make doctor` step `Register Bundle ID in Apple Developer Portal` is idempotent — it confirms the Bundle ID is registered without trying to create it. Same for `Verify ASC App record exists`.

## Step-by-step walkthrough

### 1. Fork the template + rename

```bash
gh repo create my-existing-app --template=indiagrams/apple-shipkit --private --clone
cd my-existing-app
bin/rename.sh --email=you@example.com
$EDITOR app/Identity.xcconfig
```

`bin/rename.sh` personalizes the contact address and the repository slug. Identity is the four keys of `app/Identity.xcconfig` — `APP_PRODUCT_NAME`, `BUNDLE_ID`, `DISPLAY_NAME`, `COPYRIGHT` — which you set by hand to your real app's values. Both generators read them as `$(VAR)`, so there is no literal to substitute and nothing to keep in step. Run `ruby bin/preflight-identity.rb` afterwards; it refuses, naming the key, if any of the four resolves to nothing.

### 2. Fill `.bootstrap.env`

```bash
cp .bootstrap.env.example .bootstrap.env
$EDITOR .bootstrap.env
```

The critical fields for adoption:

```
APP_NAME=MyExistingApp                          # matches app/Identity.xcconfig's APP_PRODUCT_NAME
BUNDLE_ID=com.theirteam.myexistingapp           # your REAL bundle id (already on the App Store)
FASTLANE_TEAM_ID=ABCD1234EF                     # the team that owns your existing app
ASC_API_KEY_ID=ABCD1234                         # your ASC API key
ASC_API_KEY_ISSUER_ID=12345678-...               # your ASC issuer ID
ASC_API_KEY_P8_BASE64=LS0tLS1CRUdJTi...          # base64-encoded .p8 file contents
RELEASE_MODE=local                              # or 'ci' if shipping from GitHub Actions
```

See [BOOTSTRAP.md](BOOTSTRAP.md) for the full field reference.

### 3. Run `make doctor` to verify connectivity

```bash
make doctor
```

For an existing-app fork, this should pass cleanly. Expected output:

```
✓ Apple credentials                       Reachable. Team: ABCD1234EF
✓ GitHub credentials                       gh authenticated
✓ Register Bundle ID in Apple Developer  com.theirteam.myexistingapp already registered
✓ Verify ASC App record exists           Found: MyExistingApp
⚠ App Store metadata text files          8 files need attention before App Store review:
                                            - fastlane/metadata/en-US/description.txt
                                            - fastlane/metadata/en-US/keywords.txt
                                            …

                                            If your fork is adopting a LIVE App Store app, do NOT just edit
                                            these files — running `make submit` would overwrite your real
                                            App Store listing with the local placeholders. Instead, run
                                            `make adopt` first to pull your existing ASC metadata +
                                            screenshots down to disk. See docs/ADOPTING-EXISTING-APP.md.
```

The metadata warning is what doctor flags for placeholder text. The hint pointing you to `make adopt` fires once `BUNDLE_ID` is non-placeholder and ASC creds are configured (i.e., the existing-app fingerprint).

### 4. Run `make adopt`

```bash
make adopt
```

This:

| Step | What | Where |
|---|---|---|
| 1 | Verifies ASC App record exists for your bundle id | Spaceship API call |
| 2 | Downloads all metadata localizations (description, keywords, marketing/support/privacy URLs, name, subtitle, promotional text, release notes) | `fastlane/metadata/<locale>/*.txt` |
| 3 | Downloads all screenshots, all device classes, all locales | `fastlane/screenshots/<locale>/*.png` |
| 4 | Reports your latest ASC marketing version | stdout — for you to manually sync into `app/project.yml` |

Performance: ~5 sec for metadata; ~30–60 sec for screenshots (depends on count + locale set). Both run by default.

Skip flags:

```bash
make adopt SKIP_SCREENSHOTS=true   # metadata only — fast iteration
make adopt SKIP_METADATA=true      # screenshots only
```

### 5. Review + commit

```bash
git diff fastlane/metadata fastlane/screenshots
```

This is the moment to verify the adoption pulled what you expected. Common things to spot-check:

- Description matches what's live on the App Store
- Screenshots are in the right device-class buckets
- Locales: if your app has e.g. `en-US`, `de-DE`, `ja`, you should see directories for each

If something looks wrong, **don't proceed**. Re-investigate ASC's actual state, fix it in the ASC web UI if needed, then re-run `make adopt`.

When the diff looks right:

```bash
git add fastlane/metadata fastlane/screenshots
git commit -m "chore: adopt existing ASC app state"
```

### 6. Sync marketing version

`make adopt` reports your current live App Store version (e.g. `3.4.2`). Update your project manifest to match:

**XcodeGen** (`app/project.yml`):

```yaml
settings:
  base:
    MARKETING_VERSION: 3.4.2          # match ASC's live version
```

**Tuist** (`app/Project.swift`):

```swift
.settings(base: [
    "MARKETING_VERSION": "3.4.2",
])
```

apple-shipkit's CFBundleVersion (build number) auto-bumps from ASC's existing build count, so build numbers never collide.

### 7. Ship as normal

```bash
make ship      # joins your existing TestFlight build history
make submit    # uploads YOUR metadata (now on disk after adopt), not placeholders
```

The first `make ship` after adoption produces TestFlight build `v3.4.2+<N+1>` where `N` is your previous build count.

## Moving an app between Apple teams

Adopting an existing app sometimes comes with a second question: the app is on
a personal team and you want it under an organization. App Store Connect has a
transfer flow for this, but it has hard constraints that are easy to discover
too late.

- **Transfer requires at least one released version.** Apple's
  [app transfer criteria](https://developer.apple.com/help/app-store-connect/transfer-an-app/app-transfer-criteria)
  require the app to have had a version released to the App Store. An app that
  has only ever been in Prepare for Submission — including one with TestFlight
  builds — cannot be transferred at all.

- **A transfer changes your team prefix, and that breaks the keychain.**
  `keychain-access-groups` and `com.apple.security.application-groups` resolve
  through `$(AppIdentifierPrefix)` / `$(TeamIdentifierPrefix)` to
  `<TeamID>.<identifier>`. After a transfer the prefix is the recipient's, so
  every existing item in those groups becomes unreadable. Apple documents the
  consequence as *"users must re-login once"*. For an app that stores only a
  session token that is a shrug; for an app holding credentials, encryption
  keys, or Secure Enclave key references it is silent data loss for every
  installed user. **If you can move teams before your first public release, do
  — the cost is config churn instead of user data.**

- **A bundle ID is bound to its account permanently by the first TestFlight
  upload.** It cannot be reclaimed by a different team afterwards, so a team
  move that isn't a transfer means a **new bundle ID**. Bundle IDs are not
  user-visible; this is cheaper than it sounds, and cheapest before you ship.

- **An unreleased app record reserves its name.** To free a name for a record
  on another team, **rename the old record** (e.g. to
  `ZZZ_DO_NOT_USE_<name>`) rather than deleting it. Deleting releases the name
  into the general pool *for everyone except you*, which is the opposite of
  what you want. Renaming an unreleased record is free and immediate, though
  the name can take a few minutes to become available.

- **TestFlight does not come along.** Builds and testers do not transfer, and
  Apple requires beta testing to be turned off and Xcode Cloud data removed
  before a transfer is accepted. Testers reinstall either way.

## When NOT to run `make adopt`

- **Greenfield forks** — no existing App Store app. Edit metadata files directly. `make adopt` would fail with "no ASC App record found".
- **Multi-step rebrand** — if you're using this template migration AS a chance to rename your app's marketing copy:
  1. Run `make adopt` to capture the old state for the historical record + so apple-shipkit knows your locale set
  2. Edit the freshly-downloaded metadata files with your new copy
  3. Then `make submit` ships the new copy
- **You're in the middle of an App Review submission** — running `make submit` after `make adopt` will create a NEW version. If you have a version pending review, hold off on `make adopt` until the current review concludes.

## Re-running `make adopt`

Idempotent. Useful when:

- You edited metadata in the ASC web UI and want to mirror back to disk
- Apple's App Review changed something during review
- You think your local got out of sync somehow

By default, `make adopt` refuses to overwrite uncommitted changes in `fastlane/metadata` or `fastlane/screenshots`. To override:

```bash
FORCE=true make adopt   # overwrite even with uncommitted changes — destructive
```

## Troubleshooting

| Error | Meaning | Fix |
|---|---|---|
| `BUNDLE_ID is the template placeholder 'com.example.helloapp'` | You haven't set BUNDLE_ID in `.bootstrap.env` | Edit `.bootstrap.env` with your real bundle id |
| `no ASC App record found for bundle '...' on team ...` | Either bundle id is wrong, team id is wrong, or app exists on a different team | Verify both in ASC web UI: My Apps → app → App Information → Bundle ID; Account → Team |
| `Uncommitted changes detected in fastlane/metadata` | Local edits would be lost on overwrite | `git commit` first, or `FORCE=true make adopt` |
| `Missing required env vars: ASC_API_KEY_*` | `.bootstrap.env` is incomplete | Fill in all `ASC_API_KEY_*` fields; see [BOOTSTRAP.md](BOOTSTRAP.md) |
| `fastlane deliver download_metadata` hangs | Apple's API briefly flaking | Ctrl-C, wait 30 sec, re-run |

## See also

- [GETTING-STARTED.md](GETTING-STARTED.md) — greenfield walkthrough (the counterpart to this guide)
- [MAINTAINING-A-FORK.md](MAINTAINING-A-FORK.md) — day-2 fork operations
- [BOOTSTRAP.md](BOOTSTRAP.md) — `.bootstrap.env` field reference
- [CONTINUOUS-VALIDATION.md](CONTINUOUS-VALIDATION.md) — the catalog of shipping-pipeline gotchas
