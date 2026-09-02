// Stub unit tests for the macOS app. Forks should add real tests here.
//
// Run via:
//   xcodebuild test -project app/App.xcodeproj \
//     -scheme App-macOS -destination 'platform=macOS'
//
// CI runs this on every PR via .github/workflows/pr.yml.

import XCTest

final class AppMacOSTests: XCTestCase {
    func testSmoke() {
        // Sanity: the unit-test target compiles, links, and the test bundle
        // launches under xcodebuild test. Replace with real assertions as
        // your fork adds logic worth testing.
        XCTAssertEqual(2 + 2, 4)
    }
}
