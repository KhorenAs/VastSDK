//
//  ContentPlayerModel.swift
//  VASTDemo
//

import Foundation
import AVFoundation
import Combine

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Drives the demo's own transport controls for the *content* stream.
///
/// Kept separate from `VASTAdSession` on purpose: the session reports the ad's
/// timeline, this reports the show's. They observe the same `AVPlayer`, which is
/// exactly why the controls must be disabled while an ad owns it — otherwise the
/// scrubber would be seeking the creative.
@MainActor
final class ContentPlayerModel: ObservableObject {

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    /// While true the controls are inert and hidden: the ad session owns the player.
    @Published var isSuspended = false

    /// Position being dragged, if any. The scrubber follows the finger rather
    /// than the playhead so it does not fight the periodic observer.
    @Published var scrubTarget: TimeInterval?

    private let player: AVPlayer
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []
    /// Whether the viewer had asked for playback before the app went away, so
    /// returning to the foreground resumes only what was actually playing.
    private var wasPlayingBeforeBackground = false

    init(player: AVPlayer) {
        self.player = player
        observe()
    }

    /// Explicit teardown rather than `deinit`: the observer token is not
    /// `Sendable`, so a nonisolated deinit cannot legally touch it under Swift 6
    /// strict concurrency. The view calls this when it goes away.
    func invalidate() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        cancellables.removeAll()
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, (scrubTarget ?? currentTime) / duration))
    }

    // MARK: - Actions

    func togglePlayPause() {
        guard !isSuspended else { return }
        player.rate > 0 ? player.pause() : player.play()
    }

    func play() {
        guard !isSuspended else { return }
        player.play()
    }

    func pause() {
        player.pause()
    }

    /// Called continuously while the user drags.
    func scrub(toProgress fraction: Double) {
        guard !isSuspended, duration > 0 else { return }
        scrubTarget = duration * min(1, max(0, fraction))
    }

    /// Called when the drag ends — one real seek instead of hundreds.
    func commitScrub() {
        guard !isSuspended, let target = scrubTarget else { return }
        scrubTarget = nil
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func step(by seconds: TimeInterval) {
        guard !isSuspended else { return }
        let target = max(0, min(duration, currentTime + seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    // MARK: - Observation

    private func observe() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isSuspended else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                let itemDuration = self.player.currentItem?.duration ?? .indefinite
                self.duration = itemDuration.isNumeric ? itemDuration.seconds : 0
            }
        }

        // iOS stops decoding video off-screen and never restarts it, so a
        // return to the foreground has to re-issue playback explicitly.
        #if os(macOS)
        let activated = NSApplication.didBecomeActiveNotification
        let deactivated = NSApplication.didResignActiveNotification
        #else
        let activated = UIApplication.didBecomeActiveNotification
        let deactivated = UIApplication.willResignActiveNotification
        #endif

        NotificationCenter.default.publisher(for: deactivated)
            .sink { [weak self] _ in
                guard let self else { return }
                self.wasPlayingBeforeBackground = self.player.rate > 0
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: activated)
            .sink { [weak self] _ in
                guard let self, self.wasPlayingBeforeBackground, !self.isSuspended else { return }
                self.player.play()
            }
            .store(in: &cancellables)

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = status == .playing
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
            .store(in: &cancellables)
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
