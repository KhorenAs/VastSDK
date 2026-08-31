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

    /// Whether this is a Skippable Linear Ad: the creative declared a
    /// `skipoffset` (§2.3).
    ///
    /// Not a styling question. An advertiser paid the skippable rate on the
    /// strength of that attribute, so this is what decides whether a skip control
    /// is owed at all — and under `SkipPresentation.unsupported` it is why the ad
    /// is refused with error 200 rather than played without one.
    public var isSkippable: Bool { linear.skipOffset != nil }

    /// Whether the response placed this ad in a pod, by giving it a `sequence`
    /// attribute (§3.3.1).
    ///
    /// A fact about what the ad server trafficked, not about the break being
    /// played — `VASTAdSession.AdPosition.isPod` answers that other question,
    /// "does this break have more than one slot". The two disagree more often
    /// than they look like they would:
    ///
    /// - A lone `sequence="1"` ad *is* part of a pod, while its break has one slot.
    /// - A stand-alone ad substituted for a pod member that failed to play is
    ///   *not* part of a pod, while the break around it still has all of its.
    ///
    /// So an "Ad 2 of 3" badge belongs to `AdPosition`; this is for reporting what
    /// the server actually sent.
    public var isPartOfPod: Bool { sequence != nil }

    /// Whether this response asks the player to draw no UI of its own.
    ///
    /// Read from `<Extension type="uiSettings">` — `<UiHidden>`, or the
    /// `<UiHideable>` spelling the live AdFox tag sends. A vendor convention
    /// rather than VAST: §3.18 leaves `<Extensions>` to vendors, and this is the
    /// one key the SDK interprets instead of merely handing over. Presence is the
    /// request, so `<UiHidden/>` with no text counts; only an explicitly negative
    /// value reads as "keep your UI".
    ///
    /// **This is what the response asked for, and on its own it changes nothing.**
    /// Two more answers sit above it, and the three are easy to confuse:
    ///
    /// - `VASTAd.isUIHidden` — the *response* asks for it.
    /// - `VASTAdSession.isHiddenUi` — the *host* allows it.
    /// - `VASTAdSession.suppressesAdUI` — both, and therefore whether the ad UI
    ///   is being suppressed right now.
    ///
    /// A response cannot hide the SDK's UI on its own. That would let a vendor
    /// decide whether the host honours §2.3, which is not a vendor's to decide.
    public var isUIHidden: Bool { VASTUISettings.asksForHostDrawnUI(self) }
}
