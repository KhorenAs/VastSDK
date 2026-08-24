//
//  VASTParser.swift
//  VASTSDK
//

import Foundation

/// Turns VAST XML into a `VASTDocument`.
///
/// Deliberately version-tolerant. Real ad servers still emit VAST 2.0 and 3.0,
/// 4.x adds elements this SDK does not play, and almost every server has its own
/// idea of how to write a URI — bare text, CDATA, or CDATA padded with newlines.
/// Unknown elements are skipped rather than rejected; only XML that will not
/// parse at all raises `.xmlParsing` (100).
public struct VASTParser: Sendable {

    public init() {}

    /// - Throws: `VASTError.xmlParsing` (100) when the XML is malformed.
    public func parse(_ xml: String) throws -> VASTDocument {
        guard let data = xml.data(using: .utf8) else { throw VASTError.xmlParsing }
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { throw VASTError.xmlParsing }
        // A VAST 1.0 document is well-formed XML under a different root element.
        // Reporting it as a parse error would tell the ad server the wrong thing,
        // so it gets the code the spec reserves for it.
        if builder.sawUnsupportedRoot { throw VASTError.versionNotSupported }
        guard let document = builder.document else { throw VASTError.xmlParsing }
        return document
    }
}

// MARK: - Builder

private final class Builder: NSObject, XMLParserDelegate {

    var document: VASTDocument?
    /// Set when the root element is not `<VAST>` — i.e. a pre-3.0 document.
    var sawUnsupportedRoot = false

    private var version = ""
    private var entries: [VASTDocument.Entry] = []
    private var rootError: URL?

    private var path: [String] = []
    private var text = ""

    // Current <Ad>
    private var adID = ""
    private var adSequence: Int?
    private var isWrapper = false

    private var impressions: [URL] = []
    private var errors: [URL] = []
    private var tagURI: URL?
    private var adSystem: String?
    private var adTitle: String?
    private var followAdditionalWrappers = true
    private var allowMultipleAds = false
    private var fallbackOnNoAd: Bool?

    // Current <Linear>
    private var duration: TimeInterval = 0
    private var skipOffset: VASTAd.SkipOffset?
    private var mediaFiles: [VASTAd.MediaFile] = []
    private var clickThrough: URL?
    private var clickTracking: [URL] = []
    private var tracking: [VASTAd.TrackingEvent: [URL]] = [:]
    private var progress: [VASTAd.ProgressEvent] = []

    private var pendingTrackingEvent: String?
    private var pendingTrackingOffset: String?
    private var pendingMediaFile: [String: String] = [:]

    /// Set by `<NonLinearAds>` or `<CompanionAds>`: creatives this SDK ignores,
    /// but whose presence distinguishes "not playable here" from "no fill".
    private var sawUnplayableCreative = false

    // Current <AdVerifications>
    //
    // VAST 4 puts these under <InLine>/<Wrapper>; VAST 3 had no element for them
    // and vendors shipped the same content inside <Extension type="AdVerifications">.
    // Both shapes land in the same list — a host should not have to know which
    // version the server speaks.
    private var verifications: [VASTAd.Verification] = []
    /// Inside `<AdVerifications>` — or the VAST 3 extension standing in for it.
    private var insideVerifications = false
    /// True while the extension currently open is that VAST 3 stand-in, so its
    /// `</Extension>` closes the verification scope rather than a raw capture.
    private var extensionIsVerifications = false
    private var verificationVendor: String?
    private var verificationResources: [VASTAd.Verification.Resource] = []
    private var verificationParameters: String?
    private var verificationNotExecuted: [URL] = []
    private var pendingResource: [String: String] = [:]

    // Raw <Extension> capture
    private var extensions: [VASTAd.Extension] = []
    private var extensionDepth = 0
    private var extensionType: String?
    private var extensionXML = ""

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement element: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        // Everything under <Extension> is copied verbatim: the SDK never
        // interprets vendor XML, it just hands it to the host (§3.18).
        if extensionDepth > 0 {
            extensionXML += "<\(element)\(Self.attributeString(attributes))>"
            extensionDepth += 1
            path.append(element)
            return
        }

        if path.isEmpty, element != "VAST" {
            sawUnsupportedRoot = true
        }

        path.append(element)
        text = ""

        switch element {
        case "VAST":
            version = attributes["version"] ?? ""

        case "Ad":
            resetAd()
            adID = attributes["id"] ?? ""
            adSequence = attributes["sequence"].flatMap(Int.init)

        case "Wrapper":
            isWrapper = true
            followAdditionalWrappers = Self.bool(attributes["followAdditionalWrappers"], default: true)
            allowMultipleAds = Self.bool(attributes["allowMultipleAds"], default: false)
            fallbackOnNoAd = attributes["fallbackOnNoAd"].map { Self.bool($0, default: false) }

        case "Linear":
            skipOffset = attributes["skipoffset"].flatMap(Self.offset)

        case "Tracking":
            pendingTrackingEvent = attributes["event"]
            pendingTrackingOffset = attributes["offset"]

        case "MediaFile":
            pendingMediaFile = attributes

        case "AdVerifications":
            insideVerifications = true

        case "Verification":
            verificationVendor = attributes["vendor"]
            verificationResources = []
            verificationParameters = nil
            verificationNotExecuted = []
            // A Verification outside <AdVerifications> is the VAST 3 shape with
            // the wrapper element omitted; treat the scope as open either way.
            insideVerifications = true

        case "JavaScriptResource", "ExecutableResource":
            pendingResource = attributes

        case "Extension":
            // The VAST 3 stand-in is parsed, not captured raw: a host asking for
            // `adVerifications` should get them whatever the server speaks, and
            // returning the same content twice would invite double-reporting.
            if attributes["type"]?.lowercased() == "adverifications" {
                extensionIsVerifications = true
                insideVerifications = true
                return
            }
            extensionDepth = 1
            extensionType = attributes["type"]
            extensionXML = ""

        // Not parsed — but seeing one changes what an ad with no Linear means:
        // the server filled the slot, just not with something playable here.
        case "NonLinearAds", "CompanionAds":
            sawUnplayableCreative = true

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if extensionDepth > 0 {
            extensionXML += string
        } else {
            text += string
        }
    }

    /// CDATA arrives here rather than in `foundCharacters`. Ad servers wrap URIs
    /// inconsistently, so both paths feed the same buffer and are trimmed later.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        if extensionDepth > 0 {
            extensionXML += "<![CDATA[\(string)]]>"
        } else {
            text += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement element: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        defer { if !path.isEmpty { path.removeLast() } }

        if extensionDepth > 0 {
            extensionDepth -= 1
            if extensionDepth == 0 {
                extensions.append(.init(type: extensionType, xml: extensionXML))
                extensionType = nil
                extensionXML = ""
            } else {
                extensionXML += "</\(element)>"
            }
            return
        }

        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""

        switch element {
        case "AdSystem":
            adSystem = value

        case "AdTitle":
            adTitle = value

        case "Impression":
            append(value, to: &impressions)

        case "Error":
            // A root-level <Error> with no <Ad> is the "no ad" response (§2.3.6.4).
            if path.count <= 2 {
                rootError = Self.url(value)
            } else {
                append(value, to: &errors)
            }

        case "VASTAdTagURI":
            // May be relative (real responses do this). Resolution against the
            // document's own base URL belongs to the loader, which is the only
            // layer that knows where this XML was fetched from.
            tagURI = Self.url(value)

        case "Duration":
            duration = Self.seconds(value) ?? 0

        case "ClickThrough":
            clickThrough = Self.url(value)

        case "ClickTracking":
            append(value, to: &clickTracking)

        case "MediaFile":
            appendMediaFile(url: value)

        case "Tracking":
            // `<TrackingEvents>` appears under both `<Linear>` and
            // `<Verification>`. Without the scope, a verification's tracker would
            // be filed as a creative event — and since `verificationNotExecuted`
            // is not one, it would vanish instead.
            if insideVerifications {
                appendVerificationTracking(url: value)
            } else {
                appendTracking(url: value)
            }

        case "JavaScriptResource":
            appendVerificationResource(kind: .javaScript, url: value)

        case "ExecutableResource":
            appendVerificationResource(kind: .executable, url: value)

        case "VerificationParameters":
            verificationParameters = value.isEmpty ? nil : value

        case "Verification":
            finishVerification()

        case "AdVerifications":
            insideVerifications = false

        case "Extension":
            // Only reached for the VAST 3 stand-in; a raw-captured extension is
            // closed by the depth branch above and never falls through to here.
            if extensionIsVerifications {
                extensionIsVerifications = false
                insideVerifications = false
            }

        case "Linear", "Creative", "Creatives", "InLine", "TrackingEvents",
             "VideoClicks", "MediaFiles", "Extensions":
            break

        case "Ad":
            finishAd()

        case "VAST":
            document = VASTDocument(version: version, entries: entries, noAdError: rootError)

        default:
            break
        }
    }

    // MARK: - Assembly

    private func appendTracking(url value: String) {
        guard let name = pendingTrackingEvent, let url = Self.url(value) else { return }
        defer { pendingTrackingEvent = nil; pendingTrackingOffset = nil }

        // `progress` carries an offset and drives skippable-ad billing, so it is
        // modelled separately from the fixed quartiles (§3.14.1).
        if name == "progress" {
            guard let offset = pendingTrackingOffset.flatMap(Self.offset) else { return }
            progress.append(.init(offset: offset, url: url))
            return
        }
        guard let event = VASTAd.TrackingEvent(rawValue: name) else { return }
        tracking[event, default: []].append(url)
    }

    private func appendMediaFile(url value: String) {
        let attributes = pendingMediaFile
        pendingMediaFile = [:]
        guard let url = Self.url(value) else { return }
        mediaFiles.append(VASTAd.MediaFile(
            id: attributes["id"],
            url: url,
            mimeType: attributes["type"] ?? "",
            delivery: VASTAd.Delivery(rawValue: attributes["delivery"] ?? "") ?? .progressive,
            width: attributes["width"].flatMap(Int.init),
            height: attributes["height"].flatMap(Int.init),
            bitrate: attributes["bitrate"].flatMap(Int.init),
            minBitrate: attributes["minBitrate"].flatMap(Int.init),
            maxBitrate: attributes["maxBitrate"].flatMap(Int.init),
            scalable: Self.bool(attributes["scalable"], default: true),
            maintainAspectRatio: Self.bool(attributes["maintainAspectRatio"], default: true),
            codec: attributes["codec"]
        ))
    }

    private func appendVerificationResource(kind: VASTAd.Verification.Resource.Kind, url value: String) {
        let attributes = pendingResource
        pendingResource = [:]
        guard insideVerifications, let url = Self.url(value) else { return }
        verificationResources.append(VASTAd.Verification.Resource(
            kind: kind,
            url: url,
            apiFramework: attributes["apiFramework"],
            browserOptional: Self.bool(attributes["browserOptional"], default: false),
            type: attributes["type"]
        ))
    }

    /// The only tracker a `<Verification>` may carry (§3.16).
    private func appendVerificationTracking(url value: String) {
        let event = pendingTrackingEvent
        defer { pendingTrackingEvent = nil; pendingTrackingOffset = nil }
        guard event == "verificationNotExecuted", let url = Self.url(value) else { return }
        verificationNotExecuted.append(url)
    }

    /// A `<Verification>` with no resource at all asks for nothing and is dropped;
    /// one with only an unusable resource is kept, because the vendor still
    /// expects to hear why it did not run.
    private func finishVerification() {
        defer {
            verificationVendor = nil
            verificationResources = []
            verificationParameters = nil
            verificationNotExecuted = []
        }
        guard !verificationResources.isEmpty else { return }
        verifications.append(VASTAd.Verification(
            vendor: verificationVendor,
            resources: verificationResources,
            parameters: verificationParameters,
            notExecutedTrackers: verificationNotExecuted
        ))
    }

    private func finishAd() {
        let entry: VASTDocument.Entry

        if isWrapper {
            guard let tagURI else { resetAd(); return }
            entry = VASTDocument.Entry(id: adID, sequence: adSequence, body: .wrapper(
                VASTDocument.Wrapper(
                    tagURI: tagURI,
                    impressions: impressions,
                    errors: errors,
                    trackingEvents: tracking,
                    clickTracking: clickTracking,
                    clickThrough: clickThrough,
                    extensions: extensions,
                    verifications: verifications,
                    followAdditionalWrappers: followAdditionalWrappers,
                    allowMultipleAds: allowMultipleAds,
                    fallbackOnNoAd: fallbackOnNoAd
                )
            ))
        } else {
            // An InLine with no playable Linear is not an ad. If it offered a
            // NonLinear or Companion creative the slot was filled — the response
            // is simply the wrong linearity, and §2.3.6 reserves 201 for that.
            // Dropping it silently reported "no fill" and threw away the
            // `<Error>` URI the server expected to hear on.
            guard !mediaFiles.isEmpty || duration > 0 else {
                if sawUnplayableCreative {
                    entries.append(.init(id: adID, sequence: adSequence, body: .unplayableCreative(errors: errors)))
                }
                resetAd()
                return
            }
            entry = VASTDocument.Entry(id: adID, sequence: adSequence, body: .inLine(
                VASTAd(
                    id: adID,
                    sequence: adSequence,
                    adSystem: adSystem,
                    title: adTitle,
                    linear: VASTAd.Linear(
                        duration: duration,
                        skipOffset: skipOffset,
                        mediaFiles: mediaFiles,
                        clickThrough: clickThrough,
                        clickTracking: clickTracking,
                        trackingEvents: tracking,
                        progressEvents: progress
                    ),
                    impressions: impressions,
                    errors: errors,
                    extensions: extensions,
                    adVerifications: verifications
                )
            ))
        }

        entries.append(entry)
        resetAd()
    }

    private func resetAd() {
        adID = ""; adSequence = nil; isWrapper = false
        impressions = []; errors = []; tagURI = nil
        adSystem = nil; adTitle = nil
        followAdditionalWrappers = true; allowMultipleAds = false; fallbackOnNoAd = nil
        duration = 0; skipOffset = nil; mediaFiles = []
        clickThrough = nil; clickTracking = []; tracking = [:]; progress = []
        extensions = []; sawUnplayableCreative = false
        verifications = []; insideVerifications = false; extensionIsVerifications = false
        verificationVendor = nil; verificationResources = []
        verificationParameters = nil; verificationNotExecuted = []; pendingResource = [:]
    }

    private func append(_ value: String, to list: inout [URL]) {
        guard let url = Self.url(value) else { return }
        list.append(url)
    }

    // MARK: - Scalars

    private static func url(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    /// VAST booleans appear as `true`/`false` and as `1`/`0`, interchangeably.
    private static func bool(_ value: String?, default fallback: Bool) -> Bool {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1": true
        case "false", "0": false
        default: fallback
        }
    }

    /// `HH:MM:SS` or `HH:MM:SS.mmm`.
    private static func seconds(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// A `skipoffset` or `progress` offset: a timestamp or a percentage.
    private static func offset(_ value: String) -> VASTAd.SkipOffset? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%"), let percent = Double(trimmed.dropLast()) {
            return .percent(percent)
        }
        return seconds(trimmed).map { .time($0) }
    }

    private static func attributeString(_ attributes: [String: String]) -> String {
        attributes
            .sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\($0.value)\"" }
            .joined()
    }
}
