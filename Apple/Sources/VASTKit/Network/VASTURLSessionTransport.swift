//
//  VASTURLSessionTransport.swift
//  VASTSDK
//

import Foundation
import VASTCore

/// Default transport: a plain `GET` per beacon, concurrently, with one retry.
///
/// At-least-once delivery is safe by design — a VAST tracking URI carries its own
/// event identity, so a repeat is de-duplicated by the ad server rather than
/// double-counted. Failures are swallowed: tracking must never break playback.
public struct VASTURLSessionTransport: iVASTBeaconTransport {

    private let session: URLSession
    private let maxAttempts: Int

    /// Short per-request timeout. A tracking beacon that has not landed in a few
    /// seconds is not going to, and `URLSession`'s 60-second default would keep
    /// retry work alive long after the ad it describes has finished.
    public static let requestTimeout: TimeInterval = 5

    public init(session: URLSession? = nil, maxAttempts: Int = 2) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout * 2
            self.session = URLSession(configuration: configuration)
        }
        self.maxAttempts = max(1, maxAttempts)
    }

    public func fire(_ beacons: [VASTBeacon]) async {
        guard !beacons.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for beacon in beacons {
                group.addTask { await send(beacon.url) }
            }
        }
    }

    private func send(_ url: URL) async {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        for _ in 0..<maxAttempts {
            do {
                _ = try await session.data(for: request)
                return
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
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
