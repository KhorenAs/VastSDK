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
        /// `<CustomClick>` (§3.10.3) — trackers for a click the player reports
        /// without opening anything, as distinct from `<ClickTracking>`, which
        /// accompanies a click-through. Real tags send both.
        public let customClicks: [URL]
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
            customClicks: [URL] = [],
            trackingEvents: [TrackingEvent: [URL]] = [:],
            progressEvents: [ProgressEvent] = []
        ) {
            self.duration = duration
            self.skipOffset = skipOffset
            self.mediaFiles = mediaFiles
            self.clickThrough = clickThrough
            self.clickTracking = clickTracking
            self.customClicks = customClicks
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

        /// The text of a direct child element, e.g. `value(of: "UiHideable")` on a
        /// `uiSettings` extension.
        ///
        /// Reading a vendor key should not mean writing a string scanner in every
        /// host. This still assigns the value no meaning — whether `"1"` means the
        /// UI should hide is the vendor's convention, and the host's to apply.
        ///
        /// `nil` when the element is absent; an element present but empty yields
        /// `""`, which is a different fact and is reported as such.
        public func value(of element: String) -> String? {
            guard let openStart = xml.range(of: "<\(element)"),
                  let openEnd = xml[openStart.upperBound...].firstIndex(of: ">")
            else { return nil }

            // `<UiHideable/>` carries no text, and its ">" belongs to the open tag.
            if xml[openStart.upperBound..<openEnd].hasSuffix("/") { return "" }

            let bodyStart = xml.index(after: openEnd)
            guard let closeStart = xml.range(of: "</\(element)>", range: bodyStart..<xml.endIndex)
            else { return nil }

            return Self.text(in: String(xml[bodyStart..<closeStart.lowerBound]))
        }

        /// Ad servers wrap extension values in CDATA about as often as not.
        private static func text(in body: String) -> String {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("<![CDATA["), trimmed.hasSuffix("]]>") else { return trimmed }
            return String(trimmed.dropFirst(9).dropLast(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
