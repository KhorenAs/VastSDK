//
//  VASTMacroExpander.swift
//  VASTSDK
//

import Foundation

/// Substitutes VAST 4.3 §6 macros into a tracking URI.
///
/// Three rules from the spec drive the whole implementation:
///
/// - A macro is its name *including* the brackets, and the whole thing is
///   replaced: `?e=[ERRORCODE]` becomes `?e=403`, not `?e=[403]`.
/// - `encodeURIComponent` is applied to each **value**, not to the finished
///   string — so a comma separating two array values stays a comma while a comma
///   inside one value does not.
/// - A macro the spec defines but this player does not supply becomes `-1`
///   (unknown) or `-2` (known but withheld). A macro the spec does *not* define
///   is left exactly as it was: "do not replace all unknown macros with -1".
public struct VASTMacroExpander: Sendable {

    /// What this player can tell the ad server about the moment being reported.
    ///
    /// Every field is optional because honesty is the point: a value left `nil`
    /// is reported as unknown rather than guessed at.
    public struct Context: Sendable {

        public var errorCode: VASTError?
        /// Why a verification vendor's code did not run, for `[REASON]` on a
        /// `verificationNotExecuted` tracker (§3.16). Unset on every other beacon.
        public var verificationNotExecutedReason: VASTAd.Verification.NotExecutedReason?
        /// Playhead within the ad creative.
        public var adPlayhead: TimeInterval?
        /// Playhead within the content the ad interrupted.
        public var contentPlayhead: TimeInterval?
        public var assetURI: URL?
        /// Defaults to the moment of expansion when `nil`.
        public var timestamp: Date?
        /// Pinned in tests; a fresh random value otherwise.
        public var cacheBuster: String?
        public var playerSize: (width: Int, height: Int)?
        public var isMuted: Bool?
        public var isFullscreen: Bool?
        public var appBundle: String?
        /// Vendors named in the ad's `<AdVerifications>`. Reported as unknown
        /// while empty, which is the difference between "nobody asked" and
        /// "somebody asked and we are not saying".
        public var verificationVendors: [String]
        /// The OMID partner name and version, when a measurement integration is
        /// present to have one.
        public var omidPartner: String?
        /// Vendor macros this SDK knows nothing about, supplied by the host.
        public var custom: [String: String]
        /// Everything only the host can answer — identifier, consent, where the
        /// break sits. Unset values report `-1`, which is what §6 means by
        /// "unknown" and an honest thing to say.
        public var host: VASTMacroValues
        /// The MIME type of the creative being played, for `[MEDIAMIME]`.
        public var mediaMIMEType: String?
        /// `[TRANSACTIONID]` — one value for one break, so an ad server can tie
        /// this request's beacons together.
        public var transactionID: String?
        /// Whether something will execute the ad's verification code, which is
        /// what `[APIFRAMEWORKS]` is being asked about.
        public var executesOMID: Bool

        public init(
            errorCode: VASTError? = nil,
            verificationNotExecutedReason: VASTAd.Verification.NotExecutedReason? = nil,
            adPlayhead: TimeInterval? = nil,
            contentPlayhead: TimeInterval? = nil,
            assetURI: URL? = nil,
            timestamp: Date? = nil,
            cacheBuster: String? = nil,
            playerSize: (width: Int, height: Int)? = nil,
            isMuted: Bool? = nil,
            isFullscreen: Bool? = nil,
            appBundle: String? = nil,
            verificationVendors: [String] = [],
            omidPartner: String? = nil,
            custom: [String: String] = [:],
            host: VASTMacroValues = VASTMacroValues(),
            mediaMIMEType: String? = nil,
            transactionID: String? = nil,
            executesOMID: Bool = false
        ) {
            self.errorCode = errorCode
            self.verificationNotExecutedReason = verificationNotExecutedReason
            self.adPlayhead = adPlayhead
            self.contentPlayhead = contentPlayhead
            self.assetURI = assetURI
            self.timestamp = timestamp
            self.cacheBuster = cacheBuster
            self.playerSize = playerSize
            self.isMuted = isMuted
            self.isFullscreen = isFullscreen
            self.appBundle = appBundle
            self.verificationVendors = verificationVendors
            self.omidPartner = omidPartner
            self.custom = custom
            self.host = host
            self.mediaMIMEType = mediaMIMEType
            self.transactionID = transactionID
            self.executesOMID = executesOMID
        }
    }

    /// Macros §6 defines. Only these become `-1` when unsupplied; anything else
    /// is somebody's vendor extension and is none of our business.
    static let specDefined: Set<String> = [
        "ERRORCODE", "ADPLAYHEAD", "MEDIAPLAYHEAD", "CONTENTPLAYHEAD",
        "ASSETURI", "TIMESTAMP", "CACHEBUSTING", "PLAYERSTATE",
        "PLAYERSIZE", "PLAYERCAPABILITIES", "APPBUNDLE", "DOMAIN",
        "PAGEURL", "IFA", "IFATYPE", "CLIENTUA", "DEVICEUA", "DEVICEIP",
        "SERVERSIDE", "ADTYPE", "ADCATEGORIES", "BREAKPOSITION",
        "BLOCKEDADCATEGORIES", "CLICKTYPE", "GDPRCONSENT", "LIMITADTRACKING",
        "REGULATIONS", "TRANSACTIONID", "PLACEMENTTYPE", "INVENTORYSTATE",
        "CONTENTID", "CONTENTURI", "MEDIAMIME", "OMIDPARTNER", "VASTVERSIONS",
        "APIFRAMEWORKS", "EXTENSIONS", "VERIFICATIONVENDORS", "REASON",
    ]

    /// The VAST versions the parser accepts, for `[VASTVERSIONS]`.
    ///
    /// A list rather than one number: the parser is deliberately version-tolerant,
    /// and an ad server that knows it may send VAST 2 will send its VAST 2.
    static let supportedVASTVersions = "2,3,4,4.1,4.2,4.3"

    /// Reported for a macro the spec defines but this player does not know.
    static let unknownValue = "-1"
    /// Reported for a value that is known but must not be shared.
    public static let withheldValue = "-2"

    public init() {}

    public func expand(_ url: URL, with context: Context) -> URL {
        var expanded = expand(url.absoluteString, with: context)

        // Any bracket still standing belongs to a macro this player left alone —
        // a vendor's own. Brackets are not legal in a query, so handing the string
        // to `URL(string:)` like this makes Foundation "repair" it by encoding the
        // whole thing, which turns the `%3A` in a value already encoded correctly
        // into `%253A`. Re-encoding just the brackets keeps the string valid and
        // leaves every other escape exactly as it was.
        expanded = expanded
            .replacingOccurrences(of: "[", with: "%5B")
            .replacingOccurrences(of: "]", with: "%5D")

        return URL(string: expanded) ?? url
    }

    /// String form, so a caller holding a template rather than a `URL` — and the
    /// tests — can use the same code path.
    public func expand(_ string: String, with context: Context) -> String {
        var result = ""
        var remainder = Substring(Self.normalisingEncodedBrackets(string))

        while let open = remainder.firstIndex(of: "[") {
            result += remainder[remainder.startIndex..<open]
            let afterOpen = remainder.index(after: open)

            guard let close = remainder[afterOpen...].firstIndex(of: "]") else {
                // An unbalanced bracket is just text.
                result += remainder[open...]
                return result
            }

            let name = String(remainder[afterOpen..<close])
            result += replacement(for: name, context: context)
                ?? String(remainder[open...close])
            remainder = remainder[remainder.index(after: close)...]
        }

        return result + remainder
    }

    /// Restores brackets that became `%5B`/`%5D`.
    ///
    /// `URL(string:)` percent-encodes brackets, so a macro survives being parsed
    /// out of a VAST document only to arrive here as `%5BERRORCODE%5D`. Scanning
    /// for `[` alone found nothing, and every macro would have gone out
    /// unexpanded — silently, because the URI still looked plausible.
    ///
    /// Only bracket pairs wrapping a macro-shaped name are touched, so an encoded
    /// bracket that is genuinely part of a value is left as it is.
    static func normalisingEncodedBrackets(_ string: String) -> String {
        guard string.localizedCaseInsensitiveContains("%5B") else { return string }
        let pattern = try? NSRegularExpression(
            pattern: "%5B([A-Za-z0-9_]+)%5D",
            options: .caseInsensitive
        )
        guard let pattern else { return string }
        return pattern.stringByReplacingMatches(
            in: string,
            range: NSRange(string.startIndex..., in: string),
            withTemplate: "[$1]"
        )
    }

    // MARK: - Values

    /// `nil` means "leave the macro alone" — it is not one the spec defines.
    private func replacement(for name: String, context: Context) -> String? {
        if let value = context.custom[name] {
            return Self.encode(value)
        }

        switch name {
        case "ERRORCODE":
            return context.errorCode.map { String($0.rawValue) } ?? Self.unknownValue

        case "REASON":
            return context.verificationNotExecutedReason.map { String($0.rawValue) } ?? Self.unknownValue

        case "VERIFICATIONVENDORS":
            guard !context.verificationVendors.isEmpty else { return Self.unknownValue }
            return Self.encode(context.verificationVendors.joined(separator: ","))

        case "OMIDPARTNER":
            return context.omidPartner.map(Self.encode) ?? Self.unknownValue

        case "ADPLAYHEAD", "MEDIAPLAYHEAD":
            // MEDIAPLAYHEAD is the pre-4.1 spelling of the same value.
            return context.adPlayhead.map { Self.encode(Self.timecode($0)) } ?? Self.unknownValue

        case "CONTENTPLAYHEAD":
            return context.contentPlayhead.map { Self.encode(Self.timecode($0)) } ?? Self.unknownValue

        case "ASSETURI":
            return context.assetURI.map { Self.encode($0.absoluteString) } ?? Self.unknownValue

        case "TIMESTAMP":
            return Self.encode(Self.iso8601(context.timestamp ?? Date()))

        case "CACHEBUSTING":
            // Always answerable, and the whole point is that it differs per request.
            return context.cacheBuster ?? Self.randomCacheBuster()

        case "PLAYERSTATE":
            return Self.encode(Self.playerState(context))

        case "PLAYERSIZE":
            guard let size = context.playerSize else { return Self.unknownValue }
            // An array macro: values are comma separated and the comma is not encoded.
            return "\(size.width),\(size.height)"

        case "APPBUNDLE":
            return context.appBundle.map(Self.encode) ?? Self.unknownValue

        // MARK: Host-supplied

        case "IFA":
            return context.host.identifierForAdvertising.map(Self.encode) ?? Self.unknownValue

        case "IFATYPE":
            return context.host.identifierType.map(Self.encode) ?? Self.unknownValue

        case "LIMITADTRACKING":
            // Reported as the spec's booleans, and only when it is known: `false`
            // and "nobody asked" are different facts about a viewer.
            return context.host.limitsAdTracking.map { $0 ? "1" : "0" } ?? Self.unknownValue

        case "GDPRCONSENT":
            // Already base64url by the time a CMP produces it, so encoding it
            // again would corrupt it.
            return context.host.gdprConsent ?? Self.unknownValue

        case "REGULATIONS":
            return context.host.regulations.map(Self.encode) ?? Self.unknownValue

        case "DEVICEUA":
            return context.host.deviceUserAgent.map(Self.encode) ?? Self.unknownValue

        case "PLACEMENTTYPE":
            return context.host.placementType.map(String.init) ?? Self.unknownValue

        case "BREAKPOSITION":
            return context.host.breakPosition.map(String.init) ?? Self.unknownValue

        case "CONTENTID":
            return context.host.contentID.map(Self.encode) ?? Self.unknownValue

        case "CONTENTURI":
            return context.host.contentURI.map { Self.encode($0.absoluteString) } ?? Self.unknownValue

        // MARK: Answerable by the SDK itself

        case "MEDIAMIME":
            return context.mediaMIMEType.map(Self.encode) ?? Self.unknownValue

        case "TRANSACTIONID":
            return context.transactionID.map(Self.encode) ?? Self.unknownValue

        case "SERVERSIDE":
            // 0 is "the client made this request", which is always true here:
            // there is no server-side stitching in this SDK to be unsure about.
            return "0"

        case "ADTYPE":
            // The only creative this SDK plays is a Linear video.
            return "video"

        case "CLIENTUA":
            // The spec's `name/version` form, naming the SDK rather than the app:
            // the app is `[APPBUNDLE]`, and conflating the two loses both.
            return Self.encode("VASTSDK/\(VASTVersion.current)")

        case "VASTVERSIONS":
            // What the parser accepts, not what this document happens to be.
            return Self.supportedVASTVersions

        case "APIFRAMEWORKS":
            // 7 is OMID-1 in AdCOM's list, and it is only true when something is
            // actually there to execute a vendor's code. Claiming it otherwise
            // would tell a verification vendor to expect a session that never
            // starts.
            return context.executesOMID ? "7" : Self.unknownValue

        default:
            // Defined by the spec but not supplied: report unknown. Not defined by
            // the spec: leave it for whoever put it there.
            return Self.specDefined.contains(name) ? Self.unknownValue : nil
        }
    }

    /// `PLAYERSTATE` is an array of flags; an empty state is still an answer.
    private static func playerState(_ context: Context) -> String {
        var flags: [String] = []
        if context.isMuted == true { flags.append("muted") }
        if context.isFullscreen == true { flags.append("fullscreen") }
        return flags.joined(separator: ",")
    }

    // MARK: - Formatting

    /// `HH:MM:SS.mmm`, the form §6 specifies for playhead values.
    static func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00:00.000" }
        let total = Int(seconds)
        let milliseconds = Int((seconds - Double(total)) * 1000)
        return String(
            format: "%02d:%02d:%02d.%03d",
            total / 3600, (total % 3600) / 60, total % 60, milliseconds
        )
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func randomCacheBuster() -> String {
        String(format: "%08d", Int.random(in: 0..<100_000_000))
    }

    /// Percent-encodes one value. Applied per value rather than to the finished
    /// URI, which is what keeps array separators intact.
    static func encode(_ value: String) -> String {
        // `urlQueryAllowed` leaves `&`, `=`, `+` and `?` alone, which would break
        // the query a value is being placed into.
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
