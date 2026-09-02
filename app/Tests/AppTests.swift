// Stub unit tests for the iOS app. Forks should add real tests here.
//
// Run via:
//   xcodebuild test -project app/App.xcodeproj \
//     -scheme App-iOS -destination 'platform=iOS Simulator,name=iPhone 16 Plus,OS=latest'
//
// CI runs this on every PR via .github/workflows/pr.yml.

import XCTest

final class AppTests: XCTestCase {
    func testSmoke() {
        // Sanity: the unit-test target compiles, links, and the test bundle
        // launches under xcodebuild test. Replace with real assertions as
        // your fork adds logic worth testing.
        XCTAssertEqual(2 + 2, 4)
    }
}
