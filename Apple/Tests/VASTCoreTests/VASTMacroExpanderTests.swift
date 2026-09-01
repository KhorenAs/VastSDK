//
//  VASTMacroExpanderTests.swift
//  VASTCoreTests
//

import XCTest
@testable import VASTCore

/// VAST 4.3 §6. The rules are short but each has a way of going wrong that is
/// invisible until an ad server reports nonsense.
final class VASTMacroExpanderTests: XCTestCase {

    private let expander = VASTMacroExpander()

    // MARK: - Replacement

    /// The brackets are part of the macro and go with it.
    func testMacroIsReplacedIncludingItsBrackets() {
        let result = expander.expand(
            "https://ads.test/e?code=[ERRORCODE]",
            with: .init(errorCode: .noSupportedMediaFile)
        )
        XCTAssertEqual(result, "https://ads.test/e?code=403")
    }

    /// This is the bug the whole file exists to prevent: an unexpanded macro
    /// reaches the ad server as text, and every error looks identical.
    func testErrorCodeIsNeverLeftAsLiteralText() {
        let result = expander.expand(
            "https://ads.test/e?code=[ERRORCODE]",
            with: .init(errorCode: .wrapperLimitReached)
        )
        XCTAssertFalse(result.contains("[ERRORCODE]"))
        XCTAssertTrue(result.hasSuffix("=302"))
    }

    func testSeveralMacrosInOneURI() {
        let result = expander.expand(
            "https://ads.test/t?p=[ADPLAYHEAD]&cb=[CACHEBUSTING]&e=[ERRORCODE]",
            with: .init(errorCode: .mediaFileTimeout, adPlayhead: 12.5, cacheBuster: "12345678")
        )
        XCTAssertEqual(result, "https://ads.test/t?p=00%3A00%3A12.500&cb=12345678&e=402")
    }

    // MARK: - Unknown values

    /// §6: a macro the spec defines but the player does not supply is `-1`.
    func testSpecMacroWithNoValueBecomesMinusOne() {
        let result = expander.expand("https://ads.test/t?p=[ADPLAYHEAD]", with: .init())
        XCTAssertEqual(result, "https://ads.test/t?p=-1")
    }

    /// §6, verbatim: "do not replace all unknown macros with -1, only do this for
    /// macros specifically mentioned in this section". A vendor's own macro is
    /// somebody else's contract and is left alone.
    func testMacroTheSpecDoesNotDefineIsLeftUntouched() {
        let result = expander.expand("https://ads.test/t?x=[ADFOX_SOMETHING]", with: .init())
        XCTAssertEqual(result, "https://ads.test/t?x=[ADFOX_SOMETHING]")
    }

    func testHostSuppliedCustomMacroIsSubstituted() {
        let result = expander.expand(
            "https://ads.test/t?x=[ADFOX_SOMETHING]",
            with: .init(custom: ["ADFOX_SOMETHING": "kinodaran"])
        )
        XCTAssertEqual(result, "https://ads.test/t?x=kinodaran")
    }

    // MARK: - Encoding

    /// §6: encode each value, not the finished string — otherwise the `?` and `&`
    /// that make the URI a URI get encoded too.
    func testValuesAreEncodedButTheURIStructureIsNot() {
        let result = expander.expand(
            "https://ads.test/t?asset=[ASSETURI]&next=1",
            with: .init(assetURI: URL(string: "https://cdn.test/a b.mp4?v=2&x=3")!)
        )
        XCTAssertTrue(result.hasPrefix("https://ads.test/t?asset="))
        XCTAssertTrue(result.hasSuffix("&next=1"), "the URI's own separators survived")
        XCTAssertTrue(result.contains("%3F"), "the value's own '?' was encoded")
        XCTAssertTrue(result.contains("%26"), "the value's own '&' was encoded")
    }

    /// An array macro separates values with commas, and those commas stay commas.
    func testArrayMacroKeepsItsSeparators() {
        let result = expander.expand(
            "https://ads.test/t?size=[PLAYERSIZE]",
            with: .init(playerSize: (width: 1280, height: 720))
        )
        XCTAssertEqual(result, "https://ads.test/t?size=1280,720")
    }

    func testPlayerStateReportsFlagsAsAnArray() {
        let muted = expander.expand("[PLAYERSTATE]", with: .init(isMuted: true, isFullscreen: true))
        XCTAssertEqual(muted, "muted%2Cfullscreen")

        let plain = expander.expand("[PLAYERSTATE]", with: .init(isMuted: false, isFullscreen: false))
        XCTAssertEqual(plain, "", "no flags is still an answer, not unknown")
    }

    // MARK: - Formats

    /// §6 specifies `HH:MM:SS.mmm` for playhead values.
    func testPlayheadUsesTheSpecifiedTimeFormat() {
        XCTAssertEqual(VASTMacroExpander.timecode(0), "00:00:00.000")
        XCTAssertEqual(VASTMacroExpander.timecode(12.5), "00:00:12.500")
        XCTAssertEqual(VASTMacroExpander.timecode(3661.25), "01:01:01.250")
    }

    /// `MEDIAPLAYHEAD` is the older spelling of `ADPLAYHEAD`; a server using
    /// either must get the same answer.
    func testMediaPlayheadIsTreatedAsTheAdPlayhead() {
        let context = VASTMacroExpander.Context(adPlayhead: 7)
        XCTAssertEqual(
            expander.expand("[MEDIAPLAYHEAD]", with: context),
            expander.expand("[ADPLAYHEAD]", with: context)
        )
    }

    func testTimestampIsISO8601() {
        let result = expander.expand(
            "[TIMESTAMP]",
            with: .init(timestamp: Date(timeIntervalSince1970: 0))
        )
        XCTAssertTrue(result.contains("1970"), "got \(result)")
    }

    /// Cache busting is always answerable, and differing per request is the point.
    func testCacheBustingIsGeneratedWhenNotSupplied() {
        let first = expander.expand("[CACHEBUSTING]", with: .init())
        XCTAssertNotEqual(first, VASTMacroExpander.unknownValue)
        XCTAssertEqual(first.count, 8)
    }

    // MARK: - Robustness

    /// A stray bracket in a URI is text, not a malformed macro.
    func testUnbalancedBracketIsLeftAlone() {
        let result = expander.expand("https://ads.test/t?x=[oops", with: .init())
        XCTAssertEqual(result, "https://ads.test/t?x=[oops")
    }

    func testURIWithNoMacrosIsUnchanged() {
        let plain = "https://ads.test/impression?id=42"
        XCTAssertEqual(expander.expand(plain, with: .init()), plain)
    }

    /// Expanding to something unparseable must not lose the beacon entirely.
    func testExpandingAURLFallsBackToTheOriginalWhenInvalid() {
        let url = URL(string: "https://ads.test/t?e=[ERRORCODE]")!
        let expanded = expander.expand(url, with: .init(errorCode: .undefined))
        XCTAssertEqual(expanded.absoluteString, "https://ads.test/t?e=900")
    }
}

// MARK: - Percent-encoded brackets

/// A macro that has been through `URL(string:)` no longer has literal brackets.
/// Every beacon the SDK sends has, so this is the form that actually matters.
extension VASTMacroExpanderTests {

    func testMacroSurvivesHavingBeenParsedIntoAURL() {
        // Exactly what `VASTParser` produces from <Error><![CDATA[...]]></Error>.
        let url = URL(string: "https://ads.test/e?code=[ERRORCODE]")!
        XCTAssertTrue(
            url.absoluteString.contains("%5B"),
            "precondition: URL encodes the brackets, which is the whole problem"
        )

        let expanded = expander.expand(url, with: .init(errorCode: .noSupportedMediaFile))
        XCTAssertEqual(expanded.absoluteString, "https://ads.test/e?code=403")
    }

    func testEncodedBracketsAreRecognisedInStringForm() {
        let result = expander.expand(
            "https://ads.test/e?code=%5BERRORCODE%5D",
            with: .init(errorCode: .wrapperTimeout)
        )
        XCTAssertEqual(result, "https://ads.test/e?code=301")
    }

    /// Lower-case escapes are just as valid.
    func testLowercaseEncodedBracketsAreRecognised() {
        let result = expander.expand(
            "https://ads.test/e?code=%5berrorcode%5d".replacingOccurrences(of: "errorcode", with: "ERRORCODE"),
            with: .init(errorCode: .undefined)
        )
        XCTAssertEqual(result, "https://ads.test/e?code=900")
    }

    /// An encoded bracket that is not wrapping a macro name stays encoded.
    func testEncodedBracketThatIsNotAMacroIsLeftAlone() {
        let result = expander.expand(
            "https://ads.test/t?q=%5Bnot%20a%20macro%5D",
            with: .init()
        )
        XCTAssertEqual(result, "https://ads.test/t?q=%5Bnot%20a%20macro%5D")
    }
}

// MARK: - No double encoding

extension VASTMacroExpanderTests {

    /// Regression. A vendor macro left in place keeps its brackets, brackets are
    /// illegal in a query, and `URL(string:)` responds by encoding the whole
    /// string — turning a correctly encoded `%3A` into `%253A`. The ad server then
    /// reads a timestamp full of literal `%25`.
    func testValuesAreNotEncodedTwiceWhenAVendorMacroRemains() {
        let url = URL(string: "https://ads.test/e?t=[TIMESTAMP]&x=[VENDOR_THING]")!
        let expanded = expander.expand(
            url,
            with: .init(timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        ).absoluteString

        XCTAssertTrue(expanded.contains("%3A"), "the value is encoded once")
        XCTAssertFalse(expanded.contains("%253A"), "and not a second time")
        XCTAssertTrue(expanded.contains("%5BVENDOR_THING%5D"), "the vendor macro survives")
    }

    func testAssetURIIsEncodedExactlyOnce() {
        let url = URL(string: "https://ads.test/e?a=[ASSETURI]&x=[VENDOR]")!
        let expanded = expander.expand(
            url,
            with: .init(assetURI: URL(string: "https://cdn.test/a.mp4")!)
        ).absoluteString

        XCTAssertTrue(expanded.contains("https%3A%2F%2Fcdn.test%2Fa.mp4"))
        XCTAssertFalse(expanded.contains("%25"))
    }

    // MARK: - What only the host can answer

    /// Without these an exchange often will not bid at all, so the point of the
    /// group is that a supplied value arrives and an unsupplied one says so.
    func testTheHostsIdentifierReachesTheServer() {
        let values = VASTMacroValues(
            identifierForAdvertising: "AAAA-BBBB",
            identifierType: "idfa",
            limitsAdTracking: false
        )
        let expanded = expander.expand(
            "https://ads.test/i?ifa=[IFA]&t=[IFATYPE]&lmt=[LIMITADTRACKING]",
            with: .init(host: values)
        )
        XCTAssertEqual(expanded, "https://ads.test/i?ifa=AAAA-BBBB&t=idfa&lmt=0")
    }

    /// `false` and "nobody asked" are different facts about a viewer, and the
    /// difference is the one an auditor cares about.
    func testAnUnknownTrackingPreferenceIsNotReportedAsPermission() {
        let expanded = expander.expand(
            "https://ads.test/i?lmt=[LIMITADTRACKING]",
            with: .init(host: VASTMacroValues())
        )
        XCTAssertEqual(expanded, "https://ads.test/i?lmt=-1")
    }

    /// A TCF string is already base64url when the CMP hands it over. Encoding it
    /// again is how consent arrives corrupted and gets read as absent.
    func testTheConsentStringIsPassedThroughUntouched() {
        let consent = "CPcqBNVPcqBNVABCDEF_gABABCAAA-AAAAAAAAAAAA"
        let expanded = expander.expand(
            "https://ads.test/i?gdpr_consent=[GDPRCONSENT]",
            with: .init(host: VASTMacroValues(gdprConsent: consent))
        )
        XCTAssertTrue(expanded.hasSuffix(consent), "the consent string was re-encoded")
    }

    func testWhereTheBreakSitsComesFromTheHost() {
        let expanded = expander.expand(
            "https://ads.test/i?pos=[BREAKPOSITION]&plcmt=[PLACEMENTTYPE]&cid=[CONTENTID]",
            with: .init(host: VASTMacroValues(placementType: 2, breakPosition: 1, contentID: "show-42"))
        )
        XCTAssertEqual(expanded, "https://ads.test/i?pos=1&plcmt=2&cid=show-42")
    }

    // MARK: - What the SDK can answer itself

    /// Each of these was reporting "unknown" while the answer was sitting in the
    /// session, which is most of what made a request look unattributable.
    func testTheSDKAnswersWhatItKnowsAboutItself() {
        let expanded = expander.expand(
            "https://ads.test/i?ss=[SERVERSIDE]&type=[ADTYPE]&mime=[MEDIAMIME]&tx=[TRANSACTIONID]",
            with: .init(mediaMIMEType: "video/mp4", transactionID: "abc-123")
        )
        XCTAssertEqual(
            expanded,
            "https://ads.test/i?ss=0&type=video&mime=video%2Fmp4&tx=abc-123"
        )
    }

    /// `[CLIENTUA]` names the SDK and `[APPBUNDLE]` names the app. Conflating them
    /// loses both, and an exchange uses the first to tell one player from another
    /// when a creative misbehaves.
    func testTheClientUserAgentNamesTheSDKNotTheApp() {
        let expanded = expander.expand(
            "https://ads.test/i?ua=[CLIENTUA]&app=[APPBUNDLE]",
            with: .init(appBundle: "com.kinodaran.app")
        )
        XCTAssertTrue(expanded.contains("VASTSDK%2F\(VASTVersion.current)"))
        XCTAssertTrue(expanded.contains("app=com.kinodaran.app"))
    }

    /// What the parser accepts, not what this response happens to be — an ad
    /// server that knows it may send VAST 2 will send its VAST 2.
    func testEveryParsableVASTVersionIsAdvertised() {
        let expanded = expander.expand("https://ads.test/i?v=[VASTVERSIONS]", with: .init())
        XCTAssertEqual(expanded, "https://ads.test/i?v=2,3,4,4.1,4.2,4.3")
    }

    /// OMID is claimed only when something is actually there to run a vendor's
    /// code. Claiming it otherwise tells a verification vendor to expect a
    /// session that never starts.
    func testOMIDIsClaimedOnlyWhenSomethingWillRunIt() {
        XCTAssertEqual(
            expander.expand("[APIFRAMEWORKS]", with: .init(executesOMID: false)), "-1"
        )
        XCTAssertEqual(
            expander.expand("[APIFRAMEWORKS]", with: .init(executesOMID: true)), "7"
        )
    }

    /// The player's own size, which is the number an exchange is asking for.
    func testPlayerSizeIsAnArrayWithItsCommaIntact() {
        let expanded = expander.expand(
            "https://ads.test/i?size=[PLAYERSIZE]",
            with: .init(playerSize: (width: 1170, height: 658))
        )
        XCTAssertEqual(expanded, "https://ads.test/i?size=1170,658")
    }

    /// And the rule the whole group depends on: a spec macro nobody supplied says
    /// so, while a vendor's macro is left exactly as it was.
    func testUnsuppliedSpecMacrosSayUnknownAndVendorMacrosAreLeftAlone() {
        let expanded = expander.expand(
            "https://ads.test/i?ifa=[IFA]&dev=[DEVICEUA]&own=[CORRELATOR]",
            with: .init()
        )
        // Left as text here, because this is the string form. Only the `URL`
        // overload re-encodes the brackets, and it does that so Foundation cannot
        // "repair" the whole query and double-encode what was already correct.
        XCTAssertEqual(expanded, "https://ads.test/i?ifa=-1&dev=-1&own=[CORRELATOR]")

        let asURL = expander.expand(
            URL(string: "https://ads.test/i?own=%5BCORRELATOR%5D")!,
            with: .init()
        )
        XCTAssertEqual(asURL.absoluteString, "https://ads.test/i?own=%5BCORRELATOR%5D")
    }
}
