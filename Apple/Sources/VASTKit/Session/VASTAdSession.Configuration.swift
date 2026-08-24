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
        /// Restore the host's original player item when the ad break ends.
        var restoresPlayerItem: Bool { get }
        var skipPresentation: SkipPresentation { get }
        var clickPresentation: ClickPresentation { get }
        /// `nil` uses the built-in `AVPlayer` observer clock.
        var clock: (any iVASTClock)? { get }
        var transport: (any iVASTBeaconTransport)? { get }
        var loader: (any iVASTResourceLoader)? { get }
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

    struct Configuration: iConfiguration {

        public var maxWrapperDepth: Int
        public var wrapperTimeout: TimeInterval
        public var restoresPlayerItem: Bool
        public var skipPresentation: SkipPresentation
        public var clickPresentation: ClickPresentation
        public var clock: (any iVASTClock)?
        public var transport: (any iVASTBeaconTransport)?
        public var loader: (any iVASTResourceLoader)?

        /// Defaults are the compliant ones: the SDK draws the skip control and
        /// the ad surface is clickable, so a host that configures nothing still
        /// honours §2.3 and §3.10.1.
        public init(
            maxWrapperDepth: Int = 5,
            wrapperTimeout: TimeInterval = 5,
            restoresPlayerItem: Bool = true,
            skipPresentation: SkipPresentation = .sdk,
            clickPresentation: ClickPresentation = .surface,
            clock: (any iVASTClock)? = nil,
            transport: (any iVASTBeaconTransport)? = nil,
            loader: (any iVASTResourceLoader)? = nil
        ) {
            self.maxWrapperDepth = maxWrapperDepth
            self.wrapperTimeout = wrapperTimeout
            self.restoresPlayerItem = restoresPlayerItem
            self.skipPresentation = skipPresentation
            self.clickPresentation = clickPresentation
            self.clock = clock
            self.transport = transport
            self.loader = loader
        }
    }
}
