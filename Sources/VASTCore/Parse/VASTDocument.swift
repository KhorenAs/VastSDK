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
        /// An `<InLine>` whose only creatives are ones this SDK does not play —
        /// `<NonLinearAds>`, `<CompanionAds>`. Kept rather than dropped so the
        /// server hears 201 ("expecting different linearity") instead of being
        /// told it returned nothing, and so its `<Error>` URIs still fire.
        case unplayableCreative(errors: [URL])
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
        /// Verification vendors are usually injected by an intermediary rather
        /// than the advertiser, so a Wrapper carrying them is the common case.
        public let verifications: [VASTAd.Verification]
        /// A Wrapper may ask about viewability on its own account (§3.6), and an
        /// intermediary that wanted to hear does not stop wanting because the
        /// InLine wanted to as well.
        public let viewableImpression: VASTAd.ViewableImpression?
        /// Default `true` (§3.19).
        public let followAdditionalWrappers: Bool
        /// Default `false` (§3.19).
        public let allowMultipleAds: Bool
        public let fallbackOnNoAd: Bool?
    }
}
