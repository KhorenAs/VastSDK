//
//  VASTUISettings.swift
//  VASTSDK
//

import Foundation

/// The one vendor convention this SDK interprets.
///
/// `<Extension type="uiSettings">` is nobody's standard: §3.18 leaves
/// `<Extensions>` entirely to vendors, and `VASTAd.Extension.value(of:)`
/// deliberately stops at *reading* a key rather than deciding what it means.
/// This is the single exception to that, kept in one file so the exception stays
/// countable — and surfaced only through `VASTAd.isUIHidden`.
///
/// It lives in `VASTCore` because a host depending on `VASTCore` alone — its own
/// player, its own UI — is exactly the host that most needs the answer.
///
/// Acting on it is still opt-in, through `VASTAdSession.isHiddenUi`. A response
/// must not be able to take a compliance promise away from a host that never
/// agreed to draw the ad UI itself.
enum VASTUISettings {

    static let extensionType = "uiSettings"

    /// Both spellings seen in the wild. The live AdFox tag this SDK was tested
    /// against sends `<UiHideable>`; `<UiHidden>` is the spelling used elsewhere
    /// in the same family. Reading both costs nothing, and missing the key costs
    /// a whole break drawn with the wrong UI — silently, because the response
    /// still looks fine.
    static let hiddenKeys = ["UiHidden", "UiHideable"]

    /// Whether this ad's response asks the player to draw no UI of its own.
    ///
    /// Presence is the signal, as the vendor intends: `<UiHidden/>` with no text
    /// counts. Only an explicitly negative value is read as "no", so a server
    /// that sends `0` to mean "keep your UI" is honoured rather than inverted.
    static func asksForHostDrawnUI(_ ad: VASTAd) -> Bool {
        for vendor in ad.extensions
        where vendor.type?.caseInsensitiveCompare(extensionType) == .orderedSame {
            for key in hiddenKeys {
                guard let value = vendor.value(of: key) else { continue }
                return isAffirmative(value)
            }
        }
        return false
    }

    private static func isAffirmative(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "false", "no": false
        default: true
        }
    }
}
