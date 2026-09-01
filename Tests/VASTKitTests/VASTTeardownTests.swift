//
//  VASTTeardownTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
@testable import VASTCore
@testable import VASTKit

private struct SlowLoader: iVASTResourceLoader {
    let xml: String
    let delay: TimeInterval
    func loadVAST(from url: URL, timeout: TimeInterval) async throws -> String {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return xml
    }
}

/// Leaving the screen, and asking for a second break, both used to leave the
/// first one running: still holding the player, still making noise.
@MainActor
final class VASTTeardownTests: XCTestCase {

    private static let response = """
    <VAST version="4.3"><Ad id="a"><InLine>
      <AdSystem>test</AdSystem>
      <Impression><![CDATA[https://ads.test/impression]]></Impression>
      <Creatives><Creative><Linear skipoffset="00:00:02">
        <Duration>00:00:30</Duration>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4"><![CDATA[https://ads.test/v.mp4]]></MediaFile></MediaFiles>
      </Linear></Creative></Creatives>
    </InLine></Ad></VAST>
    """

    private func makeSession(loadDelay: TimeInterval = 0) -> (VASTAdSession, AVPlayer) {
        let player = AVPlayer()
        let session = VASTAdSession(
            player: player,
            configuration: VASTAdSession.Configuration(
                loader: SlowLoader(xml: Self.response, delay: loadDelay)
            )
        )
        return (session, player)
    }

    /// The symptom was audible: back out of the screen and the ad kept playing.
    /// `stop()` has to leave the player silent, and the break's own teardown must
    /// not undo that by restoring the content and resuming it.
    func testStopLeavesThePlayerPaused() async {
        let (session, player) = makeSession()
        try? await session.load(tag: URL(string: "https://ads.test/tag")!)

        let playing = Task { @MainActor in await session.play() }
        try? await Task.sleep(nanoseconds: 300_000_000)

        session.stop()
        _ = await playing.value
        // Give the abandoned break's teardown a chance to misbehave.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(player.rate, 0, "the player is still playing after stop()")
        XCTAssertEqual(session.state, .idle)
    }

    /// `stop()` while the creative is still loading: the wait has to give up
    /// rather than come back later and start playing on a player nobody is
    /// watching.
    func testStopDuringCreativeLoadDoesNotStartPlayback() async {
        let (session, player) = makeSession()
        try? await session.load(tag: URL(string: "https://ads.test/tag")!)

        let playing = Task { @MainActor in await session.play() }
        // Abort almost immediately — the creative cannot be ready yet.
        try? await Task.sleep(nanoseconds: 20_000_000)
        session.stop()

        _ = await playing.value
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(session.currentAd, "an abandoned break left an ad on screen")
    }

    /// Asking for a second break replaces the first rather than racing it. Two
    /// live breaks meant two creatives swapping into one player.
    func testSecondLoadEndsTheFirstBreakBeforeStartingAnother() async {
        let (session, _) = makeSession()
        try? await session.load(tag: URL(string: "https://ads.test/tag")!)

        let first = Task { @MainActor in await session.play() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        // A "replay" press: load again while the first break is still running.
        try? await session.load(tag: URL(string: "https://ads.test/tag")!)

        let firstOutcome = await first.value
        XCTAssertNotEqual(firstOutcome, .completed, "the abandoned break reported success")

        let second = await session.play()
        XCTAssertNotNil(second, "the replacement break ran")
        session.stop()
    }

    /// Two `play()` calls join one break instead of starting rivals.
    func testConcurrentPlayCallsShareOneBreak() async {
        let (session, _) = makeSession()
        try? await session.load(tag: URL(string: "https://ads.test/tag")!)

        async let first = session.play()
        async let second = session.play()
        let outcomes = await [first, second]

        XCTAssertEqual(outcomes[0], outcomes[1], "the two callers saw different breaks")
        session.stop()
    }
}

// MARK: - No fill

/// A tracking host that never answers, which is what an unreachable `<Error>`
/// URI is in practice.
private struct HangingTransport: iVASTBeaconTransport {
    func fire(_ beacons: [VASTBeacon]) async {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

extension VASTTeardownTests {

    private static let noFill = """
    <VAST version="4.3"><Error><![CDATA[https://ads.test/no-ad]]></Error></VAST>
    """

    /// Regression: reporting the no-fill error was awaited, so `load` stayed in
    /// `.loading` for as long as the ad server's tracking host took to answer.
    /// With an unreachable host that is forever, and the screen never recovered.
    func testNoFillFailsPromptlyEvenWhenTrackingHangs() async {
        let session = VASTAdSession(
            player: AVPlayer(),
            configuration: VASTAdSession.Configuration(
                transport: HangingTransport(),
                loader: SlowLoader(xml: Self.noFill, delay: 0)
            )
        )

        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await session.load(tag: URL(string: "https://ads.test/tag")!)
            XCTFail("a response with no ads should not load")
        } catch {
            XCTAssertEqual(error as? VASTError, .noVASTResponseAfterWrappers)
            XCTAssertEqual(VASTError.noVASTResponseAfterWrappers.rawValue, 303)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertLessThan(elapsed, 1, "load waited on a tracking request")
        XCTAssertEqual(session.state, .finished(.failed(.noVASTResponseAfterWrappers)))
    }
}

// MARK: - Navigating away mid-load

extension VASTTeardownTests {

    /// The reported symptom: open the screen, leave, repeat, and eventually an ad
    /// is heard with no screen showing it.
    ///
    /// The cause was ordering. `stop()` cleared the schedule, but a `load` still
    /// resolving came back afterwards and put it straight back — so the `play`
    /// queued behind it started a break on a dismissed screen, with nothing left
    /// to stop it.
    func testLoadResolvingAfterStopDoesNotArmTheSession() async {
        let (session, player) = makeSession(loadDelay: 0.4)

        // The host's flow: load, then play. Both are in flight when it leaves.
        let flow = Task { @MainActor in
            try? await session.load(tag: URL(string: "https://ads.test/tag")!)
            _ = await session.play()
        }

        // Navigate away while the response is still being fetched.
        try? await Task.sleep(nanoseconds: 100_000_000)
        session.stop()

        _ = await flow.value
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(player.rate, 0, "an ad started on a stopped session")
        XCTAssertNil(session.currentAd)
        XCTAssertEqual(session.state, .idle)
    }

    /// `load` says why it gave up, so a host can tell its own teardown apart from
    /// an ad server problem.
    func testLoadInterruptedByStopReportsThatItWasStopped() async {
        let (session, _) = makeSession(loadDelay: 0.4)

        let load = Task { @MainActor () -> Error? in
            do {
                try await session.load(tag: URL(string: "https://ads.test/tag")!)
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        session.stop()

        let error = await load.value
        XCTAssertEqual(error as? VASTAdSession.SessionError, .stopped)
    }

    /// Open and close repeatedly. Each session has to end silent — one that does
    /// not is the leak that was audible after a few passes.
    func testRepeatedOpenAndCloseLeavesNothingPlaying() async {
        var players: [AVPlayer] = []

        for _ in 0..<5 {
            let (session, player) = makeSession(loadDelay: 0.1)
            players.append(player)

            let flow = Task { @MainActor in
                try? await session.load(tag: URL(string: "https://ads.test/tag")!)
                _ = await session.play()
            }
            // Leave at a different moment each pass, before and after the load.
            try? await Task.sleep(nanoseconds: 80_000_000)
            session.stop()
            _ = await flow.value
        }

        try? await Task.sleep(nanoseconds: 500_000_000)
        for (index, player) in players.enumerated() {
            XCTAssertEqual(player.rate, 0, "player \(index) is still playing")
        }
    }
}
