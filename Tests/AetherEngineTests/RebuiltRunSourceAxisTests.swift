import Foundation
import Testing
@testable import AetherEngine

@Suite("Rebuilt VOD runs retain their source timestamp normalization")
struct RebuiltRunSourceAxisTests {
    @Test("cached landing and recut keep the source axis used by PGS cues")
    func cachedLandingAndRecut() {
        var axis = RebuiltRunSourceAxis()
        axis.record(
            index: 0,
            presentationShift: 600.333333,
            normalizationShift: 600.208333,
            isRecut: false)

        #expect(axis.shift(at: 0) == 600.333333)
        #expect(axis.shift(at: 36) == 600.208333)
        #expect(169 + (axis.shift(at: 36) ?? 0) > 737.42)

        axis.record(
            index: 36,
            presentationShift: 598,
            normalizationShift: 600.208333,
            isRecut: true)
        #expect(axis.shift(at: 36) == 600.208333)
        #expect(axis.measuredWorth(at: 36, composedWorth: 0, rebuilt: true) == 600.208333)
        #expect(axis.measuredWorth(at: 36, composedWorth: 0, rebuilt: false) == 0)
        #expect(axis.shift(at: 82) == 600.208333)
    }

    @Test("a backward rewrite removes only superseded source-axis epochs")
    func backwardRewrite() {
        var axis = RebuiltRunSourceAxis()
        axis.record(index: 0, presentationShift: 600.333333,
                    normalizationShift: 600.208333, isRecut: false)
        axis.record(index: 70, presentationShift: 601,
                    normalizationShift: 600.25, isRecut: false)
        #expect(axis.shift(at: 75) == 600.25)

        axis.record(index: 30, presentationShift: 599,
                    normalizationShift: 600, isRecut: false)
        #expect(axis.shift(at: 75) == 600)
        #expect(axis.shift(at: 20) == 600.208333)
    }

    @Test("unknown and zero-origin runs do not invent an offset")
    func zeroOrigin() {
        var axis = RebuiltRunSourceAxis()
        #expect(axis.shift(at: 0) == nil)

        axis.record(index: 13, presentationShift: -9,
                    normalizationShift: 0, isRecut: false)
        #expect(axis.shift(at: 13) == -9)
        #expect(axis.shift(at: 19) == 0)

        axis.record(index: 20, presentationShift: -3,
                    normalizationShift: 0, isRecut: true)
        #expect(axis.shift(at: 20) == 0)
    }
}
