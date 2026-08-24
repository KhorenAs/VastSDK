//
//  DemoCatalog.swift
//  VASTDemo
//

import Foundation

/// The scenarios offered on the demo's first screen.
///
/// Each one exercises a different branch of the SDK, so picking through the list
/// is a manual pass over the behaviour the unit tests cover.
struct DemoScenario: Identifiable, Hashable {

    enum Source: Hashable {
        /// Fetched from an ad server, Wrapper chain and all.
        case tag(URL)
        /// A response already in hand.
        case xml(String)
    }

    let id: String
    let title: String
    let detail: String
    let source: Source
}

enum DemoCatalog {

    /// Content the viewer is "watching". Ads interrupt this and it resumes
    /// afterwards, which is what makes the snapshot/restore behaviour visible.
    static let contentStream = URL(string: """
        https://devstreaming-cdn.apple.com/videos/streaming/examples/\
        img_bipbop_adv_example_ts/master.m3u8
        """)!

    /// Stamps a live tag with a fresh `correlator` before requesting it.
    ///
    /// Google's ad server dedupes on that parameter: sent empty, the first
    /// request is filled and every one after it returns an empty VAST — which
    /// the SDK correctly reports as error 303, and which looks exactly like a
    /// bug in the SDK. IMA generates this value itself, so a host driving its
    /// own player has to do the same.
    ///
    /// Substituted textually rather than through `URLComponents`, which would
    /// re-encode `cust_params=sample_ct%3Dlinear` and change the request.
    static func requestReady(_ tag: URL) -> URL {
        let string = tag.absoluteString
        guard string.hasSuffix("correlator=") || string.contains("correlator=&") else { return tag }
        let stamp = String(UInt64(Date().timeIntervalSince1970 * 1000))
        return URL(string: string.replacingOccurrences(of: "correlator=", with: "correlator=\(stamp)")) ?? tag
    }

    static let scenarios: [DemoScenario] = [
        DemoScenario(
            id: "live-linear",
            title: "Live tag — single inline linear",
            detail: "Google's public IMA sample tag. VAST 3.0 from a real ad server.",
            source: .tag(URL(string: """
                https://pubads.g.doubleclick.net/gampad/ads\
                ?iu=/21775744923/external/single_ad_samples&sz=640x480\
                &cust_params=sample_ct%3Dlinear&ciu_szs=300x250%2C728x90\
                &gdfp_req=1&output=vast&unviewed_position_start=1&env=vp&correlator=
                """)!)
        ),
        DemoScenario(
            id: "live-skippable",
            title: "Live tag — skippable",
            detail: "Same server, skipoffset 00:00:05 — the skip control is real.",
            source: .tag(URL(string: """
                https://pubads.g.doubleclick.net/gampad/ads\
                ?iu=/21775744923/external/single_preroll_skippable&sz=640x480\
                &ciu_szs=300x250%2C728x90&gdfp_req=1&output=vast\
                &unviewed_position_start=1&env=vp&correlator=
                """)!)
        ),
        DemoScenario(
            id: "skippable",
            title: "Skippable InLine",
            detail: "52s creative, skip unlocks at 5s, 15s progress beacon.",
            source: .xml(DemoVAST.inLine(skipOffset: "00:00:05"))
        ),
        DemoScenario(
            id: "non-skippable",
            title: "Non-skippable InLine",
            detail: "52s creative, no skipoffset — the skip control never appears.",
            source: .xml(DemoVAST.inLine(skipOffset: nil))
        ),
        DemoScenario(
            id: "pod",
            title: "Ad Pod — 3 ads",
            detail: "Back to back. Skip at 2s, then 4s, then not at all.",
            source: .xml(DemoVAST.pod)
        ),
        DemoScenario(
            id: "no-fill",
            title: "No fill",
            detail: "Empty response. The session reports VAST error 303 promptly.",
            source: .xml(DemoVAST.noAd)
        ),
        DemoScenario(
            id: "bad-media",
            title: "Unplayable creative",
            detail: "MediaFile type the player cannot decode — expect error 403.",
            source: .xml(DemoVAST.unsupportedMedia)
        ),
    ]
}

// MARK: - Responses

enum DemoVAST {

    /// A public W3C sample clip, so the offline scenarios need no ad server and
    /// no hosting of our own. 854×480, 52.2s.
    static let creative = "https://media.w3.org/2010/05/sintel/trailer.mp4"

    /// `duration` matches the real creative (52.2s). Declaring something
    /// else is legal — `<Duration>` is advisory — but it makes the countdown
    /// jump the moment the player reports the true length.
    static func inLine(skipOffset: String?, id: String = "demo-1", duration: String = "00:00:52") -> String {
        let skip = skipOffset.map { #" skipoffset="\#($0)""# } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <VAST version="4.3">
          <Ad id="\(id)">
            <InLine>
              <AdSystem>VASTSDK Demo</AdSystem>
              <AdTitle>\(skipOffset == nil ? "Non-skippable" : "Skippable") demo</AdTitle>
              <Error><![CDATA[https://example.com/error?code=[ERRORCODE]]]></Error>
              <Impression><![CDATA[https://example.com/impression]]></Impression>
              <Creatives>
                <Creative id="1">
                  <Linear\(skip)>
                    <Duration>\(duration)</Duration>
                    <TrackingEvents>
                      <Tracking event="start"><![CDATA[https://example.com/start]]></Tracking>
                      <Tracking event="firstQuartile"><![CDATA[https://example.com/q1]]></Tracking>
                      <Tracking event="midpoint"><![CDATA[https://example.com/q2]]></Tracking>
                      <Tracking event="thirdQuartile"><![CDATA[https://example.com/q3]]></Tracking>
                      <Tracking event="complete"><![CDATA[https://example.com/complete]]></Tracking>
                      <Tracking event="skip"><![CDATA[https://example.com/skip]]></Tracking>
                      <Tracking event="progress" offset="00:00:15"><![CDATA[https://example.com/p15]]></Tracking>
                    </TrackingEvents>
                    <VideoClicks>
                      <ClickThrough><![CDATA[https://kinodaran.com]]></ClickThrough>
                      <ClickTracking><![CDATA[https://example.com/click]]></ClickTracking>
                    </VideoClicks>
                    <MediaFiles>
                      <MediaFile delivery="progressive" type="video/mp4" width="854" height="480" bitrate="1200">
                        <![CDATA[\(creative)]]>
                      </MediaFile>
                    </MediaFiles>
                  </Linear>
                </Creative>
              </Creatives>
              <Extensions>
                <Extension type="uiSettings"><UiHideable>1</UiHideable></Extension>
              </Extensions>
            </InLine>
          </Ad>
        </VAST>
        """
    }

    /// Three sequenced ads with deliberately different skip rules, because a pod
    /// where they all behave the same proves nothing: the point is that the
    /// control resets per creative rather than carrying over.
    ///
    /// - 1: skippable at 2s
    /// - 2: skippable at 4s — the countdown restarts rather than continuing
    /// - 3: not skippable at all — the control has to disappear again
    ///
    /// The first two unlock early on purpose, so walking the pod does not mean
    /// sitting through 52 seconds to reach the interesting part.
    static let pod: String = {
        let skipOffsets = ["00:00:02", "00:00:04", nil]
        let ads = (1...3).map { index in
            ad(id: "pod-\(index)", sequence: index, skipOffset: skipOffsets[index - 1])
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <VAST version="4.3">
        \(ads.joined(separator: "\n"))
        </VAST>
        """
    }()

    /// One `<Ad>` element, optionally sequenced into a pod.
    private static func ad(id: String, sequence: Int?, skipOffset: String?, duration: String = "00:00:52") -> String {
        let sequenceAttribute = sequence.map { #" sequence="\#($0)""# } ?? ""
        let skip = skipOffset.map { #" skipoffset="\#($0)""# } ?? ""
        return """
          <Ad id="\(id)"\(sequenceAttribute)>
            <InLine>
              <AdSystem>VASTSDK Demo</AdSystem>
              <AdTitle>\(id)</AdTitle>
              <Error><![CDATA[https://example.com/error?code=[ERRORCODE]]]></Error>
              <Impression><![CDATA[https://example.com/impression/\(id)]]></Impression>
              <Creatives><Creative><Linear\(skip)>
                <Duration>\(duration)</Duration>
                <TrackingEvents>
                  <Tracking event="start"><![CDATA[https://example.com/\(id)/start]]></Tracking>
                  <Tracking event="firstQuartile"><![CDATA[https://example.com/\(id)/q1]]></Tracking>
                  <Tracking event="midpoint"><![CDATA[https://example.com/\(id)/q2]]></Tracking>
                  <Tracking event="thirdQuartile"><![CDATA[https://example.com/\(id)/q3]]></Tracking>
                  <Tracking event="complete"><![CDATA[https://example.com/\(id)/complete]]></Tracking>
                  <Tracking event="skip"><![CDATA[https://example.com/\(id)/skip]]></Tracking>
                </TrackingEvents>
                <MediaFiles>
                  <MediaFile delivery="progressive" type="video/mp4" width="854" height="480" bitrate="1200">
                    <![CDATA[\(creative)]]>
                  </MediaFile>
                </MediaFiles>
              </Linear></Creative></Creatives>
            </InLine>
          </Ad>
        """
    }

    static let noAd = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.3">
      <Error><![CDATA[https://example.com/no-ad]]></Error>
    </VAST>
    """

    static let unsupportedMedia = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.3">
      <Ad id="bad-media">
        <InLine>
          <AdSystem>VASTSDK Demo</AdSystem>
          <Error><![CDATA[https://example.com/error?code=[ERRORCODE]]]></Error>
          <Impression><![CDATA[https://example.com/impression]]></Impression>
          <Creatives><Creative><Linear>
            <Duration>00:00:15</Duration>
            <MediaFiles>
              <MediaFile delivery="progressive" type="video/x-flv"><![CDATA[https://example.com/creative.flv]]></MediaFile>
            </MediaFiles>
          </Linear></Creative></Creatives>
        </InLine>
      </Ad>
    </VAST>
    """
}
