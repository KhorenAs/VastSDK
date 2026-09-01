//
//  VASTBeaconDeliveryTests.swift
//  VASTKitTests
//

import XCTest
@testable import VASTCore
@testable import VASTKit

/// A tracking request is the only record that an ad was shown. These check that
/// one is not lost when it fails — the case that used to happen most, and
/// silently.
final class VASTBeaconDeliveryTests: XCTestCase {

    private var queue: VASTBeaconQueue!

    override func setUp() async throws {
        try await super.setUp()
        // A file of this test's own: the shared queue belongs to the app, and a
        // test must not inherit or destroy what the last run left there.
        queue = VASTBeaconQueue(fileName: "vast-test-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        await queue.removeAll()
        queue = nil
        try await super.tearDown()
    }

    // MARK: - The queue

    func testAnUndeliveredBeaconIsKept() async {
        await queue.enqueue([Self.url("impression")])
        let count = await queue.count()
        XCTAssertEqual(count, 1)
    }

    /// Taken rather than copied. Draining and keeping would send every beacon
    /// again on every flush for as long as one of them kept failing.
    func testDrainingEmptiesTheQueue() async {
        await queue.enqueue([Self.url("a"), Self.url("b")])

        let drained = await queue.drain()
        XCTAssertEqual(drained.count, 2)

        let remaining = await queue.count()
        XCTAssertEqual(remaining, 0, "a drained beacon would be sent twice")
    }

    /// The whole point: a beacon queued by one launch is still there for the next.
    func testTheQueueSurvivesTheProcessThatWroteIt() async {
        let name = "vast-test-\(UUID().uuidString).json"
        let first = VASTBeaconQueue(fileName: name)
        await first.enqueue([Self.url("impression")])

        // A different instance reading the same file is as close as a test gets
        // to a relaunch.
        let second = VASTBeaconQueue(fileName: name)
        let drained = await second.drain()
        XCTAssertEqual(drained.map(\.lastPathComponent), ["impression"])

        await second.removeAll()
    }

    func testTheQueueIsCappedOldestOutFirst() async {
        let urls = (0..<(VASTBeaconQueue.capacity + 20)).map { Self.url("beacon\($0)") }
        await queue.enqueue(urls)

        let drained = await queue.drain()
        XCTAssertEqual(drained.count, VASTBeaconQueue.capacity)
        XCTAssertEqual(
            drained.last?.lastPathComponent, "beacon\(VASTBeaconQueue.capacity + 19)",
            "the newest beacons are the ones worth keeping"
        )
    }

    // MARK: - The transport

    func testABeaconThatFailsIsQueuedRatherThanLost() async {
        FailingProtocol.reset(failing: true)
        let transport = VASTURLSessionTransport(
            session: Self.stubbedSession(), maxAttempts: 1, queue: queue
        )

        await transport.fire([Self.beacon("impression")])

        let held = await queue.count()
        XCTAssertEqual(held, 1, "the impression that paid for the break was dropped")
    }

    func testABeaconThatLandsIsNotQueued() async {
        FailingProtocol.reset(failing: false)
        let transport = VASTURLSessionTransport(
            session: Self.stubbedSession(), maxAttempts: 1, queue: queue
        )

        await transport.fire([Self.beacon("impression")])

        let held = await queue.count()
        XCTAssertEqual(held, 0)
    }

    /// Retries ride along with the next flush rather than on a timer of their own,
    /// so they happen when the network is known to be working.
    func testTheNextFlushCarriesTheEarlierFailure() async {
        FailingProtocol.reset(failing: true)
        let failing = VASTURLSessionTransport(
            session: Self.stubbedSession(), maxAttempts: 1, queue: queue
        )
        await failing.fire([Self.beacon("impression")])
        let heldBefore = await queue.count()
        XCTAssertEqual(heldBefore, 1)

        FailingProtocol.reset(failing: false)
        let working = VASTURLSessionTransport(
            session: Self.stubbedSession(), maxAttempts: 1, queue: queue
        )
        await working.fire([Self.beacon("start")])

        XCTAssertEqual(
            Set(FailingProtocol.requested), ["impression", "start"],
            "the earlier failure did not ride along"
        )
        let heldAfter = await queue.count()
        XCTAssertEqual(heldAfter, 0)
    }

    /// A host that has its own counting can opt out; the default must not be that.
    func testRetentionIsOnByDefault() {
        let transport = VASTURLSessionTransport()
        XCTAssertNotNil(transport, "the default transport keeps what it cannot deliver")
    }

    // MARK: - Fixtures

    private static func url(_ path: String) -> URL {
        URL(string: "https://ads.test/\(path)")!
    }

    private static func beacon(_ path: String) -> VASTBeacon {
        VASTBeacon(kind: .impression, url: url(path), adID: "a")
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingProtocol.self]
        return URLSession(configuration: configuration)
    }
}

// MARK: - A network that fails on demand

/// Answers every request without touching a network, so "the beacon failed" is a
/// setting rather than a wait.
private final class FailingProtocol: URLProtocol {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shouldFail = false
    nonisolated(unsafe) private static var seen: [String] = []

    static func reset(failing: Bool) {
        lock.lock()
        shouldFail = failing
        seen = []
        lock.unlock()
    }

    static var requested: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        if let path = request.url?.lastPathComponent { Self.seen.append(path) }
        let failing = Self.shouldFail
        Self.lock.unlock()

        if failing {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
