//
//  VASTTagResolverTests.swift
//  VASTCoreTests
//

import XCTest
@testable import VASTCore

/// Both ways in have to behave the same. `resolve(xml:)` used to start the tail
/// of the chain over, which quietly lost everything the document it was handed
/// had collected — and a host holding XML rather than a URL had no way to know.
final class VASTTagResolverTests: XCTestCase {

    // MARK: - The chain carries on

    /// The same wrapper, down each path, has to yield the same trackers.
    func testHandingInAWrapperCollectsAsMuchAsFetchingIt() async throws {
        let resolver = Self.resolver()

        let fetched = try await resolver.resolve(tag: Self.outerURL)
        let handedIn = try await resolver.resolve(xml: Self.wrapper, baseURL: Self.outerURL)

        let fromFetch = try XCTUnwrap(fetched.ads.first)
        let fromHandIn = try XCTUnwrap(handedIn.ads.first)

        XCTAssertEqual(
            Set(fromHandIn.impressions.map(\.host)), Set(fromFetch.impressions.map(\.host)),
            "the wrapper's own <Impression> was dropped"
        )
        XCTAssertEqual(
            Set(fromHandIn.errors.map(\.host)), Set(fromFetch.errors.map(\.host)),
            "the wrapper's own <Error> was dropped, so a failure would go unreported"
        )
        XCTAssertEqual(
            fromHandIn.wrapperAdIDs, fromFetch.wrapperAdIDs,
            "the intermediary that served the ad was forgotten"
        )
    }

    /// Specifically: the wrapper's URIs, not just the InLine's.
    func testTheOuterWrapperContributesItsOwnTrackers() async throws {
        let resolution = try await Self.resolver().resolve(xml: Self.wrapper, baseURL: Self.outerURL)
        let ad = try XCTUnwrap(resolution.ads.first)

        XCTAssertTrue(ad.impressions.contains { $0.host == "outer.example" })
        XCTAssertTrue(ad.errors.contains { $0.host == "outer.example" })
        XCTAssertEqual(ad.wrapperAdIDs, ["outer"])
    }

    /// The depth count carries on too. Starting the tail over made the real limit
    /// twice `maxDepth`, which is a chain twice as long as §3.19.1 asks anyone to
    /// accept.
    func testDepthIsNotRestartedForTheTail() async throws {
        let resolution = try await Self.resolver().resolve(xml: Self.wrapper, baseURL: Self.outerURL)
        XCTAssertEqual(resolution.chain.depth, 1, "the hop this document itself made was forgotten")
    }

    // MARK: - What the chain must not lose

    /// The chain rebuilds the ad on the way out, and everything it forgets to
    /// copy disappears for any response that came through a Wrapper — which is
    /// most of them. These are the fields a reporting pipeline needs, so losing
    /// them is invisible until someone asks why a report is empty.
    func testTheChainCarriesTheInLinesOwnMetadata() async throws {
        let resolution = try await Self.resolver(inLine: Self.richInLine)
            .resolve(tag: Self.outerURL)
        let ad = try XCTUnwrap(resolution.ads.first)

        XCTAssertEqual(ad.adServingID, "serving-1")
        XCTAssertEqual(ad.universalAdIDs.first?.value, "CNPA0484000H")
        XCTAssertEqual(ad.advertiser, "Kinodaran")
        XCTAssertEqual(ad.icons.count, 1)
        XCTAssertEqual(ad.linear.customClicks.map(\.lastPathComponent), ["custom"])
    }

    /// A Wrapper may ask about viewability on its own account (§3.6). An
    /// intermediary that wanted to hear does not stop wanting because the InLine
    /// wanted to as well, so both sets of URIs survive.
    func testBothTheWrapperAndTheInLineAreHeardAboutViewability() async throws {
        let resolution = try await Self.resolver(inLine: Self.richInLine)
            .resolve(tag: Self.outerURL)
        let asked = try XCTUnwrap(try XCTUnwrap(resolution.ads.first).viewableImpression)

        XCTAssertEqual(
            Set(asked.viewUndetermined.map(\.host)),
            ["inner.example", "outer.example"]
        )
    }

    // MARK: - Fixtures

    private static let outerURL = URL(string: "https://outer.example/vast.xml")!
    private static let innerURL = URL(string: "https://inner.example/vast.xml")!

    private static func resolver(inLine page: String? = nil) -> VASTTagResolver {
        VASTTagResolver(loader: StubLoader(pages: [
            outerURL.absoluteString: wrapper,
            innerURL.absoluteString: page ?? inLine,
        ]))
    }

    private static let wrapper = """
    <VAST version="4.0"><Ad id="outer"><Wrapper>
      <AdSystem>outer</AdSystem>
      <Impression><![CDATA[https://outer.example/impression]]></Impression>
      <Error><![CDATA[https://outer.example/error]]></Error>
      <VASTAdTagURI><![CDATA[https://inner.example/vast.xml]]></VASTAdTagURI>
      <ViewableImpression>
        <ViewUndetermined><![CDATA[https://outer.example/undetermined]]></ViewUndetermined>
      </ViewableImpression>
      <Creatives><Creative><Linear><TrackingEvents>
        <Tracking event="start"><![CDATA[https://outer.example/start]]></Tracking>
      </TrackingEvents></Linear></Creative></Creatives>
    </Wrapper></Ad></VAST>
    """

    private static let inLine = """
    <VAST version="4.0"><Ad id="inner"><InLine>
      <AdSystem>inner</AdSystem>
      <Impression><![CDATA[https://inner.example/impression]]></Impression>
      <Creatives><Creative><Linear>
        <Duration>00:00:15</Duration>
        <MediaFiles>
          <MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://inner.example/a.mp4]]></MediaFile>
        </MediaFiles>
      </Linear></Creative></Creatives>
    </InLine></Ad></VAST>
    """
}

/// Serves fixtures instead of hitting a network.
private struct StubLoader: iVASTResourceLoader {
    let pages: [String: String]

    func loadVAST(from url: URL, timeout: TimeInterval) async throws -> String {
        guard let xml = pages[url.absoluteString] else { throw VASTError.wrapperTimeout }
        return xml
    }
}

private extension VASTTagResolverTests {

    /// An InLine carrying the VAST 4 fields a reporting pipeline reads.
    static let richInLine = """
    <VAST version="4.3"><Ad id="inner"><InLine>
      <AdSystem>inner</AdSystem>
      <AdServingId>serving-1</AdServingId>
      <Advertiser>Kinodaran</Advertiser>
      <Impression><![CDATA[https://inner.example/impression]]></Impression>
      <ViewableImpression>
        <ViewUndetermined><![CDATA[https://inner.example/undetermined]]></ViewUndetermined>
      </ViewableImpression>
      <Creatives><Creative>
        <UniversalAdId idRegistry="Ad-ID">CNPA0484000H</UniversalAdId>
        <Icons><Icon program="AdChoices">
          <StaticResource creativeType="image/png"><![CDATA[https://inner.example/i.png]]></StaticResource>
        </Icon></Icons>
        <Linear>
          <Duration>00:00:15</Duration>
          <VideoClicks>
            <CustomClick><![CDATA[https://inner.example/custom]]></CustomClick>
          </VideoClicks>
          <MediaFiles>
            <MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://inner.example/a.mp4]]></MediaFile>
          </MediaFiles>
        </Linear>
      </Creative></Creatives>
    </InLine></Ad></VAST>
    """
}
