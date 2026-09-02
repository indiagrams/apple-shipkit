// app/Project.swift — Tuist 4 manifest for App, the template's project structure.
//
// 1:1 equivalent of app/project.yml. Both ship on `main`; bin/rename.sh's
// `--generator=tuist|xcodegen` flag (see #38) selects which one a fresh
// fork keeps post-rename. CI runs both via .github/workflows/pr.yml's
// 6-job matrix so any drift between the two manifests fails fast.
//
// When editing this file, also update app/project.yml (and vice versa).
// The CI matrix is the source of truth — both must produce a
// build-green App.xcodeproj.
//
// Identity — bundle id, product name, display name, copyright — is NOT in
// this file. Every identity setting below is a $(VAR) reference into
// Identity.xcconfig, attached per configuration in `Project(settings:)`.
// An xcconfig value is overridden by anything a manifest writes into the
// .pbxproj, so a value here would silently win over the tracked source of
// truth.
//
// Tuist has no pre-generation hook, and a guard embedded in this manifest
// is skipped whenever the manifest cache is warm — the one case it would be
// for (only Identity.xcconfig changed) is the case it cannot fire in. The
// identity preflight for the Tuist path is ci/check-identity.sh, run as
// plain text in pr.yml's config job.

import ProjectDescription

// MARK: - Shared settings

let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "MARKETING_VERSION": "0.0.1",
    "CURRENT_PROJECT_VERSION": "1",
    // DEVELOPMENT_TEAM is deliberately absent. The Apple Team ID resolves from
    // the gitignored app/Local.xcconfig through Identity.xcconfig's optional
    // include, and appears in no tracked build or signing configuration.
    // Setting it here would put the value in git and override the include. A
    // clone without Local.xcconfig gets a named failure from
    // `bin/preflight-identity.rb --require-team`, not from Xcode.
    "CODE_SIGN_STYLE": "Automatic",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "NO",
    "GCC_TREAT_WARNINGS_AS_ERRORS": "NO",
]

// MARK: - iOS app

let iosInfoPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "$(DISPLAY_NAME)",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    // Set here, as a plist key, exactly as the macOS target does. An
    // INFOPLIST_KEY_NSHumanReadableCopyright build setting reaches the
    // bundle only under GENERATE_INFOPLIST_FILE = YES, and this target's
    // plist is this dictionary (GENERATE_INFOPLIST_FILE = NO), so the setting
    // resolved in -showBuildSettings but the built plist had no key.
    "NSHumanReadableCopyright": "$(COPYRIGHT)",
    "UILaunchScreen": .dictionary([:]),
    "UIApplicationSceneManifest": .dictionary([
        "UIApplicationSupportsMultipleScenes": false,
    ]),
    "UISupportedInterfaceOrientations": .array([
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ]),
    "UISupportedInterfaceOrientations~ipad": .array([
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ]),
    "ITSAppUsesNonExemptEncryption": false,
]

// The productName argument is not optional and must precede bundleId (Tuist
// enforces the argument order). Tuist writes a per-target PRODUCT_NAME equal
// to the target name when it is omitted, which would override the xcconfig
// and make the two generators disagree. Tuist prints a cosmetic "Invalid
// product name '$(APP_PRODUCT_NAME)'" warning because it validates the
// string before it knows it is a build-setting reference; generation
// succeeds and PRODUCT_NAME resolves from Identity.xcconfig regardless.
let iosTarget = Target.target(
    name: "App-iOS",
    destinations: [.iPhone, .iPad],
    product: .app,
    productName: "$(APP_PRODUCT_NAME)",
    bundleId: "$(BUNDLE_ID)",
    deploymentTargets: .iOS("17.0"),
    infoPlist: .extendingDefault(with: iosInfoPlist),
    sources: ["Shared/**", "iOS/**"],
    resources: [
        "iOS/Assets.xcassets",
        "Shared/PrivacyInfo.xcprivacy",
        "Shared/Localizable.xcstrings",
    ],
    entitlements: .file(path: "iOS/App.entitlements"),
    settings: .settings(base: [
        "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID)",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "SUPPORTS_MACCATALYST": "NO",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.utilities",
    ])
)

// MARK: - macOS app

let macInfoPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "$(DISPLAY_NAME)",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
    "LSApplicationCategoryType": "public.app-category.utilities",
    "NSHumanReadableCopyright": "$(COPYRIGHT)",
    "NSPrincipalClass": "NSApplication",
    // CFBundleIconName intentionally NOT set — its presence makes Sonoma+
    // prefer Assets.car AppIcon (which has actool's broken 4-size set).
    // The post-build script below installs the hand-rolled .icns instead.
    "CFBundleIconFile": "AppIcon",
    "ITSAppUsesNonExemptEncryption": false,
]

// Overwrites actool's broken 4-size .icns with the hand-rolled 10-size
// version. Tuist places `.post` scripts at the END of buildPhases (after
// Resources / Frameworks / Embed Frameworks) but before Code Sign — so
// the .icns gets overwritten *after* actool emits its broken version,
// and the signed bundle ships with the hand-rolled 10-size set.
let macIconScript: TargetScript = .post(
    script: """
    set -euo pipefail
    /bin/cp "$SCRIPT_INPUT_FILE_0" "$SCRIPT_OUTPUT_FILE_0"
    echo "Overwrote $SCRIPT_OUTPUT_FILE_0 with hand-rolled 10-size .icns"
    """,
    name: "Overwrite actool's broken AppIcon.icns with hand-rolled 10-size version",
    inputPaths: ["$(SRCROOT)/macOS/Resources/AppIcon.icns"],
    outputPaths: ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/AppIcon.icns"]
)

let macTarget = Target.target(
    name: "App-macOS",
    destinations: [.mac],
    product: .app,
    productName: "$(APP_PRODUCT_NAME)",
    bundleId: "$(BUNDLE_ID)",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .extendingDefault(with: macInfoPlist),
    sources: [
        "Shared/**",
        // macOS/Resources/ holds the hand-rolled AppIcon.icns + source 1024 PNG.
        // Excluded here because the post-build script copies the .icns into
        // the .app over actool's broken 4-size version.
        .glob("macOS/**", excluding: ["macOS/Resources/**"]),
    ],
    resources: [
        "macOS/Assets.xcassets",
        "Shared/PrivacyInfo.xcprivacy",
        "Shared/Localizable.xcstrings",
    ],
    entitlements: .file(path: "macOS/App.entitlements"),
    scripts: [macIconScript],
    settings: .settings(base: [
        "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID)",
        // Suppress actool's auto-injection of CFBundleIconName=AppIcon.
        // Empty value = actool emits Assets.car as before but does not set
        // the key, so macOS reads CFBundleIconFile → our hand-rolled .icns.
        "ASSETCATALOG_COMPILER_APPICON_NAME": "",
    ])
)

// MARK: - UI test targets
//
// The four test-bundle identifiers derive from $(BUNDLE_ID) with a fixed
// suffix, exactly as app/project.yml does, so the xcconfig stays at four
// keys. No productName: on any test target — each keeps its target name, so
// the two iOS .xctest bundles never collide.

let iosUITestTarget = Target.target(
    name: "AppUITests",
    destinations: [.iPhone, .iPad],
    product: .uiTests,
    bundleId: "$(BUNDLE_ID).uitests",
    deploymentTargets: .iOS("17.0"),
    infoPlist: .default,
    sources: ["UITests/**", "Shared/AccessibilityIdentifiers.swift"],
    dependencies: [.target(name: "App-iOS")],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "App-iOS",
        // SnapshotHelper.swift is fastlane-shipped and predates Swift 6's
        // strict-by-default concurrency model. Pin this target to Swift 5
        // mode so the file compiles unmodified — base SWIFT_VERSION is 6.0.
        "SWIFT_VERSION": "5.9",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
    ])
)

let macUITestTarget = Target.target(
    name: "AppMacOSUITests",
    destinations: [.mac],
    product: .uiTests,
    bundleId: "$(BUNDLE_ID).macuitests",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: ["MacOSUITests/**", "Shared/AccessibilityIdentifiers.swift"],
    dependencies: [.target(name: "App-macOS")],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "App-macOS",
        // AppStoreScreenshotTests overrides XCTestCase.setUpWithError /
        // tearDownWithError in a @MainActor class — Swift 6 errors on
        // main-actor-isolated mutation in nonisolated overrides. Pin this
        // target to Swift 5 mode (parallel to iosUITestTarget).
        "SWIFT_VERSION": "5.9",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
    ])
)

// MARK: - Unit test targets (sanity tests; forks should add real tests here)

let iosUnitTestTarget = Target.target(
    name: "AppTests",
    destinations: [.iPhone, .iPad],
    product: .unitTests,
    bundleId: "$(BUNDLE_ID).tests",
    deploymentTargets: .iOS("17.0"),
    infoPlist: .default,
    sources: ["Tests/**"],
    dependencies: [.target(name: "App-iOS")],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "App-iOS",
    ])
)

let macUnitTestTarget = Target.target(
    name: "AppMacOSTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "$(BUNDLE_ID).mactests",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: ["MacOSTests/**"],
    dependencies: [.target(name: "App-macOS")],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "App-macOS",
    ])
)

// MARK: - Schemes

let iosScheme: Scheme = .scheme(
    name: "App-iOS",
    shared: true,
    // NB: only the main app target — UI tests live in testAction only.
    // Including AppUITests here would compile it during plain
    // `xcodebuild build` and trip strict-concurrency errors that the
    // per-target SWIFT_STRICT_CONCURRENCY=minimal override can't suppress.
    buildAction: .buildAction(targets: ["App-iOS"]),
    testAction: .targets(
        ["AppUITests", "AppTests"],
        configuration: .debug
    ),
    runAction: .runAction(configuration: .debug, executable: "App-iOS"),
    archiveAction: .archiveAction(configuration: .release)
)

let macScheme: Scheme = .scheme(
    name: "App-macOS",
    shared: true,
    buildAction: .buildAction(targets: ["App-macOS"]),
    testAction: .targets(
        ["AppMacOSUITests", "AppMacOSTests"],
        configuration: .debug
    ),
    runAction: .runAction(configuration: .debug, executable: "App-macOS"),
    archiveAction: .archiveAction(configuration: .release)
)

// MARK: - Project

// `name:` governs both App.xcodeproj and App.xcworkspace (Tuist emits both;
// XcodeGen emits only the .xcodeproj). Identity.xcconfig is the base layer of
// each configuration; it ends in `#include? "Local.xcconfig"`, the gitignored
// per-clone file that carries DEVELOPMENT_TEAM.
let project = Project(
    name: "App",
    options: .options(
        defaultKnownRegions: ["en"],
        developmentRegion: "en"
    ),
    settings: .settings(
        base: baseSettings,
        configurations: [
            .debug(name: "Debug", xcconfig: "Identity.xcconfig"),
            .release(name: "Release", xcconfig: "Identity.xcconfig"),
        ],
        defaultSettings: .recommended
    ),
    targets: [iosTarget, macTarget, iosUITestTarget, macUITestTarget, iosUnitTestTarget, macUnitTestTarget],
    schemes: [iosScheme, macScheme]
)
