//
//  VASTMeasurementTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
@testable import VASTCore
@testable import VASTKit

/// The seam third-party measurement plugs into. What matters is not any single
/// call but the *sequence*, which is what measurement integrations get wrong.
@MainActor
final class VASTMeasurementTests: XCTestCase {

    private final class MeasurementSpy: iVASTAdMeasurement {
        var begins = 0
        var finishes = 0
        var events: [VASTMeasurementEvent] = []
        var context: VASTMeasurementContext?

        func begin(_ context: VASTMeasurementContext) {
            begins += 1
            self.context = context
        }
        func record(_ event: VASTMeasurementEvent) { events.append(event) }
        func finish() { finishes += 1 }
    }

    private actor RecordingTransport: iVASTBeaconTransport {
        private var fired: [VASTBeacon] = []
        func fire(_ beacons: [VASTBeacon]) { fired += beacons }
        func recorded() -> [VASTBeacon] { fired }
    }

    private func ad(verificationTracker: String? = nil) -> VASTAd {
        let verification = verificationTracker.map {
            VASTAd.Verification(
                vendor: "measure.com",
                resources: [.init(kind: .javaScript, url: URL(string: "https://measure.com/v.js")!, apiFramework: "omid")],
                notExecutedTrackers: [URL(string: $0)!]
            )
        }
        return VASTAd(
            id: "a1",
            linear: VASTAd.Linear(
                duration: 30,
                skipOffset: .time(5),
                mediaFiles: [],
                clickThrough: nil,
                clickTracking: [],
                trackingEvents: [
                    .start: [URL(string: "https://ads.test/start")!],
                    .firstQuartile: [URL(string: "https://ads.test/q1")!],
                ],
                progressEvents: []
            ),
            impressions: [
                URL(string: "https://ads.test/i1")!,
                URL(string: "https://ads.test/i2")!,
            ],
            adVerifications: verification.map { [$0] } ?? []
        )
    }

    // MARK: - Reporting changes when measurement exists

    /// With nothing measuring, the vendor is told so. The engine is where that
    /// decision lands, and the session is what tells it.
    func testVendorIsToldNothingRanItsCode() {
        var engine = VASTTrackingEngine(ad: ad(verificationTracker: "https://measure.com/ne"), measurementWillRun: false)
        let beacons = engine.advance(to: VASTTick(adTime: 0, duration: 30, rate: 1, wallClock: 0))

        XCTAssertTrue(beacons.contains { $0.kind == .verificationNotExecuted(.notExecuted) })
    }

    /// With something measuring, the SDK goes quiet: reporting "not executed"
    /// alongside real measurement data would contradict it.
    func testNothingIsReportedWhenMeasurementIsConfigured() {
        var engine = VASTTrackingEngine(ad: ad(verificationTracker: "https://measure.com/ne"), measurementWillRun: true)
        let beacons = engine.advance(to: VASTTick(adTime: 0, duration: 30, rate: 1, wallClock: 0))

        XCTAssertFalse(beacons.contains { if case .verificationNotExecuted = $0.kind { return true } else { return false } })
        XCTAssertTrue(beacons.contains { $0.kind == .impression }, "the ad still runs and is still tracked")
    }

    // MARK: - Event stream

    /// Driven from the beacons, so a vendor observes the same order the ad server
    /// is told about — and two `<Impression>` elements are still one impression.
    func testEventsFollowTheBeaconsAndCollapseDuplicates() {
        let session = VASTAdSession(player: AVPlayer())
        let spy = MeasurementSpy()
        session.measurement = spy

        let ad = ad()
        session.send([
            VASTBeacon(kind: .impression, url: ad.impressions[0], adID: ad.id),
            VASTBeacon(kind: .impression, url: ad.impressions[1], adID: ad.id),
            VASTBeacon(kind: .tracking(.start), url: URL(string: "https://ads.test/start")!, adID: ad.id),
            VASTBeacon(kind: .tracking(.firstQuartile), url: URL(string: "https://ads.test/q1")!, adID: ad.id),
            VASTBeacon(kind: .clickTracking, url: URL(string: "https://ads.test/click")!, adID: ad.id),
        ])

        XCTAssertEqual(spy.events, [
            .impression,
            .start(duration: 0, isMuted: false),
            .quartile(.firstQuartile),
            .clicked,
        ])
    }

    /// A notExecuted beacon only fires when nothing is measuring, so forwarding
    /// it to a measurement layer would be reporting to an empty room.
    func testNotExecutedBeaconsAreNotForwardedAsEvents() {
        let session = VASTAdSession(player: AVPlayer())
        let spy = MeasurementSpy()
        session.measurement = spy

        session.send([
            VASTBeacon(
                kind: .verificationNotExecuted(.notExecuted),
                url: URL(string: "https://measure.com/ne")!,
                adID: "a1"
            ),
        ])

        XCTAssertTrue(spy.events.isEmpty)
    }

    // MARK: - Reason 2

    /// `resourceLoadError` can only come from whoever tried to load the resource,
    /// which is never the SDK. This is the way back in.
    func testMeasurementCanReportALoadFailure() async {
        let transport = RecordingTransport()
        let session = VASTAdSession(
            player: AVPlayer(),
            configuration: VASTAdSession.Configuration(transport: transport)
        )
        let verification = VASTAd.Verification(
            vendor: "measure.com",
            resources: [.init(kind: .javaScript, url: URL(string: "https://measure.com/v.js")!, apiFramework: "omid")],
            notExecutedTrackers: [URL(string: "https://measure.com/ne?r=%5BREASON%5D")!]
        )
        session.currentAd = ad()

        session.reportVerificationNotExecuted(verification)

        // Beacons are dispatched and forgotten, so give the detached task a turn.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let fired = await transport.recorded()
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.kind, .verificationNotExecuted(.resourceLoadError))
        XCTAssertEqual(fired.first?.url.absoluteString, "https://measure.com/ne?r=2", "[REASON] carries the code")
    }

    /// Nothing to report against with no ad on screen.
    func testLoadFailureWithoutAnAdIsIgnored() async {
        let transport = RecordingTransport()
        let session = VASTAdSession(
            player: AVPlayer(),
            configuration: VASTAdSession.Configuration(transport: transport)
        )
        session.reportVerificationNotExecuted(
            VASTAd.Verification(vendor: "v", resources: [], notExecutedTrackers: [URL(string: "https://v/ne")!])
        )

        try? await Task.sleep(nanoseconds: 100_000_000)
        let fired = await transport.recorded()
        XCTAssertTrue(fired.isEmpty)
    }
}
