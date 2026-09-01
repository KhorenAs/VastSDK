//
//  VASTMetadataTests.swift
//  VASTCoreTests
//

import XCTest
@testable import VASTCore

/// The VAST 4 elements a reporting pipeline needs and the parser used to skip.
/// Two of them the specification makes required, and skipping those left the most
/// useful fields in a response on the floor.
final class VASTMetadataTests: XCTestCase {

    // MARK: - Identity

    /// `<AdServingId>` is what both sides quote when their counts disagree, and
    /// `<UniversalAdId>` is the only identifier that means the same thing to each
    /// of them. VAST 4 makes both required.
    func testTheIdentifiersBothSidesQuoteAreParsed() throws {
        let ad = try Self.ad(inLine: """
        <AdServingId>c8b7d3a1-2f4e</AdServingId>
        <Advertiser>Kinodaran</Advertiser>
        """, creative: """
        <UniversalAdId idRegistry="Ad-ID">CNPA0484000H</UniversalAdId>
        """)

        XCTAssertEqual(ad.adServingID, "c8b7d3a1-2f4e")
        XCTAssertEqual(ad.advertiser, "Kinodaran")
        XCTAssertEqual(ad.universalAdIDs.count, 1)
        XCTAssertEqual(ad.universalAdIDs.first?.registry, "Ad-ID")
        XCTAssertEqual(ad.universalAdIDs.first?.value, "CNPA0484000H")
    }

    /// `unknown` is a registry some servers really send, and it is a different
    /// fact from having sent nothing.
    func testAnUnknownRegistryIsStillARegistry() throws {
        let ad = try Self.ad(creative: """
        <UniversalAdId idRegistry="unknown">abc123</UniversalAdId>
        """)
        XCTAssertEqual(ad.universalAdIDs.first?.registry, "unknown")
    }

    func testPricingAndCategoriesAreParsed() throws {
        let ad = try Self.ad(inLine: """
        <Pricing model="CPM" currency="USD">12.50</Pricing>
        <Category authority="https://iabtechlab.com/categories">IAB1-1</Category>
        <Expires>3600</Expires>
        """)

        XCTAssertEqual(ad.pricing, .init(model: "CPM", currency: "USD", value: 12.5))
        XCTAssertEqual(ad.categories, [
            .init(authority: "https://iabtechlab.com/categories", code: "IAB1-1"),
        ])
        // Plain seconds, unlike <Duration>'s timecode.
        XCTAssertEqual(ad.expires, 3600)
    }

    // MARK: - Viewability

    func testAllThreeViewabilityOutcomesAreParsed() throws {
        let ad = try Self.ad(inLine: """
        <ViewableImpression id="vi-1">
          <Viewable><![CDATA[https://ads.test/viewable]]></Viewable>
          <NotViewable><![CDATA[https://ads.test/not-viewable]]></NotViewable>
          <ViewUndetermined><![CDATA[https://ads.test/undetermined]]></ViewUndetermined>
        </ViewableImpression>
        """)

        let asked = try XCTUnwrap(ad.viewableImpression)
        XCTAssertEqual(asked.id, "vi-1")
        XCTAssertEqual(asked.viewable.map(\.lastPathComponent), ["viewable"])
        XCTAssertEqual(asked.notViewable.map(\.lastPathComponent), ["not-viewable"])
        XCTAssertEqual(asked.viewUndetermined.map(\.lastPathComponent), ["undetermined"])
    }

    /// An element that asked for nothing is nothing.
    func testAnEmptyViewableImpressionIsDropped() throws {
        let ad = try Self.ad(inLine: "<ViewableImpression id=\"vi-1\"></ViewableImpression>")
        XCTAssertNil(ad.viewableImpression)
    }

    /// The only outcome this player can honestly claim, and it goes out with the
    /// impression. Silence would let a buyer count an unmeasured impression as
    /// measured — the mistake `verificationNotExecuted` exists to prevent.
    func testViewUndeterminedIsReportedWhenNothingCanMeasure() throws {
        let ad = try Self.ad(inLine: """
        <ViewableImpression>
          <Viewable><![CDATA[https://ads.test/viewable]]></Viewable>
          <ViewUndetermined><![CDATA[https://ads.test/undetermined]]></ViewUndetermined>
        </ViewableImpression>
        """)
        var engine = VASTTrackingEngine(ad: ad, duration: 20, measurementWillRun: false)

        let fired = engine.advance(to: VASTTick(adTime: 0, duration: 20, rate: 1, wallClock: 0))

        XCTAssertTrue(
            fired.contains { $0.kind == .viewUndetermined },
            "the response asked about viewability and heard nothing back"
        )
        XCTAssertFalse(
            fired.contains { $0.url.lastPathComponent == "viewable" },
            "a player that cannot measure viewability must not claim it"
        )
    }

    /// With measurement in place the answer is the adapter's to give, not the
    /// engine's to pre-empt.
    func testViewUndeterminedIsSilentWhenSomethingWillMeasure() throws {
        let ad = try Self.ad(inLine: """
        <ViewableImpression>
          <ViewUndetermined><![CDATA[https://ads.test/undetermined]]></ViewUndetermined>
        </ViewableImpression>
        """)
        var engine = VASTTrackingEngine(ad: ad, duration: 20, measurementWillRun: true)

        let fired = engine.advance(to: VASTTick(adTime: 0, duration: 20, rate: 1, wallClock: 0))
        XCTAssertFalse(fired.contains { $0.kind == .viewUndetermined })
    }

    // MARK: - Icons

    /// From the live AdFox tag in `Fixtures/legacy-events.xml`, which is where the
    /// empty `width=""` comes from — a real server really sends that, and an empty
    /// attribute is not a zero.
    func testTheIconFromARealTagIsParsed() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "legacy-events", withExtension: "xml", subdirectory: "Fixtures"
        ))
        let document = try VASTParser().parse(try String(contentsOf: url, encoding: .utf8))
        guard case .inLine(let ad) = try XCTUnwrap(document.entries.first).body else {
            return XCTFail("the fixture stopped being an InLine response")
        }

        let icon = try XCTUnwrap(ad.icons.first)
        XCTAssertEqual(icon.program, "IconTopLeft")
        XCTAssertEqual(icon.xPosition, "left")
        XCTAssertEqual(icon.yPosition, "top")
        XCTAssertEqual(icon.offset, 0)
        XCTAssertNil(icon.width, #"width="" is not a width of zero"#)
        XCTAssertEqual(icon.staticResource?.lastPathComponent, "icon.png")
        XCTAssertEqual(icon.staticResourceType, "image/png")
        XCTAssertEqual(icon.clickThrough?.lastPathComponent, "icon-landing")
    }

    /// An icon with no image is dropped: a host cannot draw an absent resource,
    /// and keeping it would look like an AdChoices mark that failed to load.
    func testAnIconWithNothingToDrawIsDropped() throws {
        let ad = try Self.ad(creative: """
        <Icons><Icon program="AdChoices" xPosition="right" yPosition="top"/></Icons>
        """)
        XCTAssertTrue(ad.icons.isEmpty)
    }

    /// And the creative around it survives, which is what §3.15 being unsupported
    /// used to be about.
    func testAnIconDoesNotDisturbTheCreativeAroundIt() throws {
        let ad = try Self.ad(creative: """
        <Icons><Icon program="AdChoices">
          <StaticResource creativeType="image/png"><![CDATA[https://ads.test/i.png]]></StaticResource>
        </Icon></Icons>
        """)
        XCTAssertEqual(ad.linear.mediaFiles.count, 1)
        XCTAssertEqual(ad.linear.duration, 20)
        XCTAssertEqual(ad.icons.count, 1)
    }

    // MARK: - Custom clicks

    /// `<CustomClick>` is not `<ClickTracking>`: one accompanies a destination and
    /// the other reports an interaction that opens nothing. Real tags send both,
    /// and firing one for the other misreports both.
    func testCustomClicksAreKeptApartFromClickTracking() throws {
        let ad = try Self.ad(creative: """
        <VideoClicks>
          <ClickThrough><![CDATA[https://ads.test/landing]]></ClickThrough>
          <ClickTracking><![CDATA[https://ads.test/click]]></ClickTracking>
          <CustomClick><![CDATA[https://ads.test/custom]]></CustomClick>
        </VideoClicks>
        """)

        XCTAssertEqual(ad.linear.clickTracking.map(\.lastPathComponent), ["click"])
        XCTAssertEqual(ad.linear.customClicks.map(\.lastPathComponent), ["custom"])
    }

    func testReportingACustomClickFiresOnlyItsOwnURIs() throws {
        let ad = try Self.ad(creative: """
        <VideoClicks>
          <ClickTracking><![CDATA[https://ads.test/click]]></ClickTracking>
          <CustomClick><![CDATA[https://ads.test/custom]]></CustomClick>
        </VideoClicks>
        """)
        var engine = VASTTrackingEngine(ad: ad, duration: 20)
        _ = engine.advance(to: VASTTick(adTime: 0, duration: 20, rate: 1, wallClock: 0))

        let fired = engine.reportCustomClick()
        XCTAssertEqual(fired.map(\.url.lastPathComponent), ["custom"])
        XCTAssertEqual(fired.first?.kind, .customClick)
    }

    // MARK: - Fixtures

    private static func ad(inLine: String = "", creative: String = "") throws -> VASTAd {
        let xml = """
        <VAST version="4.3"><Ad id="a"><InLine>
          <AdSystem>test</AdSystem>
          <Impression><![CDATA[https://ads.test/impression]]></Impression>
          \(inLine)
          <Creatives><Creative>
            \(creative)
            <Linear>
              <Duration>00:00:20</Duration>
              <MediaFiles>
                <MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://ads.test/v.mp4]]></MediaFile>
              </MediaFiles>
            </Linear>
          </Creative></Creatives>
        </InLine></Ad></VAST>
        """
        let document = try VASTParser().parse(xml)
        guard case .inLine(let ad) = try XCTUnwrap(document.entries.first).body else {
            return try XCTUnwrap(nil as VASTAd?)
        }
        return ad
    }
}
