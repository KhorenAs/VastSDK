//
//  VASTBeaconQueue.swift
//  VASTSDK
//

import Foundation
import os

/// Beacons that did not land, kept until they do.
///
/// A tracking request is the only record that an ad was shown, and the SDK used
/// to lose one the moment it failed. Worse, it lost them in the case that happens
/// most: a request in flight when the app left the foreground was cancelled, and
/// nothing remembered it. That is not a rounding error in somebody's report — it
/// is the impression that paid for the break.
///
/// Retrying, including across launches, is safe here by design rather than by
/// hope: a VAST tracking URI carries its own event identity, so a repeat is
/// de-duplicated by the ad server instead of double-counted. `<Impression>` is
/// explicit about at-least-once delivery for exactly this reason.
///
/// Two limits keep the file from becoming a graveyard. A beacon older than
/// `maxAge` is dropped, because a report about yesterday is worth less to an ad
/// server than a clean count; and the queue holds `capacity` entries, oldest
/// first out, so a device that spends a week offline does not accumulate a
/// megabyte of URLs it will never send.
actor VASTBeaconQueue {

    /// Shared, so retries survive the session that queued them — and so a host
    /// that builds a transport per break does not build a queue per break.
    static let shared = VASTBeaconQueue()

    /// Older than this and a beacon is dropped rather than sent.
    static let maxAge: TimeInterval = 6 * 60 * 60

    /// Most beacons kept at once.
    static let capacity = 500

    private struct Entry: Codable {
        let url: URL
        let recorded: Date
    }

    private let fileURL: URL?
    private var pending: [Entry]?
    private let log = Logger(subsystem: "com.kinodaran.vastsdk", category: "delivery")

    init(fileName: String = "vast-pending-beacons.json") {
        // Caches rather than Application Support, for two reasons: the system
        // reclaiming these costs a count rather than anything the viewer would
        // miss, and Caches is excluded from device backups — so a queued
        // identifier does not travel to iCloud or to a desktop archive.
        fileURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    /// Keeps beacons that failed, so the next flush can try again.
    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var entries = load()
        entries += urls.map { Entry(url: $0, recorded: Date()) }
        entries = trimmed(entries)
        pending = entries
        save(entries)
        log.notice("holding \(entries.count, privacy: .public) beacon(s) for retry")
    }

    /// Takes everything worth retrying, and forgets it.
    ///
    /// Taken rather than copied: whoever drains the queue owns delivery from that
    /// point, and re-queues what fails again. Holding on as well would send every
    /// beacon twice on every flush for as long as one of them kept failing.
    func drain() -> [URL] {
        let entries = trimmed(load())
        guard !entries.isEmpty else { return [] }
        pending = []
        save([])
        return entries.map(\.url)
    }

    func count() -> Int { trimmed(load()).count }

    /// Only for tests, which must not inherit the last run's file.
    func removeAll() {
        pending = []
        save([])
    }

    // MARK: - Storage

    private func load() -> [Entry] {
        if let pending { return pending }
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            pending = []
            return []
        }
        let entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        pending = entries
        return entries
    }

    private func save(_ entries: [Entry]) {
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        // Encrypted at rest, because of what these URLs contain. Macros are
        // expanded before a beacon reaches a transport, so a queued URL carries
        // whatever the host supplied — an advertising identifier and a TCF consent
        // string among them. Holding that in plaintext for hours is not what
        // keeping a beacon was meant to cost.
        //
        // `.completeFileProtection` rather than `.completeUnlessOpen`: a flush
        // only happens while an ad is playing, so the file never needs reading
        // while the device is locked.
        //
        // Not on macOS, where the option is not merely unnecessary but fatal:
        // data protection classes are an iOS mechanism, and `write` refuses the
        // whole write rather than ignoring an option it cannot honour — which
        // meant the queue never survived a relaunch there at all. Whole-disk
        // encryption is the Mac's answer and is not ours to ask for.
        //
        // A failed write is not worth interrupting anything for: the beacons are
        // still in memory, and this run will still try to send them.
        #if os(macOS)
        let options: Data.WritingOptions = [.atomic]
        #else
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #endif
        do {
            try data.write(to: fileURL, options: options)
        } catch {
            log.notice("could not hold beacons for retry: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func trimmed(_ entries: [Entry]) -> [Entry] {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        let fresh = entries.filter { $0.recorded > cutoff }
        guard fresh.count > Self.capacity else { return fresh }
        return Array(fresh.suffix(Self.capacity))
    }
}
