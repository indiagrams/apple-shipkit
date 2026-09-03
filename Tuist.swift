// Tuist.swift — top-level Tuist 4 configuration for the apple-shipkit.
//
// Lives at repo root (Tuist 4 default; pre-4.0 used Tuist/Config.swift).
// Companion to app/Project.swift; both ship alongside app/project.yml so
// forkers can pick their generator at fork time via
//   bin/switch-to-tuist.sh / bin/switch-to-xcodegen.sh
// Default remains XcodeGen — see docs/MIGRATING-TO-TUIST.md and #38.
//
// compatibleXcodeVersions: .all is intentional. .upToNextMajor("15.0")
// rejects Xcode 16+ at generate time, which is a foot-gun for forkers
// upgrading Xcode mid-project. Forkers wanting a strict pin can edit
// here once they've taken ownership of their fork.

import ProjectDescription

let config = Config(
    compatibleXcodeVersions: .all,
    swiftVersion: "5.9",
    generationOptions: .options(
        resolveDependenciesWithSystemScm: false,
        disablePackageVersionLocking: false
    )
)
