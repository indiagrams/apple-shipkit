import XCTest

// THE GENERIC ROBOT BASE: ONE ROBOT PER APPLICATION, EVERY METHOD RETURNS SELF, NO SCREEN NAMED.
//
// This file and `ElementText.swift` / `BlindReadGuards.swift` beside it are compiled into BOTH
// UI-test targets and contain no identifier, view name, string or type belonging to the application
// under test. Drop the directory into any SwiftUI project, list it in the two UI-test targets, and
// it works.
//
// Three pieces, each one a thing a macOS UI suite otherwise hand-rolls in every test class:
//
// 1. A ROBOT BASE. `TestRobot` wraps one `XCUIApplication`; every method returns `Self`, so a test
//    body reads as a chain of actions. A robot for your own screens subclasses it.
//
// 2. THE macOS WINDOW-ACTIVATION DANCE. `presentWindow(within:)` activates the app only when it is
//    not already frontmost, waits for a window, and falls back to `File > New Window`. On a real
//    Mac a window can launch behind other GUI apps, so the activation is load-bearing. Reading
//    `state` first makes "was activation needed" something the run records rather than assumes,
//    and the route that produced the window is returned so a failure message can name it. Measured
//    on a hosted macos-15 runner (2026-09-15): activation cost 0.009 s, and the New Window fallback
//    ran and produced a window.
//
// 3. AN AUTOMATIC `final-state` TEARDOWN CAPTURE. `register(with:)` attaches a screenshot at test
//    scope when the test ends, pass or fail. That is exactly the attachment
//    `bin/dump-failure-screenshots.sh` recovers from a failed run's `.xcresult`.
//
// EVIDENCE CHANNEL: `print` reaches `xcodebuild`'s output on the iOS Simulator and does NOT on
// macOS. Every value this file records goes through `uiTestRecord(_:)`, which is both a `print`
// and an `XCTContext.runActivity`, so a macOS run keeps the value in its `.xcresult` even though
// the log swallows it.

/// One line, recorded twice — see the file header's "EVIDENCE CHANNEL" paragraph. `print` alone is
/// silent on macOS; `XCTContext.runActivity` alone leaves the iOS Simulator log with nothing to
/// `grep`. A free function, so the robot, the macOS-only extension below, and any call site can
/// reach it without an `XCTestCase` instance.
func uiTestRecord(_ line: String) {
    print(line)
    XCTContext.runActivity(named: line) { _ in }
}

extension XCTestCase {
    /// Attach a named screenshot to the current `.xcresult`, `.keepAlways` so it survives a passing
    /// run. Use it for a labelled moment a reader will want without hunting through the automatic
    /// `final-state` capture ``TestRobot/register(with:)`` installs.
    func namedScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

#if os(macOS)
    extension XCUIApplication {
        /// The macOS window-activation dance (see the file header). Returns which route produced a
        /// window: `"present"` (one was already there, or `activate()` alone surfaced it),
        /// `"new-window"` (the `File > New Window` fallback ran to completion), or `"none"`
        /// (neither did), so a caller can put the route in its own failure message instead of a
        /// bare timeout.
        @discardableResult
        func presentWindow(within timeout: TimeInterval = 8) -> String {
            let stateBefore = state
            uiTestRecord("ui_test_state_before_activate=\(stateBefore.rawValue)")
            if stateBefore != .runningForeground {
                activate()
            }
            if windows.firstMatch.waitForExistence(timeout: timeout) {
                uiTestRecord("ui_test_present_route=present")
                return "present"
            }
            let fileMenu = menuBarItems["File"]
            guard fileMenu.waitForExistence(timeout: 3) else {
                uiTestRecord("ui_test_present_route=none")
                return "none"
            }
            fileMenu.click()
            let newWindowItem = menuItems["New Window"]
            guard newWindowItem.waitForExistence(timeout: 3) else {
                uiTestRecord("ui_test_present_route=none")
                return "none"
            }
            newWindowItem.click()
            uiTestRecord("ui_test_present_route=new-window")
            return "new-window"
        }
    }
#endif

/// One robot per application under test: every method returns `Self`, so a test body reads as a
/// chain of actions rather than a sequence of raw `XCUIApplication` queries. Subclass it for your
/// own screens.
class TestRobot {
    let app: XCUIApplication

    required init(app: XCUIApplication) {
        self.app = app
    }

    /// Launch with the given arguments and environment, then, on macOS only, run the
    /// window-activation dance so the app has a window before the caller's first query. The route
    /// is kept in ``presentRoute`` so a test can assert on it without running the dance twice.
    @discardableResult
    func launch(args: [String] = [], env: [String: String] = [:]) -> Self {
        app.launchArguments = args
        app.launchEnvironment = env
        app.launch()
        #if os(macOS)
            presentRoute = app.presentWindow()
        #endif
        return self
    }

    /// Which route `launch(args:env:)` took to a window on macOS; `nil` on iOS or before launch.
    private(set) var presentRoute: String?

    /// Register an automatic `final-state` teardown screenshot for `testCase`. Call this BEFORE
    /// `launch(args:env:)`: the teardown block still runs when a test fails midway through
    /// launching, and a block added only after a failing launch never gets the chance.
    ///
    /// **The app is captured strongly, the test case weakly.** Call sites usually hold the robot in
    /// a local `let robot` inside the test method, so the robot is gone before teardown runs. A
    /// block that reached the app through `[weak self]` would find `nil`, return silently, and
    /// leave no attachment and no sign that one is missing, which is what a first version did. The
    /// app is copied out before the block; only `testCase` stays weak, because a teardown block
    /// capturing its own test case strongly is a retain cycle.
    @discardableResult
    func register(with testCase: XCTestCase) -> Self {
        let app = app
        testCase.addTeardownBlock { [weak testCase] in
            guard let testCase else { return }
            guard app.state != .notRunning else {
                // Absence made observable: a named attachment says which branch ran, instead of a
                // missing screenshot a reader cannot tell apart from a capture that never happened.
                let unavailable = XCTAttachment(string: "final-state-unavailable: app state=\(app.state.rawValue)")
                unavailable.name = "final-state-unavailable"
                unavailable.lifetime = .keepAlways
                testCase.add(unavailable)
                return
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "final-state"
            attachment.lifetime = .keepAlways
            testCase.add(attachment)
        }
        return self
    }

    /// Terminate the application under test.
    @discardableResult
    func terminate() -> Self {
        app.terminate()
        return self
    }

    /// Wait up to `timeout` for `identifier` to exist anywhere in the tree, failing the current test
    /// at the CALL SITE (via `file`/`line`) if it never does, so a reader finds the assertion in
    /// their own test body rather than in this file.
    @discardableResult
    func waitForElement(
        _ identifier: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Self {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Element '\(identifier)' must exist within \(timeout)s",
            file: file,
            line: line
        )
        return self
    }
}
