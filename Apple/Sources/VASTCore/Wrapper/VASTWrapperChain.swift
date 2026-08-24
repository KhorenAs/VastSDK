//
//  VASTWrapperChain.swift
//  VASTSDK
//

import Foundation

/// Drives Wrapper redirection without performing any IO.
///
/// The caller executes `.follow(url)` with its own loader and feeds the result
/// back in. Depth limits, tracker accumulation, ClickThrough precedence and
/// error reporting are therefore exercised with fixture strings and no network.
public struct VASTWrapperChain: Sendable {

    public enum Step: Sendable {
        /// Fetch this tag and call `accept` again with the parsed result.
        case follow(URL)
        /// The chain ended at an InLine response; these ads carry every tracker
        /// collected on the way down.
        case resolved([VASTAd])
        case failed(VASTError)
    }

    public let maxDepth: Int

    /// Every `<Error>` seen on the way down. On failure they all fire, because
    /// §2.3.5.1 requires each Wrapper in the chain to be told.
    public private(set) var accumulatedErrors: [URL] = []
    public private(set) var depth = 0

    private var impressions: [URL] = []
    private var tracking: [VASTAd.TrackingEvent: [URL]] = [:]
    private var clickTracking: [URL] = []
    /// §2.3.5.2: the ClickThrough closest to the InLine response wins, so this is
    /// overwritten as the chain descends and by the InLine itself if it has one.
    private var clickThrough: URL?
    private var extensions: [VASTAd.Extension] = []
    private var allowMultipleAds = false

    /// §3.19.1: "the player is only required to accept five wrappers".
    public init(maxDepth: Int = 5) {
        self.maxDepth = maxDepth
    }

    /// Consumes one parsed document.
    ///
    /// - Parameter baseURL: where this document was fetched from. A
    ///   `VASTAdTagURI` is frequently relative, and only the caller knows what to
    ///   resolve it against.
    public mutating func accept(_ document: VASTDocument, from baseURL: URL? = nil) -> Step {
        guard !document.isNoAd else {
            // §2.3.6.4 names 303 for the no-ad response, and it is the honest
            // code at either depth: no VAST response produced an ad. Reporting a
            // wrapper error for a direct response describes a hop that never
            // happened.
            if let rootError = document.noAdError {
                accumulatedErrors.append(rootError)
            }
            return .failed(.noVASTResponseAfterWrappers)
        }

        let inLineAds = document.entries.compactMap { entry -> VASTAd? in
            guard case .inLine(let ad) = entry.body else { return nil }
            return ad
        }
        if !inLineAds.isEmpty {
            return .resolved(permitted(inLineAds).map(merge))
        }

        // No InLine yet, so this is another Wrapper hop.
        guard let wrapper = firstWrapper(in: document) else {
            return .failed(.wrapperGeneral)
        }
        absorb(wrapper)

        guard depth < maxDepth else {
            return .failed(.wrapperLimitReached)
        }
        guard wrapper.followAdditionalWrappers || depth == 0 else {
            // The parent forbade further redirection, and this response is not
            // an InLine, so there is nothing left to play.
            return .failed(.noVASTResponseAfterWrappers)
        }
        depth += 1
        return .follow(Self.resolve(wrapper.tagURI, against: baseURL))
    }

    /// Applies the calling Wrapper's `allowMultipleAds` constraint (§3.19).
    ///
    /// The attribute defaults to `false`, which means "only the first stand-alone
    /// Ad (with no sequence values) in the requested VAST response is allowed" —
    /// so a wrapper that says nothing is asking for one ad, not a pod.
    ///
    /// A direct response is untouched: the constraint belongs to a wrapper
    /// requesting on someone's behalf, and there is no wrapper at depth zero.
    private func permitted(_ ads: [VASTAd]) -> [VASTAd] {
        guard depth > 0, !allowMultipleAds, ads.count > 1 else { return ads }

        // Read literally, a pod-only response under this constraint contains
        // nothing that is allowed. Taking its first ad instead keeps the slot
        // filled while still honouring "not multiple" — refusing fill outright
        // would punish the advertiser for the wrapper's default.
        if let standAlone = ads.first(where: { $0.sequence == nil }) {
            return [standAlone]
        }
        return [ads[0]]
    }

    /// Marks the chain as failed, returning every error URI owed. Use when the
    /// caller's own step fails — a fetch timeout, or a document that will not parse.
    public func errorBeacons(for error: VASTError, adID: String = "-") -> [VASTBeacon] {
        accumulatedErrors.map { VASTBeacon(kind: .error(error), url: $0, adID: adID) }
    }

    // MARK: - Accumulation

    private func firstWrapper(in document: VASTDocument) -> VASTDocument.Wrapper? {
        // A pod's members are handled once the chain resolves; redirection itself
        // follows a single tag, and `allowMultipleAds` governs what the response
        // to it may contain.
        for entry in document.entries {
            if case .wrapper(let wrapper) = entry.body { return wrapper }
        }
        return nil
    }

    private mutating func absorb(_ wrapper: VASTDocument.Wrapper) {
        impressions += wrapper.impressions
        accumulatedErrors += wrapper.errors
        clickTracking += wrapper.clickTracking
        extensions += wrapper.extensions
        allowMultipleAds = wrapper.allowMultipleAds
        for (event, urls) in wrapper.trackingEvents {
            tracking[event, default: []] += urls
        }
        if let wrapperClickThrough = wrapper.clickThrough {
            clickThrough = wrapperClickThrough
        }
    }

    /// Folds everything collected on the way down into the resolved ad.
    ///
    /// A pod resolved through a Wrapper gets the wrapper's trackers on *every*
    /// member (§3.3.1), which falls out of merging per ad rather than once.
    private func merge(_ ad: VASTAd) -> VASTAd {
        var merged = ad.linear.trackingEvents
        for (event, urls) in tracking {
            merged[event, default: []] += urls
        }
        return VASTAd(
            id: ad.id,
            sequence: ad.sequence,
            adSystem: ad.adSystem,
            title: ad.title,
            linear: VASTAd.Linear(
                duration: ad.linear.duration,
                skipOffset: ad.linear.skipOffset,
                mediaFiles: ad.linear.mediaFiles,
                // The InLine's own ClickThrough is closest to the creative and
                // therefore wins over anything a calling Wrapper supplied.
                clickThrough: ad.linear.clickThrough ?? clickThrough,
                clickTracking: ad.linear.clickTracking + clickTracking,
                trackingEvents: merged,
                progressEvents: ad.linear.progressEvents
            ),
            impressions: ad.impressions + impressions,
            errors: ad.errors + accumulatedErrors,
            extensions: ad.extensions + extensions
        )
    }

    /// Real responses redirect with a relative `VASTAdTagURI`.
    static func resolve(_ tag: URL, against base: URL?) -> URL {
        guard tag.scheme == nil, let base else { return tag }
        return URL(string: tag.absoluteString, relativeTo: base)?.absoluteURL ?? tag
    }
}
