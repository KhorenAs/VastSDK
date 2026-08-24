//
//  VASTPodScheduler.swift
//  VASTSDK
//

import Foundation

/// Decides play order for a VAST response (§3.3.1).
///
/// Sequenced ads form the pod and play in numerical order. Non-sequenced ads are
/// the "ad buffet" and are held back as substitutes for pod members that fail.
public struct VASTPodScheduler: Sendable {

    private var pod: [VASTAd]
    private var spares: [VASTAd]
    private var index = 0

    public var totalCount: Int { pod.count }
    public var currentIndex: Int { index }

    public init(ads: [VASTAd]) {
        self.pod = ads.filter { $0.sequence != nil }.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
        self.spares = ads.filter { $0.sequence == nil }
        // A response with no sequenced ads is a plain single/buffet response;
        // play the first stand-alone ad as the "pod".
        if pod.isEmpty, !spares.isEmpty {
            pod = [spares.removeFirst()]
        }
    }

    public mutating func next() -> VASTAd? {
        guard index < pod.count else { return nil }
        defer { index += 1 }
        return pod[index]
    }

    /// The ad just handed out could not play. Substitute an unplayed stand-alone
    /// ad if one exists; otherwise the caller moves on to the next pod entry.
    public mutating func substituteForFailure() -> VASTAd? {
        spares.isEmpty ? nil : spares.removeFirst()
    }
}
