//
//  VASTTagResolver.swift
//  VASTSDK
//

import Foundation

/// Fetches a tag and follows its Wrapper chain to the InLine ads behind it.
///
/// The only impure part is asking the loader for XML; every decision — when to
/// stop, which error code to report, what to accumulate — belongs to
/// `VASTWrapperChain` and is tested without IO.
public struct VASTTagResolver: Sendable {

    /// Ads plus the error URIs owed if playback later fails.
    public struct Resolution: Sendable {
        public let ads: [VASTAd]
        public let chain: VASTWrapperChain
    }

    /// Raised when the chain ends without a playable ad. `beacons` are the
    /// `<Error>` requests owed to every Wrapper that was traversed.
    public struct Failure: Error, Sendable {
        public let error: VASTError
        public let beacons: [VASTBeacon]
    }

    private let loader: any iVASTResourceLoader
    private let parser = VASTParser()
    private let maxDepth: Int
    private let timeout: TimeInterval

    public init(loader: any iVASTResourceLoader, maxDepth: Int = 5, timeout: TimeInterval = 5) {
        self.loader = loader
        self.maxDepth = maxDepth
        self.timeout = timeout
    }

    /// Resolves a tag URL, following Wrappers until an InLine response.
    public func resolve(tag url: URL) async throws -> Resolution {
        try await follow(url, chain: VASTWrapperChain(maxDepth: maxDepth))
    }

    /// Resolves a document already in hand. Wrappers inside it are still
    /// followed, so a caller holding XML gets the same behaviour as `resolve(tag:)`.
    public func resolve(xml: String, baseURL: URL? = nil) async throws -> Resolution {
        var chain = VASTWrapperChain(maxDepth: maxDepth)
        switch try step(xml, from: baseURL, chain: &chain) {
        case .resolved(let ads):
            return Resolution(ads: ads, chain: chain)
        case .failed(let error):
            throw Failure(error: error, beacons: chain.errorBeacons(for: error))
        case .follow(let url):
            // The chain carries on rather than starting again. Handing the tail a
            // fresh one dropped this document's own `<Impression>` and `<Error>`
            // URIs, restarted the depth count — making the effective limit twice
            // `maxDepth` — and lost its `allowMultipleAds` constraint.
            return try await follow(url, chain: chain)
        }
    }

    /// Walks the redirect chain from `url`, carrying what has been collected.
    ///
    /// Takes the chain by value and returns the result rather than mutating in
    /// place: `inout` cannot cross an `await`, and the chain is a value type
    /// precisely so that this is not a problem.
    private func follow(_ url: URL, chain: VASTWrapperChain) async throws -> Resolution {
        var chain = chain
        var next = url

        while true {
            let xml: String
            do {
                xml = try await loader.loadVAST(from: next, timeout: timeout)
            } catch {
                // A dead or slow redirect is a 301, and the wrappers already
                // traversed still expect to hear about it.
                throw Failure(error: .wrapperTimeout, beacons: chain.errorBeacons(for: .wrapperTimeout))
            }

            switch try step(xml, from: next, chain: &chain) {
            case .resolved(let ads):
                return Resolution(ads: ads, chain: chain)
            case .follow(let url):
                next = url
            case .failed(let error):
                throw Failure(error: error, beacons: chain.errorBeacons(for: error))
            }
        }
    }

    private func step(
        _ xml: String,
        from baseURL: URL?,
        chain: inout VASTWrapperChain
    ) throws -> VASTWrapperChain.Step {
        do {
            return chain.accept(try parser.parse(xml), from: baseURL)
        } catch let error as VASTError {
            throw Failure(error: error, beacons: chain.errorBeacons(for: error))
        }
    }
}
