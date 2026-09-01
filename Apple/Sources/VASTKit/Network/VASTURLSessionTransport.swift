//
//  VASTURLSessionTransport.swift
//  VASTSDK
//

import Foundation
import os
import VASTCore

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Default transport: a plain `GET` per beacon, concurrently, with one retry —
/// and what fails is kept rather than lost.
///
/// At-least-once delivery is safe by design: a VAST tracking URI carries its own
/// event identity, so a repeat is de-duplicated by the ad server rather than
/// double-counted. That is what makes the two things below possible, and both are
/// about the same failure — an impression the ad server never heard about.
///
/// **Undelivered beacons are queued.** Anything that fails every attempt goes to
/// `VASTBeaconQueue`, which persists it and hands it back on a later flush,
/// including after the app has been relaunched.
///
/// **A flush holds a background task.** Requests in flight when the app leaves
/// the foreground used to be cancelled outright, which is where beacons were lost
/// most often — the end of a break is exactly when a viewer puts the phone down.
///
/// A failure still never interrupts playback. It is simply no longer forgotten.
public struct VASTURLSessionTransport: iVASTBeaconTransport {

    private let session: URLSession
    private let maxAttempts: Int
    private let queue: VASTBeaconQueue?

    /// Short per-request timeout. A tracking beacon that has not landed in a few
    /// seconds is not going to, and `URLSession`'s 60-second default would keep
    /// retry work alive long after the ad it describes has finished.
    public static let requestTimeout: TimeInterval = 5

    private static let log = Logger(subsystem: "com.kinodaran.vastsdk", category: "delivery")

    /// - Parameter retainsUndelivered: whether beacons that fail every attempt are
    ///   kept and retried later. `false` restores the old behaviour of dropping
    ///   them, which is only reasonable where something else is counting.
    public init(
        session: URLSession? = nil,
        maxAttempts: Int = 2,
        retainsUndelivered: Bool = true
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout * 2
            self.session = URLSession(configuration: configuration)
        }
        self.maxAttempts = max(1, maxAttempts)
        self.queue = retainsUndelivered ? .shared : nil
    }

    /// Testing seam: a queue of this transport's own, so a test never shares the
    /// file the app uses.
    init(session: URLSession, maxAttempts: Int = 1, queue: VASTBeaconQueue?) {
        self.session = session
        self.maxAttempts = max(1, maxAttempts)
        self.queue = queue
    }

    public func fire(_ beacons: [VASTBeacon]) async {
        guard !beacons.isEmpty else { return }
        await holdingBackgroundTask {
            // Earlier failures ride along with current traffic, so a retry costs
            // no timer of its own and happens when the network is known to work.
            let retries = await queue?.drain() ?? []
            await deliver(retries + beacons.map(\.url))
        }
    }

    private func deliver(_ urls: [URL]) async {
        let undelivered = await withTaskGroup(of: URL?.self) { group in
            for url in urls {
                group.addTask { await send(url) ? nil : url }
            }
            var failed: [URL] = []
            for await url in group {
                if let url { failed.append(url) }
            }
            return failed
        }

        guard !undelivered.isEmpty else { return }
        Self.log.warning("\(undelivered.count, privacy: .public) beacon(s) undelivered")
        await queue?.enqueue(undelivered)
    }

    /// - Returns: whether the beacon landed.
    private func send(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        for _ in 0..<maxAttempts {
            do {
                let (_, response) = try await session.data(for: request)
                // A 4xx or 5xx is the server's answer, not a delivery failure:
                // retrying it forever would be the SDK arguing with an ad server
                // about a URI the ad server wrote.
                if let http = response as? HTTPURLResponse, (500..<600).contains(http.statusCode) {
                    continue
                }
                return true
            } catch is CancellationError {
                // The app is going away. This is the case the queue exists for.
                return false
            } catch {
                continue
            }
        }
        return false
    }

    /// Keeps the app alive long enough to finish a flush.
    ///
    /// Beacons went missing here more than anywhere else: a break ends, the
    /// viewer puts the phone down, and every request still in flight is
    /// cancelled. macOS has no equivalent and needs none.
    private func holdingBackgroundTask(_ body: () async -> Void) async {
        #if canImport(UIKit) && !os(watchOS)
        let token = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "VASTSDK beacon flush")
        }
        await body()
        await MainActor.run {
            if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
        }
        #else
        await body()
        #endif
    }
}

/// Default loader for tags and Wrapper redirection.
public struct VASTURLSessionLoader: iVASTResourceLoader {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func loadVAST(from url: URL, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/xml, text/xml;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VASTError.wrapperTimeout
        }
        // Ad servers are inconsistent about declaring an encoding; UTF-8 first,
        // then Latin-1, which never fails and is better than discarding the ad.
        guard let xml = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw VASTError.xmlParsing
        }
        return xml
    }
}
