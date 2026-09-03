# Switching an already-renamed fork from XcodeGen to Tuist

> **If you're forking the template fresh, prefer
> `bin/switch-to-tuist.sh` — it produces a Tuist-only
> fork in one shot.** This doc covers the in-place switch path:
> you already ran `bin/rename.sh` (or the default
> `--generator=xcodegen`) and now want to flip your existing fork
> from `app/project.yml` to `app/Project.swift`.

The fast path is one command:

```bash
bin/switch-to-tuist.sh   # idempotent + atomic-rollback (parity with bin/rename.sh)
```

That script is what `bin/refork-smoketest.sh --generator=tuist` invokes for you
at fork time. Running it standalone on an already-renamed fork is the
equivalent in-place operation.

The rest of this document explains **what** the script does (so you can
audit, adapt, or step through it manually if you prefer) and the
**non-obvious gotchas** that surfaced during validation. If you trust
the script, [Step 4 — Validate end-to-end](#step-4--validate-end-to-end)
is the only section you really need.

> **Status:** in-place switch path. The template's `main` ships both
> manifests (`Tuist.swift` + `app/Project.swift` alongside
> `app/project.yml`) and CI verifies both stay in sync on every PR
> via the 6-job matrix (3 XcodeGen + 3 Tuist parity). Tracked in
> [#34](https://github.com/indiagrams/apple-shipkit/issues/34) +
> [#38](https://github.com/indiagrams/apple-shipkit/issues/38).
>
> Validated end-to-end against this repo: a throwaway clone, ran
> `bin/switch-to-tuist.sh`, then `make check` / `make check-sim` /
> `make check-macos` all green. The script's
> `ci/test-switch-to-tuist.sh` harness re-runs that validation in CI.
>
> Generator parity is gated at multiple points, not just PR time:
> `pr.yml`'s 6-job matrix on every PR (build-only); since v1.5,
> `.github/workflows/canary-local-mode.yml`'s `[xcodegen, tuist]`
> matrix runs `fastlane release` weekly on the smoketest fork; and
> since v1.6, `release.yml` itself uses the same mint-fresh-cert-then-revoke
> path as `canary-local-mode.yml`, so every actual ship from a
> Tuist-only fork exercises the post-migration Tuist release pipeline
> through the same code path the canary validates. A Tuist-only fork's
> release pipeline is canary-validated upstream **and** validated on
> each of its own ships.
>
## Why this exists

Two-of-two r/iOSProgramming commenters on the v1.0.0 launch post
independently mentioned a Tuist preference. Real audience signal worth
acting on. The trade-off is genuine and depends on team preference:

| Aspect | XcodeGen (current) | Tuist |
|---|---|---|
| Manifest format | YAML (`project.yml`) | Swift (`Project.swift`) |
| Toolchain footprint | Single ~10 MB Go binary | ~120 MB binary; richer feature set |
| Type-safety on the manifest | Schema-validated at generate time | Compiler-enforced |
| Caching | None | Built-in incremental cache (`tuist generate`) |
| Build-graph features | None — just generates an .xcodeproj | `tuist run`, `tuist test`, `tuist cache warm` |
| Module/dependency graph awareness | None | First-class — supports modular apps cleanly |
| Distribution | Homebrew core | Homebrew Cask / mise |
| Best for | Single-app projects; minimal-deps teams | Modular monorepos; teams that want a build-graph tool |

Neither is wrong. Pick whichever your team prefers. The template
defaults to XcodeGen because it imposes the lowest cognitive load on a
first-time forker; this doc is for forkers who'd rather migrate.

## What this doc covers

- What `bin/switch-to-tuist.sh` does, surface-by-surface, so you can audit
  or adapt it
- The Tuist 4 manifest layout (`Tuist.swift` + `app/Project.swift` —
  both already on `main` after #38; this is a pointer + audit reference,
  not a "type this in" recipe)
- Edits to `Makefile`, `Brewfile`, `ci/local-check.sh`,
  `ci/local-release-check.sh`, `.github/workflows/pr.yml` that the
  script applies
- Caveats / gotchas the validation surfaced
## What this doc does not cover

- **Maintaining both XcodeGen and Tuist in lockstep.** This template's
  `main` does maintain both (verified by the 6-job CI matrix), but in
  your fork after `bin/switch-to-tuist.sh` runs, `app/project.yml` is
  gone and the XcodeGen tooling is removed. Pick one for your fork; the
  template carries both so you can pick at fork time.
- **Adopting Tuist's caching / build-graph features
  (`tuist cache warm`, `tuist run`, project-as-package).** Those are
  Tuist's actual differentiators — but they're independent of the
  XcodeGen-replacement story this doc covers. Once you've migrated, the
  Tuist docs at <https://docs.tuist.dev> are the right next read.
- **Workspaces with multiple projects.** This template has one project.
  If you're modularizing into multiple projects, see Tuist's
  [workspace guide](https://docs.tuist.dev/en/guides/develop/projects/structure)
  separately.

## Prerequisites

Tuist is **not on Homebrew core** — it ships via Homebrew Cask or
[mise](https://mise.jdx.dev/). Pick one:

```bash
# Option A — Homebrew Cask (simplest; matches the template's existing Brewfile pattern)
brew install --cask tuist

# Option B — mise (recommended by Tuist for teams who want a pinned version per project)
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
source ~/.zshrc
mise use -g tuist@latest
```

Verify:

```bash
tuist version    # NB: `tuist version` (no dashes), not `tuist --version` — Tuist 4 quirk
```

The migration was validated against Tuist **4.191.x**. Older versions
(pre-4.0) used a different `Project.swift` schema and the steps below
will not apply.

## Step 1 — `Tuist.swift` is already on `main`

Since #38, the template ships a top-level [`Tuist.swift`](../Tuist.swift)
at the repo root. You don't need to author one. If you're auditing it
or adapting it for a stricter Xcode-version pin, here's the relevant
contract:

```swift
// Tuist.swift (excerpt — see ../Tuist.swift for the full file)
let config = Config(
    compatibleXcodeVersions: .all,    // .upToNextMajor("15.0") rejects Xcode 16+; use .all unless you want a hard pin
    swiftVersion: "5.9",
    generationOptions: .options(...)
)
```

> **Gotcha — old location.** Tuist <4.0 used `Tuist/Config.swift` (a
> subdirectory). Tuist 4 emits a deprecation warning for that path and
> wants `Tuist.swift` at the repo root. The template uses the new
> location.

## Step 2 — Delete `app/project.yml` (the script does this)

`bin/switch-to-tuist.sh` runs `git rm -f app/project.yml`. The Tuist
equivalent ([`app/Project.swift`](../app/Project.swift), 1:1 with
`project.yml`) is already on `main` post-#38, so there's nothing to
author here either.

If you're auditing the translation, here's the project.yml ↔ Project.swift
mapping that produced [`app/Project.swift`](../app/Project.swift):

Key translation points from `project.yml` → `Project.swift`:

| project.yml | Project.swift |
|---|---|
| `options.bundleIdPrefix: com.example` | Set per-target `bundleId:` (Tuist has no project-wide prefix concept) |
| `options.deploymentTarget.iOS: "17.0"` | `Target.target(deploymentTargets: .iOS("17.0"))` |
| `options.developmentLanguage: en` | `Project.options(developmentRegion: "en", defaultKnownRegions: ["en"])` |
| `options.defaultConfig: Release` | `Scheme.archiveAction(configuration: .release)` per scheme |
| `settings.base.SWIFT_VERSION: 5.9` | `Project(settings: .settings(base: ["SWIFT_VERSION": "5.9", ...]))` |
| target `info.path` + `info.properties` | `Target.target(infoPlist: .extendingDefault(with: [...]))` — auto-generates the .plist |
| target `sources: [path: ...]` | `Target.target(sources: ["Shared/**", "iOS/**"])` |
| `excludes: ["Resources"]` | `.glob("macOS/**", excluding: ["macOS/Resources/**"])` |
| `info.properties.CFBundleDisplayName: $(DISPLAY_NAME)` | `infoPlist: .extendingDefault(with: ["CFBundleDisplayName": "$(DISPLAY_NAME)", ...])` (both resolve from `app/Identity.xcconfig`) |
| `CODE_SIGN_ENTITLEMENTS: iOS/App.entitlements` | `entitlements: .file(path: "iOS/App.entitlements")` |
| target-level `settings.base` | `Target.target(settings: .settings(base: [...]))` (overrides project-level) |
| `dependencies: [target: App-iOS]` | `dependencies: [.target(name: "App-iOS")]` |
| `configFiles: {Debug: Identity.xcconfig, Release: Identity.xcconfig}` | `Project(settings: .settings(configurations: [.debug(name: "Debug", xcconfig: "Identity.xcconfig"), .release(name: "Release", xcconfig: "Identity.xcconfig")]))` |
| per-target `PRODUCT_NAME: $(APP_PRODUCT_NAME)` | `Target.target(productName: "$(APP_PRODUCT_NAME)", ...)` — required; Tuist otherwise writes the target name as PRODUCT_NAME and overrides the xcconfig |
| `postCompileScripts:` | `scripts: [TargetScript.post(...)]` (see gotcha below) |
| `schemes.<name>.build.targets` | `Scheme.scheme(buildAction: .buildAction(targets: [...]))` |

> **Gotcha — UI test targets must NOT be in `buildAction.targets`.** In
> XcodeGen, `AppUITests: [test]` declares the target builds for
> the test action only. The Tuist equivalent is **omitting** the UI
> test target from `BuildAction.targets` (only include the main app
> target there) and including it in `TestAction.targets`. If you put
> the UI test target in both, `xcodebuild build -scheme App-iOS`
> will compile the UI tests under iOS device's strict-concurrency
> setting and fail on `SnapshotHelper.swift`'s actor-isolation
> warnings — the very thing the per-target
> `SWIFT_STRICT_CONCURRENCY: minimal` override is supposed to prevent.
> Empirically validated.

> **Gotcha — `TargetScript.post` argument order.** Swift's compiler
> requires `name:` before `inputPaths:` / `outputPaths:` even though
> the Tuist docs sometimes show them after. Use:
> ```swift
> TargetScript.post(
>     script: "...",
>     name: "Overwrite actool's broken AppIcon.icns ...",   // before inputPaths/outputPaths
>     inputPaths: [...],
>     outputPaths: [...]
> )
> ```

> **Gotcha — post-build script placement differs from XcodeGen.**
> XcodeGen's `postCompileScripts` puts the Run Script phase *between*
> Sources and Resources. Tuist's `TargetScript.post(...)` puts it at
> the *end* of the buildPhases list (after Resources, Frameworks,
> Embed Frameworks) but *before* Code Sign. Both placements run before
> Code Sign, so the icon overwrite remains effective. Verify
> empirically: after a clean build, `shasum` the `.icns` in the built
> .app's `Contents/Resources/` against `app/macOS/Resources/AppIcon.icns`
> — they must match.

## Step 3 — Ancillary script edits (the script does these)

`bin/switch-to-tuist.sh` applies the diffs below in one pass. They're
documented here as audit reference — if you'd rather step through
manually, you can apply each diff yourself; the result is identical
to running the script. The diffs are also what the 3 Tuist parity CI
jobs in `.github/workflows/pr.yml` exercise on every template PR
(via `bin/switch-to-tuist.sh --force`), so any drift between this
doc and the script fails CI immediately:

### `Brewfile`

```diff
-brew "xcodegen"        # app/project.yml → app/App.xcodeproj
+cask "tuist"           # app/Project.swift → app/App.xcodeproj
```

(If you went the mise route in Step 0, add a `mise.toml` instead and
drop the Brewfile line entirely.)

### `Makefile`

```diff
 bootstrap:
 	brew bundle
 	lefthook install
-	cd app && xcodegen generate
+	cd app && tuist generate --no-open
 	bundle install
…
 generate:
-	cd app && xcodegen generate
+	cd app && tuist generate --no-open
```

### `ci/local-check.sh`

```diff
 ensure_xcodeproj() {
   require_cmd xcodebuild
-  require_cmd xcodegen
-  step "app: xcodegen generate"
-  ( cd app && xcodegen generate >/dev/null )
+  require_cmd tuist
+  step "app: tuist generate"
+  ( cd app && tuist generate --no-open >/dev/null )
 }
```

### `ci/local-release-check.sh`

```diff
-step "xcodegen generate"
-( cd app && xcodegen generate >/dev/null )
+step "tuist generate"
+( cd app && tuist generate --no-open >/dev/null )
```

### `.github/workflows/pr.yml`

All three originally-XcodeGen jobs (`app-ios-device`, `app-ios-sim`,
`app-macos`) repeat the same install + generate steps. The script
rewrites each — equivalent diffs:

```diff
-      - name: install xcbeautify + xcodegen
-        run: brew install xcbeautify xcodegen
+      - name: install xcbeautify
+        run: brew install xcbeautify
+
+      - name: install tuist
+        run: brew install --cask tuist

-      - name: regenerate Xcode project
+      - name: regenerate Xcode project (Tuist)
         working-directory: app
-        run: xcodegen generate
+        run: tuist generate --no-open
```

> **Optional:** if you want to cache the Tuist binary across CI runs to
> shave the `brew install` minute, swap to
> [`actions/cache`](https://github.com/actions/cache) on
> `~/.cache/tuist` plus mise, or use the community
> [`tuist/setup-tuist`](https://github.com/tuist/setup-tuist) action.
> Not necessary at this template's size; flagged for completeness.

### `.gitignore`

Tuist generates a `Derived/` cache directory inside `app/` and an
`.xcworkspace` alongside the `.xcodeproj`. Add them:

```diff
 # XcodeGen-generated project (regenerated from project.yml)
+# Tuist-generated project (regenerated from app/Project.swift)
 app/App.xcodeproj
+app/App.xcworkspace
+app/Derived/
+.tuist/
```

(Keep the existing `app/App.xcodeproj` rule — Tuist still emits
the `.xcodeproj` for `xcodebuild` to consume.)

### `bin/rename.sh`

The rename script substitutes `HelloApp`, `com.example.helloapp`, and
the maintainer email across tracked files. The identity values live in
`app/Identity.xcconfig`, which both manifests reference as `$(VAR)`, so
the migration moves no identity string at all.
The script's `git ls-files`-based grep already handles
this — no edit required *if* you ran the migration on a fresh fork
before any rename. **But:** if you migrate first, then rename, verify
with:

```bash
git grep "com.example.helloapp" app/Project.swift   # should show 4 hits before rename
bin/rename.sh --email=you@example.com   # then edit app/Identity.xcconfig
git grep "com.example.helloapp" app/Project.swift   # should be empty after rename
```

`bin/rename.sh` no longer substitutes identity in either manifest.
Bundle id, product name, display name and copyright are `$(VAR)`
references into `app/Identity.xcconfig`, which both generators read
natively, so neither manifest carries a literal for the migration to
miss and nothing here needs a generator-specific edit.

## Step 4 — Validate end-to-end

The acceptance criterion for this migration (per
[issue #34](https://github.com/indiagrams/apple-shipkit/issues/34))
is "`make check` passing post-migration on a fresh fork." Run all
three signal paths:

```bash
# Sanity: the project regenerates cleanly
cd app && tuist generate --no-open && cd ..

# Three signal paths — all must be green
make check          # iOS device (primary)
make check-sim      # iOS Simulator (backup)
make check-macos    # macOS

# Confirm the macOS app got the hand-rolled .icns (not actool's broken 4-size)
shasum -a 256 \
  app/macOS/Resources/AppIcon.icns \
  ~/Library/Developer/Xcode/DerivedData/App-*/Build/Products/Debug/HelloApp.app/Contents/Resources/AppIcon.icns
# Both hashes must match.
```

If all three checks are green and the `shasum` lines match, the
migration is complete.

## Caveats

- **Tuist generates BOTH `App.xcodeproj` AND `App.xcworkspace`.**
  XcodeGen only generates the `.xcodeproj`. The existing build commands
  in `ci/local-check.sh` and `ci/local-release-check.sh` use
  `-project app/App.xcodeproj` — they keep working. If you ever
  open the project in Xcode, prefer the `.xcworkspace`.
- **Tuist version pinning.** Use `mise.toml` (mise) or commit a
  `.tuist-version`-style pin to ensure CI uses the same Tuist version
  as your local. The template's CI installs `--cask tuist` which
  always pulls latest; for stability across a long-lived fork, pin.
- **Product name.** Both manifests set `PRODUCT_NAME` on the two app
  targets from `$(APP_PRODUCT_NAME)` in `app/Identity.xcconfig`, so the
  built bundle is `<APP_PRODUCT_NAME>.app` under either generator and the
  two agree. (Without an explicit `productName:` Tuist would sanitize the
  target name `App-iOS` → `App_iOS` and XcodeGen would keep the hyphen —
  that is why the Tuist manifest passes `productName:` explicitly.) The
  final `.ipa` / `.pkg` names are the constants `App-<version>.ipa` /
  `App-<version>.pkg`, written by `ci/local-release-check.sh` and read by
  `fastlane/Fastfile`, independent of the bundle name.
- **`SWIFT_STRICT_CONCURRENCY: minimal` on the UI test target only.**
  This is the same override XcodeGen carries (per
  [`app/project.yml`](../app/project.yml) line 129). Tuist applies it
  identically when set as `Target.target(settings: .settings(base: [...]))`.
- **`compatibleXcodeVersions`.** Don't pin to a single major if you
  want forward compatibility — `.upToNextMajor("15.0")` rejects Xcode
  16+ at generate time. Use `.all` for a single-app template, or pin
  more strictly only if you have a CI-enforced reason.

## Verification (what "done" looks like)

After migrating on a fresh fork:

- [ ] `tuist generate --no-open` completes with no errors or warnings
      (deprecation warnings about old config locations should be gone).
- [ ] `make check` green.
- [ ] `make check-sim` green.
- [ ] `make check-macos` green.
- [ ] All 6 CI checks (3 XcodeGen — now using Tuist after the script
      mutates the workflow — plus 3 Tuist parity) green on the PR.
- [ ] The macOS app bundle's `.icns` matches `app/macOS/Resources/AppIcon.icns`
      by SHA-256 (post-build script ran correctly).
- [ ] `ruby bin/preflight-identity.rb` exits 0 — every key in
      `app/Identity.xcconfig` resolves through `Project.swift` too.
- [ ] Signed release flow: `fastlane release tag:v0.0.0 skip_upload:true skip_tag:true`
      produces signed `.ipa` + `.pkg` artifacts in `build/`. (Optional
      but recommended if you ship via fastlane.)

## Reference `Project.swift`

The full `Project.swift` lives at [`app/Project.swift`](../app/Project.swift)
on `main` — that's the file `tuist generate` reads. Read or copy from
there directly; this doc no longer carries an inline skeleton (it
bit-rotted twice during validation). Notable layout choices:

- 6 targets: `App-iOS`, `App-macOS`, `AppUITests`, `AppMacOSUITests`,
  `AppTests`, `AppMacOSTests`
- 2 schemes: `App-iOS`, `App-macOS` (UI test targets in
  `testAction:` only — see the gotcha above)
- macOS post-build script (`macIconScript`) for the AppIcon.icns
  override
- Project-level + per-target settings split (matches `project.yml`'s
  shape)

## References

- [Tuist documentation](https://docs.tuist.dev)
- [`Project.swift` API reference](https://docs.tuist.dev/en/references/project-description/structs/project)
- [`Target.target(...)` API reference](https://docs.tuist.dev/en/references/project-description/structs/target)
- [Tuist 4 release notes](https://docs.tuist.dev/en/contributors/principles/changelog)
- [XcodeGen project.yml schema](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md) (for cross-reference during migration)
- This template — [`SCOPE.md`](../SCOPE.md), [`docs/PRINCIPLES.md`](PRINCIPLES.md), [`app/project.yml`](../app/project.yml) (the source the script switches away from), [`app/Project.swift`](../app/Project.swift) (the destination), [`bin/switch-to-tuist.sh`](../bin/switch-to-tuist.sh) (the script this doc explains)
