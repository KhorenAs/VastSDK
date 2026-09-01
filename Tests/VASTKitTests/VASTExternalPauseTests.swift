//
//  VASTExternalPauseTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
@testable import VASTCore
@testable import VASTKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

private final actor RecordingTransport: iVASTBeaconTransport {
    private(set) var beacons: [VASTBeacon] = []
    func fire(_ beacons: [VASTBeacon]) async { self.beacons += beacons }
    func recorded() async -> [VASTBeacon] { beacons }
}

/// A pause the SDK did not make.
///
/// The Picture in Picture window's own button is the case that prompted these —
/// it cannot be removed, so it has to be understood — but a host reaching for
/// `AVPlayer.pause()` lands in the same place. Both used to be silent: no
/// §3.14.1 `pause`, no `resume`, `state` still saying the ad was playing, and a
/// measurement layer reading the beacons told the same thing.
@MainActor
final class VASTExternalPauseTests: XCTestCase {

    private func makeSession(
        _ policy: VASTAdSession.PictureInPicturePolicy = .suspended,
        transport: RecordingTransport
    ) -> VASTAdSession {
        VASTAdSession(
            player: AVPlayer(),
            configuration: VASTAdSession.Configuration(
                restoresPlayerItem: false,
                pictureInPicture: policy,
                transport: transport
            )
        )
    }

    private func trackedAd() -> VASTAd {
        VASTAd(
            id: "a1",
            linear: VASTAd.Linear(
                duration: 30,
                skipOffset: nil,
                mediaFiles: [],
                clickThrough: nil,
                clickTracking: [],
                trackingEvents: [
                    .pause: [URL(string: "https://ads.test/pause")!],
                    .resume: [URL(string: "https://ads.test/resume")!],
                ],
                progressEvents: []
            )
        )
    }

    /// A break running with a creative on screen, ten seconds from its end.
    @discardableResult
    private func playing(_ session: VASTAdSession) -> VASTPlaybackController {
        let ad = trackedAd()
        let playback = VASTPlaybackController(player: session.player)
        session.currentAd = ad
        session.activePlayback = playback
        session.activeEngine = VASTTrackingEngine(ad: ad, measurementWillRun: false)
        session.remainingTime = 10
        session.state = .playing
        return playback
    }

    /// Beacons are dispatched rather than awaited — one slow tracking host must
    /// not be able to stop the playback loop — so a test has to let that happen.
    private func fired(_ transport: RecordingTransport) async -> [VASTBeacon] {
        try? await Task.sleep(nanoseconds: 50_000_000)
        return await transport.recorded()
    }

    /// Puts the controller in the state leaving the app puts it in.
    private func suspendBySystem() async {
        #if os(macOS)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #else
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        #endif
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: - Reported

    func testAPauseFromOutsideIsReportedAndHeld() async {
        let transport = RecordingTransport()
        let session = makeSession(transport: transport)
        let playback = playing(session)

        session.noteExternalPlayback(isPlaying: false)

        XCTAssertEqual(session.state, .paused)
        XCTAssertTrue(
            playback.isPausedByUser,
            "without this the tick loop re-issues playback and undoes the pause"
        )
        let beacons = await fired(transport)
        XCTAssertTrue(beacons.contains { $0.kind == .tracking(.pause) })
    }

    func testResumingFromOutsideIsReportedToo() async {
        let transport = RecordingTransport()
        let session = makeSession(transport: transport)
        let playback = playing(session)

        session.noteExternalPlayback(isPlaying: false)
        session.noteExternalPlayback(isPlaying: true)

        XCTAssertEqual(session.state, .playing)
        XCTAssertFalse(playback.isPausedByUser)
        let beacons = await fired(transport)
        XCTAssertTrue(beacons.contains { $0.kind == .tracking(.resume) })
    }

    /// Playback carries on in the window while the app is away, so a stop there
    /// is the viewer's own control and nothing else.
    func testAPauseInTheWindowIsReportedWhileTheAppIsAway() async {
        let transport = RecordingTransport()
        let session = makeSession(.allowed, transport: transport)
        playing(session)
        session.isInPictureInPicture = true
        await suspendBySystem()

        session.noteExternalPlayback(isPlaying: false)

        XCTAssertEqual(session.state, .paused)
        let beacons = await fired(transport)
        XCTAssertTrue(beacons.contains { $0.kind == .tracking(.pause) })
    }

    // MARK: - Not a pause

    /// Leaving the app stops decoding, and that is the system rather than the
    /// viewer: it lifts on its own, and reporting it would put a `pause` in
    /// every session that was ever backgrounded.
    func testLeavingTheAppIsNotAPause() async {
        let transport = RecordingTransport()
        let session = makeSession(transport: transport)
        playing(session)
        await suspendBySystem()

        session.noteExternalPlayback(isPlaying: false)

        XCTAssertEqual(session.state, .playing)
        let beacons = await fired(transport)
        XCTAssertFalse(beacons.contains { $0.kind == .tracking(.pause) })
    }

    /// Under `.suspended` the ad is not meant to be in the window at all, and
    /// the stop seen there is the window closing at the SDK's own request.
    func testTheWindowClosingUnderSuspendIsNotAPause() async {
        let transport = RecordingTransport()
        let session = makeSession(.suspended, transport: transport)
        playing(session)
        session.isInPictureInPicture = true
        await suspendBySystem()

        session.noteExternalPlayback(isPlaying: false)

        XCTAssertEqual(session.state, .playing)
        let beacons = await fired(transport)
        XCTAssertFalse(beacons.contains { $0.kind == .tracking(.pause) })
    }

    /// The creative running out stops the player like anything else does.
    /// `pause` arriving after `complete` is a sequence no ad server should see.
    func testTheEndOfTheCreativeIsNotAPause() async {
        let transport = RecordingTransport()
        let session = makeSession(transport: transport)
        playing(session)
        session.remainingTime = 0.1

        session.noteExternalPlayback(isPlaying: false)

        XCTAssertEqual(session.state, .playing)
        let beacons = await fired(transport)
        XCTAssertFalse(beacons.contains { $0.kind == .tracking(.pause) })
    }

    /// The same, from the other side: an engine that is done with this ad has
    /// nothing left to report about it.
    func testAFinishedAdIsNotPaused() async {
        let transport = RecordingTransport()
        let session = makeSession(transport: transport)
        playing(session)
        var engine = session.activeEngine!
        _ = engine.fail(.undefined)
        session.activeEngine = engine

        session.noteExternalPlayback(isPlaying: false)

        XCTAssertEqual(session.state, .playing)
        let beacons = await fired(transport)
        XCTAssertFalse(beacons.contains { $0.kind == .tracking(.pause) })
    }

    /// Nothing is playing, so there is nothing to pause — and no break to
    /// report it against.
    func testAPauseBetweenBreaksIsIgnored() async {
        let transport = RecordingTransport()
        let session = makeSession(transport: transport)

        session.noteExternalPlayback(isPlaying: false)

        XCTAssertEqual(session.state, .idle)
        let beacons = await fired(transport)
        XCTAssertTrue(beacons.isEmpty)
    }
}
