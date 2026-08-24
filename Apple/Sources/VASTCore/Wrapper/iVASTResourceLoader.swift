//
//  iVASTResourceLoader.swift
//  VASTSDK
//

import Foundation

/// Fetches a VAST document. Lives in VASTCore rather than VASTKit because
/// wrapper resolution is pure logic that only needs "give me the XML at this
/// URL" — keeping the protocol here lets the whole chain be tested with a
/// dictionary of fixtures instead of a network.
public protocol iVASTResourceLoader: Sendable {
    /// - Throws: `VASTError.wrapperTimeout` (301) when the deadline passes.
    func loadVAST(from url: URL, timeout: TimeInterval) async throws -> String
}
