import Testing
import Foundation
@testable import AetherEngine

extension EpochAxis {
    /// The geometry every AE#418, AE#448 and AE#481 arm was measured on: a source whose timestamps
    /// start at zero, where what an epoch's first segment SHOWS against its advertised start and what
    /// its bytes CARRY are the same number, so nothing separated them for nine rounds.
    ///
    /// Measured on `tc-cues-lie.mkv`, resuming at 53 s:
    /// `actual=43000 desired=52000 pinnedTo=43000 shift=0 presentedShift=-9000`.
    static func zeroOrigin(_ presented: Double, isRecut: Bool = false) -> EpochAxis {
        return EpochAxis(presented: presented, carried: 0, isRecut: isRecut)
    }

    /// The same session on the same bytes remuxed with `-output_ts_offset 600`:
    /// `actual=643000 desired=52000 pinnedTo=43000 shift=600000 presentedShift=591000`.
    /// One gate, one backoff of 9 s, and two numbers 600 s apart.
    static func originAt600(_ presented: Double, isRecut: Bool = false) -> EpochAxis {
        return EpochAxis(presented: presented, carried: 600, isRecut: isRecut)
    }
}

/// PR #533: an epoch leaves two quantities behind, and a run AVPlayer rebuilt needs the other one.
///
/// A landing that reads "this run opens at the segment's own playlist position" is reading that the
/// PLACEMENT offset is gone. AE#481 published a zero for it, which says something stronger: that item
/// time IS source time there. On the fixtures both statements are true at once because their
/// timestamps start at zero. On a source that starts at 600 s the second one is false by the whole
/// source origin, and the session then maps the item axis onto itself: measured on the #481 arm over
/// `Scripts/slowrange.py` at 600 kbps / 300 ms, `capErr` goes from -600.000 to +0.017 at the landing
/// and the host clock reads `cur=-515.10` for the rest of the session.
@Suite("PR #533: what an epoch places and what its bytes carry are two numbers")
struct EpochAxisTableTests {

    // MARK: - The two quantities

    @Test("the backoff is the difference, on either geometry")
    func backoffDropsTheOrigin() {
        // The pin makes `carried` the plan anchor, so the source origin cancels and what is left is
        // what the gate actually did: open 9 s below its boundary. Both lines measured, same bytes.
        #expect(EpochAxis.zeroOrigin(-9).gateBackoffSeconds == -9)
        #expect(EpochAxis.originAt600(591).gateBackoffSeconds == -9)
    }

    @Test("an AE#412 re-cut places nothing and is read on the axis it was written with")
    func recutPlacesNothing() {
        // AVPlayer puts a re-cut at its own tfdt inside the timeline it is already building, so it
        // moves the axis by nothing (AE#412, measured 3 of 3) and its bytes are read with their
        // normalization rather than with where its advertised start would have shown them.
        let recut = EpochAxis.originAt600(598, isRecut: true)
        #expect(recut.placed == 0)
        #expect(recut.openingSourceAxis == 600)
        let ordinary = EpochAxis.originAt600(598)
        #expect(ordinary.placed == 598)
        #expect(ordinary.openingSourceAxis == 598)
    }

    // MARK: - What a producer restart does to the record

    @Test("a new epoch drops what older epochs claimed at and above its own index")
    func newEpochDropsTheIndicesItRewrites() {
        var table = EpochAxisTable()
        table.record(.zeroOrigin(-0.875), at: 11)
        table.record(.zeroOrigin(-9.0), at: 13)
        table.record(.zeroOrigin(-5.0), at: 12)
        #expect(table.opening(at: 11)?.placed == -0.875)
        #expect(table.opening(at: 12)?.placed == -5.0)
        // seg13 is now cut on its own boundary by the new producer, so claiming -9.0 for it would be
        // the table-shaped mistake round 1 avoided by keeping a single pair.
        #expect(table.opening(at: 13) == nil)
    }

    @Test("an epoch that opened on its boundary is recorded as worth nothing")
    func exactEpochIsRecordedAsZero() {
        // AE#448: worth nothing to the axis VALUE is not the same as nothing to record. The entry is
        // what says "an epoch begins here", and dropping it left the stretch the epoch had just taken
        // over folding with the seam underneath it.
        var table = EpochAxisTable()
        table.record(.zeroOrigin(-9.0), at: 13)
        table.record(.zeroOrigin(0), at: 20)
        #expect(table.opening(at: 13)?.placed == -9.0)
        #expect(table.opening(at: 20)?.placed == 0)
    }

    // MARK: - The source axis a rebuilt run is read on

    @Test("inside a run the bytes carry the normalization, not the opening's offset")
    func insideARunTheBytesCarryTheNormalization() {
        // The measured session: the resume epoch opens at seg13 having backed off 9 s, so its own
        // segment shows 591 s against its advertised start while every segment it cuts afterwards
        // sits on its boundary and carries the plain 600 s the producer folded in.
        var table = EpochAxisTable()
        table.record(.originAt600(591), at: 13)
        #expect(table.sourceAxis(at: 13) == 591)
        #expect(table.sourceAxis(at: 18) == 600)
        #expect(table.sourceAxis(at: 29) == 600)
    }

    @Test("a run below every recorded epoch is refused rather than read as zero")
    func belowEveryEpochIsSilent() {
        // The zero this used to fall back to is only ever right on a source whose timestamps start at
        // zero, which is the defect and not the fix. Unknown leaves the standing axis alone, which is
        // what every session did before AE#481.
        var table = EpochAxisTable()
        #expect(table.sourceAxis(at: 0) == nil)
        table.record(.originAt600(591), at: 13)
        #expect(table.sourceAxis(at: 12) == nil)
        #expect(table.sourceAxis(at: 13) == 591)
    }

    @Test("a backward restart hands the stretch above it to its own normalization")
    func backwardRestartRewritesTheStretchAbove() {
        var table = EpochAxisTable()
        table.record(.originAt600(591), at: 13)
        // A restart's normalization is its own: a matroska seek can land past the planned keyframe,
        // so the epoch above folds by a slightly different number than the one below it (#55).
        table.record(EpochAxis(presented: 600.25, carried: 600.25, isRecut: false), at: 30)
        #expect(table.sourceAxis(at: 40) == 600.25)
        // A producer starting at seg20 rewrites seg30 and seg40 on their own boundaries, so they are
        // now read with the new epoch's normalization and not with the one that stopped writing there.
        table.record(.originAt600(599), at: 20)
        #expect(table.sourceAxis(at: 40) == 600)
        #expect(table.sourceAxis(at: 20) == 599)
        #expect(table.sourceAxis(at: 15) == 600)
    }

    @Test("a source that starts at zero reads exactly as it did before")
    func zeroOriginIsUnchanged() {
        // The control arm, byte-identical between main and the fix on `tc-cues-lie.mkv`: the landing
        // at item 84.000 reads 0.000 off seg18 and the capErr mean over the 25 ticks after it is
        // +0.000 on both.
        var table = EpochAxisTable()
        table.record(.zeroOrigin(-9.0), at: 13)
        #expect(table.sourceAxis(at: 13) == -9.0)
        #expect(table.sourceAxis(at: 18) == 0)
    }
}
