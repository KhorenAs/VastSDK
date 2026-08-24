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
    }
}
