# Maintaining your fork after the first ship

You've forked apple-shipkit, run `make all`, and your build is in TestFlight. Now what?

This guide answers the questions that come up *after* the first release:

- What state do I actually own?
- What does Apple manage for me?
- What needs backing up?
- What breaks if I ignore it for six months?
- I want to add [push notifications / Sign in with Apple / iCloud / App Groups] — does that change anything?
- An Apple cert expired. What do I do?

It's deliberately accessible — assumes you've shipped *one* iOS or macOS app before, but doesn't assume you've memorized Apple's certificate hierarchy or fastlane's internals.

## TL;DR for the impatient

If you do nothing else after your first ship:

1. **Renew Apple Developer Program annually** ($99/yr). If it lapses, every cert your team holds is auto-revoked. Apple emails reminders 30 days out.
2. **Ship at least once every ~12 months**, even just a no-op build. Apple processing requirements drift (new SDK minimums, new entitlement formats); shipping keeps you exercised against the current policy.
3. **Keep `.bootstrap.env` and `~/.config/secrets/*` backed up somewhere safe** (1Password, your dotfiles repo, etc.). Without these, you can re-create state from scratch in ~30 minutes; with them, ~2 minutes.

That's it. Everything else below is "in case you need it."

## What's persistent (lives forever, you own it)

These survive across releases, machine swaps, even moving to a different fork:

| Asset | Lives where | Why it persists |
|---|---|---|
| **Bundle ID** | Apple Developer Portal | Registered once via `make bootstrap-fork`; tied to your team. Identifies your app to iOS/macOS forever. |
| **App Store Connect App record** | App Store Connect | Created manually (Apple disallows API creation). Holds your app's metadata, screenshots, reviews. |
| **Team ID** | Apple Developer Portal | Your `FASTLANE_TEAM_ID` — assigned when you joined the Apple Developer Program. |
| **App ID capabilities** (App Groups, Push, Sign in with Apple, iCloud, etc.) | Apple Developer Portal | Each capability you enable is registered against your Bundle ID. Stays enabled across releases. |
| **App users' iCloud data, Keychain entries, settings** | User devices, iCloud | Tied to Bundle ID + Team ID. Won't be lost when you ship a new version. |
| **GitHub repo + commit history** | GitHub | Standard git stuff. |
| **Source code, CHANGELOG, screenshots, App Store metadata** | Your repo | All in version control. |

What this means: you can lose your laptop, lose your `.bootstrap.env`, lose every cert in your keychain, and your app's *identity* is fine. You'd just need to re-bootstrap a new machine to get back to shipping.

## What's ephemeral (auto-managed by apple-shipkit, ignore it)

These are minted on-demand and revoked or rotated automatically. You don't think about them:

| Asset | When it's created | When it's gone |
|---|---|---|
| **Apple Distribution cert** (used to sign App Store builds) | CI mode: each `release.yml` run mints one. Local mode: auto-minted by `make bootstrap-fork` into your login keychain. | CI mode: revoked at end of every run via `if: always()`. Local mode: stays in keychain ~1 year, then expires; replaced on next `make bootstrap-fork` or `make mint-local-certs`. |
| **Apple Development cert** | Same as above. | Same as above. |
| **3rd Party Mac Developer Installer cert** (used to sign macOS .pkg installers) | Same as above. | Same as above. |
| **App Store provisioning profile** | `fastlane sigh` mints one each release run. | Apple expires them after ~1 year, but you're minting fresh per release anyway. |

What this means: signing certs are throwaway. **Apple identifies your app by Bundle ID + Team ID, not by which specific cert signed each build.** Once a TestFlight build is uploaded, Apple archives the cert that signed it; later cert revocation doesn't invalidate the already-uploaded build. Your testers see the new build via TestFlight as if nothing changed.

## What you (the developer) actively own

Things apple-shipkit *won't* manage for you. Most forks need none of these — they're for apps with specific features.

### If your app uses push notifications (APNs)

Apple Push Notification service uses a **separate** auth key (`.p8` file) — not your signing certs.

- **Where to get it**: App Store Connect → Users and Access → Keys → Generate (select "Apple Push Notifications service (APNs)" capability).
- **What you back up**: the `.p8` file (Apple shows it once at creation; if you lose it, you generate a new one and revoke the old).
- **What apple-shipkit knows about it**: nothing. APNs is outside the bootstrap flow. You hold the `.p8` and feed it to your push-sending backend (your server, OneSignal, AWS SNS, etc.).
- **Lifecycle**: never expires (unlike push *certs* which Apple deprecated). Revoke + replace if it leaks.

> **Note**: the `.p8` you used during `make init` (`ASC_API_KEY_P8_BASE64` GH Secret) is a *different* `.p8` — that one is the App Store Connect API key, used by fastlane to talk to Apple. APNs auth keys are separate. They look identical (PEM-encoded EC key), but Apple treats them as different credential types.

### If your app uses Sign in with Apple

Sign in with Apple needs a **Service ID** + a **private key** for verifying user tokens server-side.

- **Where to get it**: Apple Developer Portal → Identifiers → New → Services IDs.
- **What you back up**: the Service ID name and the private key it's bound to.
- **Lifecycle**: tied to your Apple Developer Program membership. Never auto-rotated.

### If your app uses Wallet (Pass Type ID)

Each pass type your app issues needs a Pass Type ID + cert.

- **Where to get it**: Apple Developer Portal → Identifiers → New → Pass Type IDs.
- **What you back up**: the cert's `.p12` (export from Keychain Access). Apple expires these certs annually; renew via the portal.
- **Why apple-shipkit doesn't manage it**: Pass Type ID certs aren't standard signing certs and aren't part of the App Store distribution flow.

### If your app distributes outside the Mac App Store (Developer ID)

Direct distribution (the user downloads a `.dmg` or `.pkg` from your website) requires a **Developer ID Application** cert, distinct from Mac App Distribution.

- **Where to get it**: Apple Developer Portal → Certificates → Production → Developer ID Application.
- **What you back up**: the `.p12` (private key + cert).
- **Lifecycle**: 5 years. Renew before expiry.
- **Why apple-shipkit doesn't auto-mint these**: the project is App Store first; Developer ID is a separate distribution path. If you need it, mint via the portal manually and add a custom signing step in your release lane.

### If your app uses CloudKit / iCloud / App Groups

These are **entitlements** registered against your Bundle ID. They have no separate cert lifecycle.

- **Where to enable**: Apple Developer Portal → Identifiers → your Bundle ID → enable the capability.
- **What you back up**: the entitlement is auto-saved in your `.entitlements` files in the repo. Just keep your repo backed up.
- **Lifecycle**: enabled forever once registered. Free to use within Apple Developer Program limits.

## Day-2 operations: when you need to do something

### "I want to add custom lanes (Slack notify, Crashlytics dSYM, Firebase distribution, etc.)"

The template's `fastlane/Fastfile` is intentionally release-shaped for App Store + TestFlight only. Forks extend it via `fastlane/Fastfile.local` — a tracked, fork-owned file that survives upstream `apple-shipkit` syncs without merge conflicts.

```bash
cp fastlane/Fastfile.local.example fastlane/Fastfile.local
# edit — uncomment the patterns you want
git add fastlane/Fastfile.local
git commit -m "chore(fastlane): add custom release hooks"
```

The example file ships ~7 copy-pasteable patterns adapted from [`fastlane/examples`](https://github.com/fastlane/examples):

| Pattern | What it does |
|---|---|
| 1. `after_all` Slack hook | Posts a success message to a channel after every successful lane (`release`, `submit_for_review`, etc.) |
| 2. `error` Slack hook | Posts a failure message when any lane raises |
| 3. `lane :ship_with_crashlytics` | Wraps the template's `release` lane with a follow-up `download_dsyms` + `upload_symbols_to_crashlytics` step |
| 4. `lane :beta` | Mints an ad-hoc profile and pushes to Firebase App Distribution (skips TestFlight processing latency) |
| 5. App Store submission notification | Filters `after_all` to fire only on `submit_for_review` — useful for bumping Jira / Linear / internal tracker tickets |
| 6. Custom action under `fastlane/actions/` | Drops a Discord webhook action; fastlane auto-loads any `.rb` under that path |
| 7. Internal version-tracking → Linear | Pushes the just-shipped tag into a project-management system on `release` success |

All patterns use only documented fastlane primitives (`after_all`, `error`, `override_lane`, `import`). Template constants (`APP_NAME`, `APP_IDENTIFIER`, `IOS_SCHEME`, `MACOS_SCHEME`) and helpers (`asc_api_key`, `pilot_with_retry`, `changelog_text`, `extract_changelog_section`, `parse_release_tag`) are all callable from `Fastfile.local` because fastlane merges imported files into a single namespace.

Hook conventions:

- The template **claims `before_all`** for `setup_ci` (CI mode) + `asc_api_key` setup. Fastlane's `before_all` is last-write-wins, so DON'T define `before_all` in `Fastfile.local` — it would silently drop the template's ASC bootstrap. To run setup before a specific lane, override that lane.
- The template **does NOT claim `after_all` or `error`** — both are free for forks to use without conflict. Multiple `after_all` / `error` blocks compose: every imported file's hooks fire in import order.
- The import sits at the BOTTOM of the template Fastfile (not the top) so `override_lane` works — the original lane has to exist before it can be overridden.
- Wrap every third-party API call in `rescue StandardError` and log via `UI.important`. The template's contract is that the App Store ship succeeded; a Slack 404 must not turn that into a fastlane "failure" exit code that retro-actively breaks `make ship` reporting.

Custom actions: any `fastlane/actions/<name>.rb` is auto-loaded at startup. No `import` needed; the action is callable from any lane. The example file has the action skeleton.

### "I want to ship a new version"

`make ship` (CI mode) or `make ship` from your local Mac (local mode). Versioning is automatic: `v<MARKETING>+<BUILD>` where `<MARKETING>` is read from `app/project.yml` (or `app/Project.swift` for Tuist) and `<BUILD>` resolves from ASC as `max(builds at this marketing version) + 1`. Cert minting, signing, upload, tag push, "What to Test" annotation all happen end-to-end. Takes ~5 minutes.

### "I want to submit to App Store review"

After at least one TestFlight build is processed, run:

```bash
# Take screenshots (uses fastlane snapshot — slow, 10-30+ minutes;
# review the PNGs in fastlane/screenshots/ before submitting)
make screenshots

# Stage (default) or auto-submit. Reads PLATFORMS + SUBMIT_FOR_REVIEW
# from .bootstrap.env. Per-platform fastlane lane invoked once per
# active platform.
make submit
```

### Stage vs auto-submit: the maturity ramp

`make submit` has two modes, controlled by `SUBMIT_FOR_REVIEW` in `.bootstrap.env`:

| Setting | What `make submit` does | Recommended for |
|---|---|---|
| `SUBMIT_FOR_REVIEW=false` (default) | Uploads screenshots + metadata + attaches the TestFlight build + fills export-compliance answers, but **does NOT click "Submit for Review"**. The version sits in App Store Connect's "Prepare for Submission" state. You review the prepared listing in the ASC web UI, then click Submit yourself. **No GitHub Release is created** until you actually submit. | Early releases. Every first-timer should start here. |
| `SUBMIT_FOR_REVIEW=true` | All of the above **plus clicks Submit**. Version goes to "Waiting for Review"; Apple's queue starts. **GitHub Release published** with notes from `CHANGELOG.md`. | Once you trust your screenshots / metadata / CHANGELOG pipeline (typically after 3-4 successful releases). |

The recommended progression: ship a few releases with `SUBMIT_FOR_REVIEW=false`, eyeball each one in the ASC web UI before submitting manually, then flip to `true` once it feels routine.

Per-invocation overrides (env wins over the config field):

```bash
SUBMIT_FOR_REVIEW=true  make submit   # one-off auto-submit when config says false
SUBMIT_FOR_REVIEW=false make submit   # one-off stage when config says true
PLATFORMS=ios           make submit   # submit iOS only on a both-configured project
                                       # (common: stage+submit iOS first, watch it,
                                       #  then PLATFORMS=macos make submit)
RELEASE_SKIP_GH_RELEASE=true make submit   # skip the GH Release one-off
                                            # (e.g. `gh` CLI broken on the runner)
```

Apple's review takes 24-48 hours typically. If they reject, fix the issue and re-submit; the same build can be re-submitted unchanged (pure metadata fixes), or upload a new build via `make ship`.

### Direct fastlane invocation (advanced)

`make submit` is the recommended path. If you need finer control, the underlying fastlane lanes are:

| Lane | Behavior |
|---|---|
| `bundle exec fastlane ios submit_for_review` | iOS auto-submit (always — does not consult `SUBMIT_FOR_REVIEW` config) |
| `bundle exec fastlane ios stage_for_review` | iOS stage only |
| `bundle exec fastlane mac submit_for_review` | macOS auto-submit |
| `bundle exec fastlane mac stage_for_review` | macOS stage only |

The direct `submit_for_review` lanes always submit (preserving existing fastlane CLI muscle memory); `make submit` is the layer that introduces the stage-vs-submit toggle.

### "I added a new entitlement (e.g. Push) and signing now fails"

Each time you add a new capability to your Bundle ID:

1. Enable it in Apple Developer Portal → Identifiers → your Bundle ID.
2. Add it to your `.entitlements` files in the repo (`app/iOS/App.entitlements`, `app/macOS/App.entitlements` — constant paths on every fork).
3. Re-ship via `make ship`. The next mint cycle will produce certs/profiles that include the new capability.

If you re-ship without enabling the capability in the portal first, signing succeeds but the entitlement is stripped from the binary and your feature won't work at runtime.

### "An Apple cert expired"

Distribution + Development certs expire ~1 year from issuance. The mint-fresh CI flow doesn't care (each run mints fresh). For local mode:

```bash
make clean-revoked-certs    # removes locally-cached expired/revoked certs
make mint-local-certs       # mints fresh ones via fastlane cert
```

### "I'm at-cap on Apple's cert quota"

Apple limits per team:

| Cert type | Cap | Why it might fill up |
|---|---|---|
| Apple Distribution | 3 | Manual mints over the years; multiple devs per team |
| Apple Development | ≥5 | Same |
| 3rd Party Mac Developer Installer | 2 | Same |

If `make ship` fails with HTTP 409 at the mint step, you're at-cap. Fix:

```bash
# Preview what's in the team:
bundle exec fastlane list_certs

# Revoke a specific cert (find its ID in the list output):
bundle exec fastlane revoke_cert id:<CERT_ID>

# Or revoke many at once:
bundle exec fastlane revoke_certs ids:CERT_ID_1,CERT_ID_2
```

For ongoing CI mint-fresh runs, you need at least 1 free cycling slot per constrained type. See [docs/APPLE-PREREQS.md](APPLE-PREREQS.md) — "Per-team certificate quotas".

### "My Apple Developer Program membership lapsed"

If you don't renew within ~30 days of expiry, Apple revokes ALL your team's certs. Effects:

- TestFlight: existing builds stop accepting new testers; existing testers can keep using the build until it expires (~90 days after upload).
- App Store: published versions stay live (Apple already-vetted them); you can't ship new builds.
- Re-enrollment: pay $99, wait 24-48 hours for Apple to re-activate, then re-bootstrap (`make bootstrap-fork` mints fresh certs).

Set a calendar reminder. Apple's email reminders are easy to miss.

### "I want to migrate to a different Apple team"

The fork's bundle ID is registered against ONE team. Migrating means:

1. Register the same bundle ID under the new team (might require Apple support if the bundle ID's already taken in the old team — Apple has a transfer process).
2. Update `FASTLANE_TEAM_ID` in `.bootstrap.env` (and the corresponding GH Secret).
3. Re-run `make bootstrap-fork`.

This is rare. Most forks stay on one team forever.

### "I want to retire this fork"

If you stop developing the app:

1. **Apple side**: log into App Store Connect, set the app to "Removed from sale" (existing users keep the app; new downloads blocked). Or if you want to fully delete, there's a "Remove App" button at the bottom of the App Information page.
2. **GitHub side**: archive the repo (`gh repo archive`). Optional — keeps history accessible without active maintenance.
3. **Cert cleanup** (optional, just hygiene): `bundle exec fastlane revoke_certs ids:…` to free up team slots.

## Backups checklist

Things worth backing up to a secrets manager (1Password, Bitwarden, etc.):

| What | Why |
|---|---|
| `.bootstrap.env` | Reconstructible from secrets, but faster to restore |
| `~/.config/secrets/AuthKey_*.p8` (the ASC API key) | Apple won't give you this again — only generate-and-replace |
| `~/.config/secrets/keychain-password` (CI mode only) | Only matters if you want to keep the same controlled-keychain password on a new machine; otherwise just regenerate |
| Apple Developer Program login email + password (or your team admin's) | Without it, you can't renew membership or manage certs |
| App Store Connect API key team admin email | If your ASC API key is revoked at Apple's end (rare), you need ASC web access to mint a new one |
| Your fork's repo URL + branch protection state (or `bin/setup-github.sh` config) | Reconstructible but easier to restore from notes |

What you do **not** need to back up (apple-shipkit can recreate or doesn't store):

- Signing certs (`.cer`, `.p12`) — auto-minted on demand
- Provisioning profiles (`.mobileprovision`, `.provisionprofile`) — auto-minted by `sigh` per run
- Match repo / certs repo — doesn't exist anymore (v1.6+)
- MATCH_PASSWORD — doesn't exist anymore (v1.6+)
- GitHub fine-grained PAT — only existed for the old certs repo (v1.6+ removed it)

## What changes when apple-shipkit upgrades

apple-shipkit ships breaking changes occasionally (e.g. v1.6 dropped match-based signing entirely). When you bump your fork:

1. **Read the CHANGELOG** for the version range you're crossing. Breaking changes are flagged.
2. **Check `.bootstrap.env.example`** for new fields. Compare to your `.bootstrap.env`; add anything new.
3. **Re-run `make doctor`**. If new required fields appear, doctor will tell you. Fix and re-run `make bootstrap-fork`.

## When things go sideways

- **Build won't sign**: see [docs/CONTINUOUS-VALIDATION.md](CONTINUOUS-VALIDATION.md) — the failure-mode catalog has 16 entries covering every signing failure we've seen in the wild.
- **CI release fails**: see [docs/ROLLBACK.md](ROLLBACK.md) for the rollback procedure.
- **`make ship` says "no certs found"**: local mode — run `make mint-local-certs`. CI mode — check your team isn't at-cap; check you ran `gh auth login` on the machine triggering `make ship`.
- **TestFlight "What to Test" is empty**: should be auto-populated from `CHANGELOG.md`'s `[Unreleased]` block. If empty, set `RELEASE_CHANGELOG=...` in `release.yml`'s env block before triggering.
- **Anything else**: open an issue on apple-shipkit upstream. The smoketest fork validates the shipping path weekly, so the upstream maintainers usually catch regressions before forkers do.

## Mental model: who owns what

```
                  Apple (forever)
                  ──────────────
                  ├── Team ID (your $99/yr)
                  ├── Bundle ID + capabilities
                  ├── ASC App record + metadata + reviews
                  └── User devices: installed apps, iCloud data, Keychain

                                    │
                                    │  registered against
                                    ▼

                  apple-shipkit (per ship)
                  ────────────────────────
                  ├── Mints fresh signing certs on the runner
                  ├── Mints provisioning profiles via sigh
                  ├── Builds + signs + uploads
                  ├── Tags release in git
                  ├── Annotates "What to Test" from CHANGELOG.md
                  └── Revokes the just-minted certs (always)

                                    │
                                    │  reuses
                                    ▼

                  You (one-time setup)
                  ────────────────────
                  ├── Apple Developer Program subscription ($99/yr)
                  ├── App Store Connect API key (.p8) — generate once, reuse forever
                  ├── GitHub repo + `gh auth login`
                  ├── `.bootstrap.env` filled in
                  └── (Optional) APNs key, Pass Type ID, Sign in with Apple — for those features
```

The whole point of v1.6's mint-fresh-per-run architecture: the middle layer is *as ephemeral as possible*. You set up the bottom layer once, Apple manages the top layer forever, and apple-shipkit churns the middle layer per ship.

You don't have to think about the middle layer. That's the design.
