//
//  AdBreakScreen.swift
//  VASTDemo
//

import Foundation
import AVFoundation
import Combine
import VASTCore
import VASTKit

/// Everything one player screen owns: the `AVPlayer`, the ad session, and the
/// content transport.
///
/// One owner on purpose. Previously the view held the player, and so did the
/// session, and so did the content model — three references created in the view's
/// `init`, which SwiftUI re-runs on every redraw. An `AVPlayer` that is genuinely
/// released stops making sound on its own, so the way to guarantee silence after
/// the screen goes away is for exactly one object to own it and for that object
/// to be the thing SwiftUI releases.
@MainActor
final class AdBreakScreen: ObservableObject {

    /// Live instances. After backing out of every player screen this must read
    /// zero; a number that stays up is a screen — and its player — still alive.
    ///
    /// Counted in `init`/`deinit`, deliberately. An earlier version decremented in
    /// `invalidate()`, which measured "teardown was called" rather than "the
    /// object went away" — so it would have read zero while leaking, which is
    /// worse than no diagnostic at all.
    ///
    /// `deinit` is nonisolated, so the counter cannot be actor-bound. A lock keeps
    /// it correct and a main-actor mirror keeps it observable.
    final class LiveCount: @unchecked Sendable, ObservableObject {

        static let shared = LiveCount()

        @Published private(set) var value = 0
        private let lock = NSLock()
        private var count = 0

        fileprivate func adjust(_ delta: Int) {
            lock.lock()
            count += delta
            let snapshot = count
            lock.unlock()
            // Published on the next turn: `AdBreakScreen` is built inside
            // `StateObject(wrappedValue:)`, which SwiftUI evaluates during a view
            // update, and publishing from there is undefined behaviour.
            Task { @MainActor in self.value = snapshot }
        }
    }

    let scenario: DemoScenario
    let player: AVPlayer
    let session: VASTAdSession
    let content: ContentPlayerModel

    @Published private(set) var log: [String] = []
    @Published private(set) var isBusy = false
    private var didStartFirstBreak = false

    init(scenario: DemoScenario) {
        self.scenario = scenario
        let player = AVPlayer(url: DemoCatalog.contentStream)
        self.player = player
        self.session = VASTAdSession(player: player)
        self.content = ContentPlayerModel(player: player)

        LiveCount.shared.adjust(1)
    }

    deinit {
        // The only honest place to count a release.
        LiveCount.shared.adjust(-1)
    }

    /// Called when the screen goes away. Explicit rather than left to `deinit`,
    /// which under strict concurrency cannot touch any of this.
    func invalidate() {
        session.stop()
        content.pause()
        content.invalidate()
        // Nothing should be left holding the player after this; releasing it is
        // what actually stops the sound.
        player.replaceCurrentItem(with: nil)
    }

    var isPlayingAd: Bool {
        switch session.state {
        case .playing, .paused: true
        case .idle, .loading, .finished: false
        }
    }

    // MARK: - Flow

    func start() async {
        content.play()
        guard !didStartFirstBreak else { return }
        didStartFirstBreak = true

        // `try?` here was the leak. SwiftUI cancels this task when the screen is
        // dismissed, `Task.sleep` throws in response — and `try?` swallowed it, so
        // execution carried straight on into the break. The screen was gone, but
        // the task went on loading and playing an ad, holding the screen (and its
        // player, and the audio) alive until the creative finished.
        do {
            // Let the content establish itself, so the hand-over and the return
            // are both visible.
            try await Task.sleep(nanoseconds: 3_000_000_000)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }
        await runBreak()
    }

    func runBreak() async {
        guard !isBusy, !Task.isCancelled else { return }
        isBusy = true
        defer { isBusy = false }

        log.removeAll()
        note("load \(scenario.id)")
        do {
            switch scenario.source {
            case .tag(let url): try await session.load(tag: DemoCatalog.requestReady(url))
            case .xml(let xml): try await session.load(xml: xml)
            }
        } catch VASTAdSession.SessionError.stopped {
            // The screen was dismissed while the response was loading.
            return
        } catch let error as VASTError {
            note("failed · VAST \(error.rawValue) \(error)")
            return
        } catch {
            note("failed · \(error)")
            return
        }

        // Between the request going out and the response arriving, the screen may
        // have been dismissed. `await` on its own does not notice.
        guard !Task.isCancelled else { return }

        note("resolved \(session.adPosition.total) slot(s) to play")
        content.isSuspended = true
        let outcome = await session.play()
        content.isSuspended = false
        note("break finished · \(outcome)")
    }

    var hasPlayedOnce: Bool { didStartFirstBreak }

    func note(_ line: String) {
        log.append(line)
    }
}
