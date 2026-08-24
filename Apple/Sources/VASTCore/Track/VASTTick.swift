//
//  VASTTick.swift
//  VASTSDK
//

import Foundation

/// One observation of the ad playhead.
///
/// The tracking engine never asks a player for the time — time is pushed in.
/// That makes every rule below (quartiles, seek rejection, asset-swap detection)
/// a pure function of two consecutive ticks, and therefore unit-testable without
/// AVFoundation, a media file, or real elapsed time.
public struct VASTTick: Sendable, Equatable {

    /// Playhead inside the ad creative.
    public let adTime: TimeInterval
    /// Duration reported by the player; falls back to `<Duration>` when unknown.
    public let duration: TimeInterval?
    /// `0` while paused/stalled. Quartiles only count at normal speed (§3.14.1).
    public let rate: Float
    /// Monotonic wall clock, used to tell natural playback from a seek.
    public let wallClock: TimeInterval
    /// `false` once the host swapped the player's item out from under the ad.
    public let itemIsOurs: Bool
    public let isMuted: Bool

    public init(
        adTime: TimeInterval,
        duration: TimeInterval?,
        rate: Float,
        wallClock: TimeInterval,
        itemIsOurs: Bool = true,
        isMuted: Bool = false
    ) {
        self.adTime = adTime
        self.duration = duration
        self.rate = rate
        self.wallClock = wallClock
        self.itemIsOurs = itemIsOurs
        self.isMuted = isMuted
    }
}
