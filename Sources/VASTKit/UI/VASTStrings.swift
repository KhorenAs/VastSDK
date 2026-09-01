//
//  VASTStrings.swift
//  VASTSDK
//

import Foundation

/// The words the SDK's own ad UI puts on screen.
///
/// Localised inside the package rather than left to the host. Every element of
/// the surface is replaceable, so a host *can* supply its own copy — but the
/// default is what a host that configures nothing gets, and shipping an English
/// skip control into an Armenian app is not a neutral default.
///
/// Read through `Bundle.module`: the strings travel with the package, so a host
/// adds nothing and localises nothing to get its own language.
enum VASTStrings {

    /// The package's own bundle, so a test can check every language rather than
    /// only the one the machine happens to be running in.
    static var bundle: Bundle { .module }

    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }

    /// Formatted separately from `text` because the arguments are numbers and the
    /// placeholder order is the translator's to change.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }
}
