//
//  VASTLog.swift
//  VASTSDK
//

import Foundation
import os

/// Where the SDK says the things a host needs to know but that cannot be
/// returned from a call.
///
/// These are compliance complaints — a skip control that is not on screen, a
/// click path that cannot exist on this platform — and they reach the host twice
/// over: through the delegate, which it can act on, and through here, which it
/// can read while debugging.
///
/// `print` was the wrong half of that. It writes to stdout, which a host cannot
/// filter, cannot redirect and cannot silence, and which is invisible in a
/// release build's device logs. A `Logger` is filterable by subsystem in Console
/// and `log stream`, and costs nothing when nobody is listening.
enum VASTLog {

    /// §2.3 and §3.10.1 promises the SDK cannot keep on its own.
    static let compliance = Logger(subsystem: "com.kinodaran.vastsdk", category: "compliance")
}
