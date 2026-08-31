//
//  VASTAdSurface.swift
//  VASTSDK
//

import SwiftUI
import VASTCore

/// The ad UI, for SwiftUI hosts.
///
/// Composed over the host's own player view:
///
///     ZStack {
///         MyPlayerView(player: player)
///         VASTAdSurface(session: session)
///     }
///
/// Exists in the SDK rather than in every host because two of the things it draws
/// are specification requirements, not decoration: a skippable ad must be offered
/// a skip control (§2.3), and the ad must be clickable (§3.10.1). Leaving those to
/// each host meant the SDK could not tell whether it was compliant. Every element
/// is still replaceable — see the `vast…` modifiers — so owning the behaviour does
/// not mean owning the look.
///
/// The surface elevates its own `zIndex` (see `defaultZIndex`), so declaration
/// order in the host's stack cannot bury the skip control by accident.
public struct VASTAdSurface: View {

    /// Where the surface places itself among its siblings.
    ///
    /// High enough that ordinary layout cannot end up on top of it, so a host
    /// does not have to remember to declare the surface last:
    ///
    ///     ZStack {
    ///         VASTAdSurface(session: session)   // still draws above
    ///         MyGradientOverlay()
    ///     }
    ///
    /// Finite on purpose. A host with a real reason to cover the ad — a modal
    /// error, a paywall — can set a higher `zIndex` deliberately. What this
    /// prevents is covering it *by accident*, which is the case that silently
    /// hid the skip control §2.3 requires.
    public static let defaultZIndex: Double = 10_000

    @ObservedObject private var session: VASTAdSession

    private var skipButton: ((TimeInterval?) -> AnyView)?
    private var adBadge: ((VASTAdSession.AdPosition) -> AnyView)?
    private var countdown: ((TimeInterval) -> AnyView)?
    private var clickHandler: ((URL) -> Void)?
    private var zIndex: Double = VASTAdSurface.defaultZIndex

    public init(session: VASTAdSession) {
        self.session = session
    }

    public var body: some View {
        // GeometryReader rather than a `.background` probe: the controls only
        // exist while an ad is on screen, so a stack built from them collapses to
        // zero size the rest of the time — and a zero-sized view reports neither
        // an appearance nor a usable size. Measuring from the outside means the
        // surface always knows how much room it was actually given.
        GeometryReader { proxy in
            ZStack {
                if isShowingAd {
                    clickLayer
                    controls
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Only appearance and size are reported. `onDisappear` fires on
            // ordinary rebuilds and on teardown, so treating it as "the host
            // removed the surface" produces a false alarm on a correct host.
            .onAppear { session.noteSurface(size: proxy.size) }
            .onChange(of: proxy.size) { size in
                session.noteSurface(size: size)
            }
        }
        // A finished or idle session leaves nothing behind to intercept taps.
        .allowsHitTesting(isShowingAd)
        .zIndex(zIndex)
    }

    private var isShowingAd: Bool {
        // The response asked for host-drawn UI and the host allowed it, so this
        // surface draws nothing and takes no taps — the host's own controls are
        // the only ones there.
        guard !session.suppressesAdUI else { return false }
        return switch session.state {
        case .playing, .paused: session.currentAd != nil
        case .idle, .loading, .finished: false
        }
    }

    // MARK: - Click

    /// §3.10.1's model: the ad itself is what the viewer clicks.
    ///
    /// Not on tvOS. There is no pointer there and nothing focusable about a
    /// transparent sheet, so this layer would be inert — and an inert click path
    /// that looks present is worse than an absent one, because nobody finds out.
    /// The session reports it instead; a tvOS host wires its own affordance under
    /// `.host`, or opts out with `.disabled`.
    @ViewBuilder
    private var clickLayer: some View {
        #if !os(tvOS)
        if session.configuration.clickPresentation == .surface,
           session.currentAd?.linear.clickThrough != nil {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: performClick)
        }
        #endif
    }

    private func performClick() {
        guard let url = session.click() else { return }
        if let clickHandler {
            clickHandler(url)
        } else {
            VASTDestinationOpener.open(url)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack {
            HStack(spacing: 8) {
                badge
                countdownLabel
                Spacer()
            }
            Spacer()
            HStack {
                Spacer()
                skip
            }
        }
        .padding()
        .foregroundStyle(.white)
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private var badge: some View {
        if let adBadge {
            adBadge(session.adPosition)
        } else {
            Text(session.adPosition.isPod
                 ? "Ad \(session.adPosition.index)/\(session.adPosition.total)"
                 : "Ad")
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.yellow, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.black)
        }
    }

    @ViewBuilder
    private var countdownLabel: some View {
        if let countdown {
            countdown(session.remainingTime)
        } else {
            Text("\(Int(session.remainingTime.rounded(.up)))s")
        }
    }

    /// Drawn only when the SDK owns the control. Under `.host` the host draws it,
    /// and under `.unsupported` a skippable ad never reaches playback at all.
    ///
    /// A host-supplied control is wrapped in a `Button` rather than given a tap
    /// gesture. A gesture is not focusable, so on tvOS — where there is no tap at
    /// all — a custom skip control was unreachable while the built-in one worked,
    /// which is exactly backwards. The `Button` also brings hit-testing and
    /// accessibility that every host would otherwise have to remember.
    @ViewBuilder
    private var skip: some View {
        if session.configuration.skipPresentation == .sdk,
           session.currentAd?.isSkippable == true {
            if let skipButton {
                skipControl {
                    skipButton(session.canSkip ? nil : session.timeUntilSkip)
                }
            } else if session.canSkip {
                Button("Skip Ad  ›") { try? session.skip() }
                    .buttonStyle(.borderedProminent)
                    .measuredAsSkipControl(of: session)
            } else if let remaining = session.timeUntilSkip {
                Text("Skip in \(Int(remaining.rounded(.up)))")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func skipControl<V: View>(@ViewBuilder _ label: () -> V) -> some View {
        let button = Button(action: { if session.canSkip { try? session.skip() } }, label: label)
            .disabled(!session.canSkip)
            .measuredAsSkipControl(of: session)

        // tvOS keeps the platform button style: it is what draws the focus state,
        // and a host's label rarely draws one itself. Elsewhere `.plain` leaves
        // the host's look alone, which is the point of supplying one.
        #if os(tvOS)
        button
        #else
        button.buttonStyle(.plain)
        #endif
    }
}

// MARK: - Measurement

private extension View {

    /// Reports the drawn size of the skip control to the session.
    ///
    /// `SkipPresentation.sdk` promises the viewer a control, and a replaceable
    /// one can be replaced with nothing: a builder returning `EmptyView` collapses
    /// to zero and the promise is quietly broken. The surface probe cannot see
    /// this — it measures the surface, which is still the full size of the player.
    func measuredAsSkipControl(of session: VASTAdSession) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { session.noteSkipControl(size: proxy.size) }
                    .onChange(of: proxy.size) { session.noteSkipControl(size: $0) }
            }
        )
    }
}

// MARK: - Styling

public extension VASTAdSurface {

    /// Replaces the skip control. The closure's argument is the time left until
    /// the control unlocks, or `nil` once it has.
    func vastSkipButton<V: View>(
        @ViewBuilder _ build: @escaping (TimeInterval?) -> V
    ) -> Self {
        var copy = self
        copy.skipButton = { AnyView(build($0)) }
        return copy
    }

    func vastAdBadge<V: View>(
        @ViewBuilder _ build: @escaping (VASTAdSession.AdPosition) -> V
    ) -> Self {
        var copy = self
        copy.adBadge = { AnyView(build($0)) }
        return copy
    }

    func vastCountdown<V: View>(
        @ViewBuilder _ build: @escaping (TimeInterval) -> V
    ) -> Self {
        var copy = self
        copy.countdown = { AnyView(build($0)) }
        return copy
    }

    /// Handles the destination yourself — an in-app browser, say — instead of
    /// letting the SDK open it.
    func vastClickThrough(_ handle: @escaping (URL) -> Void) -> Self {
        var copy = self
        copy.clickHandler = handle
        return copy
    }

    /// Overrides where the surface sits among its siblings. Lowering it below
    /// another view means the skip control can be covered, so §2.3 stops being
    /// something the SDK can vouch for.
    func vastZIndex(_ value: Double) -> Self {
        var copy = self
        copy.zIndex = value
        return copy
    }
}
