//
//  iVASTClock.swift
//  VASTSDK
//

import Foundation
import VASTCore

/// Source of playhead observations for the tracking engine.
///
/// Kept as a protocol for two reasons: tests drive a scripted tick sequence with
/// no player at all, and a host that already runs its own playback-time
/// accounting (e.g. Kinodaran's `ATPlayerTimeCalculator`, which accumulates real
/// elapsed playback rather than raw playhead position) can feed that in directly.
public protocol iVASTClock: Sendable {
    func ticks() -> AsyncStream<VASTTick>
    func stop()
}
