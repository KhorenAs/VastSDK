//
//  VASTAd.Verification.swift
//  VASTSDK
//

import Foundation

public extension VASTAd {

    /// One `<Verification>` from `<AdVerifications>` (§3.16): a measurement
    /// vendor asking to observe this ad.
    ///
    /// The SDK parses these and hands them over; it never executes them. Running
    /// verification code means the IAB Open Measurement SDK, which is licensed
    /// separately and lives outside this package — so what belongs here is the
    /// description of what was asked for, and enough detail to report honestly
    /// when nothing runs it.
    struct Verification: Sendable, Equatable {

        /// `<Verification vendor>`. Absent on responses that predate the attribute.
        public let vendor: String?
        public let resources: [Resource]
        /// `<VerificationParameters>` — opaque to everyone but the vendor.
        public let parameters: String?
        /// `<Tracking event="verificationNotExecuted">`. Owed when the vendor's
        /// code does not run, so the vendor can tell "unmeasured" from "unserved".
        public let notExecutedTrackers: [URL]

        public init(
            vendor: String?,
            resources: [Resource],
            parameters: String? = nil,
            notExecutedTrackers: [URL] = []
        ) {
            self.vendor = vendor
            self.resources = resources
            self.parameters = parameters
            self.notExecutedTrackers = notExecutedTrackers
        }

        /// The resource an Open Measurement integration can actually use.
        ///
        /// `nil` means nothing here is executable by an OMID host — an
        /// `<ExecutableResource>`, or a JavaScript resource for some other
        /// framework. That distinction is what separates
        /// `.resourceNotSupported` from `.notExecuted` when reporting.
        public var omidResource: Resource? {
            resources.first { $0.kind == .javaScript && $0.isOMID }
        }

        /// One `<JavaScriptResource>` or `<ExecutableResource>`.
        public struct Resource: Sendable, Equatable {

            public enum Kind: Sendable, Equatable {
                case javaScript
                /// Native vendor code. Nothing in this SDK can run one; it is
                /// modelled so the reason reported back is the true one.
                case executable
            }

            public let kind: Kind
            public let url: URL
            /// `omid` for Open Measurement. Other values exist and are not ours.
            public let apiFramework: String?
            /// `<JavaScriptResource browserOptional>`: whether the script can run
            /// outside a browser context. Defaults to false per §3.16.
            public let browserOptional: Bool
            /// `<ExecutableResource type>`, e.g. a platform identifier.
            public let type: String?

            public init(
                kind: Kind,
                url: URL,
                apiFramework: String? = nil,
                browserOptional: Bool = false,
                type: String? = nil
            ) {
                self.kind = kind
                self.url = url
                self.apiFramework = apiFramework
                self.browserOptional = browserOptional
                self.type = type
            }

            /// Ad servers are inconsistent about the case of `omid`.
            public var isOMID: Bool { apiFramework?.lowercased() == "omid" }
        }
    }
}

public extension VASTAd.Verification {

    /// Why a vendor's code did not run, as the values §3.16 defines for the
    /// `verificationNotExecuted` tracker's `[REASON]` macro.
    enum NotExecutedReason: Int, Sendable, Equatable {
        /// No resource this host could ever execute — executable-only, or a
        /// JavaScript resource for a framework other than OMID.
        case resourceNotSupported = 1
        /// A usable resource that failed to load or timed out. Only whoever
        /// tried to load it knows this, so the SDK never reports it on its own.
        case resourceLoadError = 2
        /// A usable resource that nothing was asked to run — no measurement
        /// integration is configured.
        case notExecuted = 3
    }
}
