//
//  VASTDocument.swift
//  VASTSDK
//

import Foundation

/// One parsed `<VAST>` response, before Wrapper flattening.
public struct VASTDocument: Sendable {

    public enum Body: Sendable {
        case inLine(VASTAd)
        /// `<Wrapper>` — carries its own trackers plus the next tag to fetch.
        case wrapper(Wrapper)
    }

    public struct Entry: Sendable {
        public let id: String
        public let sequence: Int?
        public let body: Body
    }

    public let version: String
    public let entries: [Entry]
    /// Root-level `<Error>`, used for the "no ad" response (§2.3.6.4).
    public let noAdError: URL?

    public var isNoAd: Bool { entries.isEmpty }
}

public extension VASTDocument {

    struct Wrapper: Sendable {
        public let tagURI: URL
        public let impressions: [URL]
        public let errors: [URL]
        public let trackingEvents: [VASTAd.TrackingEvent: [URL]]
        public let clickTracking: [URL]
        public let clickThrough: URL?
        public let extensions: [VASTAd.Extension]
        /// Default `true` (§3.19).
        public let followAdditionalWrappers: Bool
        /// Default `false` (§3.19).
        public let allowMultipleAds: Bool
        public let fallbackOnNoAd: Bool?
    }
}
