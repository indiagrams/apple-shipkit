# Releasing with Apple-native tools (no fastlane)

An alternative release path using only Apple-shipped tooling: `xcodebuild`,
`xcrun altool`, `xcrun notarytool`, and the App Store Connect API direct.
For forkers who want to drop the Ruby + fastlane dependency surface and
ship with what `xcode-select --install` already provides.

> **Status:** documentation only. The template's default release pipeline
> remains [fastlane](../fastlane/Fastfile) (`fastlane release tag:vX.Y.Z`).
> This doc shows the equivalent commands you'd run if you replaced
> fastlane with Apple's own tools — useful as a recipe, a reference, or a
> migration plan. Tracked in [#35](https://github.com/indiagrams/apple-shipkit/issues/35).

## Why this exists

Two-of-two r/iOSProgramming commenters on the v1.0.0 launch post asked
about an Apple-native (ASC CLI) path instead of fastlane. Real signal.
The trade-off is genuine:

| Aspect | fastlane | Apple-native |
|---|---|---|
| Dependencies | Ruby + fastlane gem + plugins | None beyond Xcode |
| Cold-run startup | ~3–5 s | <1 s |
| Integrated metadata + screenshots + signing | ✓ (`deliver`, `snapshot`, `sigh` / `match`) | Manual (separate ASC API calls) |
| macOS notarization (outside App Store) | via plugin or shell-out | `xcrun notarytool` (Apple-supported) |
| Community + plugins | Mature, large | Apple-only |
| Best for | Full release pipeline in one tool | "Build + upload" only; minimal-deps shops |

Pick fastlane if you want one tool that does build + upload + screenshots
+ metadata + signing-management. (As of v1.6 apple-shipkit's own fastlane
lane uses `sigh` for profile fetching and mints fresh Apple Distribution
certs per CI run via the App Store Connect API instead of routing through
`match` + a certs repo — see [`docs/BOOTSTRAP.md`](BOOTSTRAP.md). `match`
remains an option in the fastlane ecosystem if you'd rather keep a
long-lived certs repo.) Pick Apple-native if you'd rather not depend on
a Ruby gem and you're comfortable wiring the pieces together yourself.

## What this doc covers

- iOS App Store: `xcodebuild` archive → export → upload via `xcrun altool`
- macOS App Store: archive → export → app-sandbox re-sign hack → `productbuild` → upload
- macOS outside the App Store: notarization with `xcrun notarytool` + `xcrun stapler staple`
- Metadata: minimal sync to App Store Connect via the ASC API directly (curl + JWT)
- Alternative upload path: ASC API `/v1/buildUploads` (new in WWDC 2025) for
  forkers who want the most future-proof option

## What this doc does not cover

- **`fastlane match` replacement.** Manual cert + profile management is
  documented in [`docs/APPLE-PREREQS.md`](APPLE-PREREQS.md). Apple does
  not ship a `match`-equivalent. Note that as of v1.6 the template's own
  fastlane release lane no longer uses `match` either: CI mints a fresh
  Apple Distribution cert per run via the App Store Connect API (and
  revokes it on `always()`), and local mode signs with whatever
  Distribution cert is already in your login Keychain. So if you're
  leaving fastlane *for* the Apple-native path below, the cert story
  inherits from the same baseline the template's fastlane path uses:
  bring your own certs in the keychain, or script ASC API cert minting
  yourself. (Or use a third-party helper like
  [`apple-actions/upload-testflight-build`](https://github.com/apple-actions).)
- **`fastlane snapshot` / `MacSnapfile` replacement.** Screenshot
  automation is genuinely fastlane-strong territory — there is no
  drop-in Apple-native equivalent. The template's
  [`ci/take-screenshots.sh`](../ci/take-screenshots.sh) +
  [`ci/extract-mac-screenshots.sh`](../ci/extract-mac-screenshots.sh)
  already drive iOS via `xcodebuild test` + `XCUIScreenshot` and macOS
  via `XCTAttachment` extracted from the `xcresult` — neither requires
  fastlane to capture, only to upload. You can keep the capture scripts
  and replace the upload step with the metadata flow below.

## Prerequisites

Same as the fastlane path — see [`docs/APPLE-PREREQS.md`](APPLE-PREREQS.md):

- Paid Apple Developer Program membership ($99/yr).
- **Apple Distribution** cert in your login Keychain.
- **Mac Installer Distribution** cert in your login Keychain (macOS .pkg signing).
- **App Store Connect API key** with App Manager role:
  - The `.p8` private key file (downloaded once from ASC → Users and
    Access → Integrations → Team Keys).
  - The **Key ID** (10-character alphanumeric).
  - The **Issuer ID** (UUID).
- For macOS notarization (non-App-Store distribution only): an
  app-specific password OR a `notarytool` keychain profile. See
  [`xcrun notarytool store-credentials`](#one-time-setup-notarytool-keychain-profile)
  below.

Apple announced that **starting in 2026, builds uploaded to App Store
Connect must be created with Xcode 14 or later** ([upload-builds
help](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)).
This template uses Xcode 15+; you're already covered.

The conventions below assume:

- Bundle ID: `com.example.helloapp` (substitute yours)
- Scheme: `App-iOS` / `App-macOS` (constants — the app's name is `PRODUCT_NAME`, from `app/Identity.xcconfig`)
- Team ID: read from `.bootstrap.env` as `FASTLANE_TEAM_ID` (set by `make init` + your edits)
- Build artifacts: `build/App-<version>.ipa`, `build/App-<version>.pkg`
- ASC API key path: `~/.appstoreconnect/AuthKey_<KEYID>.p8` (per
  [`docs/APPLE-PREREQS.md`](APPLE-PREREQS.md))

`xcrun altool` requires API key files to live in
`~/.appstoreconnect/private_keys/` OR
`~/.private_keys/AuthKey_<KEYID>.p8`. Symlink or copy if you keep the
canonical copy elsewhere.

## iOS App Store flow

The template's existing
[`ci/local-release-check.sh`](../ci/local-release-check.sh) already drives
the archive + export half of this; the only thing fastlane adds in the
default pipeline is the upload step (`pilot`). Replacing `pilot` with
`altool` is mechanical.

### 1. Archive

```bash
TAG=v0.1.0
VERSION="${TAG#v}"
TEAM_ID="$FASTLANE_TEAM_ID"

# Regenerate xcodeproj from project.yml (XcodeGen).
( cd app && xcodegen generate )

WORK_DIR="$(mktemp -d)"
IOS_ARCHIVE="$WORK_DIR/App-iOS.xcarchive"

xcodebuild archive \
  -project app/App.xcodeproj \
  -scheme App-iOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$IOS_ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="0"
```

`-allowProvisioningUpdates` lets Xcode auto-create the App Store
provisioning profile on first run if one doesn't already exist. Subsequent
runs reuse the cached profile.

### 2. Export the .ipa

The template ships [`ci/ExportOptions-iOS.plist`](../ci/ExportOptions-iOS.plist)
with `method=app-store-connect` and `signingStyle=automatic`. Re-use it
verbatim — the only substitution is `TEAM_ID_PLACEHOLDER`:

```bash
EXPORT_OPTS="$WORK_DIR/ExportOptions-iOS.plist"
cp ci/ExportOptions-iOS.plist "$EXPORT_OPTS"
sed -i '' "s/TEAM_ID_PLACEHOLDER/$TEAM_ID/g" "$EXPORT_OPTS"

IOS_EXPORT="$WORK_DIR/export-ios"
xcodebuild -exportArchive \
  -archivePath "$IOS_ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -exportPath "$IOS_EXPORT" \
  -allowProvisioningUpdates

IPA_SRC=$(find "$IOS_EXPORT" -maxdepth 2 -name "*.ipa" | head -1)
IPA_DEST="build/App-${VERSION}.ipa"
cp "$IPA_SRC" "$IPA_DEST"
shasum -a 256 "$IPA_DEST" | tee "$IPA_DEST.sha256"
```

### 3. Upload to TestFlight / App Store

`xcrun altool --upload-package` is the simplest Apple-native upload path.
Apple deprecated altool's *notarization* subcommands in November 2023, but
the App Store upload subcommands remain supported (see [TN3147 — Migrating
to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
and the [fastlane TN3147 discussion](https://github.com/fastlane/fastlane/discussions/21347)
for confirmation of the scope).

```bash
# Place AuthKey_<KEYID>.p8 in ~/.appstoreconnect/private_keys/ first.
# (altool searches there; symlink from your canonical location if needed.)
mkdir -p ~/.appstoreconnect/private_keys
ln -sf ~/.appstoreconnect/AuthKey_${ASC_API_KEY_ID}.p8 \
       ~/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8

xcrun altool --upload-package "$IPA_DEST" \
  --type ios \
  --apple-id "com.example.helloapp" \
  --bundle-version "$VERSION" \
  --bundle-short-version-string "$VERSION" \
  --bundle-id "com.example.helloapp" \
  --apiKey "$ASC_API_KEY_ID" \
  --apiIssuer "$ASC_API_KEY_ISSUER_ID"
```

The build appears in App Store Connect under TestFlight after the
"Processing" step (typically 5–30 min). You'll receive an Apple email
when it's ready or if it failed (e.g. ITMS-90296 sandbox issues, missing
icons, etc.).

### Alternative: ASC API direct (`POST /v1/buildUploads`)

WWDC 2025 introduced first-class build upload support in the App Store
Connect API ([Build uploads
docs](https://developer.apple.com/documentation/appstoreconnectapi/build-uploads)).
The flow is multi-step:

1. `POST /v1/buildUploads` to create the upload reservation (returns an ID).
2. `POST /v1/buildUploadFiles` per file (the .ipa is one file plus
   metadata) — returns chunked-upload reservation URLs.
3. `PUT` the file bytes to each reservation URL.
4. `PATCH /v1/buildUploadFiles/<id>` with `uploaded: true` to commit.
5. Poll the build state via the
   [`BUILD_UPLOAD_STATE_UPDATED` webhook](https://developer.apple.com/documentation/appstoreconnectapi/webhookeventtype)
   or poll `GET /v1/buildUploads/<id>`.

Use this path if you want the most future-proof, scriptable, no-binary-
dependency option (just `curl` + a JWT generator). Apple positions it as
the "ideal for CI/CD" path. The implementation is straightforward but
has more moving parts than `altool`; for a one-page recipe `altool`
remains simpler.

### 5. (Optional) Annotate the TestFlight build's "What to Test"

Each TestFlight build can carry a localized "What to Test" string (the
`BetaBuildLocalization` resource). fastlane pilot's `set_changelog`
path is structurally broken in 2.233.1 (logs success but never POSTs
the localization for fresh builds — see
[`docs/CONTINUOUS-VALIDATION.md`](CONTINUOUS-VALIDATION.md) G15);
the Apple-native equivalent below sidesteps that:

> **Note:** As of v1.6, the template's own fastlane release lane already
> performs this same POST/PATCH dance automatically via the
> `annotate_testflight_whats_new` helper in
> [`fastlane/Fastfile`](../fastlane/Fastfile) (added in #149). The recipe
> below is for forkers shipping *outside* the v1.6 fastlane path — i.e.
> you've replaced `fastlane release` entirely with `xcrun altool` + the
> curl calls in this doc, and therefore need to do the BBL annotation by
> hand. If you're still on the template's `fastlane release` lane, you
> get this for free.

```bash
APP_ID="1234567890"
BUILD_VERSION="2026.19.42"   # CFBundleVersion of the just-uploaded build
LOCALE="en-US"
CHANGELOG="Bug fixes and new features"   # ASCII only — see caveat below

# 1. Find the just-uploaded build's id (poll for ~1-3 min after altool —
#    ASC indexes uploads asynchronously after altool returns):
BUILD_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/builds?filter[app]=$APP_ID&filter[version]=$BUILD_VERSION&limit=1" \
  | jq -r '.data[0].id')

# 2. Check whether a BetaBuildLocalization for this locale already exists.
#    pilot's upload path can pre-create an empty BBL[en-US]; ASC's
#    indexing is racy — sometimes you'll see it, sometimes you won't.
EXISTING=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/builds/$BUILD_ID/betaBuildLocalizations?filter[locale]=$LOCALE&limit=1" \
  | jq -r '.data[0].id // empty')

if [ -n "$EXISTING" ]; then
  # 3a. PATCH the existing localization
  curl -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    "https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations/$EXISTING" \
    -d "$(jq -n --arg id "$EXISTING" --arg whatsNew "$CHANGELOG" \
      '{data:{type:"betaBuildLocalizations",id:$id,attributes:{whatsNew:$whatsNew}}}')"
else
  # 3b. POST a new one
  curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    "https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations" \
    -d "$(jq -n --arg buildId "$BUILD_ID" --arg locale "$LOCALE" --arg whatsNew "$CHANGELOG" \
      '{data:{type:"betaBuildLocalizations",attributes:{locale:$locale,whatsNew:$whatsNew},relationships:{build:{data:{type:"builds",id:$buildId}}}}}')"
fi
```

> **ASCII-only caveat:** ASC's `BetaBuildLocalization` and
> `AppStoreVersionLocalization` endpoints **silently reject non-Latin
> characters in `whatsNew`** with a "contains invalid characters" error
> (no character pointer, no row/column). Stick to ASCII letters, digits,
> and common punctuation. The same caveat applies to the `whatsNew` field
> in §2's `AppStoreVersionLocalization` PATCH.

## macOS App Store flow

Identical to iOS through the export step, then a re-sign hack, then
`productbuild`, then upload. The re-sign hack is the same one fastlane
runs (the template embeds it in
[`ci/local-release-check.sh`](../ci/local-release-check.sh) lines 181–225)
and it is **independent of fastlane vs. Apple-native** — it happens
between export and upload.

### 1. Archive

```bash
MACOS_ARCHIVE="$WORK_DIR/App-macOS.xcarchive"

xcodebuild archive \
  -project app/App.xcodeproj \
  -scheme App-macOS \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$MACOS_ARCHIVE" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="0"
```

### 2. Export

```bash
EXPORT_OPTS_MACOS="$WORK_DIR/ExportOptions-macOS-AppStore.plist"
cp ci/ExportOptions-macOS-AppStore.plist "$EXPORT_OPTS_MACOS"
sed -i '' "s/TEAM_ID_PLACEHOLDER/$TEAM_ID/g" "$EXPORT_OPTS_MACOS"

MACOS_EXPORT="$WORK_DIR/export-macos"
xcodebuild -exportArchive \
  -archivePath "$MACOS_ARCHIVE" \
  -exportPath "$MACOS_EXPORT" \
  -exportOptionsPlist "$EXPORT_OPTS_MACOS" \
  -allowProvisioningUpdates

EXPORTED_PKG=$(find "$MACOS_EXPORT" -maxdepth 2 -name "*.pkg" | head -1)
```

### 3. App-sandbox re-sign hack (mandatory before upload)

> **Why this exists.** Xcode's auto-managed Mac App Store provisioning
> profile does *not* list `app-sandbox` as a capability. The signed `.app`
> from `-exportArchive` strips `com.apple.security.app-sandbox` from
> entitlements, and TestFlight then rejects with
> [ITMS-90296](https://developer.apple.com/help/app-store-connect/reference/error-codes-and-messages/).
> The fix is to expand the .pkg, force-add app-sandbox back into the
> embedded entitlements, re-sign, and repack.
>
> See [`ci/local-release-check.sh`](../ci/local-release-check.sh#L181) —
> this exact hack is documented there and runs in the template's signed
> release path. Reuse the script as-is, or transcribe the lines into your
> own pipeline. The hack is the same regardless of whether you upload
> with fastlane or `altool`.

The entitlements re-sign uses the existing helper
[`ci/lib/resolve-dist-cert-sha.sh`](../ci/lib/resolve-dist-cert-sha.sh) to
disambiguate the Apple Distribution cert SHA-1 from the .app's embedded
provisioning profile (necessary when one team has multiple distribution
certs).

### 4. productbuild

```bash
INSTALLER_CERT=$(security find-identity -v -p basic 2>/dev/null \
  | grep -E "3rd Party Mac Developer Installer|Mac Installer Distribution" \
  | head -1 | grep -oE '"[^"]+"' | tr -d '"')

PKG_DEST="build/App-${VERSION}.pkg"
productbuild --component "$EXPANDED_APP" /Applications \
  --sign "$INSTALLER_CERT" \
  --timestamp \
  "$PKG_DEST"
shasum -a 256 "$PKG_DEST" | tee "$PKG_DEST.sha256"
```

### 5. Upload

Same `xcrun altool` flow as iOS, but `--type macos` and the .pkg path:

```bash
xcrun altool --upload-package "$PKG_DEST" \
  --type macos \
  --apple-id "com.example.helloapp" \
  --bundle-version "$VERSION" \
  --bundle-short-version-string "$VERSION" \
  --bundle-id "com.example.helloapp" \
  --apiKey "$ASC_API_KEY_ID" \
  --apiIssuer "$ASC_API_KEY_ISSUER_ID"
```

## macOS notarization (non-App-Store distribution)

If you're shipping a Mac app via your own website or a DMG (not the Mac
App Store), you need to notarize it. `notarytool` is the supported tool
since November 2023; `altool`'s notarization subcommands were
[decommissioned](https://developer.apple.com/news/upcoming-requirements/?id=11012023a).
Reference: [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

### One-time setup (`notarytool` keychain profile)

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "you@example.com" \
  --team-id "$TEAM_ID" \
  --password "abcd-efgh-ijkl-mnop"   # app-specific password from appleid.apple.com
```

Or use the ASC API key directly without storing in keychain (recommended
for CI):

```bash
xcrun notarytool submit "$PKG_DEST" \
  --key ~/.appstoreconnect/AuthKey_${ASC_API_KEY_ID}.p8 \
  --key-id "$ASC_API_KEY_ID" \
  --issuer "$ASC_API_KEY_ISSUER_ID" \
  --wait
```

### Submit and staple

```bash
# Using the keychain profile from above:
xcrun notarytool submit "$PKG_DEST" \
  --keychain-profile "AC_PASSWORD" \
  --wait

# After notarization succeeds, staple the ticket so the app validates offline:
xcrun stapler staple "$PKG_DEST"

# Verify:
xcrun stapler validate "$PKG_DEST"
spctl --assess --type install --verbose "$PKG_DEST"
```

The `--wait` flag blocks until the notary service finishes (typically
1–5 min). Without `--wait`, you get a submission ID and have to poll
with `xcrun notarytool log <id>`.

### When notarization is *not* needed

- App Store distribution (TestFlight + App Store) does **not** require
  notarization. App Review serves the same purpose.
- Mac App Store .pkgs uploaded via `altool --upload-package --type macos`
  go through App Review, not notarization.

Notarization is only for the developer-distributed-installer path
(direct download, DMG, custom updater).

## Metadata via App Store Connect API direct

Replacing `fastlane deliver` with raw ASC API calls. The template's
[fastlane `do_upload_metadata`](../fastlane/Fastfile) workaround for
`deliver`'s silently-dropped fields (the
[`do_upload_metadata`](../fastlane/Fastfile#L60) helper that reads
every metadata file directly and passes explicit hashes) becomes
unnecessary on the Apple-native path because you're not going through
`deliver` at all — you're calling the API directly with the values you
want.

### 1. Generate a JWT

The ASC API uses ES256 JWTs. Apple's
[official guide](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
covers the algorithm. A minimal Python helper (works with the standard
library + `cryptography`):

```python
#!/usr/bin/env python3
# bin/asc-jwt.py — emit a 20-min JWT for the App Store Connect API
import os, sys, time, json, base64
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

KEY_ID    = os.environ["ASC_API_KEY_ID"]
ISSUER_ID = os.environ["ASC_API_KEY_ISSUER_ID"]
KEY_PATH  = os.path.expanduser(f"~/.appstoreconnect/AuthKey_{KEY_ID}.p8")

def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

header  = b64url(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
payload = b64url(json.dumps({
    "iss": ISSUER_ID,
    "iat": int(time.time()),
    "exp": int(time.time()) + 20 * 60,
    "aud": "appstoreconnect-v1",
}).encode())
signing_input = f"{header}.{payload}".encode()

with open(KEY_PATH, "rb") as f:
    key = load_pem_private_key(f.read(), password=None)
der_sig = key.sign(signing_input, __import__("cryptography.hazmat.primitives.asymmetric.ec",
                                              fromlist=["ECDSA"]).ECDSA(hashes.SHA256()))
r, s = decode_dss_signature(der_sig)
sig = b64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
print(f"{header}.{payload}.{sig}")
```

```bash
TOKEN="$(python3 bin/asc-jwt.py)"
```

(For a Ruby or Swift JWT generator, see Apple's `appstoreconnect-swift-sdk`
or roll your own — JWT is a 5-line operation in any language.)

### 2. Update the description for the current iOS version

```bash
APP_ID="1234567890"   # numeric app ID from ASC URL
LOCALE="en-US"

# Find the current "Prepare for Submission" version localization:
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/apps/$APP_ID/appStoreVersions?filter[platform]=IOS&limit=1" \
  | jq -r '.data[0].id'   # → APP_STORE_VERSION_ID

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/appStoreVersions/$APP_STORE_VERSION_ID/appStoreVersionLocalizations?filter[locale]=$LOCALE" \
  | jq -r '.data[0].id'   # → LOCALIZATION_ID

# Patch the description (and other fields) in one shot:
curl -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/$LOCALIZATION_ID" \
  -d "$(jq -n \
    --arg id "$LOCALIZATION_ID" \
    --rawfile desc fastlane/metadata/en-US/description.txt \
    '{data: {type: "appStoreVersionLocalizations", id: $id, attributes: {description: $desc}}}')"
```

The same pattern works for `keywords`, `marketingUrl`, `supportUrl`,
`promotionalText`, `whatsNew`, etc. The full attribute list is in
[`AppStoreVersionLocalization`](https://developer.apple.com/documentation/appstoreconnectapi/appstoreversionlocalization).

### 3. Upload screenshots

`POST /v1/appScreenshotSets` to reserve, then `PUT` the bytes per Apple's
chunked-upload protocol. Significantly more code than the metadata
PATCH; if you need this, vendoring [`appstoreconnect-swift-sdk`](https://github.com/AvdLee/appstoreconnect-swift-sdk)
or writing a small wrapper is reasonable. Otherwise: keep
`ci/take-screenshots.sh` for capture and use the ASC web UI for upload —
that's a defensible trade-off if releases are infrequent.

## Limitations vs. fastlane

What you give up by leaving fastlane:

- **No `match`.** Cert + provisioning profile sync across machines is
  manual. You can install certs in the login Keychain by hand,
  re-download profiles from `developer.apple.com` when they expire, or
  rely on `-allowProvisioningUpdates` to auto-create on first run. (As
  of v1.6 the template's own fastlane lane doesn't use `match` either —
  CI mints a fresh Apple Distribution cert per run via the ASC API and
  revokes it on `always()`; local mode signs from your login Keychain —
  so the cert situation here is the same one the fastlane path lives
  with.)
- **No `precheck`.** Fastlane's pre-flight ASC linting (broken URLs,
  metadata length limits, prohibited keywords) is gone. You'll find
  these issues at App Review time instead. Run `Validate App` in
  Xcode's Organizer first if you want a similar local check.
- **No automated screenshot capture story.** The capture itself
  ([`ci/take-screenshots.sh`](../ci/take-screenshots.sh) +
  [`ci/extract-mac-screenshots.sh`](../ci/extract-mac-screenshots.sh))
  doesn't depend on fastlane — keep it. The *upload* step
  (`fastlane ios upload_screenshots` / `fastlane mac upload_screenshots`)
  is the part you replace, and the ASC API equivalent is non-trivial
  enough that doing screenshots from the ASC web UI is the pragmatic
  default for low-frequency releases.
- **No integrated TestFlight tester management.** Fastlane's `pilot`
  manages tester groups; on the API path you'd call
  [`/v1/betaGroups`](https://developer.apple.com/documentation/appstoreconnectapi/betagroups)
  and friends manually.

What you gain:

- Zero non-Apple dependencies. `xcode-select --install` is the only
  prerequisite.
- Faster cold starts (no Ruby + gem load).
- Full visibility into what each command does — every step is one
  `xcrun ...` or one `curl ...`. No magic.
- Future-proof against fastlane's own evolution (Apple is
  [deprecating Transporter's `-f` flag in 2026](https://github.com/fastlane/fastlane/issues/29608),
  and fastlane's plugins shell out to the same Apple tools you'd be
  calling directly).

## References

- Apple — [App Store Connect API: Build uploads](https://developer.apple.com/documentation/appstoreconnectapi/build-uploads) (WWDC 2025)
- Apple — [Generating tokens for API requests](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
- Apple — [TN3147: Migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- Apple — [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- Apple — [Upload builds (App Store Connect Help)](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- Apple — [App Store Connect API key setup](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- `man xcodebuild`, `man notarytool`, `man stapler`, `man codesign`, `man productbuild`
- altool man (community-mirrored, 2019 baseline; flags unchanged): <https://keith.github.io/xcode-man-pages/altool.1.html>
- This template — [`docs/APPLE-PREREQS.md`](APPLE-PREREQS.md), [`SCOPE.md`](../SCOPE.md), [`ci/local-release-check.sh`](../ci/local-release-check.sh), [`ci/ExportOptions-iOS.plist`](../ci/ExportOptions-iOS.plist), [`ci/ExportOptions-macOS-AppStore.plist`](../ci/ExportOptions-macOS-AppStore.plist)
