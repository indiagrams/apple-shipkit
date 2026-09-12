#!/usr/bin/env bash
# bin/device-rig/install-wda.sh — build, sign and install WebDriverAgent on one phone.
#
# OPT-IN. Nothing in `make check` or `make verify` calls this. It exists for the
# tests XCUITest cannot reach from inside your own app target: system permission
# alerts, the share sheet, Messages, Settings, a universal link tapped for real,
# or two phones talking to each other. See docs/UI-AUTOMATION.md.
#
# ⚠ A DEV-SIGNED WDA EXPIRES AFTER SEVEN DAYS. When sessions suddenly cannot
#   launch WebDriverAgent, check the calendar before you touch a capability.
#   Re-running this script is the whole fix.
#
# Usage:
#   bin/device-rig/install-wda.sh <UDID> [DERIVED_DATA_DIR]
#
# Env:
#   DEVELOPMENT_TEAM   Apple team id. Falls back to app/Local.xcconfig, the same
#                      gitignored file the build reads.
#   WDA_BUNDLE_ID      default com.example.WebDriverAgentRunner — anything but
#                      Facebook's shipped id, which your team cannot sign.
#
# ⚠ ONE DERIVED-DATA DIR PER PHONE. Two builds sharing a root collide on the
#   SQLite build lock. That is why the directory is an argument.
set -euo pipefail

UDID="${1:?usage: install-wda.sh <UDID> [DERIVED_DATA_DIR]}"
DD="${2:-/tmp/wda-$UDID}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

TEAM="${DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM" && -f "$REPO_ROOT/app/Local.xcconfig" ]]; then
  TEAM=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' \
           "$REPO_ROOT/app/Local.xcconfig" | head -1)
fi
[[ -n "$TEAM" ]] || {
  echo "==> ERROR: no team id. Set DEVELOPMENT_TEAM, or put it in app/Local.xcconfig." >&2
  exit 1
}
BUNDLE="${WDA_BUNDLE_ID:-com.example.WebDriverAgentRunner}"

WDA=$(find "$HOME/.appium" -type d -name appium-webdriveragent -maxdepth 6 2>/dev/null | head -1)
[[ -n "$WDA" ]] || {
  echo "==> ERROR: WebDriverAgent not found. Install it first:" >&2
  echo "      npm install -g appium && appium driver install xcuitest" >&2
  exit 1
}

echo "==> WDA source:  $WDA"
echo "==> building for $UDID (team $TEAM, bundle $BUNDLE, derived data $DD)"
(cd "$WDA" && xcodebuild -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
   -destination "id=$UDID" -derivedDataPath "$DD" \
   -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
   PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
   build-for-testing) 2>&1 | tail -3

APP="$DD/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app"
[[ -d "$APP" ]] || { echo "==> ERROR: no runner at $APP" >&2; exit 1; }
# A runner without its test bundle installs cleanly and then aborts on launch,
# which reads exactly like a signing problem and sends you the wrong way.
[[ -d "$APP/PlugIns/WebDriverAgentRunner.xctest" ]] \
  || { echo "==> ERROR: $APP has no PlugIns/WebDriverAgentRunner.xctest" >&2; exit 1; }

echo "==> installing $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
xcrun devicectl device install app --device "$UDID" "$APP" --json-output /tmp/wda-install.json >/dev/null
echo "==> installed: $(jq -r '.result.installedApplications[0].bundleID // "FAILED"' /tmp/wda-install.json 2>/dev/null || echo '(install jq to see the id)')"

cat <<NEXT

==> Two things this script cannot do; both need a terminal of their own.

 1. THE TUNNEL REGISTRY — root, stays in the foreground, ONE instance for every
    phone (omit --udid to cover them all). Appium probes port 42314; without it
    the driver falls back to a path that cannot start WDA on iOS 26.
       sudo \$(command -v node) \\
         \$(find ~/.appium -type d -name appium-ios-remotexpc | head -1)/scripts/tunnel-creation.mjs \\
         --keep-open --reconnect-retries 0

 2. THE APPIUM SERVER:   appium server -p 4723

 Then create a session — usePrebuiltWDA, NOT usePreinstalledWDA (see the doc):
   {"platformName":"iOS","appium:automationName":"XCUITest",
    "appium:udid":"$UDID","appium:usePrebuiltWDA":true,
    "appium:derivedDataPath":"$DD","appium:updatedWDABundleId":"$BUNDLE",
    "appium:xcodeOrgId":"$TEAM","appium:xcodeSigningId":"Apple Development",
    "appium:wdaLocalPort":8101,"appium:wdaLaunchTimeout":180000}
NEXT
