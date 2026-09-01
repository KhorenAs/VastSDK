//
//  VASTAdSession.Configuration.swift
//  VASTSDK
//

import Foundation
import VASTCore

public extension VASTAdSession {

    /// Everything a host may swap out. Supplying your own type lets the whole
    /// session run against a fake clock, fake transport and fake loader.
    protocol iConfiguration: Sendable {
        /// VAST 4.3 §3.19.1 requires accepting at least five.
        var maxWrapperDepth: Int { get }
        var wrapperTimeout: TimeInterval { get }
        /// Total time a response may take to resolve, however many Wrappers it
        /// needs. `wrapperTimeout` bounds one hop, and five hops at five seconds
        /// is twenty-five — a viewer who waited that long for an ad was shown a
        /// bug, not an ad. Zero disables the budget.
        var resolutionTimeout: TimeInterval { get }
        /// Restore the host's original player item when the ad break ends.
        var restoresPlayerItem: Bool { get }
        var skipPresentation: SkipPresentation { get }
        var clickPresentation: ClickPresentation { get }
        /// Whether the ad may follow the content into the Picture in Picture
        /// window, where the ad surface cannot go with it.
        var pictureInPicture: PictureInPicturePolicy { get }
        /// What the system's Now Playing controls show, and allow, while an ad
        /// is on the player.
        var nowPlaying: NowPlayingPolicy { get }
        /// `nil` uses the built-in `AVPlayer` observer clock.
        var clock: (any iVASTClock)? { get }
        var transport: (any iVASTBeaconTransport)? { get }
        var loader: (any iVASTResourceLoader)? { get }
        /// §6 macro values only the host can supply — identifier, consent, where
        /// this break sits in its content. Unsupplied values report `-1`, which
        /// is honest and also often unbiddable; see `VASTMacroValues`.
        var macroValues: VASTMacroValues { get }
    }

    /// Who provides the skip control.
    ///
    /// Not a styling choice. VAST 4.3 §2.3 states the player should not "play the
    /// Skippable Ad as a Linear Ad (without skip controls)", so this decides
    /// whether a skippable ad may be played at all — an advertiser paid the
    /// skippable rate and is owed the skip.
    enum SkipPresentation: Sendable, Equatable {
        /// The SDK draws the control. Compliant by construction.
        case sdk
        /// The host draws it, reading `canSkip` and `timeUntilSkip`.
        case host
        /// Skippable ads are refused with VAST error 200 rather than played
        /// without a skip control.
        case unsupported
    }

    /// How a click reaches the advertiser.
    ///
    /// §3.10.1 makes `ClickThrough` support Required, and describes it as the URI
    /// "the media player opens when a viewer clicks the ad" — the ad surface
    /// itself, not necessarily a separate button.
    enum ClickPresentation: Sendable, Equatable {
        /// Tapping the ad opens the destination. The spec's own model.
        case surface
        /// The host wires its own affordance and calls `click()`.
        case host
        /// No click path at all. Not compliant; opt in knowingly.
        case disabled
    }

    /// Whether an ad may play in the Picture in Picture window.
    ///
    /// The window shows the player layer and the system's own transport
    /// controls; the ad surface — skip control, badge, click layer — is a view
    /// in the app and stays behind. What that costs is smaller than it first
    /// looks: tapping the window returns to the app, where the whole surface is
    /// where it was. The skip control is a tap further away, not gone.
    ///
    /// So the default is to leave the window alone. A viewer who asked for
    /// Picture in Picture asked for it, and Picture in Picture follows the
    /// `AVPlayerLayer` rather than the item — a host that supports it at all
    /// carries the creative there whether or not anyone decided to. The other
    /// two cases are for players that must keep an ad where its controls are.
    enum PictureInPicturePolicy: Sendable, Equatable {
        /// The ad plays in the window, like the content it interrupted. The
        /// default. The delegate is told when a skip control comes due while
        /// the viewer is out there and cannot see it.
        case allowed
        /// The window stays, but entering it pauses the ad — reported as §3.14.1
        /// `pause` — and leaving it resumes. Nothing plays unwatched.
        case pausesAd
        /// The window closes for the length of the break, and automatic entry is
        /// switched off while it runs. The strictest reading of §2.3: the ad
        /// plays where its controls are or it does not play.
        case suspended
    }

    /// What the system's Now Playing transport does during a break.
    ///
    /// Control Centre, the lock screen, AirPods and CarPlay all draw from the
    /// same two process-wide objects, and they are on offer because Picture in
    /// Picture needed the `audio` background mode to exist at all. Their seek
    /// and skip controls are the window's scrubber again, in a place the host
    /// cannot see, and their title is the content's while an ad is playing.
    enum NowPlayingPolicy: Sendable, Equatable {
        /// Locks the controls that would seek or skip the creative, and
        /// describes the ad while it plays. Both are put back when the break
        /// ends. The default: the alternative is a lock screen naming a film
        /// that is not the thing making the sound.
        case describesAd
        /// Locks the controls, and leaves the host's Now Playing information
        /// exactly as it is.
        case locksControls
        /// Neither. The system controls are the host's, seeking included.
        case untouched
    }

    struct Configuration: iConfiguration {

        public var maxWrapperDepth: Int
        public var wrapperTimeout: TimeInterval
        public var resolutionTimeout: TimeInterval
        public var restoresPlayerItem: Bool
        public var skipPresentation: SkipPresentation
        public var clickPresentation: ClickPresentation
        public var pictureInPicture: PictureInPicturePolicy
        public var nowPlaying: NowPlayingPolicy
        public var clock: (any iVASTClock)?
        public var transport: (any iVASTBeaconTransport)?
        public var loader: (any iVASTResourceLoader)?
        public var macroValues: VASTMacroValues

        /// Defaults are the compliant ones: the SDK draws the skip control and
        /// the ad surface is clickable, so a host that configures nothing still
        /// honours §2.3 and §3.10.1.
        public init(
            maxWrapperDepth: Int = 5,
            wrapperTimeout: TimeInterval = 5,
            resolutionTimeout: TimeInterval = 10,
            restoresPlayerItem: Bool = true,
            skipPresentation: SkipPresentation = .sdk,
            clickPresentation: ClickPresentation = .surface,
            pictureInPicture: PictureInPicturePolicy = .allowed,
            nowPlaying: NowPlayingPolicy = .describesAd,
            clock: (any iVASTClock)? = nil,
            transport: (any iVASTBeaconTransport)? = nil,
            loader: (any iVASTResourceLoader)? = nil,
            macroValues: VASTMacroValues = VASTMacroValues()
        ) {
            self.maxWrapperDepth = maxWrapperDepth
            self.wrapperTimeout = wrapperTimeout
            self.resolutionTimeout = resolutionTimeout
            self.restoresPlayerItem = restoresPlayerItem
            self.skipPresentation = skipPresentation
            self.clickPresentation = clickPresentation
            self.pictureInPicture = pictureInPicture
            self.nowPlaying = nowPlaying
            self.clock = clock
            self.transport = transport
            self.loader = loader
            self.macroValues = macroValues
        }
    }
}

/// Defaults for everything added to `iConfiguration` after it shipped.
///
/// A protocol requirement with no default is a source break for every host that
/// already wrote a configuration type, over settings most of them will never
/// touch. These are exactly that: a budget with a sensible value, values only
/// some hosts can supply at all, and a window most hosts do not have.
public extension VASTAdSession.iConfiguration {

    /// Ten seconds for a whole response, however many Wrappers it takes.
    var resolutionTimeout: TimeInterval { 10 }

    /// Nothing, which reports `-1` for each — honest, and what a host that never
    /// mentioned them means.
    var macroValues: VASTMacroValues { VASTMacroValues() }

    /// Leave the window alone, which is what a host that never mentioned Picture
    /// in Picture means — and what a viewer who opened it asked for.
    var pictureInPicture: VASTAdSession.PictureInPicturePolicy { .allowed }

    /// Take the seek controls off the lock screen for the break and say what is
    /// playing, which is what a host that never thought about it wants.
    var nowPlaying: VASTAdSession.NowPlayingPolicy { .describesAd }
}
