//
//  VASTPlaybackControlsTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
import AVKit
@testable import VASTKit

/// The answer for a host drawing its own controls.
@MainActor
final class VASTPlaybackControlsOfferTests: XCTestCase {

    private func session() -> VASTAdSession {
        VASTAdSession(player: AVPlayer(), configuration: VASTAdSession.Configuration())
    }

    func testTheControlsAreWithdrawnForTheLengthOfABreak() {
        let session = session()
        XCTAssertTrue(session.permitsPlaybackControls, "between breaks the player is the host's")

        for state in [VASTAdSession.State.loading, .playing, .paused] {
            session.state = state
            XCTAssertFalse(session.permitsPlaybackControls, "offered during \(state)")
        }

        session.state = .finished(.completed)
        XCTAssertTrue(session.permitsPlaybackControls, "the break is over")
    }

    /// Unlike Picture in Picture, there is no policy that can leave the seek
    /// controls up: registering is the only choice, and it is the host's.
    func testTheAnswerDoesNotDependOnConfiguration() {
        for policy in [VASTAdSession.PictureInPicturePolicy.suspended, .pausesAd, .allowed] {
            let session = VASTAdSession(
                player: AVPlayer(),
                configuration: VASTAdSession.Configuration(pictureInPicture: policy)
            )
            session.state = .playing
            XCTAssertFalse(session.permitsPlaybackControls, "offered under \(policy)")
        }
    }
}

/// The coordinator that does it for an AVKit host.
///
/// Driven directly rather than through a break: `runBreak` needs a real item on a
/// real player, and what is worth asserting here is that the host's own settings
/// come back — value by value, and not from a default.
@MainActor
final class VASTPlaybackControlsCoordinatorTests: XCTestCase {

    func testABreakTakesTheSeekControlsAndGivesThemBack() {
        let controls = PlatformPlayerControls()
        let coordinator = VASTPlaybackControlsCoordinator(controls: controls)

        #if os(macOS)
        controls.controlsStyle = .floating
        coordinator.adBreakDidBegin()
        XCTAssertEqual(controls.controlsStyle, .none, "the pane still carries a timeline")
        coordinator.adBreakDidEnd()
        XCTAssertEqual(controls.controlsStyle, .floating)
        #else
        controls.requiresLinearPlayback = false
        coordinator.adBreakDidBegin()
        XCTAssertTrue(controls.requiresLinearPlayback, "the creative can be scrubbed past")
        XCTAssertTrue(controls.speeds.isEmpty, "a 2x ad is watched in half the time")
        coordinator.adBreakDidEnd()
        XCTAssertFalse(controls.requiresLinearPlayback)
        XCTAssertFalse(controls.speeds.isEmpty, "the host's speed menu is gone for good")
        #endif
    }

    /// A host that already required linear playback for its own content — a live
    /// stream, or a player that never allowed scrubbing — must not be handed
    /// scrubbing as a parting gift.
    func testAHostsOwnRestrictionSurvivesTheBreak() {
        let controls = PlatformPlayerControls()
        let coordinator = VASTPlaybackControlsCoordinator(controls: controls)

        #if os(macOS)
        controls.controlsStyle = .none
        coordinator.adBreakDidBegin()
        coordinator.adBreakDidEnd()
        XCTAssertEqual(controls.controlsStyle, .none)
        #else
        controls.requiresLinearPlayback = true
        coordinator.adBreakDidBegin()
        coordinator.adBreakDidEnd()
        XCTAssertTrue(controls.requiresLinearPlayback)
        #endif
    }

    /// Registering mid-break applies immediately, so `adBreakDidBegin` can arrive
    /// twice for one break. The second must not save what the first wrote.
    func testASecondBeginDoesNotOverwriteWhatWasSaved() {
        let controls = PlatformPlayerControls()
        let coordinator = VASTPlaybackControlsCoordinator(controls: controls)

        #if os(macOS)
        controls.controlsStyle = .inline
        coordinator.adBreakDidBegin()
        coordinator.adBreakDidBegin()
        coordinator.adBreakDidEnd()
        XCTAssertEqual(controls.controlsStyle, .inline)
        #else
        controls.requiresLinearPlayback = false
        coordinator.adBreakDidBegin()
        coordinator.adBreakDidBegin()
        coordinator.adBreakDidEnd()
        XCTAssertFalse(controls.requiresLinearPlayback)
        #endif
    }

    /// `unregisterPlaybackControls` while a break is running has to put the
    /// controls back on the way out: the host is taking its object home.
    func testInvalidatingRestoresWhatItChanged() {
        let controls = PlatformPlayerControls()
        let coordinator = VASTPlaybackControlsCoordinator(controls: controls)

        #if os(macOS)
        controls.controlsStyle = .floating
        coordinator.adBreakDidBegin()
        coordinator.invalidate()
        XCTAssertEqual(controls.controlsStyle, .floating)
        #else
        controls.requiresLinearPlayback = false
        coordinator.adBreakDidBegin()
        coordinator.invalidate()
        XCTAssertFalse(controls.requiresLinearPlayback)
        #endif
    }

    /// The session is the seam the host actually uses; it has to reach the same
    /// object twice without leaving the first one holding the controls.
    func testRegisteringTwiceLeavesOneCoordinator() {
        let session = VASTAdSession(player: AVPlayer(), configuration: VASTAdSession.Configuration())
        let controls = PlatformPlayerControls()

        session.registerPlaybackControls(controls)
        let first = session.playbackControls
        session.registerPlaybackControls(controls)
        XCTAssertNotNil(session.playbackControls)
        XCTAssertFalse(first === session.playbackControls)

        session.unregisterPlaybackControls()
        XCTAssertNil(session.playbackControls)
    }
}
