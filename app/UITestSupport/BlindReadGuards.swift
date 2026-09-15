import XCTest

// ASSERT THAT THE INSTRUMENT CAN SEE, BEFORE ASSERTING WHAT IT SEES. APP-AGNOSTIC BY CONSTRUCTION.
//
// A UI-test read that comes back empty is not a failure signal. It is the ABSENCE of a signal, and
// an assertion placed on top of it reports something — usually something confident and wrong. Two
// shapes of that were shipped in this repository and both are named in the doc comments below,
// because a guard whose motivation is abstract gets deleted by the next person who finds it noisy:
//
//   1  LOUD AND MISLEADING. `XCTAssertEqual(Set(readings).count, expectedCount)` reported
//      "two elements render the same value" when the truth was three EMPTY reads —
//      `Set(["", "", ""]).count` is 1 as surely as `Set(["a", "a", "b"]).count` is 2. A duplicate
//      is a defect in the application; an empty sweep is a blind instrument. Opposite findings,
//      and the second was reported in the first's words. That cost a session.
//
//   2  SILENT AND GREEN. `XCTAssertEqual(derived.label, transform(source.label))` compared
//      `"" == ""` and recorded a pass, for two phases, because the transform in use mapped the
//      empty string to the empty string. A gate that has stopped measuring its subject and says so
//      to nobody is worse than one that fails: a loud failure announces itself on the next run.
//
// THE RULE THEY CARRY: assert READABILITY first, as its own assertion with its own message, then
// assert the RELATION. Two assertions where there was one. Nothing is weakened — every original
// assertion survives verbatim as the second half — and the two opposite findings can no longer
// wear each other's words.
//
// WHY THESE ARE FREE FUNCTIONS: a UI-test suite's helpers are not all `XCTestCase` methods, and
// these must be callable from a driver type, from an extension, and from a test body alike. Each
// takes `file`/`line` defaulted to the CALL SITE, so a failure points at the assertion a reader is
// looking for rather than at this file.
//
// NOTHING HERE NAMES AN APPLICATION. No identifier, no view, no string, no type belonging to the
// application under test appears in this file — the same property `ElementText.swift` holds, and
// for the same reason: this is meant to be dropped into any SwiftUI project unchanged.
//
// SWIFT 5.9 / `SWIFT_STRICT_CONCURRENCY: minimal`, matching both UI-test targets.

/// Read `element` and FAIL, naming a BLIND READ, if the read is empty — then return the text.
///
/// Use this everywhere a read feeds another assertion. The returned value is safe to compare
/// against, because the comparison is only reached once the read has been shown to have happened:
///
///     let source = assertReadable(sourceElement, "the source value")
///     XCTAssertEqual(assertReadable(derivedElement, "the derived value"), transform(source))
///
/// `what` is prose naming the element in the reader's own vocabulary — "the first row's title",
/// "the detail pane's timestamp". It is the whole value of the message, so spell it for somebody
/// reading a CI log three weeks from now with no access to the screen.
///
/// AN EMPTY READ IS NOT NECESSARILY AN ABSENT ELEMENT. On macOS the three commonest SwiftUI text
/// shapes publish their content in `AXValue` alone and XCUITest's `.label` never reads it, and a
/// MENU ITEM publishes in `AXTitle` and in neither of those — so an element that is present,
/// correct and on screen still reads empty through `label`. ``XCUIElement/renderedText`` is what
/// this function reads and it asks all three, so those cases are already handled; a failure here
/// means the text is in none of the three, which is a genuine finding.
@discardableResult
func assertReadable(
    _ element: XCUIElement,
    _ what: String,
    file: StaticString = #filePath,
    line: UInt = #line
) -> String {
    let text = element.renderedText
    XCTAssertFalse(
        text.isEmpty,
        "BLIND READ: \(what) renders nothing this test can read, so every assertion below it is "
            + "about the empty string rather than about the application. Either the element is "
            + "absent, or its text is published in an attribute none of `label`, `value` and "
            + "`title` exposes — see `ElementText.swift`, which names the shape each of the "
            + "three was measured to carry.",
        file: file,
        line: line
    )
    return text
}

/// Fail, naming a BLIND READ and counting it, if ANY of `texts` is empty.
///
/// The array form of ``assertReadable(_:_:file:line:)``, for a population read in one pass —
/// typically `someQuery.renderedTexts`. The count in the message is what distinguishes "one row
/// out of nine is wrong" from "the whole read is blind", which are different investigations.
///
/// AN EMPTY ARRAY PASSES, AND DELIBERATELY SO: "no element matched" is a different finding from
/// "elements matched and read empty", and conflating them puts a population assertion's failure
/// into a readability assertion's message. Assert the population separately — that is what
/// ``assertDistinctReadable(_:expected:_:file:line:)`` does.
func assertAllReadable(
    _ texts: [String],
    _ what: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let blank = texts.filter(\.isEmpty).count
    XCTAssertEqual(
        blank, 0,
        "BLIND READ: \(blank) of \(texts.count) reads of \(what) came back EMPTY: \(texts). That "
            + "is a blind instrument, not a finding about the application — see `ElementText.swift` "
            + "for which shapes publish their text where on which platform.",
        file: file,
        line: line
    )
}

/// Assert `texts` holds `expected` readings and that no two are alike — as TWO failures, not one.
///
/// Readability is checked FIRST and names itself, so the failure mode that cost a session cannot
/// recur: `XCTAssertEqual(Set(texts).count, expected)` alone answers "two elements render the same
/// value" for a genuine duplicate AND for a read that came back empty on every element. Those are
/// opposite findings. Here the empty case is reported as a blind read, by name, and the duplicate
/// assertion survives verbatim underneath it.
///
/// With `continueAfterFailure = false` — the usual setting for a driven walk — the first of the
/// two is the one reported, which is the right order: there is no point asking whether readings
/// are distinct until it is established that there were readings.
func assertDistinctReadable(
    _ texts: [String],
    expected: Int,
    _ what: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    assertAllReadable(texts, what, file: file, line: line)
    XCTAssertEqual(
        Set(texts).count, expected,
        "two of \(what) render the same value: \(texts)",
        file: file,
        line: line
    )
}

/// Assert `element` renders exactly `expected`, refusing a comparison neither side can fail.
///
/// THE EXPECTATION IS GUARDED TOO, AND THAT IS THE HALF USUALLY MISSING. A relation whose expected
/// side is itself computed from a read — `transform(source.label)` — is satisfied by two blind
/// reads whenever the transform maps the empty string to the empty string, which base64, trimming,
/// joining, percent-encoding and most formatting all do. Checking only the actual side leaves that
/// gate green and silent. Both sides are checked here, each with its own message.
func assertRendersText(
    _ element: XCUIElement,
    _ expected: String,
    _ what: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertFalse(
        expected.isEmpty,
        "VACUOUS EXPECTATION: the value \(what) is being compared against is itself empty, so this "
            + "assertion is satisfied by a blind read of \(what) and cannot fail. Guard whatever "
            + "produced the expectation with `assertReadable` before computing it.",
        file: file,
        line: line
    )
    let actual = assertReadable(element, what, file: file, line: line)
    XCTAssertEqual(
        actual, expected,
        "\(what) renders \"\(actual)\", expected \"\(expected)\"",
        file: file,
        line: line
    )
}
