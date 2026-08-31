//
//  VASTAdSession.swift
//  VASTSDK
//

import Foundation
import AVFoundation
import Combine
import VASTCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Plays one VAST response on a host-supplied `AVPlayer` and reports tracking.
///
/// The session owns no UI. It publishes state (`ObservableObject`, for SwiftUI)
/// and forwards the same transitions to `iVASTAdSessionDelegate` (for UIKit and
/// AppKit hosts). Drawing the skip control is the host's job — see `canSkip`.
@MainActor
public final class VASTAdSession: ObservableObject {

    // MARK: - Published state (SwiftUI)

    @Published public internal(set) var state: State = .idle
    @Published public internal(set) var currentAd: VASTAd?
    /// Position within the pod, 1-based. `(1, 1)` for a single ad.
    @Published public internal(set) var adPosition: AdPosition = .single
    @Published public internal(set) var remainingTime: TimeInterval = 0
    /// `true` once `skipoffset` has elapsed on a skippable ad.
    @Published public internal(set) var canSkip = false
    /// Seconds until the skip control unlocks; `nil` when the ad is not skippable.
    @Published public internal(set) var timeUntilSkip: TimeInterval?

    /// Whether the host is willing to draw the whole ad UI itself when a
    /// response asks it to.
    ///
    /// `false`, the default, means the SDK draws its own UI whatever the response
    /// says. That is deliberate: `<Extensions>` is vendor territory, and a
    /// vendor key must not be able to take the §2.3 skip promise away from a host
    /// that never agreed to honour it.
    ///
    /// Set it to `true` and the SDK reads the `uiSettings` UI-hidden key from the
    /// response. When the key is there the SDK draws nothing at all — no badge,
    /// no countdown, no click layer and no skip control — and the entire ad UI
    /// becomes yours. Pair it with `skipPresentation = .host`, which is the
    /// statement that you accept that obligation; leaving it at `.sdk` is
    /// reported through the delegate, because the control the SDK promised is
    /// then on nobody's screen.
    ///
    /// `suppressesAdUI` is the answer for the ad currently playing.
    @Published public var isHiddenUi = false

    /// Whether the ad on screen right now must be drawn by the host: the host
    /// allowed it *and* this response asked for it.
    public var suppressesAdUI: Bool {
        guard isHiddenUi, let ad = currentAd else { return false }
        return ad.isUIHidden
    }

    public weak var delegate: (any iVASTAdSessionDelegate)?

    /// Third-party measurement, if anything is going to execute the ad's
    /// `<AdVerifications>`. Set it before `play()`.
    ///
    /// Held strongly, unlike `delegate`: a measurement integration is usually
    /// created for the session and holds the vendor session state, and a weak
    /// reference there fails by silently measuring nothing — the one failure a
    /// measurement layer must not have.
    ///
    /// Leaving this `nil` is not a gap: the SDK then reports
    /// `verificationNotExecuted` to every vendor that asked, which is the honest
    /// answer and the whole reason the field is optional.
    public var measurement: (any iVASTAdMeasurement)?

    let player: AVPlayer
    /// Read by the ad surface, which has to know who owns the skip control and
    /// whether the creative is clickable.
    public let configuration: any iConfiguration
    let transport: any iVASTBeaconTransport
    private let resolver: VASTTagResolver

    var scheduler: VASTPodScheduler?
    /// The engine for the ad on screen. Held here because `skip()` arrives from
    /// the host on a different call than the tick loop that owns playback.
    var activeEngine: VASTTrackingEngine?
    var activeClock: (any iVASTClock)?
    var skipRequested = false
    /// The break currently running, if any.
    ///
    /// Two concurrent breaks would share `activeEngine` and `activeClock` and
    /// corrupt each other: one loop reads the other's engine, exits immediately
    /// and leaves the published countdown frozen, while the other reports a
    /// completion it never earned. A host can call `load`/`play` whenever it
    /// likes, so the session — not the host — has to enforce one at a time.
    var activeBreak: Task<Outcome, Never>?
    /// The controller driving the current break, so it can be aborted from
    /// outside the loop that owns it.
    var activePlayback: VASTPlaybackController?
    /// Bumped by `stop()`. Work that was already in flight compares the token it
    /// started with and discards its result if the session has moved on.
    ///
    /// Without this, `stop()` clearing the schedule was not enough: a `load`
    /// still resolving would come back afterwards, put the schedule back, and the
    /// `play` queued behind it would start a break on a screen that had already
    /// been dismissed — audible, and with nothing left to stop it.
    private var generation = 0

    /// The last tick seen, so a beacon can report where the playhead was — the
    /// ad server asked for `[ADPLAYHEAD]`, not for "somewhere in the ad".
    var lastTick: VASTTick?
    /// The creative being played, for `[ASSETURI]`.
    var currentMediaFile: VASTAd.MediaFile?
    let macros = VASTMacroExpander()
    /// Weak on purpose. The surface holds the session so it can read published
    /// state, and the container it was added to owns the surface — so a strong
    /// handle here closes a cycle that keeps the session, its `AVPlayer` and the
    /// decoded creative alive for the rest of the process. All this reference is
    /// for is being able to remove the view again.
    /// The surface pinned by `attach(to:)`, when the host took that route.
    /// Measurement needs a view to measure, and this is the only one the SDK is
    /// ever handed.
    weak var attachedSurface: VASTAdSurfaceView?

    /// What is known about the ad surface being on screen. Reported by the
    /// surface itself; see `VASTSurfacePresence` for what it can and cannot see.
    public private(set) var surfacePresence = VASTSurfacePresence()
    /// One complaint per ad: the control is re-measured on every layout pass, and
    /// a warning repeated forty times a second helps nobody.
    private var reportedSkipControlProblem = false

    func noteSurface(size: CGSize) {
        surfacePresence.update(size: size)
    }

    /// Reports a vendor's resource as having failed to load.
    ///
    /// Only the measurement layer can know this — the SDK never fetches a
    /// verification resource — so `resourceLoadError` reaches the vendor through
    /// here or not at all. Firing it is additive: the SDK stayed silent about
    /// this ad precisely because measurement was configured.
    public func reportVerificationNotExecuted(
        _ verification: VASTAd.Verification,
        reason: VASTAd.Verification.NotExecutedReason = .resourceLoadError
    ) {
        guard let ad = currentAd else { return }
        send(verification.notExecutedTrackers.map {
            VASTBeacon(kind: .verificationNotExecuted(reason), url: $0, adID: ad.id)
        })
    }

    /// Each ad in a pod gets its own control, and its own chance to be wrong.
    func resetSkipControlReport() {
        reportedSkipControlProblem = false
    }

    /// Reported when the skip control is laid out, which is the only moment its
    /// real size exists. Judged here rather than at unlock time: the control is
    /// drawn after `canSkip` flips, so asking then would read a size that has not
    /// happened yet.
    func noteSkipControl(size: CGSize) {
        surfacePresence.update(skipControlSize: size)
        guard configuration.skipPresentation == .sdk,
              let ad = currentAd, ad.isSkippable,
              !reportedSkipControlProblem,
              let diagnosis = surfacePresence.skipControlDiagnosis
        else { return }
        reportedSkipControlProblem = true
        print("[VASTKit] skip control unavailable: \(diagnosis)")
        delegate?.session(self, skipControlUnavailableFor: ad, reason: diagnosis)
    }

    /// §3.10.1 makes ClickThrough support Required, and the surface is how the
    /// SDK provides it — except where a transparent sheet cannot be reached at
    /// all. Saying so is the difference between a host choosing `.host` and a
    /// host shipping an ad nobody can click.
    func verifyClickPath(for ad: VASTAd) {
        #if os(tvOS)
        guard configuration.clickPresentation == .surface,
              ad.linear.clickThrough != nil
        else { return }
        let reason = """
        clickPresentation is .surface, but tvOS has no pointer and a transparent \
        layer cannot take focus, so this ad has no click path. Set \
        clickPresentation to .host and call click() from a focusable control of \
        your own, or to .disabled to opt out knowingly.
        """
        print("[VASTKit] click path unavailable: \(reason)")
        delegate?.session(self, clickThroughUnavailableFor: ad, reason: reason)
        #endif
    }

    /// The ad UI is being suppressed at the response's request, but the host
    /// never took the skip control over. Reported rather than refused: unlike
    /// `skipPresentation = .unsupported`, the host did opt in here — it just
    /// opted in to half of what that means.
    func verifyHostDrawnUI(for ad: VASTAd) {
        guard suppressesAdUI, ad.isSkippable, configuration.skipPresentation == .sdk else { return }
        let reason = """
        the response asked for host-drawn UI and isHiddenUi permits it, so the SDK \
        is drawing nothing — but skipPresentation is still .sdk, which promised \
        this skippable ad a control. Set skipPresentation to .host and draw one, \
        or leave isHiddenUi false for this break.
        """
        print("[VASTKit] skip control unavailable: \(reason)")
        delegate?.session(self, skipControlUnavailableFor: ad, reason: reason)
    }

    /// Checks the one compliance promise the SDK cannot verify on its own, at the
    /// moment it actually matters: the control is due, so it had better be
    /// somewhere a viewer can reach.
    func verifySkipSurface(for ad: VASTAd) {
        guard configuration.skipPresentation == .sdk, ad.isSkippable else { return }
        // Already reported at the start of the ad, and no control was drawn to
        // measure — complaining again when the offset elapses says nothing new.
        guard !suppressesAdUI else { return }
        // `attach(to:)` means the SDK owns the surface and pinned it itself.
        guard attachedSurface == nil else { return }
        guard let diagnosis = surfacePresence.diagnosis else { return }
        // Reported, not fatal. This is a heuristic about someone else's layout,
        // and a heuristic that is wrong must not take the host's app down with
        // it — which is exactly what an assertion here did the first time the
        // probe misread a surface it had in fact been given.
        print("[VASTKit] skip control unavailable: \(diagnosis)")
        delegate?.session(self, skipControlUnavailableFor: ad, reason: diagnosis)
    }

    public init(player: AVPlayer, configuration: any iConfiguration = Configuration()) {
        self.player = player
        self.configuration = configuration
        self.transport = configuration.transport ?? VASTURLSessionTransport()
        self.resolver = VASTTagResolver(
            loader: configuration.loader ?? VASTURLSessionLoader(),
            maxDepth: configuration.maxWrapperDepth,
            timeout: configuration.wrapperTimeout
        )
    }

    // MARK: - Loading

    /// Requests a tag from an ad server and follows its Wrapper chain.
    ///
    /// Preferred over `load(xml:)` whenever the response comes from a URL: a
    /// `VASTAdTagURI` is often relative, and only the fetch location can resolve it.
    ///
    /// - Throws: `VASTError` describing why no ad could be produced. Every
    ///   `<Error>` URI collected on the way down has already been fired, as
    ///   §2.3.5.1 requires, before this throws.
    public func load(tag url: URL) async throws {
        try await load { try await resolver.resolve(tag: url) }
    }

    /// Loads a response already in hand. `baseURL` should be supplied when known,
    /// so that a relative `VASTAdTagURI` inside it can still be followed.
    public func load(xml: String, baseURL: URL? = nil) async throws {
        try await load { try await resolver.resolve(xml: xml, baseURL: baseURL) }
    }

    private func load(_ resolve: () async throws -> VASTTagResolver.Resolution) async throws {
        // Loading a new response mid-break abandons the old one rather than
        // running both; a "replay" button is otherwise a race by construction.
        await cancelActiveBreak()
        let token = generation
        state = .loading
        do {
            let resolution = try await resolve()
            guard token == generation else { throw SessionError.stopped }
            guard !resolution.ads.isEmpty else { throw VASTError.noVASTResponseAfterWrappers }
            let scheduler = VASTPodScheduler(ads: resolution.ads)
            self.scheduler = scheduler
            adPosition = AdPosition(index: 0, total: scheduler.totalCount)
            state = .idle
        } catch let failure as VASTTagResolver.Failure {
            // The wrappers traversed are owed an error request even though the
            // caller is about to see a thrown error — but it is not awaited.
            // Awaiting it left `load` sitting in `.loading` until somebody else's
            // tracking host answered, which on a no-fill response meant the UI
            // never came back at all.
            send(failure.beacons)
            state = .finished(.failed(failure.error))
            throw failure.error
        } catch let stopped as SessionError {
            // Nothing to report: the host asked for this by stopping.
            throw stopped
        } catch {
            state = .finished(.failed(.undefined))
            throw error
        }
    }

    // MARK: - Ad surface

    /// Adds the SDK's ad UI to a container the host already owns.
    ///
    /// For UIKit and AppKit hosts. SwiftUI hosts compose `VASTAdSurface` in
    /// their own `ZStack` instead — same behaviour, idiomatic placement.
    /// - Note: the surface is added last and kept front-most, which is the one
    ///   thing the SwiftUI path cannot do — there, ordering is the host's.
    public func attach(to container: PlatformView) {
        detach()
        let surface = VASTAdSurfaceView(session: self)
        surface.translatesAutoresizingMaskIntoConstraints = false

        // Added front-most in one step. Adding and then re-adding to reorder
        // re-parents the view on AppKit, which drops the constraints pinning it
        // and leaves the surface unsized — with no room for the control it is
        // supposed to guarantee.
        #if os(macOS)
        container.addSubview(surface, positioned: .above, relativeTo: nil)
        #else
        container.addSubview(surface)
        container.bringSubviewToFront(surface)
        #endif

        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        attachedSurface = surface
    }

    public func detach() {
        attachedSurface?.removeFromSuperview()
        attachedSurface = nil
    }

    /// Records a click on the creative.
    ///
    /// Fires every `<ClickTracking>` URI and returns the `<ClickThrough>`
    /// destination. Opening it is the host's decision: only the host knows
    /// whether that means a browser, an in-app sheet, or nothing at all on a TV.
    @discardableResult
    public func click() -> URL? {
        guard let ad = currentAd else { return nil }
        let beacons = ad.linear.clickTracking.map {
            VASTBeacon(kind: .clickTracking, url: $0, adID: ad.id)
        }
        send(beacons)
        return ad.linear.clickThrough
    }

    /// Ends the running break and waits for it to actually be over.
    ///
    /// Aborting the playback controller is the part that matters: cancelling the
    /// task and stopping the clock still left a `begin` in flight, which would
    /// come back, swap in its creative and start playing on top of whatever
    /// replaced it.
    func cancelActiveBreak() async {
        guard let running = activeBreak else { return }
        activeBreak = nil
        activePlayback?.abort()
        activeClock?.stop()
        activeEngine = nil
        running.cancel()
        _ = await running.value
    }

    // MARK: - Playback control

    /// - Throws: `SkipError` when the current ad is not skippable, or when
    ///   `skipoffset` has not elapsed yet. Never silently ignores the request —
    ///   playing a skippable ad without honouring its skip control violates
    ///   VAST §2.3.
    public func skip() throws {
        guard let ad = currentAd else { throw SkipError.noActiveAd }
        guard ad.isSkippable else { throw SkipError.notSkippable }
        guard canSkip else { throw SkipError.notYetAvailable(after: timeUntilSkip ?? 0) }

        skipRequested = true
        if var engine = activeEngine {
            let beacons = engine.userDidSkip()
            activeEngine = engine
            send(beacons)
        }
        // Ending the tick stream lets the pod loop advance to the next ad.
        activeClock?.stop()
    }

    /// Pauses the ad on screen and reports it (§3.14.1 player operation metrics).
    ///
    /// Pause has to come through here rather than through the `AVPlayer`. The
    /// session re-issues playback on every tick so that an ad survives the system
    /// stopping it — iOS leaves `rate` at 0 after backgrounding and never resumes
    /// — and it cannot tell that apart from a host pausing behind its back, so a
    /// pause made on the player is undone within one tick and reported to nobody.
    ///
    /// Does nothing unless an ad is playing.
    public func pause() {
        guard state == .playing, let playback = activePlayback else { return }
        playback.pauseByUser()
        report(.pause)
        state = .paused
    }

    /// Resumes an ad paused by `pause()`, and reports that too.
    ///
    /// Does nothing unless the session is paused; in particular it will not
    /// override a pause the *system* imposed, which lifts on its own.
    public func resume() {
        guard state == .paused, let playback = activePlayback else { return }
        playback.resumeByUser()
        report(.resume)
        state = .playing
    }

    /// Reports an event the SDK cannot observe for itself — mute, fullscreen and
    /// the rest of §3.14.1's player operation metrics.
    ///
    /// Quartiles, `start` and `complete` are derived from observed playback and
    /// are refused here, so a host cannot fabricate a billable event. Reporting
    /// an event no `<Tracking>` element asked for is free and does nothing.
    public func report(_ event: VASTAd.TrackingEvent) {
        guard var engine = activeEngine else { return }
        let beacons = engine.report(event)
        activeEngine = engine
        send(beacons)
    }

    /// Abandons the break and hands the player back to the host.
    ///
    /// This is what a screen calls on its way out, so it also takes the ad UI
    /// down: leaving the surface behind leaves a view observing a session nobody
    /// is driving any more.
    public func stop() {
        // Invalidate first: a `load` or `play` already in flight has to be able
        // to tell that it is no longer wanted.
        generation += 1
        // Then order matters: abort so nothing in flight can start playing
        // again, and pause before the break's own teardown gets a chance to
        // restore the host's item and resume it.
        activePlayback?.abort()
        activeBreak?.cancel()
        // Cleared, not just cancelled. A cancelled task the session still holds
        // is still a task the session holds.
        activeBreak = nil
        activePlayback = nil
        activeClock?.stop()
        activeClock = nil
        activeEngine = nil
        scheduler = nil
        player.pause()
        detach()
        state = .idle
    }
}
