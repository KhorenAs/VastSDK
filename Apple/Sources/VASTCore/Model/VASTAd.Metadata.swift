//
//  VASTAd.Metadata.swift
//  VASTSDK
//

import Foundation

public extension VASTAd {

    /// `<UniversalAdId>` (§3.7.1). Required in VAST 4.
    ///
    /// The one identifier that means the same thing to everyone: an ad server's
    /// own `<Ad id>` is its own, while this names the *creative* in a registry
    /// both sides can look up. It is what a buyer blocks by, what a reporting
    /// pipeline groups by, and what two parties compare when their counts
    /// disagree — which is why VAST 4 made it required and why parsing the rest
    /// of a response without it leaves the most useful field on the floor.
    struct UniversalAdID: Sendable, Equatable {
        /// `idRegistry` — who issued the value. `"unknown"` when a server says so.
        public let registry: String?
        public let value: String

        public init(registry: String?, value: String) {
            self.registry = registry
            self.value = value
        }
    }

    /// `<ViewableImpression>` (§3.6).
    ///
    /// Three outcomes, not one: the ad was viewable, it was not, or the player
    /// could not tell. The third is the honest answer for a player with no
    /// viewability measurement, and it is the one this SDK sends — silence would
    /// let a buyer treat an unmeasured impression as measured, which is the same
    /// mistake `verificationNotExecuted` exists to prevent.
    struct ViewableImpression: Sendable {
        public let id: String?
        public let viewable: [URL]
        public let notViewable: [URL]
        public let viewUndetermined: [URL]

        public init(
            id: String? = nil,
            viewable: [URL] = [],
            notViewable: [URL] = [],
            viewUndetermined: [URL] = []
        ) {
            self.id = id
            self.viewable = viewable
            self.notViewable = notViewable
            self.viewUndetermined = viewUndetermined
        }

        public var isEmpty: Bool {
            viewable.isEmpty && notViewable.isEmpty && viewUndetermined.isEmpty
        }
    }

    /// `<Icon>` (§3.15) — the AdChoices mark, in practice.
    ///
    /// Parsed and handed over rather than drawn. Drawing it means fetching an
    /// image, placing it by the coordinates below, and opening a click-through of
    /// its own; a host that draws its own ad UI is already doing all three for its
    /// own controls. What matters is that the response's icon is not silently
    /// dropped, because in the EU rendering it is not optional.
    struct Icon: Sendable {
        /// `program` — which scheme the icon belongs to, e.g. `AdChoices`.
        public let program: String?
        public let width: Int?
        public let height: Int?
        /// `left`, `right`, or a number of pixels.
        public let xPosition: String?
        /// `top`, `bottom`, or a number of pixels.
        public let yPosition: String?
        /// When the icon should appear, from the start of the creative.
        public let offset: TimeInterval?
        /// How long it should stay. `nil` means for the rest of the ad.
        public let duration: TimeInterval?
        public let staticResource: URL?
        public let staticResourceType: String?
        public let clickThrough: URL?
        public let clickTracking: [URL]
        public let viewTracking: [URL]

        public init(
            program: String? = nil,
            width: Int? = nil,
            height: Int? = nil,
            xPosition: String? = nil,
            yPosition: String? = nil,
            offset: TimeInterval? = nil,
            duration: TimeInterval? = nil,
            staticResource: URL? = nil,
            staticResourceType: String? = nil,
            clickThrough: URL? = nil,
            clickTracking: [URL] = [],
            viewTracking: [URL] = []
        ) {
            self.program = program
            self.width = width
            self.height = height
            self.xPosition = xPosition
            self.yPosition = yPosition
            self.offset = offset
            self.duration = duration
            self.staticResource = staticResource
            self.staticResourceType = staticResourceType
            self.clickThrough = clickThrough
            self.clickTracking = clickTracking
            self.viewTracking = viewTracking
        }
    }

    /// `<Pricing>` (§3.8). What the impression cost, as the server states it.
    struct Pricing: Sendable, Equatable {
        /// `CPM`, `CPC`, `CPE`, `CPV`.
        public let model: String?
        /// ISO 4217, e.g. `USD`.
        public let currency: String?
        public let value: Double

        public init(model: String?, currency: String?, value: Double) {
            self.model = model
            self.currency = currency
            self.value = value
        }
    }

    /// `<Category>` (§3.5) — the advertiser's industry, per some authority.
    struct Category: Sendable, Equatable {
        /// `authority` — the URL of the taxonomy the code belongs to.
        public let authority: String?
        public let code: String

        public init(authority: String?, code: String) {
            self.authority = authority
            self.code = code
        }
    }
}
