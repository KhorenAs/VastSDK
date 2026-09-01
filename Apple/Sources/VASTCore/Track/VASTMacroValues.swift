//
//  VASTMacroValues.swift
//  VASTSDK
//

import Foundation

/// The §6 macro values only the host can supply.
///
/// Every one of these is something the SDK must not decide for itself. An
/// advertising identifier requires the host to have asked the viewer for
/// permission; a consent string comes from a CMP the host chose; whether this
/// break is a pre-roll is a fact about the host's own timeline. The SDK reporting
/// a guess in any of those places would be worse than reporting nothing, which is
/// what an unsupplied macro does — §6 gives it `-1`, meaning "not known", and
/// that is an honest answer.
///
/// Left empty, every macro here goes out as `-1`. That is the correct default and
/// also a real cost: an ad server with no `IFA` and no `APPBUNDLE` will often not
/// bid at all, or will treat the traffic as unattributable. Filling these in is
/// the difference between a request an exchange can price and one it cannot.
public struct VASTMacroValues: Sendable {

    /// `[IFA]` — the advertising identifier, if the host has permission to use
    /// one. On Apple platforms that means ATT was requested and granted; without
    /// it, leave this `nil` rather than sending a zeroed identifier.
    public var identifierForAdvertising: String?

    /// `[IFATYPE]` — what kind of identifier `identifierForAdvertising` is, in the
    /// vendor-agnostic spelling the spec asks for: `idfa`, `idfv`, `sessionid`.
    public var identifierType: String?

    /// `[LIMITADTRACKING]` — whether the viewer asked not to be tracked. `nil`
    /// means unknown, which is different from `false`.
    public var limitsAdTracking: Bool?

    /// `[GDPRCONSENT]` — the IAB TCF consent string, straight from the CMP.
    public var gdprConsent: String?

    /// `[REGULATIONS]` — which regimes apply to this request, e.g. `gdpr` or
    /// `coppa`.
    public var regulations: String?

    /// `[DEVICEUA]` — the device's browser user agent.
    ///
    /// Host-supplied because obtaining it means instantiating a `WKWebView`, and
    /// this SDK deliberately has none. A host that already has one can hand its
    /// value over; a host that does not should leave this alone rather than
    /// inventing a plausible string, which is worse for fraud scoring than an
    /// honest blank.
    public var deviceUserAgent: String?

    /// `[PLACEMENTTYPE]` — where the player sits, in AdCOM's numbering.
    public var placementType: Int?

    /// `[BREAKPOSITION]` — 1 pre-roll, 2 mid-roll, 3 post-roll, 0 unknown.
    ///
    /// The SDK cannot know this: it is handed one break at a time and never sees
    /// the content timeline that decides where the break sits.
    public var breakPosition: Int?

    /// `[CONTENTID]` — the host's own identifier for what the ad interrupted.
    public var contentID: String?

    /// `[CONTENTURI]` — where that content came from.
    public var contentURI: URL?

    /// Vendor macros this SDK knows nothing about.
    ///
    /// Keyed without brackets: `["CORRELATOR": "1234"]` replaces `[CORRELATOR]`.
    /// Anything §6 does not define is left alone when it is not here, because the
    /// spec is explicit that unknown macros must not all become `-1`.
    public var custom: [String: String]

    public init(
        identifierForAdvertising: String? = nil,
        identifierType: String? = nil,
        limitsAdTracking: Bool? = nil,
        gdprConsent: String? = nil,
        regulations: String? = nil,
        deviceUserAgent: String? = nil,
        placementType: Int? = nil,
        breakPosition: Int? = nil,
        contentID: String? = nil,
        contentURI: URL? = nil,
        custom: [String: String] = [:]
    ) {
        self.identifierForAdvertising = identifierForAdvertising
        self.identifierType = identifierType
        self.limitsAdTracking = limitsAdTracking
        self.gdprConsent = gdprConsent
        self.regulations = regulations
        self.deviceUserAgent = deviceUserAgent
        self.placementType = placementType
        self.breakPosition = breakPosition
        self.contentID = contentID
        self.contentURI = contentURI
        self.custom = custom
    }
}
