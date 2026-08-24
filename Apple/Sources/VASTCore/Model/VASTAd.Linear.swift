//
//  VASTAd.Linear.swift
//  VASTSDK
//

import Foundation

public extension VASTAd {

    /// `<Linear>` — the only creative type this SDK plays.
    struct Linear: Sendable {

        public let duration: TimeInterval
        /// `<Linear skipoffset>`. Non-nil means the ad is a Skippable Linear Ad
        /// and MUST be offered with skip controls (§2.3).
        public let skipOffset: SkipOffset?
        public let mediaFiles: [MediaFile]
        public let clickThrough: URL?
        public let clickTracking: [URL]
        public let trackingEvents: [TrackingEvent: [URL]]
        /// `<Tracking event="progress" offset="...">` — decides whether a skipped
        /// ad still counts as viewed (§3.14.1).
        public let progressEvents: [ProgressEvent]

        public init(
            duration: TimeInterval,
            skipOffset: SkipOffset? = nil,
            mediaFiles: [MediaFile] = [],
            clickThrough: URL? = nil,
            clickTracking: [URL] = [],
            trackingEvents: [TrackingEvent: [URL]] = [:],
            progressEvents: [ProgressEvent] = []
        ) {
            self.duration = duration
            self.skipOffset = skipOffset
            self.mediaFiles = mediaFiles
            self.clickThrough = clickThrough
            self.clickTracking = clickTracking
            self.trackingEvents = trackingEvents
            self.progressEvents = progressEvents
        }

        public func resolvedSkipOffset() -> TimeInterval? {
            skipOffset?.seconds(forDuration: duration)
        }
    }

    /// `HH:MM:SS`, `HH:MM:SS.mmm`, or `n%`.
    enum SkipOffset: Sendable, Equatable {
        case time(TimeInterval)
        case percent(Double)

        public func seconds(forDuration duration: TimeInterval) -> TimeInterval {
            switch self {
            case .time(let value): value
            case .percent(let value): duration * value / 100
            }
        }
    }

    struct ProgressEvent: Sendable {
        public let offset: SkipOffset
        public let url: URL

        public init(offset: SkipOffset, url: URL) {
            self.offset = offset
            self.url = url
        }
    }

    /// One `<Extension>` kept as raw XML. The SDK never interprets these; a host
    /// reads its own vendor keys (e.g. Kinodaran's `uiSettings/UiHideable`).
    struct Extension: Sendable {
        public let type: String?
        public let xml: String

        public init(type: String?, xml: String) {
            self.type = type
            self.xml = xml
        }
    }
}
