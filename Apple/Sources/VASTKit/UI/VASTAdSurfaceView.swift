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
        func makeNSView(context: Context) -> PlatformView { view }
        func updateNSView(_ nsView: PlatformView, context: Context) {}
    }
    #else
    private struct Wrapper: UIViewRepresentable {
        let view: PlatformView
        func makeUIView(context: Context) -> PlatformView { view }
        func updateUIView(_ uiView: PlatformView, context: Context) {}
    }
    #endif
}
