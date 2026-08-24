//
//  PlatformView.swift
//  VASTSDK
//

import Foundation

#if os(macOS)
import AppKit
/// The native view type an ad surface is added to.
public typealias PlatformView = NSView
#else
import UIKit
public typealias PlatformView = UIView
#endif

/// Opens a creative's click-through destination.
///
/// This lives inside the SDK because `ClickPresentation.surface` promises the
/// spec's own model — "the media player opens [the URI] when a viewer clicks the
/// ad" (§3.10.1) — and a promise the host has to keep is not a promise.
enum VASTDestinationOpener {

    @MainActor
    static func open(_ url: URL) {
        #if os(tvOS)
        // tvOS has no browser. The click is still tracked; there is simply
        // nowhere to send the viewer, which is why `click()` also returns the URL
        // so a TV host can show a QR code or a message instead.
        _ = url
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #else
        guard UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
