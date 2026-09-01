//
//  VASTTrackingEngineTests.swift
//  VASTCoreTests
//

import XCTest
@testable import VASTCore

/// The engine is pure, so every rule below is exercised with a scripted tick
/// sequence — no player, no media file, no real elapsed time.
final class VASTTrackingEngineTests: XCTestCase {

    // MARK: - Fixtures

    private func url(_ path: String) -> URL { URL(string: "https://ads.test/\(path)")! }

    /// 30 second ad, skippable at 5s, full quartile set plus a 15s progress beacon.
    private func makeAd(duration: TimeInterval = 30) -> VASTAd {
        VASTAd(
            id: "ad-1",
            linear: VASTAd.Linear(
                duration: duration,
                skipOffset: .time(5),
                trackingEvents: [
                    .start: [url("start")],
                    .firstQuartile: [url("q1")],
                    .midpoint: [url("q2")],
                    .thirdQuartile: [url("q3")],
                    .complete: [url("complete")],
                    .skip: [url("skip")],
                ],
                progressEvents: [.init(offset: .time(15), url: url("p15"))]
            ),
            impressions: [url("impression")],
            errors: [url("error")]
        )
    }

    private func tick(_ time: TimeInterval, _ wall: TimeInterval, rate: Float = 1, ours: Bool = true) -> VASTTick {
        VASTTick(adTime: time, duration: 30, rate: rate, wallClock: wall, itemIsOurs: ours)
    }

    /// Runs a tick sequence and returns the events that fired, in order.
    private func play(
        _ ticks: [(TimeInterval, TimeInterval)],
        ad: VASTAd? = nil,
        engine: inout VASTTrackingEngine
    ) -> [String] {
        ticks.flatMap { engine.advance(to: tick($0.0, $0.1)) }.map(\.label)
    }

    // MARK: - Normal playback

    func testUninterruptedPlaybackFiresEveryEventOnce() {
        var engine = VASTTrackingEngine(ad: makeAd())
        let events = play(stride(from: 0.0, through: 30.0, by: 1.0).map { ($0, $0) }, engine: &engine)

        XCTAssertEqual(events, [
            "impression", "start", "firstQuartile", "midpoint", "p15", "thirdQuartile", "complete",
        ])
        XCTAssertEqual(engine.watched, 30, accuracy: 0.01)
    }

    func testImpressionFiresOnceEvenAcrossManyTicks() {
        var engine = VASTTrackingEngine(ad: makeAd())
        let events = play([(0, 0), (1, 1), (2, 2), (3, 3)], engine: &engine)

        XCTAssertEqual(events.filter { $0 == "impression" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "start" }.count, 1)
    }

    // MARK: - Seeking

    /// VAST 4.3 §3.14.1 defines a quartile as the creative having "played
    /// continuously ... at normal speed", so skipping ahead must not earn one.
    func testForwardSeekDoesNotEarnQuartiles() {
        var engine = VASTTrackingEngine(ad: makeAd())
        let events = play([(0, 0), (1, 1), (2, 2), (28, 3), (29, 4)], engine: &engine)

        XCTAssertEqual(events, ["impression", "start"])
        XCTAssertFalse(events.contains("firstQuartile"))
        XCTAssertFalse(events.contains("complete"))
        XCTAssertEqual(engine.watched, 2, accuracy: 0.01)
    }

    /// Regression: the tick immediately after a seek looks like ordinary
    /// playback, so a mark anchored on the raw playhead let the skipped span back
    /// in and unlocked every quartile. Coverage stays where the viewer left off.
    func testTickAfterForwardSeekDoesNotReadmitSkippedTime() {
        var engine = VASTTrackingEngine(ad: makeAd())
        _ = play([(0, 0), (1, 1), (2, 2), (28, 3), (29, 4), (30, 5)], engine: &engine)

        XCTAssertEqual(engine.watched, 2, accuracy: 0.01)
    }

    func testRewindDoesNotRefireAlreadyEarnedQuartiles() {
        var engine = VASTTrackingEngine(ad: makeAd())
        let events = play([(0, 0), (8, 8), (16, 16), (2, 17), (3, 18), (4, 19)], engine: &engine)

        XCTAssertEqual(events.filter { $0 == "firstQuartile" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "midpoint" }.count, 1)
        // Coverage peaked at 16s; rewinding and replaying does not extend it.
        XCTAssertEqual(engine.watched, 16, accuracy: 0.01)
    }

    // MARK: - Player state

    func testPausedTicksDoNotAccumulateWatchedTime() {
        var engine = VASTTrackingEngine(ad: makeAd())
        _ = engine.advance(to: tick(0, 0))
        _ = engine.advance(to: tick(4, 4))
        // Paused for ten wall-clock seconds; the playhead does not move.
        _ = engine.advance(to: tick(4, 14, rate: 0))
        _ = engine.advance(to: tick(5, 15))

        XCTAssertEqual(engine.watched, 5, accuracy: 0.01, "the pause cost no coverage")
    }

    /// The host swapping the player's item out means nothing afterwards can be
    /// attributed to this creative.
    func testForeignPlayerItemEndsSessionWithDisplayError() {
        var engine = VASTTrackingEngine(ad: makeAd())
        _ = engine.advance(to: tick(0, 0))
        _ = engine.advance(to: tick(4, 4))
        let beacons = engine.advance(to: tick(5, 5, ours: false))

        XCTAssertEqual(beacons.map(\.label), ["error 405"])
        XCTAssertTrue(engine.isFinished)
        XCTAssertTrue(engine.advance(to: tick(6, 6)).isEmpty, "a finished session emits nothing further")
    }

    // MARK: - Skip

    /// §3.14.1: a `progress` offset the viewer already earned still counts when
    /// the ad is skipped after it — that is what makes a skipped view billable.
    func testSkipAfterProgressOffsetStillFiresThatProgressBeacon() {
        var engine = VASTTrackingEngine(ad: makeAd())
        _ = play(stride(from: 0.0, through: 16.0, by: 1.0).map { ($0, $0) }, engine: &engine)
        let events = engine.userDidSkip().map(\.label)

        XCTAssertEqual(events, ["skip"], "p15 already fired during playback")
        XCTAssertTrue(engine.isFinished)
    }

    func testSkipBeforeProgressOffsetDoesNotFireIt() {
        var engine = VASTTrackingEngine(ad: makeAd())
        _ = play([(0, 0), (1, 1), (2, 2)], engine: &engine)
        let events = engine.userDidSkip().map(\.label)

        XCTAssertEqual(events, ["skip"])
    }

    func testSkipAfterFinishEmitsNothing() {
        var engine = VASTTrackingEngine(ad: makeAd())
        _ = play(stride(from: 0.0, through: 30.0, by: 1.0).map { ($0, $0) }, engine: &engine)

        XCTAssertTrue(engine.userDidSkip().isEmpty)
    }

    // MARK: - Errors

    func testFailureFiresEveryErrorURIInTheChain() {
        let ad = VASTAd(
            id: "ad-1",
            linear: VASTAd.Linear(duration: 30),
            errors: [url("wrapper-1-error"), url("wrapper-2-error"), url("inline-error")]
        )
        var engine = VASTTrackingEngine(ad: ad)
        let beacons = engine.fail(.noSupportedMediaFile)

        XCTAssertEqual(beacons.count, 3, "§2.3.5.1 requires every wrapper in the chain to be told")
        XCTAssertEqual(Set(beacons.map(\.label)), ["error 403"])
    }

    // MARK: - Duration

    func testZeroDurationNeverFiresQuartiles() {
        var engine = VASTTrackingEngine(ad: makeAd(duration: 0), duration: 0)
        let events = play([(0, 0), (1, 1), (2, 2)], engine: &engine)

        XCTAssertFalse(events.contains("firstQuartile"))
    }

    /// `<Duration>` is advisory; the player's real duration wins when supplied.
    func testPlayerDurationOverridesDeclaredDuration() {
        var engine = VASTTrackingEngine(ad: makeAd(duration: 30), duration: 8)
        let events = play([(0, 0), (2, 2), (4, 4)], engine: &engine)

        XCTAssertTrue(events.contains("firstQuartile"))
        XCTAssertTrue(events.contains("midpoint"))
    }
}

// MARK: - Helpers

private extension VASTBeacon {

    /// Short, stable name for assertions.
    var label: String {
        switch kind {
        case .impression: "impression"
        case .tracking(let event): event.rawValue
        case .progress: url.lastPathComponent
        case .clickTracking: "clickTracking"
        case .error(let error): "error \(error.rawValue)"
        case .verificationNotExecuted(let reason): "verificationNotExecuted \(reason.rawValue)"
        }
    }
}

// MARK: - End of playback

/// Regression cases for the hang that made an ad look paused on its last frame.
extension VASTTrackingEngineTests {

    /// Buffering does not skip any of the creative, so it must not stand between
    /// the viewer and `complete`. Discounting stalls — as summing playback deltas
    /// would — left the ad frozen on its last frame with nothing able to end it.
    func testStallDoesNotPreventCompletion() {
        var engine = VASTTrackingEngine(ad: makeAd())
        var events: [String] = []

        events += engine.advance(to: tick(0, 0)).map(\.label)
        for second in 1...10 {
            events += engine.advance(to: tick(Double(second), Double(second))).map(\.label)
        }
        events += engine.advance(to: tick(10, 18)).map(\.label)   // stalled 8s
        for second in 11...30 {
            events += engine.advance(to: tick(Double(second), Double(second) + 8)).map(\.label)
        }

        XCTAssertEqual(engine.watched, 30, accuracy: 0.01, "the stall cost no coverage")
        XCTAssertTrue(events.contains("complete"))
    }

    /// Real media routinely runs a little short of its declared `<Duration>`, so
    /// coverage alone may never cross the threshold. The player's end-of-item
    /// signal is what ends the ad in that case.
    func testShortMediaEndsOnEndOfItemRatherThanHanging() {
        var engine = VASTTrackingEngine(ad: makeAd(duration: 30), duration: 30)
        // The file actually runs 26s, so coverage stops well short of 29.1.
        _ = engine.advance(to: tick(0, 0))
        for second in 1...26 {
            _ = engine.advance(to: tick(Double(second), Double(second)))
        }
        XCTAssertFalse(engine.isFinished, "coverage cannot reach a threshold the media never allows")

        let beacons = engine.playbackDidReachEnd().map(\.label)
        XCTAssertTrue(engine.isFinished)
        XCTAssertFalse(
            beacons.contains("complete"),
            "26 of a declared 30 seconds is not 100% of the creative"
        )
    }

    /// Reaching the end is not the same as having watched it: seeking to the end
    /// must not earn `complete` (§3.14.1 "played to the end at normal speed").
    func testSeekingToTheEndDoesNotEarnComplete() {
        var engine = VASTTrackingEngine(ad: makeAd())
        _ = engine.advance(to: tick(0, 0))
        _ = engine.advance(to: tick(1, 1))
        _ = engine.advance(to: tick(29, 2))             // jump

        let beacons = engine.playbackDidReachEnd().map(\.label)
        XCTAssertFalse(beacons.contains("complete"))
        XCTAssertTrue(engine.isFinished, "the session still ends")
    }

    func testEndOfItemIsIgnoredAfterTheSessionAlreadyFinished() {
        var engine = VASTTrackingEngine(ad: makeAd())
        _ = play(stride(from: 0.0, through: 30.0, by: 1.0).map { ($0, $0) }, engine: &engine)

        XCTAssertTrue(engine.isFinished)
        XCTAssertTrue(engine.playbackDidReachEnd().isEmpty, "complete must not fire twice")
    }

    /// `<Duration>` is advisory and routinely disagrees with the real media by a
    /// fraction of a second; the player's figure replaces it.
    func testReportedDurationReplacesTheDeclaredOne() {
        var engine = VASTTrackingEngine(ad: makeAd(duration: 24))
        _ = engine.advance(to: VASTTick(adTime: 0, duration: 24.04, rate: 1, wallClock: 0))
        XCTAssertEqual(engine.duration, 24.04, accuracy: 0.001)
    }

    // MARK: - The end of the creative

    /// What the engine cuts off the end of a creative is bounded by one tick, not
    /// by a fraction of the running time.
    ///
    /// As a ratio the same figure took nearly a second off a thirty-second ad and
    /// a third of that off a ten-second one — the wrong quantity to hold
    /// constant, and the longer the creative the more of its ending was lost.
    func testTheCutAtTheEndIsWithinOneTickWhateverTheDuration() {
        let interval = 0.2

        for duration in [10.0, 30.0, 60.0] {
            var engine = VASTTrackingEngine(ad: makeAd(duration: duration), duration: duration)
            var completedAt: TimeInterval?
            var time = 0.0

            while time <= duration, completedAt == nil {
                let fired = engine.advance(to: VASTTick(
                    adTime: time, duration: duration, rate: 1, wallClock: time
                )).map(\.label)
                if fired.contains("complete") { completedAt = time }
                time += interval
            }

            let completed = try? XCTUnwrap(completedAt)
            XCTAssertNotNil(completed, "a \(Int(duration))s creative never completed")
            XCTAssertLessThanOrEqual(
                duration - (completed ?? 0), interval + 0.001,
                "a \(Int(duration))s creative lost more than one tick of its ending"
            )
        }
    }

    /// A creative that stalls *after* being watched through is finished, not
    /// broken. Reporting 402 for its last frames would tell the ad server that a
    /// delivered impression had failed.
    func testAStallPastTheWatchedThresholdCompletesRatherThanFailing() {
        var engine = VASTTrackingEngine(ad: makeAd(duration: 30), duration: 30)
        _ = engine.advance(to: tick(0, 0))
        for second in 1...29 {
            _ = engine.advance(to: tick(Double(second), Double(second)))
        }
        // Past `completionThreshold`, short of the margin the engine finishes on.
        _ = engine.advance(to: tick(29.5, 29.5))
        XCTAssertFalse(engine.isFinished)

        let beacons = engine.playbackDidStall().map(\.label)
        XCTAssertTrue(beacons.contains("complete"), "29.5 of 30 seconds is a watched creative")
        XCTAssertFalse(beacons.contains("error 402"))
        XCTAssertTrue(engine.isFinished)
    }

    /// A creative that never advances is written off, and the error goes to every
    /// URI in the chain.
    func testStallReportsMediaTimeout() {
        var engine = VASTTrackingEngine(ad: makeAd())
        _ = engine.advance(to: tick(0, 0))
        let beacons = engine.playbackDidStall().map(\.label)

        XCTAssertEqual(beacons, ["error 402"])
        XCTAssertTrue(engine.isFinished)
    }
}
