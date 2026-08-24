//
//  VASTAdVerificationsTests.swift
//  VASTCoreTests
//

import XCTest
@testable import VASTCore

/// `<AdVerifications>` moved between VAST 3 and VAST 4, and ad servers still
/// send both shapes. A host asks for `adVerifications` and should not have to
/// know which version answered.
final class VASTAdVerificationsTests: XCTestCase {

    private let parser = VASTParser()

    private func ad(_ xml: String) throws -> VASTAd {
        let document = try parser.parse(xml)
        guard case .inLine(let ad) = try XCTUnwrap(document.entries.first).body else {
            throw XCTSkip("expected an InLine ad")
        }
        return ad
    }

    /// The body of an InLine, with whatever verification markup a test supplies.
    private func inLine(version: String = "4.3", verifications: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <VAST version="\(version)">
          <Ad id="a1"><InLine>
            <AdSystem>test</AdSystem>
            <Impression><![CDATA[https://ads.test/impression]]></Impression>
            <Creatives><Creative><Linear>
              <Duration>00:00:30</Duration>
              <TrackingEvents>
                <Tracking event="start"><![CDATA[https://ads.test/start]]></Tracking>
                <Tracking event="complete"><![CDATA[https://ads.test/complete]]></Tracking>
              </TrackingEvents>
              <MediaFiles>
                <MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://ads.test/v.mp4]]></MediaFile>
              </MediaFiles>
            </Linear></Creative></Creatives>
            \(verifications)
          </InLine></Ad>
        </VAST>
        """
    }

    // MARK: - VAST 4

    func testParsesVAST4AdVerifications() throws {
        let ad = try ad(inLine(verifications: """
        <AdVerifications>
          <Verification vendor="measure.com-omid">
            <JavaScriptResource apiFramework="omid" browserOptional="true">
              <![CDATA[https://measure.com/omid.js]]>
            </JavaScriptResource>
            <VerificationParameters><![CDATA[{"key":"abc123"}]]></VerificationParameters>
            <TrackingEvents>
              <Tracking event="verificationNotExecuted"><![CDATA[https://measure.com/not-executed]]></Tracking>
            </TrackingEvents>
          </Verification>
        </AdVerifications>
        """))

        let verification = try XCTUnwrap(ad.adVerifications.first)
        XCTAssertEqual(ad.adVerifications.count, 1)
        XCTAssertEqual(verification.vendor, "measure.com-omid")
        XCTAssertEqual(verification.parameters, #"{"key":"abc123"}"#)
        XCTAssertEqual(
            verification.notExecutedTrackers.map(\.absoluteString),
            ["https://measure.com/not-executed"]
        )

        let resource = try XCTUnwrap(verification.omidResource)
        XCTAssertEqual(resource.url.absoluteString, "https://measure.com/omid.js")
        XCTAssertEqual(resource.kind, .javaScript)
        XCTAssertTrue(resource.browserOptional)
    }

    // MARK: - VAST 3

    /// VAST 3 had no element for this, so vendors shipped the same content inside
    /// `<Extension type="AdVerifications">`. It must normalise to the same model.
    func testParsesVAST3ExtensionShapeIdentically() throws {
        let ad = try ad(inLine(version: "3.0", verifications: """
        <Extensions>
          <Extension type="AdVerifications">
            <AdVerifications>
              <Verification vendor="measure.com-omid">
                <JavaScriptResource apiFramework="omid" browserOptional="true">
                  <![CDATA[https://measure.com/omid.js]]>
                </JavaScriptResource>
                <VerificationParameters><![CDATA[{"key":"abc123"}]]></VerificationParameters>
                <TrackingEvents>
                  <Tracking event="verificationNotExecuted"><![CDATA[https://measure.com/not-executed]]></Tracking>
                </TrackingEvents>
              </Verification>
            </AdVerifications>
          </Extension>
        </Extensions>
        """))

        let verification = try XCTUnwrap(ad.adVerifications.first)
        XCTAssertEqual(verification.vendor, "measure.com-omid")
        XCTAssertEqual(verification.omidResource?.url.absoluteString, "https://measure.com/omid.js")
        XCTAssertEqual(verification.parameters, #"{"key":"abc123"}"#)
        XCTAssertEqual(verification.notExecutedTrackers.count, 1)
    }

    /// Some servers omit the inner `<AdVerifications>` and put `<Verification>`
    /// straight into the extension.
    func testParsesVAST3ExtensionWithoutTheInnerWrapper() throws {
        let ad = try ad(inLine(version: "3.0", verifications: """
        <Extensions>
          <Extension type="adverifications">
            <Verification vendor="terse.com">
              <JavaScriptResource apiFramework="omid"><![CDATA[https://terse.com/v.js]]></JavaScriptResource>
            </Verification>
          </Extension>
        </Extensions>
        """))

        XCTAssertEqual(ad.adVerifications.first?.vendor, "terse.com", "the type attribute's case is not ours to police")
    }

    /// Normalised, not duplicated: the same content must not also surface as a
    /// raw extension, or a host wiring both would report twice.
    func testVerificationExtensionIsNotAlsoReportedRaw() throws {
        let ad = try ad(inLine(version: "3.0", verifications: """
        <Extensions>
          <Extension type="AdVerifications">
            <AdVerifications>
              <Verification vendor="measure.com">
                <JavaScriptResource apiFramework="omid"><![CDATA[https://measure.com/v.js]]></JavaScriptResource>
              </Verification>
            </AdVerifications>
          </Extension>
          <Extension type="uiSettings"><UiHideable>1</UiHideable></Extension>
        </Extensions>
        """))

        XCTAssertEqual(ad.adVerifications.count, 1)
        XCTAssertEqual(ad.extensions.compactMap(\.type), ["uiSettings"], "other extensions are untouched")
    }

    // MARK: - Scope

    /// `<TrackingEvents>` lives under both `<Linear>` and `<Verification>`.
    /// Filing a verification's tracker as a creative event loses it twice over:
    /// `verificationNotExecuted` is not a creative event, so it vanishes.
    func testVerificationTrackerDoesNotLeakIntoCreativeEvents() throws {
        let ad = try ad(inLine(verifications: """
        <AdVerifications>
          <Verification vendor="measure.com">
            <JavaScriptResource apiFramework="omid"><![CDATA[https://measure.com/v.js]]></JavaScriptResource>
            <TrackingEvents>
              <Tracking event="verificationNotExecuted"><![CDATA[https://measure.com/not-executed]]></Tracking>
            </TrackingEvents>
          </Verification>
        </AdVerifications>
        """))

        XCTAssertEqual(ad.linear.trackingEvents[.start]?.count, 1)
        XCTAssertEqual(ad.linear.trackingEvents[.complete]?.count, 1)
        XCTAssertEqual(ad.linear.trackingEvents.count, 2, "no third event arrived from the verification")
        XCTAssertEqual(ad.adVerifications.first?.notExecutedTrackers.count, 1)
    }

    // MARK: - Resources

    /// An executable resource cannot run here, but the vendor still expects to
    /// hear why — so it is kept, with no OMID resource to offer.
    func testExecutableOnlyVerificationIsKeptButUnusable() throws {
        let ad = try ad(inLine(verifications: """
        <AdVerifications>
          <Verification vendor="native.com">
            <ExecutableResource apiFramework="native" type="binary">
              <![CDATA[https://native.com/lib.bin]]>
            </ExecutableResource>
            <TrackingEvents>
              <Tracking event="verificationNotExecuted"><![CDATA[https://native.com/not-executed]]></Tracking>
            </TrackingEvents>
          </Verification>
        </AdVerifications>
        """))

        let verification = try XCTUnwrap(ad.adVerifications.first)
        XCTAssertNil(verification.omidResource, "reason 1, not reason 3")
        XCTAssertEqual(verification.resources.first?.kind, .executable)
        XCTAssertEqual(verification.resources.first?.type, "binary")
        XCTAssertEqual(verification.notExecutedTrackers.count, 1)
    }

    /// A JavaScript resource for someone else's framework is not an OMID resource.
    func testNonOMIDJavaScriptIsNotOfferedAsOMID() throws {
        let ad = try ad(inLine(verifications: """
        <AdVerifications>
          <Verification vendor="other.com">
            <JavaScriptResource apiFramework="spatial"><![CDATA[https://other.com/v.js]]></JavaScriptResource>
          </Verification>
        </AdVerifications>
        """))

        let verification = try XCTUnwrap(ad.adVerifications.first)
        XCTAssertNil(verification.omidResource)
        XCTAssertEqual(verification.resources.count, 1)
    }

    /// `browserOptional` defaults to false (§3.16), and `omid` arrives in mixed
    /// case often enough that matching it exactly would drop real vendors.
    func testDefaultsAndCaseInsensitiveFramework() throws {
        let ad = try ad(inLine(verifications: """
        <AdVerifications>
          <Verification vendor="mixed.com">
            <JavaScriptResource apiFramework="OMID"><![CDATA[https://mixed.com/v.js]]></JavaScriptResource>
          </Verification>
        </AdVerifications>
        """))

        let resource = try XCTUnwrap(ad.adVerifications.first?.omidResource)
        XCTAssertFalse(resource.browserOptional)
    }

    /// A `<Verification>` asking for nothing is not something to report on.
    func testVerificationWithoutResourcesIsDropped() throws {
        let ad = try ad(inLine(verifications: """
        <AdVerifications>
          <Verification vendor="empty.com"></Verification>
        </AdVerifications>
        """))

        XCTAssertTrue(ad.adVerifications.isEmpty)
    }

    /// Several vendors on one ad is the ordinary case, not an edge case.
    func testMultipleVendorsAreAllKept() throws {
        let ad = try ad(inLine(verifications: """
        <AdVerifications>
          <Verification vendor="one.com">
            <JavaScriptResource apiFramework="omid"><![CDATA[https://one.com/v.js]]></JavaScriptResource>
          </Verification>
          <Verification vendor="two.com">
            <JavaScriptResource apiFramework="omid"><![CDATA[https://two.com/v.js]]></JavaScriptResource>
          </Verification>
        </AdVerifications>
        """))

        XCTAssertEqual(ad.adVerifications.map(\.vendor), ["one.com", "two.com"])
    }

    /// Nothing asked for measurement; the list is empty rather than absent.
    func testAdWithoutVerificationsHasAnEmptyList() throws {
        XCTAssertTrue(try ad(inLine(verifications: "")).adVerifications.isEmpty)
    }

    // MARK: - Reporting

    private func beacons(for ad: VASTAd, measurementWillRun: Bool = false) -> [VASTBeacon] {
        var engine = VASTTrackingEngine(ad: ad, measurementWillRun: measurementWillRun)
        return engine.advance(to: VASTTick(adTime: 0, duration: 30, rate: 1, wallClock: 0))
    }

    /// Silence would let the vendor count an unmeasured session as measured.
    /// Reason 3: there was a usable resource and nothing was asked to run it.
    func testUsableResourceWithNoMeasurementReportsNotExecuted() throws {
        let ad = try ad(inLine(verifications: """
        <AdVerifications>
          <Verification vendor="measure.com">
            <JavaScriptResource apiFramework="omid"><![CDATA[https://measure.com/v.js]]></JavaScriptResource>
            <TrackingEvents>
              <Tracking event="verificationNotExecuted"><![CDATA[https://measure.com/ne?r=[REASON]]]></Tracking>
            </TrackingEvents>
          </Verification>
        </AdVerifications>
        """))

        let reported = beacons(for: ad).filter {
            if case .verificationNotExecuted = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.kind, .verificationNotExecuted(.notExecuted))
    }

    /// Reason 1: nothing here could ever have run, measurement or not.
    func testExecutableOnlyResourceReportsResourceNotSupported() throws {
        let ad = try ad(inLine(verifications: """
        <AdVerifications>
          <Verification vendor="native.com">
            <ExecutableResource apiFramework="native"><![CDATA[https://native.com/lib.bin]]></ExecutableResource>
            <TrackingEvents>
              <Tracking event="verificationNotExecuted"><![CDATA[https://native.com/ne]]></Tracking>
            </TrackingEvents>
          </Verification>
        </AdVerifications>
        """))

        let reasons: [VASTAd.Verification.NotExecutedReason] = beacons(for: ad).compactMap {
            if case .verificationNotExecuted(let reason) = $0.kind { return reason }
            return nil
        }
        XCTAssertEqual(reasons, [.resourceNotSupported])
    }

    /// A host that does run them owes nothing — reporting anyway would contradict
    /// the measurement data the vendor is about to receive.
    func testNothingIsReportedWhenMeasurementWillRun() throws {
        let ad = try ad(inLine(verifications: """
        <AdVerifications>
          <Verification vendor="measure.com">
            <JavaScriptResource apiFramework="omid"><![CDATA[https://measure.com/v.js]]></JavaScriptResource>
            <TrackingEvents>
              <Tracking event="verificationNotExecuted"><![CDATA[https://measure.com/ne]]></Tracking>
            </TrackingEvents>
          </Verification>
        </AdVerifications>
        """))

        let reported = beacons(for: ad, measurementWillRun: true).filter {
            if case .verificationNotExecuted = $0.kind { return true } else { return false }
        }
        XCTAssertTrue(reported.isEmpty)
    }

    /// `[REASON]` is what tells the vendor *why*; sent literally it says nothing.
    func testReasonMacroExpandsToTheReportedCode() throws {
        let url = URL(string: "https://measure.com/ne?r=%5BREASON%5D")!
        let expanded = VASTMacroExpander().expand(
            url,
            with: .init(verificationNotExecutedReason: .notExecuted)
        )
        XCTAssertEqual(expanded.absoluteString, "https://measure.com/ne?r=3")
    }

    /// An unsupplied spec macro reports unknown rather than a guess.
    func testReasonMacroIsUnknownOnOtherBeacons() {
        let url = URL(string: "https://ads.test/e?r=%5BREASON%5D")!
        let expanded = VASTMacroExpander().expand(url, with: .init())
        XCTAssertEqual(expanded.absoluteString, "https://ads.test/e?r=-1")
    }
}
