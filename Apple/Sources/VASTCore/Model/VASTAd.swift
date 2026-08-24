//
//  VASTAd.swift
//  VASTSDK
//

import Foundation

/// A single `<Ad>` resolved down to everything needed to play and track it.
///
/// A Wrapper chain is already flattened by the time an ad reaches this type:
/// `trackingEvents`, `impressions` and `errors` hold the accumulated URIs from
/// every Wrapper in the chain plus the final InLine, as VAST 4.3 §2.3.5 requires.
public struct VASTAd: Sendable, Identifiable {

    public let id: String
    /// `<Ad sequence="n">`. `nil` means a stand-alone ad (VAST 4.3 §3.3.1 "ad buffet").
    public let sequence: Int?
    public let adSystem: String?
    public let title: String?
    public let linear: Linear
    /// Fired together, the moment the first frame renders (§2.3.4).
    public let impressions: [URL]
    /// Every `<Error>` in the chain. On failure ALL of them fire (§2.3.5.1).
    public let errors: [URL]
    /// Vendor-specific `<Extensions>`, handed to the host untouched (§3.18).
    public let extensions: [Extension]
    /// `<AdVerifications>` (§3.16), accumulated from the whole Wrapper chain and
    /// normalised across VAST 3 and 4 shapes. Parsed, never executed — see
    /// `VASTAd.Verification`.
    public let adVerifications: [Verification]
    /// The `id` of every Wrapper crossed to reach this ad, outermost first.
    ///
    /// Empty for a direct InLine response. Reporting pipelines use this to say
    /// which intermediary served an ad, so it is kept rather than discarded with
    /// the rest of the Wrapper once the chain is flattened.
    public let wrapperAdIDs: [String]

    public init(
        id: String,
        sequence: Int? = nil,
        adSystem: String? = nil,
        title: String? = nil,
        linear: Linear,
        impressions: [URL] = [],
        errors: [URL] = [],
        extensions: [Extension] = [],
        adVerifications: [Verification] = [],
        wrapperAdIDs: [String] = []
    ) {
        self.id = id
        self.sequence = sequence
        self.adSystem = adSystem
        self.title = title
        self.linear = linear
        self.impressions = impressions
        self.errors = errors
        self.extensions = extensions
        self.adVerifications = adVerifications
        self.wrapperAdIDs = wrapperAdIDs
    }

    public var isSkippable: Bool { linear.skipOffset != nil }
    public var isPartOfPod: Bool { sequence != nil }
}
