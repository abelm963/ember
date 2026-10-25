import XCTest
@testable import EmberKitTests

fileprivate extension FormatTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__FormatTests = [
        ("testBadges", testBadges),
        ("testRuntime", testRuntime)
    ]
}

fileprivate extension JSONTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__JSONTests = [
        ("testEncodesWholeNumbersWithoutDecimals", testEncodesWholeNumbersWithoutDecimals),
        ("testParsesAndReads", testParsesAndReads)
    ]
}

fileprivate extension JellyfinTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__JellyfinTests = [
        ("testAuthHeaderIsAscii", testAuthHeaderIsAscii),
        ("testDirectPlayUsesStaticStream", asyncTest(testDirectPlayUsesStaticStream)),
        ("testFindByTmdbChecksIds", asyncTest(testFindByTmdbChecksIds)),
        ("testItemFieldsAndImages", testItemFieldsAndImages),
        ("testLowQualityAsksForH264", asyncTest(testLowQualityAsksForH264)),
        ("testNormalizesPastedAddresses", testNormalizesPastedAddresses),
        ("testQueryLeavesOutNilsAndJoinsLists", asyncTest(testQueryLeavesOutNilsAndJoinsLists)),
        ("testRemuxUsesServerHLSAddress", asyncTest(testRemuxUsesServerHLSAddress)),
        ("testSegments", asyncTest(testSegments)),
        ("testSignInStoresToken", asyncTest(testSignInStoresToken)),
        ("testWrongPasswordHasPlainMessage", asyncTest(testWrongPasswordHasPlainMessage)),
        ("testYoutubeKey", testYoutubeKey)
    ]
}

fileprivate extension SeerrTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__SeerrTests = [
        ("testDownloadProgress", testDownloadProgress),
        ("testNormalize", testNormalize),
        ("testReauthRetriesOnce", asyncTest(testReauthRetriesOnce)),
        ("testRequestBodyForSeries", asyncTest(testRequestBodyForSeries)),
        ("testSearchEncodesSpacesAndDropsPeople", asyncTest(testSearchEncodesSpacesAndDropsPeople)),
        ("testSignInKeepsCookiesAndSendsThem", asyncTest(testSignInKeepsCookiesAndSendsThem))
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __EmberKitTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(FormatTests.__allTests__FormatTests),
        testCase(JSONTests.__allTests__JSONTests),
        testCase(JellyfinTests.__allTests__JellyfinTests),
        testCase(SeerrTests.__allTests__SeerrTests)
    ]
}