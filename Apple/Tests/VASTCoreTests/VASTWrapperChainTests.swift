//
//  VASTWrapperChainTests.swift
//  VASTCoreTests
//

import XCTest
@testable import VASTCore

/// A loader backed by a dictionary, so the whole redirection chain — depth
/// limits, tracker accumulation, error reporting — runs with no network.
private struct FixtureLoader: iVASTResourceLoader {

    let documents: [String: String]
    /// URLs that should behave as unreachable.
    var unreachable: Set<String> = []

    func loadVAST(from url: URL, timeout: TimeInterval) async throws -> String {
        let key = url.absoluteString
        if unreachable.contains(key) { throw VASTError.wrapperTimeout }
        guard let xml = documents[key] else { throw VASTError.wrapperTimeout }
        return xml
    }
}

final class VASTWrapperChainTests: XCTestCase {

    private let base = URL(string: "https://ads.test/tag.xml")!

    // MARK: - Document builders

    private func wrapper(
        to tag: String,
        error: String,
        impression: String,
        clickThrough: String? = nil,
        follow: Bool = true,
        allowMultipleAds: Bool = false
    ) -> String {
        let click = clickThrough.map {
            "<VideoClicks><ClickThrough><![CDATA[\($0)]]></ClickThrough></VideoClicks>"
        } ?? ""
        return """
        <VAST version="4.3"><Ad id="w"><Wrapper followAdditionalWrappers="\(follow)" allowMultipleAds="\(allowMultipleAds)">
          <VASTAdTagURI><![CDATA[\(tag)]]></VASTAdTagURI>
          <Error><![CDATA[\(error)]]></Error>
          <Impression><![CDATA[\(impression)]]></Impression>
          <Creatives><Creative><Linear>
            <TrackingEvents><Tracking event="start"><![CDATA[https://ads.test/w-start]]></Tracking></TrackingEvents>
            \(click)
          </Linear></Creative></Creatives>
        </Wrapper></Ad></VAST>
        """
    }

    private func inLine(clickThrough: String? = nil) -> String {
        let click = clickThrough.map {
            "<VideoClicks><ClickThrough><![CDATA[\($0)]]></ClickThrough></VideoClicks>"
        } ?? ""
        return """
        <VAST version="4.3"><Ad id="inline"><InLine>
          <AdSystem>test</AdSystem>
          <Error><![CDATA[https://ads.test/inline-error]]></Error>
          <Impression><![CDATA[https://ads.test/inline-impression]]></Impression>
          <Creatives><Creative><Linear>
            <Duration>00:00:20</Duration>
            <TrackingEvents><Tracking event="start"><![CDATA[https://ads.test/inline-start]]></Tracking></TrackingEvents>
            \(click)
            <MediaFiles><MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://ads.test/v.mp4]]></MediaFile></MediaFiles>
          </Linear></Creative></Creatives>
        </InLine></Ad></VAST>
        """
    }

    private func resolver(_ documents: [String: String], unreachable: Set<String> = []) -> VASTTagResolver {
        VASTTagResolver(loader: FixtureLoader(documents: documents, unreachable: unreachable))
    }

    // MARK: - Happy path

    func testResolvesThroughTwoWrappersToInLine() async throws {
        let resolution = try await resolver([
            "https://ads.test/tag.xml": wrapper(to: "https://ads.test/w2.xml", error: "https://ads.test/e1", impression: "https://ads.test/i1"),
            "https://ads.test/w2.xml": wrapper(to: "https://ads.test/inline.xml", error: "https://ads.test/e2", impression: "https://ads.test/i2"),
            "https://ads.test/inline.xml": inLine(),
        ]).resolve(tag: base)

        let ad = try XCTUnwrap(resolution.ads.first)
        XCTAssertEqual(ad.id, "inline")
        XCTAssertEqual(resolution.chain.depth, 2)
    }

    /// §2.3.5: trackers from every Wrapper in the chain accompany the InLine's own.
    func testTrackersFromEveryWrapperAreAccumulated() async throws {
        let resolution = try await resolver([
            "https://ads.test/tag.xml": wrapper(to: "https://ads.test/w2.xml", error: "https://ads.test/e1", impression: "https://ads.test/i1"),
            "https://ads.test/w2.xml": wrapper(to: "https://ads.test/inline.xml", error: "https://ads.test/e2", impression: "https://ads.test/i2"),
            "https://ads.test/inline.xml": inLine(),
        ]).resolve(tag: base)

        let ad = try XCTUnwrap(resolution.ads.first)
        XCTAssertEqual(ad.impressions.count, 3, "inline + two wrappers")
        XCTAssertEqual(ad.errors.count, 3)
        XCTAssertEqual(ad.linear.trackingEvents[.start]?.count, 3)
    }

    /// A relative `VASTAdTagURI` is what real responses send.
    func testRelativeTagURIIsResolvedAgainstTheFetchLocation() async throws {
        let resolution = try await resolver([
            "https://ads.test/tag.xml": wrapper(to: "next.xml", error: "https://ads.test/e1", impression: "https://ads.test/i1"),
            "https://ads.test/next.xml": inLine(),
        ]).resolve(tag: base)

        XCTAssertEqual(resolution.ads.first?.id, "inline")
    }

    // MARK: - ClickThrough precedence

    /// §2.3.5.2: "if the inLine response includes a ClickThrough element then
    /// this must be favored over ClickThrough element(s) specified in calling
    /// Wrappers."
    func testInLineClickThroughWinsOverWrappers() async throws {
        let resolution = try await resolver([
            "https://ads.test/tag.xml": wrapper(to: "https://ads.test/inline.xml", error: "https://ads.test/e1", impression: "https://ads.test/i1", clickThrough: "https://ads.test/wrapper-landing"),
            "https://ads.test/inline.xml": inLine(clickThrough: "https://ads.test/inline-landing"),
        ]).resolve(tag: base)

        XCTAssertEqual(resolution.ads.first?.linear.clickThrough?.absoluteString, "https://ads.test/inline-landing")
    }

    /// "the ClickThrough element closest to the InLine response must be favored"
    func testDeepestWrapperClickThroughWinsWhenInLineHasNone() async throws {
        let resolution = try await resolver([
            "https://ads.test/tag.xml": wrapper(to: "https://ads.test/w2.xml", error: "https://ads.test/e1", impression: "https://ads.test/i1", clickThrough: "https://ads.test/outer"),
            "https://ads.test/w2.xml": wrapper(to: "https://ads.test/inline.xml", error: "https://ads.test/e2", impression: "https://ads.test/i2", clickThrough: "https://ads.test/inner"),
            "https://ads.test/inline.xml": inLine(),
        ]).resolve(tag: base)

        XCTAssertEqual(resolution.ads.first?.linear.clickThrough?.absoluteString, "https://ads.test/inner")
    }

    // MARK: - Limits and failures

    /// §3.19.1 requires accepting five wrappers; the sixth is error 302.
    func testWrapperLimitIsReportedAs302() async throws {
        var documents: [String: String] = [:]
        for index in 0...8 {
            documents["https://ads.test/w\(index).xml"] = wrapper(
                to: "https://ads.test/w\(index + 1).xml",
                error: "https://ads.test/e\(index)",
                impression: "https://ads.test/i\(index)"
            )
        }
        documents["https://ads.test/tag.xml"] = documents["https://ads.test/w0.xml"]

        do {
            _ = try await resolver(documents).resolve(tag: base)
            XCTFail("expected the chain to stop")
        } catch let failure as VASTTagResolver.Failure {
            XCTAssertEqual(failure.error, .wrapperLimitReached)
            XCTAssertEqual(failure.error.rawValue, 302)
            XCTAssertEqual(failure.beacons.count, 6, "every wrapper traversed is told")
        }
    }

    /// §2.3.5.1: "Error codes should be sent for all wrappers in the chain."
    func testUnreachableRedirectFiresEveryWrapperError() async throws {
        do {
            _ = try await resolver([
                "https://ads.test/tag.xml": wrapper(to: "https://ads.test/w2.xml", error: "https://ads.test/e1", impression: "https://ads.test/i1"),
                "https://ads.test/w2.xml": wrapper(to: "https://ads.test/dead.xml", error: "https://ads.test/e2", impression: "https://ads.test/i2"),
            ], unreachable: ["https://ads.test/dead.xml"]).resolve(tag: base)
            XCTFail("expected a failure")
        } catch let failure as VASTTagResolver.Failure {
            XCTAssertEqual(failure.error, .wrapperTimeout)
            XCTAssertEqual(failure.error.rawValue, 301)
            XCTAssertEqual(Set(failure.beacons.map(\.url.absoluteString)), [
                "https://ads.test/e1", "https://ads.test/e2",
            ])
        }
    }

    /// `followAdditionalWrappers="false"` means a Wrapper response must be ignored.
    func testFollowAdditionalWrappersFalseStopsTheChain() async throws {
        do {
            _ = try await resolver([
                "https://ads.test/tag.xml": wrapper(to: "https://ads.test/w2.xml", error: "https://ads.test/e1", impression: "https://ads.test/i1"),
                "https://ads.test/w2.xml": wrapper(to: "https://ads.test/w3.xml", error: "https://ads.test/e2", impression: "https://ads.test/i2", follow: false),
                "https://ads.test/w3.xml": inLine(),
            ]).resolve(tag: base)
            XCTFail("expected the chain to stop")
        } catch let failure as VASTTagResolver.Failure {
            XCTAssertEqual(failure.error, .noVASTResponseAfterWrappers)
        }
    }

    /// §2.3.6.4: an empty response behind a wrapper is a 303, and the wrapper's
    /// own error URI still fires.
    func testEmptyResponseBehindWrapperIsReportedAs303() async throws {
        do {
            _ = try await resolver([
                "https://ads.test/tag.xml": wrapper(to: "https://ads.test/empty.xml", error: "https://ads.test/e1", impression: "https://ads.test/i1"),
                "https://ads.test/empty.xml": #"<VAST version="4.3"><Error><![CDATA[https://ads.test/no-ad]]></Error></VAST>"#,
            ]).resolve(tag: base)
            XCTFail("expected a failure")
        } catch let failure as VASTTagResolver.Failure {
            XCTAssertEqual(failure.error, .noVASTResponseAfterWrappers)
            XCTAssertEqual(failure.error.rawValue, 303)
            XCTAssertTrue(failure.beacons.contains { $0.url.absoluteString == "https://ads.test/e1" })
        }
    }

    /// §3.3.1: a pod behind a wrapper gets the wrapper's trackers on every member.
    func testPodBehindWrapperGivesEveryAdTheWrapperTrackers() async throws {
        let pod = """
        <VAST version="4.3">
          \((1...3).map { index in
            """
            <Ad id="pod-\(index)" sequence="\(index)"><InLine>
              <AdSystem>test</AdSystem>
              <Impression><![CDATA[https://ads.test/pod-\(index)-impression]]></Impression>
              <Creatives><Creative><Linear><Duration>00:00:10</Duration>
                <MediaFiles><MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://ads.test/v.mp4]]></MediaFile></MediaFiles>
              </Linear></Creative></Creatives>
            </InLine></Ad>
            """
          }.joined())
        </VAST>
        """
        let resolution = try await resolver([
            // §3.19: a wrapper must permit multiple ads for a pod to come
            // through it at all. Without this the response is reduced to one ad,
            // which is what the constraint is for.
            "https://ads.test/tag.xml": wrapper(
                to: "https://ads.test/pod.xml",
                error: "https://ads.test/e1",
                impression: "https://ads.test/wrapper-impression",
                allowMultipleAds: true
            ),
            "https://ads.test/pod.xml": pod,
        ]).resolve(tag: base)

        XCTAssertEqual(resolution.ads.count, 3)
        for ad in resolution.ads {
            XCTAssertTrue(
                ad.impressions.contains { $0.absoluteString == "https://ads.test/wrapper-impression" },
                "\(ad.id) is missing the wrapper impression"
            )
        }
    }
}

// MARK: - allowMultipleAds (§3.19)

/// The attribute defaults to `false`, so a wrapper that says nothing about it is
/// asking for a single ad. Ignoring that meant a pod could be played through a
/// wrapper that never permitted one.
extension VASTWrapperChainTests {

    private func podResponse(count: Int, includeStandAlone: Bool = false) -> String {
        let sequenced = (1...count).map { index in
            """
            <Ad id="pod-\(index)" sequence="\(index)"><InLine>
              <AdSystem>test</AdSystem>
              <Impression><![CDATA[https://ads.test/i-pod-\(index)]]></Impression>
              <Creatives><Creative><Linear><Duration>00:00:10</Duration>
                <MediaFiles><MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://ads.test/v.mp4]]></MediaFile></MediaFiles>
              </Linear></Creative></Creatives>
            </InLine></Ad>
            """
        }
        let spare = includeStandAlone ? """
            <Ad id="spare"><InLine>
              <AdSystem>test</AdSystem>
              <Impression><![CDATA[https://ads.test/i-spare]]></Impression>
              <Creatives><Creative><Linear><Duration>00:00:10</Duration>
                <MediaFiles><MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://ads.test/v.mp4]]></MediaFile></MediaFiles>
              </Linear></Creative></Creatives>
            </InLine></Ad>
            """ : ""
        return #"<VAST version="4.3">"# + sequenced.joined() + spare + "</VAST>"
    }

    private func wrapper(to tag: String, allowMultiple: Bool?) -> String {
        let attribute = allowMultiple.map { #" allowMultipleAds="\#($0)""# } ?? ""
        return """
        <VAST version="4.3"><Ad id="w"><Wrapper\(attribute)>
          <VASTAdTagURI><![CDATA[\(tag)]]></VASTAdTagURI>
          <Error><![CDATA[https://ads.test/e]]></Error>
          <Impression><![CDATA[https://ads.test/i]]></Impression>
        </Wrapper></Ad></VAST>
        """
    }

    /// `allowMultipleAds="true"` — the pod comes through intact.
    func testWrapperPermittingMultipleAdsYieldsTheWholePod() async throws {
        let resolution = try await resolver([
            "https://ads.test/tag.xml": wrapper(to: "https://ads.test/pod.xml", allowMultiple: true),
            "https://ads.test/pod.xml": podResponse(count: 3),
        ]).resolve(tag: base)

        XCTAssertEqual(resolution.ads.count, 3)
    }

    /// Omitted means `false` (§3.19), so the same response yields one ad.
    func testWrapperWithoutTheAttributeAllowsOnlyOneAd() async throws {
        let resolution = try await resolver([
            "https://ads.test/tag.xml": wrapper(to: "https://ads.test/pod.xml", allowMultiple: nil),
            "https://ads.test/pod.xml": podResponse(count: 3),
        ]).resolve(tag: base)

        XCTAssertEqual(resolution.ads.count, 1, "the default is false, not true")
    }

    /// "only the first stand-alone Ad (with no sequence values) ... is allowed" —
    /// so the stand-alone is preferred over the head of the pod.
    func testStandAloneAdIsPreferredWhenMultipleAdsAreNotAllowed() async throws {
        let resolution = try await resolver([
            "https://ads.test/tag.xml": wrapper(to: "https://ads.test/pod.xml", allowMultiple: false),
            "https://ads.test/pod.xml": podResponse(count: 2, includeStandAlone: true),
        ]).resolve(tag: base)

        XCTAssertEqual(resolution.ads.map(\.id), ["spare"])
    }

    /// A direct response has no wrapper imposing the constraint, so a pod
    /// requested straight from an ad server plays in full.
    func testDirectResponseIsNotConstrained() async throws {
        let resolution = try await resolver([
            "https://ads.test/tag.xml": podResponse(count: 3),
        ]).resolve(tag: base)

        XCTAssertEqual(resolution.ads.count, 3, "there is no wrapper at depth zero")
    }
}
