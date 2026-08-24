//
//  VASTAd.TrackingEvent.swift
//  VASTSDK
//

import Foundation

public extension VASTAd {

    /// Every event name VAST 4.3 §3.14.1 allows under `<TrackingEvents>`.
    ///
    /// `progress` is intentionally absent: it carries an `offset` attribute and
    /// is modelled by `VASTAd.ProgressEvent` instead.
    enum TrackingEvent: String, Sendable, CaseIterable {

        // Player operation metrics
        case mute
        case unmute
        case pause
        case resume
        case rewind
        case skip
        case playerExpand
        case playerCollapse
        case notUsed

        // VAST 2.0/3.0 names. Live ad servers still emit these — a real AdFox
        // tag sends `fullscreen`, `expand`, `collapse`, `acceptInvitation` and
        // `close` — so dropping them would silently lose tracking the server is
        // waiting for. They are kept distinct from their 4.x replacements rather
        // than rewritten, because the URIs behind them are the server's, not ours.
        case fullscreen
        case exitFullscreen
        case expand
        case collapse
        case acceptInvitation
        case close

        // Linear ad metrics
        case loaded
        case start
        case firstQuartile
        case midpoint
        case thirdQuartile
        case complete
        case otherAdInteraction
        case closeLinear

        case creativeView

        /// Quartiles require continuous playback at normal speed (§3.14.1), so a
        /// forward seek past one of these must NOT fire it.
        public var requiresContinuousPlayback: Bool {
            switch self {
            case .firstQuartile, .midpoint, .thirdQuartile, .complete: true
            default: false
            }
        }

        /// Events that may be sent at most once per ad.
        public var isOnce: Bool {
            switch self {
            case .mute, .unmute, .pause, .resume, .rewind, .otherAdInteraction,
                 .fullscreen, .exitFullscreen, .expand, .collapse, .acceptInvitation:
                false
            default:
                true
            }
        }

        /// Whether a host may report this event directly.
        ///
        /// Quartiles, `start` and `complete` are derived from observed playback
        /// instead, so that a caller cannot fabricate a billable event.
        public var isHostReportable: Bool {
            switch self {
            case .start, .firstQuartile, .midpoint, .thirdQuartile, .complete,
                 .creativeView, .skip, .loaded:
                false
            default:
                true
            }
        }

        /// Names that mean the same thing across VAST versions.
        ///
        /// VAST 4.3 §3.14.1 states that `playerExpand` replaces `fullscreen` and
        /// `playerCollapse` replaces `exitFullscreen`, but servers keep sending
        /// the old spelling. Firing one fires every equivalent, so a host reports
        /// the event once and whichever name the server used is honoured.
        public var equivalents: [TrackingEvent] {
            switch self {
            case .playerExpand, .fullscreen, .expand: [.playerExpand, .fullscreen, .expand]
            case .playerCollapse, .exitFullscreen, .collapse: [.playerCollapse, .exitFullscreen, .collapse]
            case .closeLinear, .close: [.closeLinear, .close]
            default: [self]
            }
        }
    }
}
