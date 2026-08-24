//
//  VASTTrackingEngine.swift
//  VASTSDK
//

import Foundation

/// Decides which beacons a playback session owes, from a stream of ticks.
///
/// Pure and deterministic: no IO, no AVFoundation, no wall-clock reads of its
/// own. Feed it a tick sequence and it returns the beacons — which is exactly
/// how the seek and asset-swap rules are tested.
public struct VASTTrackingEngine: Sendable {

    /// A jump larger than this, relative to what elapsed wall-clock allows,
    /// is treated as a seek rather than playback.
    public static let seekTolerance: TimeInterval = 0.75

    /// Fraction of the creative that counts as "played to the end". Declared
    /// `<Duration>` and real media length routinely differ by a fraction of a
    /// second, and the last tick rarely lands exactly on the final frame.
    public static let completionThreshold = 0.97

    private let ad: VASTAd
    /// Starts from `<Duration>` and is replaced by the player's own figure as
    /// soon as one is available: the declared value is advisory, and quartiles
    /// computed against the wrong length land in the wrong places.
    private(set) public var duration: TimeInterval

    /// How far into the creative the viewer has actually got, in seconds.
    ///
    /// A high-water mark over *covered* timeline, which is the distinction
    /// §3.14.1 is really drawing with "played continuously": buffering does not
    /// skip any of the creative, whereas seeking does.
    ///
    /// - A stall leaves the playhead where it was; when it resumes, the next
    ///   position is still contiguous, so coverage continues. Summing playback
    ///   deltas instead would silently discount every stall, and on a stuttering
    ///   connection the completion threshold would never be reached at all.
    /// - A forward seek lands beyond what wall-clock time could account for, so
    ///   it never extends coverage — and cannot afterwards, because the mark only
    ///   moves within reach of where it already was.
    private(set) public var watched: TimeInterval = 0
    private(set) public var isFinished = false

    private var fired: Set<VASTAd.TrackingEvent> = []
    private var firedProgress: Set<Int> = []
    private var firedImpression = false
    private var previous: VASTTick?
    /// True when the caller pinned the duration, in which case reported values
    /// are ignored.
    private let durationIsPinned: Bool
    /// Whether something is going to execute the ad's verification resources.
    ///
    /// The engine cannot know this — running verification code means an Open
    /// Measurement integration, which lives above this layer — so it is stated
    /// by whoever built the engine. When nothing will run them, the vendors are
    /// owed `verificationNotExecuted` rather than silence.
    private let measurementWillRun: Bool

    public init(ad: VASTAd, duration: TimeInterval? = nil, measurementWillRun: Bool = false) {
        self.ad = ad
        self.duration = duration ?? ad.linear.duration
        self.durationIsPinned = duration != nil
        self.measurementWillRun = measurementWillRun
    }

    // MARK: - Input

    public mutating func advance(to tick: VASTTick) -> [VASTBeacon] {
        guard !isFinished else { return [] }

        // The host replaced the player item mid-ad. Nothing after this point can
        // be attributed to our creative, so stop and report.
        guard tick.itemIsOurs else {
            return fail(.mediaFileDisplayProblem)
        }

        var beacons: [VASTBeacon] = []
        defer { previous = tick }

        if !durationIsPinned, let reported = tick.duration, reported > 0 {
            duration = reported
        }

        if tick.rate > 0 {
            beacons += startIfNeeded()
            advanceWatched(with: tick)
        }

        beacons += quartileBeacons()
        beacons += progressBeacons()

        if watched >= duration * Self.completionThreshold {
            beacons += finish()
        }
        return beacons
    }

    /// The player reported that the item played to its end.
    ///
    /// This is the authoritative end of the creative. Accumulated watch time
    /// cannot be used on its own: every buffering stall is excluded from it by
    /// design, so on a stuttering connection the threshold is never reached and
    /// the ad would hang on its last frame forever.
    ///
    /// `complete` still requires the creative to have actually been watched
    /// through — reaching the end by seeking is not completion (§3.14.1).
    public mutating func playbackDidReachEnd() -> [VASTBeacon] {
        guard !isFinished else { return [] }
        var beacons = progressBeacons()
        if watched >= duration * Self.completionThreshold {
            beacons += fire(.complete)
        }
        isFinished = true
        return beacons
    }

    /// Playback stopped advancing and is not going to resume.
    public mutating func playbackDidStall() -> [VASTBeacon] {
        fail(.mediaFileTimeout)
    }

    public mutating func userDidSkip() -> [VASTBeacon] {
        guard !isFinished else { return [] }
        isFinished = true
        // A skipped ad may still owe progress beacons that its watched time
        // already earned (§3.14.1), so those are emitted before `skip`.
        return progressBeacons() + fire(.skip)
    }

    /// Reports a player-operation event the engine cannot observe from ticks —
    /// mute, pause, fullscreen and friends (§3.14.1 "Player Operation Metrics").
    ///
    /// Quartile and lifecycle events are derived from playback instead and are
    /// not accepted here, so a host cannot fabricate a billable impression.
    public mutating func report(_ event: VASTAd.TrackingEvent) -> [VASTBeacon] {
        guard !isFinished, event.isHostReportable else { return [] }
        return fire(event)
    }

    public mutating func fail(_ error: VASTError) -> [VASTBeacon] {
        guard !isFinished else { return [] }
        isFinished = true
        return ad.errors.map { VASTBeacon(kind: .error(error), url: $0, adID: ad.id) }
    }

    // MARK: - Rules

    /// Extends coverage to this tick's position when the position is within
    /// reach of the mark — that is, when elapsed wall-clock time at the current
    /// rate could plausibly have carried the playhead there.
    ///
    /// A rewind lands below the mark and leaves it untouched. A forward seek
    /// lands above what elapsed time allows and is refused, permanently: the
    /// mark can only ever advance from where it already is, so no later tick can
    /// smuggle the skipped span back in.
    private mutating func advanceWatched(with tick: VASTTick) {
        guard let previous else {
            watched = max(watched, min(tick.adTime, Self.seekTolerance))
            return
        }
        let elapsed = max(0, tick.wallClock - previous.wallClock) * Double(tick.rate)
        let reachable = watched + elapsed + Self.seekTolerance
        guard tick.adTime <= reachable else { return }
        watched = max(watched, tick.adTime)
    }

    private mutating func startIfNeeded() -> [VASTBeacon] {
        var beacons: [VASTBeacon] = []
        if !firedImpression {
            firedImpression = true
            beacons += ad.impressions.map {
                VASTBeacon(kind: .impression, url: $0, adID: ad.id)
            }
            // Reported with the impression, not later: the vendor is deciding
            // right now whether this session counts as measured.
            beacons += verificationsNotExecuted()
            beacons += fire(.creativeView)
        }
        beacons += fire(.start)
        return beacons
    }

    /// One beacon per tracker of every vendor whose code will not run.
    ///
    /// Reason 2 (`resourceLoadError`) never originates here — only whoever tried
    /// to load a resource can report that, and by definition nothing tried.
    private func verificationsNotExecuted() -> [VASTBeacon] {
        guard !measurementWillRun else { return [] }
        return ad.adVerifications.flatMap { verification in
            let reason: VASTAd.Verification.NotExecutedReason =
                verification.omidResource == nil ? .resourceNotSupported : .notExecuted
            return verification.notExecutedTrackers.map {
                VASTBeacon(kind: .verificationNotExecuted(reason), url: $0, adID: ad.id)
            }
        }
    }

    private mutating func quartileBeacons() -> [VASTBeacon] {
        guard duration > 0 else { return [] }
        let progress = watched / duration
        var beacons: [VASTBeacon] = []
        if progress >= 0.25 { beacons += fire(.firstQuartile) }
        if progress >= 0.50 { beacons += fire(.midpoint) }
        if progress >= 0.75 { beacons += fire(.thirdQuartile) }
        return beacons
    }

    private mutating func progressBeacons() -> [VASTBeacon] {
        var beacons: [VASTBeacon] = []
        for (index, event) in ad.linear.progressEvents.enumerated() {
            let offset = event.offset.seconds(forDuration: duration)
            guard watched >= offset, !firedProgress.contains(index) else { continue }
            firedProgress.insert(index)
            beacons.append(VASTBeacon(kind: .progress(offset), url: event.url, adID: ad.id))
        }
        return beacons
    }

    private mutating func finish() -> [VASTBeacon] {
        isFinished = true
        return fire(.complete)
    }

    /// Emits an event's URIs at most once when the event is once-only.
    private mutating func fire(_ event: VASTAd.TrackingEvent) -> [VASTBeacon] {
        if event.isOnce {
            guard !fired.contains(event) else { return [] }
            fired.insert(event)
        }
        return event.equivalents
            .flatMap { ad.linear.trackingEvents[$0] ?? [] }
            .map { VASTBeacon(kind: .tracking(event), url: $0, adID: ad.id) }
    }
}
