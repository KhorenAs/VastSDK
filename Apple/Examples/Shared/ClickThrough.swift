//
//  ClickThrough.swift
//  VASTDemo
//

import Foundation

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Opens a creative's `<ClickThrough>` destination.
///
/// Lives in the demo rather than the SDK on purpose: what a click should do is a
/// product decision. A phone opens a browser, a Mac opens the default one, and a
/// TV has no browser at all — so the SDK reports the destination and fires the
/// click trackers, and the host decides the rest.
enum ClickThrough {

    /// - Returns: what happened, for the demo's event log.
    @MainActor
    @discardableResult
    static func open(_ url: URL) -> String {
        #if os(tvOS)
        return "clickThrough not opened on tvOS (no browser): \(url.absoluteString)"
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        return "clickThrough opened \(url.absoluteString)"
        #else
        guard UIApplication.shared.canOpenURL(url) else {
            return "clickThrough cannot be opened: \(url.absoluteString)"
        }
        UIApplication.shared.open(url)
        return "clickThrough opened \(url.absoluteString)"
        #endif
    }
}
