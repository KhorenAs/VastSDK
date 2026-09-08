//
//  VASTRealWorldTagTests.swift
//  VASTCoreTests
//

import XCTest
@testable import VASTCore

/// Behaviour learned from a live ad server rather than from the specification.
/// Every case here corresponds to something a real tag did that spec-shaped
/// fixtures do not.
final class VASTRealWorldTagTests: XCTestCase {

    private func adFoxAd() throws -> VASTAd {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "legacy-events", withExtension: "xml", subdirectory: "Fixtures")
        )
        let document = try VASTParser().parse(try String(contentsOf: url, encoding: .utf8))
        guard case .inLine(let ad) = try XCTUnwrap(document.entries.first).body else {
            return try XCTUnwrap(nil as VASTAd?)
        }
        return ad
    }

    /// The tag sends VAST 2.0/3.0 names. Dropping them loses tracking the server
    /// is waiting for, so all of them must survive parsing.
    func testLegacyEventNamesAreParsed() throws {
        let ad = try adFoxAd()
        let parsed = Set(ad.linear.trackingEvents.keys)

        for legacy in [VASTAd.TrackingEvent.fullscreen, .expand, .collapse, .acceptInvitation, .close] {
            XCTAssertTrue(parsed.contains(legacy), "\(legacy.rawValue) was dropped")
        }
        XCTAssertEqual(parsed.count, 16, "16 of the tag's 17 events are well-formed")
    }

    /// `progress` requires an offset (§3.14.1). This server sends `offset=""`,
    /// which cannot be resolved to a point in the timeline, so it is discarded
    /// rather than guessed at.
    func testProgressEventWithEmptyOffsetIsDiscarded() throws {
        let ad = try adFoxAd()
        XCTAssertTrue(ad.linear.progressEvents.isEmpty)
    }

    /// §3.14.1 says `playerExpand` replaces `fullscreen`, but servers still send
    /// the old name — so reporting the event once must fire both URIs.
    func testFiringPlayerExpandAlsoFiresLegacyFullscreenURI() throws {
        let ad = try adFoxAd()
        var engine = VASTTrackingEngine(ad: ad)
        _ = engine.advance(to: VASTTick(adTime: 0, duration: 24, rate: 1, wallClock: 0))
        _ = engine.advance(to: VASTTick(adTime: 1, duration: 24, rate: 1, wallClock: 1))

        let fired = engine.report(.playerExpand).map(\.url.lastPathComponent)
        XCTAssertEqual(Set(fired), ["fullscreen", "expand"])
    }

    func testSkipOffsetAndDurationFromLiveTag() throws {
        let ad = try adFoxAd()
        XCTAssertEqual(ad.linear.duration, 24)
        XCTAssertEqual(ad.linear.skipOffset, .time(15))
        XCTAssertTrue(ad.isSkippable)
    }

    /// `<Icons>` (AdChoices) is not played by this SDK, but its presence must not
    /// disturb the Linear creative around it.
    func testIconsElementDoesNotCorruptSurroundingCreative() throws {
        let ad = try adFoxAd()
        XCTAssertEqual(ad.linear.mediaFiles.count, 1)
        XCTAssertEqual(ad.linear.clickTracking.count, 1)
        XCTAssertNotNil(ad.linear.clickThrough)
    }

    /// The vendor extension is handed over verbatim; the SDK assigns it no meaning.
    func testVendorExtensionIsExposedRaw() throws {
        let ad = try adFoxAd()
        let uiSettings = try XCTUnwrap(ad.extensions.first { $0.type == "uiSettings" })
        XCTAssertTrue(uiSettings.xml.contains("UiHideable"))
        XCTAssertEqual(uiSettings.value(of: "UiHideable"), "1", "read without scanning the string by hand")
    }
}

/// The tag KinodaranAds' own ad server returns, which is the one this SDK was
/// written to read. Here for the case nothing else covers: the day the server
/// changes its VAST output and the SDK stops understanding it without anybody
/// noticing, because the demo would simply show no ad.
final class VASTKinodaranAdServerTagTests: XCTestCase {

    private func serverAd() throws -> (document: VASTDocument, ad: VASTAd) {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "kinodaran-adserver", withExtension: "xml", subdirectory: "Fixtures"
            )
        )
        let document = try VASTParser().parse(try String(contentsOf: url, encoding: .utf8))
        guard case .inLine(let ad) = try XCTUnwrap(document.entries.first).body else {
            return try (document, XCTUnwrap(nil as VASTAd?))
        }
        return (document, ad)
    }

    /// 3.0 from a server whose editor speaks 4.x, and the whole creative has to
    /// come through the version-tolerant path intact.
    func testTheServersOwnDocumentParses() throws {
        let (document, ad) = try serverAd()

        XCTAssertEqual(document.version, "3.0")
        XCTAssertEqual(document.entries.count, 1)
        XCTAssertEqual(ad.adSystem, "KinodaranAds")
        XCTAssertEqual(ad.title, "TestVast")
        XCTAssertEqual(ad.linear.duration, 30)
        XCTAssertEqual(ad.linear.skipOffset, .time(5))
        XCTAssertTrue(ad.isSkippable, "the skip control is what the creative was sold with")
    }

    /// Six events, one impression and one error URI: the whole of what the ad
    /// server counts by. A name dropped in parsing is a count the server waits
    /// for and never gets.
    func testEverythingTheServerCountsByIsParsed() throws {
        let (_, ad) = try serverAd()

        XCTAssertEqual(
            Set(ad.linear.trackingEvents.keys),
            [.start, .firstQuartile, .midpoint, .thirdQuartile, .complete, .skip]
        )
        XCTAssertEqual(ad.impressions.count, 1)
        XCTAssertEqual(ad.errors.count, 1)

        // Long query strings inside CDATA, with raw ampersands: every parameter
        // has to survive, because the signature covers them.
        let impression = try XCTUnwrap(ad.impressions.first)
        let query = try XCTUnwrap(impression.query)
        XCTAssertTrue(query.contains("event_type=impression"))
        XCTAssertTrue(query.contains("impression_id="))
        XCTAssertTrue(query.contains("sig="))
    }

    /// The one that would have been easy to get wrong: this creative has no
    /// `<VideoClicks>` at all. A linear ad with nowhere to click is still a
    /// linear ad, and a parser that quietly required one would drop our own ads
    /// — and it is why this placement is the one that fills on a television,
    /// where a web destination is refused.
    func testACreativeWithNowhereToClickIsStillPlayable() throws {
        let (_, ad) = try serverAd()

        XCTAssertNil(ad.linear.clickThrough)
        XCTAssertTrue(ad.linear.clickTracking.isEmpty)
        XCTAssertTrue(ad.linear.customClicks.isEmpty)

        let file = try XCTUnwrap(ad.linear.mediaFiles.first)
        XCTAssertEqual(ad.linear.mediaFiles.count, 1)
        XCTAssertEqual(file.mimeType, "video/mp4")
        XCTAssertEqual(file.width, 1280)
        XCTAssertEqual(file.height, 720)
        XCTAssertEqual(file.delivery, .progressive)
    }

    /// The server sends the same `uiSettings` extension the AdFox tag carries,
    /// which asks the *host* to draw the ad UI. It is inert until a host opts in
    /// with `isHiddenUi`, and this records that the flag is arriving — so that
    /// the day it starts mattering, it is not a surprise.
    func testTheServerAsksForHostDrawnUI() throws {
        let (_, ad) = try serverAd()
        XCTAssertTrue(ad.isUIHidden)
        XCTAssertEqual(
            try XCTUnwrap(ad.extensions.first { $0.type == "uiSettings" }).value(of: "UiHideable"),
            "1"
        )
    }
}
