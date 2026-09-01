//
//  VASTPodSchedulerTests.swift
//  VASTCoreTests
//

import XCTest
@testable import VASTCore

final class VASTPodSchedulerTests: XCTestCase {

    private func ad(_ id: String, sequence: Int? = nil) -> VASTAd {
        VASTAd(id: id, sequence: sequence, linear: VASTAd.Linear(duration: 10))
    }

    private func drain(_ scheduler: inout VASTPodScheduler) -> [String] {
        var ids: [String] = []
        while let next = scheduler.next() { ids.append(next.id) }
        return ids
    }

    /// §3.3.1: sequenced ads play in numerical order, whatever order they appear
    /// in the document.
    func testPodPlaysInSequenceOrderNotDocumentOrder() {
        var scheduler = VASTPodScheduler(ads: [
            ad("c", sequence: 3), ad("a", sequence: 1), ad("b", sequence: 2),
        ])
        XCTAssertEqual(drain(&scheduler), ["a", "b", "c"])
        XCTAssertEqual(scheduler.totalCount, 3)
    }

    /// Non-sequenced ads are the "ad buffet" — held back, not played inline.
    func testStandAloneAdsAreNotPartOfThePod() {
        var scheduler = VASTPodScheduler(ads: [
            ad("pod-1", sequence: 1), ad("pod-2", sequence: 2), ad("spare"),
        ])
        XCTAssertEqual(scheduler.totalCount, 2)
        XCTAssertEqual(drain(&scheduler), ["pod-1", "pod-2"])
    }

    /// §3.3.1: "Should an ad in the Pod fail to play, the media player should
    /// substitute an un-played stand-alone ad from the response."
    func testFailedPodAdIsSubstitutedByAStandAloneAd() {
        var scheduler = VASTPodScheduler(ads: [
            ad("pod-1", sequence: 1), ad("pod-2", sequence: 2), ad("spare-1"), ad("spare-2"),
        ])
        _ = scheduler.next()
        XCTAssertEqual(scheduler.substituteForFailure()?.id, "spare-1")
        XCTAssertEqual(scheduler.substituteForFailure()?.id, "spare-2")
        XCTAssertNil(scheduler.substituteForFailure(), "each spare is used at most once")
    }

    /// "If stand-alone ads are unavailable, the player should move on to the
    /// next ad in the Ad Pod" — a failure must not end the break.
    func testPodContinuesWhenNoSubstituteRemains() {
        var scheduler = VASTPodScheduler(ads: [ad("pod-1", sequence: 1), ad("pod-2", sequence: 2)])
        XCTAssertEqual(scheduler.next()?.id, "pod-1")
        XCTAssertNil(scheduler.substituteForFailure())
        XCTAssertEqual(scheduler.next()?.id, "pod-2")
    }

    /// The common single-ad response has no sequence at all and must still play.
    func testSingleStandAloneResponsePlays() {
        var scheduler = VASTPodScheduler(ads: [ad("only")])
        XCTAssertEqual(scheduler.totalCount, 1)
        XCTAssertEqual(drain(&scheduler), ["only"])
    }

    func testEmptyResponseYieldsNothing() {
        var scheduler = VASTPodScheduler(ads: [])
        XCTAssertEqual(scheduler.totalCount, 0)
        XCTAssertNil(scheduler.next())
    }
}

// MARK: - Counting

/// What "Ad n of m" actually means, since the two numbers come from different
/// places: `m` is the size of the pod, and `n` is a slot in it rather than a
/// count of ads shown.
extension VASTPodSchedulerTests {

    /// §3.3.1: ads with no `sequence` are "an ad buffet from which the player may
    /// select one or more ad to play in any order" — alternatives, not a running
    /// order. Playing one of three offers is right; playing all three would show
    /// three ads where the server offered three choices.
    func testResponseOfOnlyStandAloneAdsPlaysOneOfThem() {
        var scheduler = VASTPodScheduler(ads: [ad("a"), ad("b"), ad("c")])

        XCTAssertEqual(scheduler.totalCount, 1, "a buffet is one slot, not three")
        XCTAssertEqual(drain(&scheduler), ["a"])
    }

    /// The remaining stand-alone ads stay available as substitutes rather than
    /// being discarded.
    func testUnplayedStandAloneAdsRemainAvailableAsSubstitutes() {
        var scheduler = VASTPodScheduler(ads: [ad("a"), ad("b"), ad("c")])
        _ = scheduler.next()

        XCTAssertEqual(scheduler.substituteForFailure()?.id, "b")
        XCTAssertEqual(scheduler.substituteForFailure()?.id, "c")
    }

    /// A substitute fills the slot the failed ad occupied, so the position the
    /// viewer is shown does not advance for it.
    func testSubstituteBelongsToTheSamePodSlot() {
        var scheduler = VASTPodScheduler(ads: [
            ad("pod-1", sequence: 1), ad("pod-2", sequence: 2), ad("spare"),
        ])

        XCTAssertEqual(scheduler.totalCount, 2)
        XCTAssertEqual(scheduler.next()?.id, "pod-1")
        XCTAssertEqual(scheduler.currentIndex, 1, "one slot consumed")
        XCTAssertEqual(scheduler.substituteForFailure()?.id, "spare")
        XCTAssertEqual(scheduler.currentIndex, 1, "a substitute does not consume a new slot")
    }

    // MARK: - Looking ahead

    /// Looking at what is next must be free. Consuming the entry to see it would
    /// play the pod in the wrong order, which is how the warming this exists for
    /// would have been paid for.
    func testPeekDoesNotConsumeTheEntry() {
        var scheduler = VASTPodScheduler(ads: [
            ad("first", sequence: 1),
            ad("second", sequence: 2),
        ])

        XCTAssertEqual(scheduler.peek()?.id, "first")
        XCTAssertEqual(scheduler.peek()?.id, "first", "looking twice changed what is next")
        XCTAssertEqual(scheduler.next()?.id, "first")
        XCTAssertEqual(scheduler.peek()?.id, "second")
    }

    func testPeekIsEmptyOnceThePodIsSpent() {
        var scheduler = VASTPodScheduler(ads: [ad("only", sequence: 1)])
        _ = scheduler.next()
        XCTAssertNil(scheduler.peek())
    }
}
