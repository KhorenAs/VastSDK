//
//  VASTReportedEventTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
@testable import VASTCore
@testable import VASTKit

/// What a host is told about its own tracking.
///
/// Tracking is the one thing a host cannot observe for itself — the beacons
/// live inside the response and go out from the session — so without this
/// callback an embedder has no way to know an ad reached its midpoint.
@MainActor
final class VASTReportedEventTests: XCTestCase {

    private final class DelegateSpy: NSObject, iVASTAdSessionDelegate {
        var reported: [VASTBeacon.Kind] = []

        func session(_ session: VASTAdSession, didReport event: VASTBeacon.Kind, for ad: VASTAd?) {
            reported.append(event)
        }
    }

    private func beacon(_ kind: VASTBeacon.Kind, _ url: String) -> VASTBeacon {
        VASTBeacon(kind: kind, url: URL(string: url)!, adID: "a1")
    }

    /// The same sequence, in the same order, that the ad server is told about.
    func testTheDelegateHearsWhatTheAdServerHears() {
        let session = VASTAdSession(player: AVPlayer())
        let spy = DelegateSpy()
        session.delegate = spy

        session.send([
            beacon(.impression, "https://ads.test/i1"),
            beacon(.tracking(.start), "https://ads.test/start"),
            beacon(.tracking(.firstQuartile), "https://ads.test/q1"),
            beacon(.progress(7), "https://ads.test/p7"),
            beacon(.clickTracking, "https://ads.test/click"),
        ])

        XCTAssertEqual(spy.reported, [
            .impression,
            .tracking(.start),
            .tracking(.firstQuartile),
            .progress(7),
            .clickTracking,
        ])
    }

    /// A response carrying several `<Impression>` URLs is several beacons and
    /// one impression, the same collapse measurement makes.
    func testRepeatedKindsCollapseToOneEvent() {
        let session = VASTAdSession(player: AVPlayer())
        let spy = DelegateSpy()
        session.delegate = spy

        session.send([
            beacon(.impression, "https://ads.test/i1"),
            beacon(.impression, "https://ads.test/i2"),
            beacon(.impression, "https://ads.test/i3"),
        ])

        XCTAssertEqual(spy.reported, [.impression])
    }

    /// Collapsing is only of neighbours: a quartile between two impressions
    /// means the second impression really is a second report.
    func testOnlyAdjacentDuplicatesCollapse() {
        let session = VASTAdSession(player: AVPlayer())
        let spy = DelegateSpy()
        session.delegate = spy

        session.send([
            beacon(.impression, "https://ads.test/i1"),
            beacon(.tracking(.midpoint), "https://ads.test/q2"),
            beacon(.impression, "https://ads.test/i2"),
        ])

        XCTAssertEqual(spy.reported, [.impression, .tracking(.midpoint), .impression])
    }

    /// Errors reach the delegate too. A host that never sees them cannot tell a
    /// break that failed from one nobody watched.
    func testErrorsAreReported() {
        let session = VASTAdSession(player: AVPlayer())
        let spy = DelegateSpy()
        session.delegate = spy

        session.send([beacon(.error(.mediaFileNotFound), "https://ads.test/e")])

        XCTAssertEqual(spy.reported, [.error(.mediaFileNotFound)])
    }

    /// Nothing sent, nothing reported — the callback mirrors reporting rather
    /// than playback.
    func testNothingIsReportedForAnEmptyBatch() {
        let session = VASTAdSession(player: AVPlayer())
        let spy = DelegateSpy()
        session.delegate = spy

        session.send([])

        XCTAssertTrue(spy.reported.isEmpty)
    }
}
