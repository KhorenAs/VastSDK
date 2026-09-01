//
//  VASTVersion.swift
//  VASTSDK
//

import Foundation

/// This SDK's own version.
///
/// Hard-coded rather than read from a bundle: `VASTCore` ships without resources,
/// and a version that reads as "unknown" in a release build is worse than one
/// that has to be edited at release time. It reaches ad servers through
/// `[CLIENTUA]`, which is how an exchange tells one player from another when a
/// creative misbehaves.
public enum VASTVersion {
    public static let current = "1.2.0"
}
