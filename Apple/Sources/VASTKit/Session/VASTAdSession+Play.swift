//
//  VASTAdSession+Play.swift
//  VASTSDK
//

import Foundation
import AVFoundation
import VASTCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension VASTAdSession {

    /// Plays every ad the response yielded, in order, then restores the host's
    /// content.
    ///
    /// A single ad failing does not end the break: §3.3.1 asks the player to
    /// substitute an unplayed stand-alone ad, and to move on to the next pod
    /// member when no substitute is left.
    @discardableResult
    public func play() async -> Outcome {
        // A second caller joins the break in flight instead of starting a rival
        // one. Returning its outcome keeps `play()` honest for both callers.
        if let running = activeBreak { return await running.value }
        // A `play` that was waiting behind a `load` the host has since stopped
        // must not start anything. `stop()` clears the schedule; this is what
        // notices.
        guard scheduler != nil else { return .failed(.undefined) }

        // `[weak self]` is defensive rather than load-bearing: a completed `Task`
        // does not retain its closure's captures, so storing it in `activeBreak`
        // is not a cycle — measured, not assumed. Weak keeps it true even if the
        // task is later made long-lived.
        let task = Task { @MainActor [weak self] () -> Outcome in
            guard let self else { return .failed(.undefined) }
            return await self.runBreak()
        }
        activeBreak = task
        let outcome = await task.value
        if activeBreak == task { activeBreak = nil }
        return outcome
    }

    private func runBreak() async -> Outcome {
        guard var scheduler else { return .failed(.undefined) }

        let playback = VASTPlaybackController(player: player)
        activePlayback = playback
        defer {
            if configuration.restoresPlayerItem {
                // An abandoned break must not hand the content back *playing*:
                // the host is leaving, and resuming here is what kept the audio
                // going after the screen was dismissed.
                playback.restore(resumingPlayback: !playback.isAborted)
            }
            playback.invalidate()
            if activePlayback === playback { activePlayback = nil }
            self.scheduler = nil
            currentAd = nil
            canSkip = false
            timeUntilSkip = nil
            remainingTime = 0
            lastTick = nil
            currentMediaFile = nil
            delegate?.sessionDidFinishAllAds(self)
        }

        var lastOutcome: Outcome = .failed(.undefined)
        var index = 0

        while let queued = scheduler.next() {
            if Task.isCancelled || playback.isAborted { break }
            index += 1
            adPosition = AdPosition(index: index, total: scheduler.totalCount)

            var outcome = await playOne(queued, using: playback)
            if case .failed = outcome, let substitute = scheduler.substituteForFailure() {
                outcome = await playOne(substitute, using: playback)
            }
            lastOutcome = outcome
        }

        self.scheduler = scheduler
        state = .finished(lastOutcome)
        return lastOutcome
    }

    // MARK: - One ad

    private func playOne(_ ad: VASTAd, using playback: VASTPlaybackController) async -> Outcome {
        currentAd = ad
        canSkip = false
        timeUntilSkip = ad.linear.resolvedSkipOffset()
        // Seed the countdown from <Duration> so the overlay reads the creative's
        // length while it buffers, instead of showing 0s.
        remainingTime = ad.linear.duration
        state = .loading
        lastTick = nil

        var engine = VASTTrackingEngine(ad: ad)

        // §2.3: "nor should the media player play the Skippable Ad as a Linear
        // Ad (without skip controls)". A host that cannot offer the control is
        // told to expect a trafficking error, not handed a compliance breach.
        if ad.isSkippable, configuration.skipPresentation == .unsupported {
            return fail(.trafficking, ad: ad, engine: &engine)
        }

        let file: VASTAd.MediaFile
        do {
            file = try VASTMediaFileSelector().select(
                from: ad.linear.mediaFiles,
                capabilities: Self.deviceCapabilities()
            )
        } catch {
            return fail(.noSupportedMediaFile, ad: ad, engine: &engine)
        }

        currentMediaFile = file

        let item: AVPlayerItem
        do {
            item = try await playback.begin(mediaFile: file)
        } catch let error as VASTError {
            return fail(error, ad: ad, engine: &engine)
        } catch {
            return fail(.mediaFileDisplayProblem, ad: ad, engine: &engine)
        }

        // The creative became playable, but the break may have been abandoned
        // while it loaded — in which case nothing should go on screen.
        if Task.isCancelled || playback.isAborted {
            return .failed(.mediaFileTimeout)
        }

        state = .playing
        delegate?.session(self, didStart: ad, at: adPosition)

        let clock = VASTPlayerClock(player: player, adItem: item)
        self.activeClock = clock
        self.activeEngine = engine
        defer { activeClock = nil; activeEngine = nil }

        // The item reaching its end is the authoritative signal that the creative
        // is over. Watch time alone cannot be trusted for this: stalls are
        // deliberately excluded from it, so a single buffering hiccup would leave
        // the ad frozen on its last frame with nothing to end it.
        let endOfItem = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, var engine = self.activeEngine else { return }
                let beacons = engine.playbackDidReachEnd()
                self.activeEngine = engine
                self.send(beacons)
                self.activeClock?.stop()
            }
        }
        defer { NotificationCenter.default.removeObserver(endOfItem) }

        /// Wall-clock moment the playhead last moved, so a dead stream is
        /// abandoned instead of hanging the break.
        var lastAdvance = ProcessInfo.processInfo.systemUptime
        var lastPosition: TimeInterval = -1

        for await tick in clock.ticks() {
            guard var current = activeEngine else { break }
            lastTick = tick
            let beacons = current.advance(to: tick)
            activeEngine = current
            engine = current

            // Never awaited. A beacon is a request to somebody else's server:
            // awaiting it here means one slow or unreachable tracking host stops
            // the playback loop dead — the countdown freezes, the skip control
            // never unlocks, and the ad can never end. Tracking is best-effort by
            // design, so it is dispatched and forgotten.
            send(beacons)
            update(with: tick, ad: ad)
            // Covers the case where the system stopped playback and the
            // activation notification arrived before this loop was listening.
            playback.resumeIfNeeded()

            if tick.adTime > lastPosition + 0.01 {
                lastPosition = tick.adTime
                lastAdvance = tick.wallClock
            } else if playback.isSuspendedBySystem {
                // Backgrounded or audio-interrupted: the playhead is meant to be
                // still, so the clock for "stuck" does not run.
                lastAdvance = tick.wallClock
            } else if playback.wantsPlayback,
                      tick.wallClock - lastAdvance > Self.stallTimeout {
                send(current.playbackDidStall())
                activeEngine = current
                engine = current
                delegate?.session(self, didFail: .mediaFileTimeout, for: ad)
                break
            }

            if current.isFinished { break }
        }
        clock.stop()

        let outcome: Outcome = outcomeFor(engine)
        skipRequested = false
        delegate?.session(self, didFinish: ad, outcome: outcome)
        return outcome
    }

    /// How long the playhead may sit still, while the player claims to be
    /// playing, before the creative is written off as unplayable (402).
    static let stallTimeout: TimeInterval = 10

    /// A skip beats everything; otherwise the creative counts as completed only
    /// if the engine actually finished it, not merely because something played.
    private func outcomeFor(_ engine: VASTTrackingEngine) -> Outcome {
        if skipRequested { return .skipped }
        guard engine.isFinished else { return .failed(.mediaFileTimeout) }
        return engine.watched >= engine.duration * VASTTrackingEngine.completionThreshold
            ? .completed
            : .failed(.mediaFileDisplayProblem)
    }

    private func fail(
        _ error: VASTError,
        ad: VASTAd,
        engine: inout VASTTrackingEngine
    ) -> Outcome {
        send(engine.fail(error))
        delegate?.session(self, didFail: error, for: ad)
        return .failed(error)
    }

    /// Hands beacons to the transport without waiting for them.
    ///
    /// Macros are substituted here rather than where each beacon is created: the
    /// values they need — playhead, muted state, which creative — belong to the
    /// session, and doing it in one place is what stops a `[ERRORCODE]` going out
    /// as the literal text `[ERRORCODE]`.
    func send(_ beacons: [VASTBeacon]) {
        guard !beacons.isEmpty else { return }
        let expanded = beacons.map(expandMacros)
        let transport = transport
        Task.detached { await transport.fire(expanded) }
    }

    private func expandMacros(_ beacon: VASTBeacon) -> VASTBeacon {
        var context = VASTMacroExpander.Context(
            adPlayhead: lastTick?.adTime,
            assetURI: currentMediaFile?.url,
            isMuted: lastTick?.isMuted
        )
        // Only an error beacon carries a code, and it is the code for *this*
        // failure — not the last one the session happened to see.
        if case .error(let error) = beacon.kind {
            context.errorCode = error
        }
        return VASTBeacon(
            kind: beacon.kind,
            url: macros.expand(beacon.url, with: context),
            adID: beacon.adID
        )
    }

    /// Publishes the state SwiftUI and the delegate render from.
    private func update(with tick: VASTTick, ad: VASTAd) {
        let duration = tick.duration ?? ad.linear.duration
        remainingTime = max(0, duration - tick.adTime)

        guard let unlockAt = ad.linear.resolvedSkipOffset() else {
            timeUntilSkip = nil
            return
        }
        let remainingUntilSkip = max(0, unlockAt - tick.adTime)
        timeUntilSkip = remainingUntilSkip > 0 ? remainingUntilSkip : nil

        if remainingUntilSkip <= 0, !canSkip {
            canSkip = true
            verifySkipSurface(for: ad)
            delegate?.session(self, skipDidBecomeAvailableFor: ad)
        }
    }

    /// The screen the creative will actually be shown on, used to rank media files.
    private static func deviceCapabilities() -> VASTMediaFileSelector.Capabilities {
        #if os(macOS)
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1280, height: 720)
        return VASTMediaFileSelector.Capabilities(width: Int(size.width), height: Int(size.height))
        #else
        let bounds = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        return VASTMediaFileSelector.Capabilities(
            width: Int(bounds.width * scale),
            height: Int(bounds.height * scale)
        )
        #endif
    }
}
