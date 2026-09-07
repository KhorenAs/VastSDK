//
//  VASTPlaybackControlsCoordinator.swift
//  VASTSDK
//

import Foundation
import AVKit
import VASTCore

#if os(macOS)
/// The AVKit object that draws the host's transport controls on this platform.
public typealias PlatformPlayerControls = AVPlayerView
#else
public typealias PlatformPlayerControls = AVPlayerViewController
#endif

public extension VASTAdSession {

    /// Hands the session the AVKit object that draws the host's transport
    /// controls, so a break can take the seek controls off it and give them back.
    ///
    /// An ad the viewer can scrub is an ad the viewer can get past. Nothing is
    /// *mis-measured* when they do — a forward seek never extends the tracking
    /// engine's coverage of the creative, and reaching the end that way is not
    /// completion — but the viewer still leaves the ad behind, and the advertiser
    /// still paid for the impression they were shown. VAST defines no attribute
    /// that would permit seeking inside a linear creative; the only reason it is
    /// possible is that the controls belong to the host.
    ///
    /// The SDK does not build the object and could not: the controls belong to
    /// the host's player view, which the SDK deliberately does not own, and an ad
    /// break is handed only an `AVPlayer`. Apple's own header says as much —
    /// "This method should not be used to disable scrubbing; use the
    /// `requiresLinearPlayback` property of the AVPlayerViewController instead."
    /// A session never sees that object, and cannot know the host uses AVKit at
    /// all. What it needs is a handle, and the host is the only one holding one.
    ///
    /// What a break changes and puts back, value by value:
    ///
    /// - `requiresLinearPlayback` on iOS and tvOS, which removes scrubbing, fast
    ///   forward and forward skip. Play and pause are not on that list and stay:
    ///   a paused ad is reported as a §3.14.1 `pause` rather than fought.
    /// - `speeds`, emptied for the length of the break. Watched time is measured
    ///   from the playhead, so a creative played at 2× is watched in half the time
    ///   and every quartile still fires — the same reason
    ///   `NowPlayingPolicy.describesAd` locks `changePlaybackRateCommand`.
    /// - `controlsStyle` on macOS, set to `.none`. `AVPlayerView` has no
    ///   `requiresLinearPlayback` and no delegate method that can refuse a seek,
    ///   and what the `.minimal` pane contains is not documented, so the pane
    ///   that certainly carries no timeline is the only honest answer. It costs
    ///   the viewer play and pause for the length of the break, which is the one
    ///   place this is blunter than it wants to be.
    ///
    /// Registering is the opt-in, which is why there is no policy to choose: a
    /// host that wants to keep its own controls simply does not register them,
    /// and binds `permitsPlaybackControls` to whatever it draws instead. Call
    /// `unregisterPlaybackControls()` if the player outlives the session.
    ///
    /// Outside a break nothing here touches the controls. They are the host's the
    /// rest of the time.
    func registerPlaybackControls(_ controls: PlatformPlayerControls) {
        playbackControls?.invalidate()
        let coordinator = VASTPlaybackControlsCoordinator(controls: controls)
        playbackControls = coordinator
        // Registered mid-break: the creative is already the item in the player,
        // so the controls have to be taken now rather than at the next break —
        // which for a single pre-roll would be never.
        if activeBreak != nil { coordinator.adBreakDidBegin() }
    }

    /// Gives the controls back and stops the session touching them.
    func unregisterPlaybackControls() {
        playbackControls?.invalidate()
        playbackControls = nil
    }
}

// MARK: - Coordinator

/// Borrows the host's transport controls for the length of an ad break and gives
/// them back exactly as they were.
///
/// Not `VASTPlaybackController`, which borrows the player *item*. This borrows
/// nothing but the controls over it, and the two are separate because a host can
/// have the first without the second: a custom control bar, or none at all.
///
/// Every change is saved before it is made and restored from the saved value
/// rather than from a default — a host that already required linear playback for
/// its own content must not have scrubbing switched on for it when the ad ends.
/// `nil` means "not ours to restore".
@MainActor
final class VASTPlaybackControlsCoordinator {

    private weak var controls: PlatformPlayerControls?

    #if os(macOS)
    private var savedControlsStyle: AVPlayerViewControlsStyle?
    #else
    private var savedRequiresLinearPlayback: Bool?
    private var savedSpeeds: [AVPlaybackSpeed]?
    #endif

    init(controls: PlatformPlayerControls) {
        self.controls = controls
    }

    // MARK: - Break lifetime

    /// Saves the host's settings and applies the break's. A second call while
    /// the first is still in force does nothing: it would otherwise save the
    /// values this coordinator had just written and "restore" them at the end.
    func adBreakDidBegin() {
        guard let controls else { return }
        #if os(macOS)
        guard savedControlsStyle == nil else { return }
        savedControlsStyle = controls.controlsStyle
        controls.controlsStyle = .none
        #else
        guard savedRequiresLinearPlayback == nil else { return }
        savedRequiresLinearPlayback = controls.requiresLinearPlayback
        controls.requiresLinearPlayback = true
        savedSpeeds = controls.speeds
        controls.speeds = []
        #endif
    }

    func adBreakDidEnd() {
        restore()
    }

    /// Restores everything this coordinator changed and lets go of the object.
    func invalidate() {
        restore()
        controls = nil
    }

    private func restore() {
        guard let controls else { return }
        #if os(macOS)
        if let saved = savedControlsStyle {
            controls.controlsStyle = saved
            savedControlsStyle = nil
        }
        #else
        if let saved = savedRequiresLinearPlayback {
            controls.requiresLinearPlayback = saved
            savedRequiresLinearPlayback = nil
        }
        if let saved = savedSpeeds {
            controls.speeds = saved
            savedSpeeds = nil
        }
        #endif
    }
}
