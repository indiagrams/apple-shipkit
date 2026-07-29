import XCTest

/// macOS App Store screenshot capture.
///
/// Run via: `ci/take-screenshots.sh --macos-only` (or `--upload` to push to ASC).
///
/// Each `attachScreenshot(...)` call attaches a PNG to the xcresult bundle.
/// `ci/extract-mac-screenshots.sh` extracts them into `fastlane/screenshots/en-US/`
/// where `fastlane mac upload_screenshots` (deliver) infers device type from
/// PNG dimensions.
///
/// fastlane snapshot is iOS-only — that's why this is a separate XCUITest path.
@MainActor
final class AppStoreScreenshotTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testScreenshot_01_Home() throws {
        // Skip on headless GitHub Actions runners.
        //
        // `app.activate()` below requires a GUI session to bring the window
        // to the foreground. On macos-15-arm64 image 20260520+ (macOS 15.7.7+)
        // the headless runner session refuses to receive focus, so activate()
        // sits for ~60s, then XCTest records "Failed to activate application
        // '<App>.app' (current state: Running Background)". With
        // `continueAfterFailure = false`, the rest of the test (window check,
        // File → New Window fallback, screenshot capture) never runs.
        //
        // Detection: macOS XCUITest spawns the runner via launchd, which
        // scrubs env vars — `ProcessInfo.processInfo.environment["CI"]` and
        // `["GITHUB_ACTIONS"]` are NOT visible inside the runner even though
        // they're set on the workflow. The home directory, however, *is*
        // inherited from the launchd user session: GH-Actions macos-* runners
        // always log in as `runner` (HOME = `/Users/runner`), a path that
        // can't match any developer Mac (HOME there is `/Users/<username>`).
        //
        // The screenshot test exists for `make screenshots` (run locally or
        // via a GUI-capable runner), not for CI smoke validation — the
        // `app (macOS)` matrix cells in pr.yml already get compile-coverage
        // of this file, plus runtime coverage of `HelloAppMacOSTests` (the
        // non-UI unit test) via the same `xcodebuild test` invocation. Skip
        // here with XCTSkip so xcodebuild exits 0; locally the test runs in
        // full.
        if NSHomeDirectory() == "/Users/runner" {
            throw XCTSkip("Skipped on headless GitHub Actions runner; runs in full locally via `make screenshots`.")
        }

        app.launchArguments = ["UI_TESTING"]
        app.launch()
        // activate() so the window comes to front; without it the window may
        // launch behind others and XCUITest's window queries return nothing
        // on a real Mac with other GUI apps running.
        app.activate()

        // Fall back to File → New Window if the headless runner loses the
        // initial window.
        if !app.windows.firstMatch.waitForExistence(timeout: 8) {
            let fileMenu = app.menuBarItems["File"]
            if fileMenu.waitForExistence(timeout: 3) {
                fileMenu.click()
                let newWindow = app.menuItems["New Window"]
                if newWindow.waitForExistence(timeout: 3) {
                    newWindow.click()
                }
            }
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5),
                      "App window must be visible")

        // Let SwiftUI settle.
        Thread.sleep(forTimeInterval: 0.5)

        attachScreenshot(name: "macos-01-home")
    }

    /// Captures the foreground window and attaches it to the xcresult bundle.
    /// `app.windows.firstMatch.screenshot()` captures only the app's window —
    /// clean for App Store submission.
    private func attachScreenshot(name: String) {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
