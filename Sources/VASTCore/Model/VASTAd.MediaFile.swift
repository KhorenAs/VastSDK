//
//  VASTAd.MediaFile.swift
//  VASTSDK
//

import Foundation

public extension VASTAd {

    struct MediaFile: Sendable, Identifiable {
        public let id: String?
        public let url: URL
        public let mimeType: String
        public let delivery: Delivery
        public let width: Int?
        public let height: Int?
        public let bitrate: Int?
        public let minBitrate: Int?
        public let maxBitrate: Int?
        public let scalable: Bool
        public let maintainAspectRatio: Bool
        public let codec: String?

        public init(
            id: String? = nil,
            url: URL,
            mimeType: String,
            delivery: Delivery = .progressive,
            width: Int? = nil,
            height: Int? = nil,
            bitrate: Int? = nil,
            minBitrate: Int? = nil,
            maxBitrate: Int? = nil,
            scalable: Bool = true,
            maintainAspectRatio: Bool = true,
            codec: String? = nil
        ) {
            self.id = id
            self.url = url
            self.mimeType = mimeType
            self.delivery = delivery
            self.width = width
            self.height = height
            self.bitrate = bitrate
            self.minBitrate = minBitrate
            self.maxBitrate = maxBitrate
            self.scalable = scalable
            self.maintainAspectRatio = maintainAspectRatio
            self.codec = codec
        }
    }

    enum Delivery: String, Sendable {
        case progressive
        case streaming
    }
}
