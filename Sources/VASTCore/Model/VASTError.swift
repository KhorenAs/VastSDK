//
//  VASTError.swift
//  VASTSDK
//

import Foundation

/// The VAST 4.3 §2.3.6.3 error table.
///
/// The raw value is what replaces the `[ERRORCODE]` macro in an `<Error>` URI.
public enum VASTError: Int, Error, Sendable, CaseIterable {

    // Document
    case xmlParsing                     = 100
    case schemaValidation               = 101
    case versionNotSupported            = 102

    // Trafficking
    case trafficking                    = 200
    case unexpectedLinearity            = 201
    case unexpectedDuration             = 202
    case unexpectedSize                 = 203
    case adCategoryMissing              = 204
    case adCategoryBlocked              = 205
    case adBreakShortened               = 206

    // Wrapper
    case wrapperGeneral                 = 300
    case wrapperTimeout                 = 301
    case wrapperLimitReached            = 302
    case noVASTResponseAfterWrappers    = 303
    case inLineTimeout                  = 304

    // Linear
    case linearGeneral                  = 400
    case mediaFileNotFound              = 401
    case mediaFileTimeout               = 402
    case noSupportedMediaFile           = 403
    case mediaFileDisplayProblem        = 405
    case mezzanineMissing               = 406
    case mezzanineDownloading           = 407
    case conditionalAdRejected          = 408
    case interactiveUnitNotExecuted     = 409
    case verificationNotExecuted        = 410
    case mezzanineBelowSpec             = 411

    // NonLinear / Companion — parsed and reported, never played by this SDK.
    case nonLinearGeneral               = 500
    case nonLinearDimensions            = 501
    case nonLinearFetchFailed           = 502
    case nonLinearUnsupportedType       = 503
    case companionGeneral               = 600
    case companionDimensions            = 601
    case companionRequiredNotShown      = 602
    case companionFetchFailed           = 603
    case companionUnsupportedType       = 604

    case undefined                      = 900
    case vpaidGeneral                   = 901
    case interactiveCreativeFile        = 902
}
