//
//  VASTAdSurfaceView.swift
//  VASTSDK
//

import Foundation
import SwiftUI
import VASTCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The ad UI for UIKit and AppKit hosts, added by `VASTAdSession.attach(to:)`.
///
/// Hosts `VASTAdSurface` so the two platforms cannot drift apart: the skip and
/// click behaviour that §2.3 and §3.10.1 require is written once. Overriding the
/// look is done with the same builders, expressed in native view types.
@MainActor
public final class VASTAdSurfaceView: PlatformView {

    /// Replaces the skip control. The argument is the time until it unlocks, or
    /// `nil` once it has.
    public var skipButtonBuilder: ((TimeInterval?) -> PlatformView)? {
        didSet { rebuild() }
    }

    public var adBadgeBuilder: ((VASTAdSession.AdPosition) -> PlatformView)? {
        didSet { rebuild() }
    }

    /// Replaces the countdown. The argument is the time left in the creative.
    public var countdownBuilder: ((TimeInterval) -> PlatformView)? {
        didSet { rebuild() }
    }

    /// Handle the click destination yourself instead of letting the SDK open it.
    public var clickThroughHandler: ((URL) -> Void)? {
        didSet { rebuild() }
    }

    private let session: VASTAdSession
    private var hosting: PlatformView?

    public init(session: VASTAdSession) {
        self.session = session
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        #else
        backgroundColor = .clear
        #endif
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func rebuild() {
        hosting?.removeFromSuperview()

        var surface = VASTAdSurface(session: session)
        if let skipButtonBuilder {
            surface = surface.vastSkipButton { remaining in
                PlatformViewRepresentable(view: skipButtonBuilder(remaining))
            }
        }
        if let adBadgeBuilder {
            surface = surface.vastAdBadge { position in
                PlatformViewRepresentable(view: adBadgeBuilder(position))
            }
        }
        if let countdownBuilder {
            surface = surface.vastCountdown { remaining in
                PlatformViewRepresentable(view: countdownBuilder(remaining))
            }
        }
        if let clickThroughHandler {
            surface = surface.vastClickThrough(clickThroughHandler)
        }

        #if os(macOS)
        let controller = NSHostingView(rootView: surface)
        #else
        let controller = _UIHostingWrapper(rootView: surface)
        #endif
        controller.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controller)
        NSLayoutConstraint.activate([
            controller.topAnchor.constraint(equalTo: topAnchor),
            controller.bottomAnchor.constraint(equalTo: bottomAnchor),
            controller.leadingAnchor.constraint(equalTo: leadingAnchor),
            controller.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        hosting = controller
    }
}

#if !os(macOS)
/// A `UIHostingController`'s view, wrapped so it can be constrained like any
/// other view without the caller managing a child controller.
@MainActor
private final class _UIHostingWrapper<Content: View>: UIView {

    private let controller: UIHostingController<Content>

    init(rootView: Content) {
        controller = UIHostingController(rootView: rootView)
        super.init(frame: .zero)
        backgroundColor = .clear
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
#endif

/// Lets a native view supplied by a UIKit/AppKit host stand in for a SwiftUI one,
/// so both surfaces share a single implementation.
private struct PlatformViewRepresentable: View {

    let view: PlatformView

    var body: some View {
        Wrapper(view: view)
            .fixedSize()
    }

    #if os(macOS)
    private struct Wrapper: NSViewRepresentable {
        let view: PlatformView
        func makeNSView(context: Context) -> SwapContainer { SwapContainer() }
        func updateNSView(_ container: SwapContainer, context: Context) {
            container.host(view)
        }
    }
    #else
    private struct Wrapper: UIViewRepresentable {
        let view: PlatformView
        func makeUIView(context: Context) -> SwapContainer { SwapContainer() }
        func updateUIView(_ container: SwapContainer, context: Context) {
            container.host(view)
        }
    }
    #endif
}

/// Holds one host-supplied view, and replaces it when a new one arrives.
///
/// `makeUIView`/`makeNSView` run once per view identity, so handing the builder's
/// view straight back froze whatever the *first* call produced: a countdown that
/// never counted, and a skip control stuck on the hourglass it was born with,
/// long after the offset had elapsed. The container is what gives `update`
/// something it can actually change.
///
/// A builder is called on every redraw, so this swaps several times a second
/// while an ad is on screen. That is cheap for a label or a pill, and it is the
/// price of a contract that returns a new view rather than updating one.
@MainActor
final class SwapContainer: PlatformView {

    private var hosted: PlatformView?

    func host(_ view: PlatformView) {
        guard hosted !== view else { return }
        hosted?.removeFromSuperview()
        hosted = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        invalidateIntrinsicContentSize()
    }

    /// The size the hosted control wants, because the container has none of its
    /// own and SwiftUI asks the container.
    ///
    /// Without this the control collapsed to whatever its own constraints forced
    /// and its content was clipped away: on tvOS a yellow pill reading "Skip"
    /// arrived as a blank 44×44 circle, which is its minimum hit target and
    /// nothing else.
    override var intrinsicContentSize: CGSize {
        guard let hosted else { return super.intrinsicContentSize }
        #if os(macOS)
        return hosted.fittingSize
        #else
        return hosted.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        #endif
    }
}
