//
//  VASTMediaFileSelector.swift
//  VASTSDK
//

import Foundation

/// Picks the `<MediaFile>` best suited to the current device.
///
/// Selection is a ranking rather than a filter wherever the spec allows it: an
/// ad with only one media file should still play even if its resolution or
/// bitrate is a poor fit, because a no-fill costs the advertiser a delivery
/// while a slightly-too-large file costs a little bandwidth.
public struct VASTMediaFileSelector: Sendable {

    public struct Capabilities: Sendable {
        /// Container types the player can decode. Files outside this set are
        /// rejected outright — playing them would produce error 403 anyway.
        public var supportedMIMETypes: Set<String>
        public var width: Int
        public var height: Int
        /// Soft ceiling in kbps. Higher-bitrate files rank lower but stay eligible.
        public var preferredBitrate: Int?
        /// `false` on platforms without an HLS-capable pipeline.
        public var supportsStreaming: Bool

        public init(
            supportedMIMETypes: Set<String> = Capabilities.appleDefaults,
            width: Int,
            height: Int,
            preferredBitrate: Int? = nil,
            supportsStreaming: Bool = true
        ) {
            self.supportedMIMETypes = supportedMIMETypes
            self.width = width
            self.height = height
            self.preferredBitrate = preferredBitrate
            self.supportsStreaming = supportsStreaming
        }

        /// What AVFoundation will play without extra work.
        public static let appleDefaults: Set<String> = [
            "video/mp4", "video/quicktime", "video/x-m4v", "video/3gpp",
            "application/x-mpegurl", "application/vnd.apple.mpegurl",
        ]
    }

    public init() {}

    /// - Throws: `VASTError.noSupportedMediaFile` (403) when nothing is playable.
    public func select(
        from files: [VASTAd.MediaFile],
        capabilities: Capabilities
    ) throws -> VASTAd.MediaFile {
        let eligible = files.filter { playable($0, capabilities) }
        guard !eligible.isEmpty else { throw VASTError.noSupportedMediaFile }

        return eligible.min { left, right in
            cost(left, capabilities) < cost(right, capabilities)
        } ?? eligible[0]
    }

    private func playable(_ file: VASTAd.MediaFile, _ capabilities: Capabilities) -> Bool {
        let type = file.mimeType.lowercased()
        guard capabilities.supportedMIMETypes.contains(type) else { return false }
        if file.delivery == .streaming, !capabilities.supportsStreaming { return false }
        return true
    }

    /// Lower is better. Resolution dominates because upscaling a small creative
    /// is the most visible defect; bitrate breaks ties.
    private func cost(_ file: VASTAd.MediaFile, _ capabilities: Capabilities) -> Double {
        var score = 0.0

        if let width = file.width, let height = file.height, width > 0, height > 0 {
            let widthRatio = Double(width) / Double(max(capabilities.width, 1))
            let heightRatio = Double(height) / Double(max(capabilities.height, 1))
            let ratio = max(widthRatio, heightRatio)
            // Being too small is penalised roughly twice as hard as being too
            // large, since the player can downscale cleanly but not invent detail.
            score += ratio >= 1 ? (ratio - 1) : (1 - ratio) * 2
        } else {
            // Undeclared dimensions are common and are not disqualifying, but a
            // file that states its size is a safer pick when one exists.
            score += 0.5
        }

        if let ceiling = capabilities.preferredBitrate, let bitrate = effectiveBitrate(file) {
            let ratio = Double(bitrate) / Double(max(ceiling, 1))
            score += ratio > 1 ? (ratio - 1) : 0
        }
        return score
    }

    /// VAST 4 lets a file declare a range instead of a single bitrate.
    private func effectiveBitrate(_ file: VASTAd.MediaFile) -> Int? {
        if let bitrate = file.bitrate { return bitrate }
        guard let minimum = file.minBitrate, let maximum = file.maxBitrate else {
            return file.minBitrate ?? file.maxBitrate
        }
        return (minimum + maximum) / 2
    }
}
