# UI automation

Two layers, and most projects need only the first.

| | Layer 1 — **in-process XCUITest** | Layer 2 — **the device rig** |
|---|---|---|
| Drives | your own app | the whole phone, any app |
| Runs on | simulator, device, macOS | physical iPhone only |
| Needs | Xcode (already required) | node, Appium, a signed WDA, a root tunnel |
| Wired into `make check` / `make verify` | yes | **no — opt-in, always** |
| Reach | your views and their accessibility tree | SpringBoard, Settings, Messages, Photos, system permission alerts, several phones at once |

Start at Layer 1. Reach for Layer 2 only when the thing under test is genuinely
outside your app: a permission alert, the share sheet, a universal link tapped
for real in Messages, or two devices talking to each other.

Both layers read the **same accessibility tree**, so both reward putting stable
identifiers in `app/Shared/AccessibilityIdentifiers.swift` — it is compiled into
the app *and* the UI-test targets, so a renamed button breaks the build instead
of a test three weeks later.

---

## Layer 1 — in-process XCUITest

`app/UITests/` and `app/MacOSUITests/` are already wired by both project
generators. Two helpers here remove the sharp edges that bite everyone.

### Run against a real device when one is plugged in

```sh
xcodebuild test -scheme App -destination "$(bin/uitest-destination.sh)" ...
```

Prefers a connected iPhone and falls back to a simulator. `FORCE_SIMULATOR=1`
pins the simulator (CI, screenshots); `SIMULATOR_NAME` picks which one. A
simulator-only habit hides exactly the behaviour a device shows first —
permission alerts, universal links, backgrounding, the real keyboard.

### See why a UI test failed

```sh
bin/dump-failure-screenshots.sh /path/to/Result.xcresult [output-dir]
```

**`xcresulttool export attachments --only-failures` does not do what its name
says.** It looks for attachments inside XCTest *failure activities*, not
attachments taken at test scope — and a `tearDown` screenshot is at test scope,
so the flag returns nothing. Drop the flag and XCTest floods you instead: every
`waitForExistence` poll auto-generates a "Debug description" and a binary "UI
Snapshot", so one 300-second wait buries the real PNG under 300+ attachments.
The script exports per failed test id and keeps only the PNGs.

Attach something worth dumping:

```swift
override func tearDown() {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "final-state"
    shot.lifetime = .keepAlways
    add(shot)
    super.tearDown()
}
```

### Conventions worth stealing

- **Name test files after the behaviour cluster, not the view.** One coherent
  capability a user can exercise — `VaultUITests`, `RecoveryUITests` — survives
  a refactor that splits a view in two.
- **If you run suites per platform, they must run identical phases in identical
  order.** A suite that quietly diverges passes locally and masks a regression on
  the other platform. That is a real bug someone shipped, not a hypothetical.
- **Clean up in an `EXIT` trap, not at the end of the happy path.** A test run
  that dies half way still owes you a teardown.

---

## Layer 2 — the device rig (opt-in)

⚠ **Everything below was measured on iOS 26.6.2, on iPhone 12s, in September
2026.** Apple moves these surfaces. Treat any ⛔ as "was true then, re-test
before believing it" and re-measure on a new major version.

### What it can and cannot do

| | |
|---|---|
| Tap, swipe, type, hardware buttons | ✅ |
| Read any app's accessibility tree, with real frames | ✅ |
| Screenshots, device syslog | ✅ |
| Several phones concurrently, one Appium server | ✅ (measured with two) |
| **Tap a link in Messages — the real universal-link path** | ✅ |
| System permission alerts | not verified; they are SpringBoard's and appear in its tree |
| Lock the device | ✅ |
| **Unlock the device** | ⛔ see below |
| Toggle VoiceOver on/off | ✅ |
| **Navigate using VoiceOver gestures** | ⛔ see below |
| **Scan a QR code** | ⛔ needs a camera pointed at a screen; iOS cannot inject camera frames |
| Face ID | ⛔ |

### Setup

```sh
npm install -g appium && appium driver install xcuitest
bin/device-rig/install-wda.sh <UDID> /tmp/wda-<name>      # per phone
```

Then two processes, each in its own terminal, both of which must stay up:

```sh
# 1. the tunnel registry — ROOT, foreground, ONE instance for ALL phones
sudo $(command -v node) \
  $(find ~/.appium -type d -name appium-ios-remotexpc | head -1)/scripts/tunnel-creation.mjs \
  --keep-open --reconnect-retries 0

# 2. the server
appium server -p 4723
```

`bin/device-rig/drive.py` holds the session primitives. Import it; don't run it.

### Scaling to as many phones as you need

Nothing here is two-phone shaped. One tunnel registry and one Appium server serve
every phone; each phone gets one WDA install and one session.

```sh
# one install per phone — the derived-data default is /tmp/wda-<UDID>,
# already unique per device, which is the rule below satisfying itself
for udid in $(xcrun xctrace list devices | grep -E "iPhone.*\(" | grep -iv simulator \
                | sed 's/.*(\(.*\))/\1/'); do
  bin/device-rig/install-wda.sh "$udid"
done

# one tunnel for ALL of them — omit --udid
sudo $(command -v node) \
  $(find ~/.appium -type d -name appium-ios-remotexpc | head -1)/scripts/tunnel-creation.mjs \
  --keep-open --reconnect-retries 0
```

**Exactly four capabilities differ per phone, and only one needs a convention
you invent:** `udid`, `derivedDataPath` (the install script's default already
makes it unique), `mjpegServerPort` if you stream, and **`wdaLocalPort`, which
you must allocate yourself** — `8100 + n` is as good a rule as any: 8101, 8102,
8103… That is the *host* side. The device side stays **8100 on every phone**, so
set `wdaRemotePort: 8100` explicitly; Appium otherwise derives it from
`wdaLocalPort` and probes a port WDA is not listening on.

**The WDA bundle id may be identical on every phone.** Appium's teardown is
UDID-scoped, so a session on one phone cannot kill another's runner.

⚠ **The real ceiling is Apple's, not this tooling's.** A development
provisioning profile registers each device against your membership, and the
allowance is per device type per membership year — and the slots do not free up
when you unregister. A large rig is a provisioning decision before it is a test
decision.

### The four things that will cost you a day each

**1. A dev-signed WDA expires after seven days.** When sessions stop launching
WebDriverAgent, check the calendar before you touch a capability. Re-running
`install-wda.sh` is the whole fix. This is a weekly chore for as long as you
depend on the rig.

**2. `usePreinstalledWDA` does not work on iOS 26.** It is the capability every
guide recommends, because it avoids `xcodebuild` entirely. On 26.6 the standalone
runner installs, launches, and aborts in under two seconds inside
`+[XCTRunnerDaemonSession sharedSession]` — by `devicectl` *and* by RemoteXPC
alike. Use **`usePrebuiltWDA: true`** instead: Appium runs `xcodebuild
test-without-building` against the tree `install-wda.sh` already built, so
nothing recompiles per session.

**3. Appium needs its OWN tunnel registry, on port 42314.** It is not
`pymobiledevice3`'s tunnel and cannot use one. Without it the driver falls back
to a `devicectl` path that cannot start WDA on this OS, and the only clue is one
line in its log: `RemoteXPC devices listing unavailable: Tunnel registry port not
found`. Take that line at face value.

**4. Per-device capabilities: exactly four differ, and one is not obvious.**
`udid`, `wdaLocalPort` (host side), `derivedDataPath` — two builds in one root
collide on the SQLite build lock — and `mjpegServerPort` if streaming. The WDA
**bundle id may be identical** on every phone; teardown is UDID-scoped, so a
session on one phone cannot kill another's runner. Note that Appium derives the
*device-side* port from `wdaLocalPort` when `wdaRemotePort` is unset, while WDA
listens on 8100; set `wdaRemotePort: 8100` explicitly and skip the confusion.

### Locking, unlocking, and why a passcode will not help

`mobile: lock` works. `mobile: unlock` does not, and neither does the `seconds:`
auto-unlock. Both reduce to WDA's `fb_unlockScreen`, which is *press Home twice
and wait*:

```objc
[self pressButton:XCUIDeviceButtonHome];   // twice, with a cool-off
return spinUntilTrue(^{ return !fb_isLocked; });   // else "Timed out while waiting..."
```

There is **no passcode entry, no typing, and no parameter that takes a
passcode** — so knowing it buys nothing, because nothing could consume it. On a
phone with no passcode the double Home press unlocks fine.

⚠ **Do not strip the passcode off a personal phone to get around this.** iOS
requires resetting Face ID first, and a test rig that is also someone's daily
phone is not worth weakening. Put a hand in the loop at a scripted beat instead:
lock by hand, launch backgrounded with `devicectl device process launch
--no-activate`, hold while the capture runs, unlock by hand when the script says
so. A dedicated passcode-free rig phone makes it automatic — that is a decision
about buying a device, not about weakening this one.

### VoiceOver: the toggle automates, the gestures do not

Turning VoiceOver on and off is fully automatable through Settings. **But WDA's
synthesised touches bypass VoiceOver's gesture layer entirely** and arrive at the
app as ordinary touches. Measured with VoiceOver confirmed on: flicks did not
move the focus ring; a swipe near the left edge triggered the app's own
back-navigation, which real VoiceOver would have consumed; and a single tap
*activated* a row rather than selecting it. So VoiceOver gesture navigation and
the rotor cannot be tested this way.

✅ **You almost certainly do not need it on.** The accessibility tree XCUITest
already reads **is** what VoiceOver speaks — labels, values, traits, traversal
order — and it reads the same with VoiceOver off. "Reads in the written order"
and "nothing truncated" are checkable straight from the tree: deterministic,
diffable, no speech to interpret.

### Privacy

Reading another app's hierarchy pulls its real content into your dump. Messages
means real conversations — names, phone numbers, email addresses. Keep those
dumps out of the repo, target elements individually instead of dumping the whole
tree, and never commit one.

---

## The two rules

**1. Score every action by its CONSEQUENCE, never by the return value.** A tap
that lands nowhere returns success with a null value; an HTTP 200 means the
request parsed, not that the phone moved. Check the frontmost bundle id, a log
line, or the element's own value. Both layers, always.

**2. Never let the app under measurement be launched by XCTest** when you are
measuring launch, backgrounding, or lifecycle. Launch it with `devicectl`, or by
tapping its icon. `xcodebuild` launching *WebDriverAgent* is fine — it never
touches your app.

And the lesson underneath both: **an instrument you cannot see with produces
confident nonsense.** Get the screen and the log before you score anything.
