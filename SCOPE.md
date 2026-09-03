# Scope

This template ships **infrastructure around iOS + macOS apps**, not application code.

The framing was crystallized by an early forker on r/iOSProgramming: *"stuff around the project, not inside the project."* That's the contribution principle.

## The test

Before opening an enhancement issue or PR, ask:

> **Does this addition require modifying Swift source files in `app/Shared/` to use it?**

- **No** → around the project; in scope. PRs welcome.
- **Yes** → inside the project; deliberately out of scope.

That's the whole rule. It's tight on purpose: it gives every contributor and reviewer a single test to run, and it keeps the maintenance surface focused.

## In scope (around the project)

Anything in these categories typically passes the test:

| Category | Examples |
|----------|----------|
| **Build / project tooling** | XcodeGen, Tuist, custom scripts that regenerate `.xcodeproj` |
| **CI providers** | GitHub Actions (current), Bitrise, CircleCI, GitLab CI alternatives |
| **Release pipelines** | fastlane (current), Apple-native (`xcodebuild` + `xcrun notarytool` + ASC API direct), TestFlight upload helpers |
| **Signing helpers** | `fastlane match`, manual cert/profile management scripts, expiry notifiers |
| **Linting + formatting** | SwiftLint, SwiftFormat, `swift-format` |
| **Test scaffolding** | XCTest setup, XCUITest harness, snapshot testing config (e.g., `swift-snapshot-testing`), `.xctestplan` files |
| **Documentation tooling** | DocC scaffold, README structure templates |
| **Security / audit tooling** | CodeQL workflow, secret scanners (gitleaks, truffleHog), pre-release audit runbooks |
| **Developer-experience helpers** | preflight installers, fork-rename scripts, version-bump scripts, lefthook / git hooks |
| **App Store / metadata tooling** | Screenshot automation, App Store Connect API key bootstrap, App Store metadata templates |
| **Distribution (Mac)** | Notarization scripts, DMG packaging, Sparkle config (config-only — no app code) |

## Out of scope (inside the project) — and why

These are **deliberately** not in the template, and PRs adding them will be politely declined with a pointer back to this doc:

| Category | Why it's out |
|----------|--------------|
| **Networking libraries** (Alamofire, Moya, Apollo) | Every team has a strong opinion; shipping any choice is wrong for someone |
| **Persistence** (Core Data, SwiftData, Realm, GRDB) | Same |
| **Auth providers** (Sign in with Apple, Auth0, Firebase Auth, OAuth wrappers) | Same |
| **UI framework opinions** (UIKit-first, SwiftUI-first, hybrid scaffolding) | Same |
| **State management** (TCA, Redux, custom architectures) | Same |
| **Crash reporters / analytics SDKs** (Sentry, Bugsnag, Crashlytics, Firebase, Mixpanel) | Require `import X` + SDK init in `App.swift` — modify app source files |
| **Subscription / paywall libraries** (RevenueCat, Glassfy) | Same — modify app source files; lock in a vendor |
| **Push-notification SDKs** (OneSignal, etc.) | Same |
| **Logging frameworks** (CocoaLumberjack) | Replace `print` calls in app source — `os_log` is Apple-native and stays in scope |
| **Auto-update frameworks** (Sparkle runtime integration) | Sparkle *config* is in scope; the runtime initialization in `App.swift` is not |

The pattern: **app-layer dependencies that get force-fed onto every forker are out**, regardless of how popular the library is. The forker can add what they need; the template should not subtract what they don't.

## How to propose an enhancement

1. **Run the test** above on your proposed addition.
2. **File an issue** stating: (a) what you'd add, (b) the answer to the test, (c) the specific value it adds, (d) any references (Reddit thread, prior art, related tools).
3. **For in-scope items:** PRs accepted. If you're proposing a parallel maintained implementation (e.g., a Tuist variant alongside XcodeGen), note the maintenance trade-off — documentation-only paths are usually preferred over parallel implementations.
4. **For out-of-scope items:** the issue gets closed with a reference to this doc. No hard feelings — this is what predictable scope looks like.

## Worked examples

Two recent classifications from r/iOSProgramming feedback (v1.0.0 launch):

| Request | Test answer | Verdict |
|---------|-------------|---------|
| **Tuist variant or migration documentation** | No — replaces `project.yml` (XcodeGen) with `Project.swift` (Tuist) at the project-config layer; app source untouched | In scope; tracked in [#TBD] |
| **Apple-native release pipeline** (`xcodebuild` + `notarytool` + ASC API direct) | No — lives in `Makefile` + `ci/` scripts + GitHub Actions workflows; app source untouched | In scope; tracked in [#TBD] |

If a hypothetical request came in for, say, *"add Sentry for crash reporting"* — the test answer would be **yes** (it requires `import Sentry` + `SentrySDK.start(...)` in `App.swift`), so it would be declined as out of scope.

## Why this discipline matters

Every accepted enhancement carries an *ongoing* maintenance cost: CI keeps running it, dependencies need updating, breaking changes need handling, edge cases need debugging. The "around the project" framing keeps that cost focused on a coherent surface (build, test, sign, ship, distribute) rather than ballooning into "every iOS dev tool ever."

The lower the cognitive load on first-time forkers, the more likely they finish the rename and ship something. Aggressive scope discipline serves that goal.
