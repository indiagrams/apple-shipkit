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

    func testScreenshot_01_Home() {
        // NO RUNNER-IDENTITY SKIP. This test used to skip whenever HOME was `/Users/runner`, on the
        // stated cause that `app.activate()` sits ~60 s on a headless runner and then records
        // "Failed to activate application". Re-measured on a hosted macos-15 runner (2026-09-15)
        // through `TestRobot`'s dance: activation cost 0.009 s, and the `File > New Window`
        // fallback ran and produced a window. What that runner does limit is the DISPLAY: 1024x768
        // points (visible frame 1024x681). This capture forces no window size, so its window fits.
        // A capture that forces one larger than the screen should skip on screen FIT, comparing
        // `NSScreen.main?.visibleFrame` with the requested size, never on who the runner is.
        //
        // `TestRobot.launch` activates only when the app is not already frontmost, then waits for a
        // window and falls back to `File > New Window`. `register(with:)` attaches `final-state`
        // at teardown, so a failed capture still leaves a picture in the `.xcresult`.
        let robot = TestRobot(app: app).register(with: self)
        robot.launch(args: ["UI_TESTING"])

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
