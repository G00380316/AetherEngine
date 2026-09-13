import Foundation

/// Source-to-item mapping carried by a producer's bytes. Placement offsets apply
/// to its opening segment only; later segments still carry timestamp normalization.
/// Access is serialized by HLSVideoEngine.anchorShiftLock.
struct RebuiltRunSourceAxis {
    struct Epoch {
        let openingShift: Double
        let normalizationShift: Double
    }
    private var epochs: [Int: Epoch] = [:]

    mutating func record(index: Int, presentationShift: Double,
                         normalizationShift: Double, isRecut: Bool) {
        epochs = epochs.filter { $0.key < index }
        epochs[index] = Epoch(openingShift: isRecut ? normalizationShift : presentationShift,
                              normalizationShift: normalizationShift)
    }

    func shift(at index: Int) -> Double? {
        guard let start = epochs.keys.filter({ $0 <= index }).max(),
              let epoch = epochs[start] else { return nil }
        return start == index ? epoch.openingShift : epoch.normalizationShift
    }

    func measuredWorth(at index: Int, composedWorth: Double, rebuilt: Bool) -> Double {
        rebuilt ? (shift(at: index) ?? composedWorth) : composedWorth
    }
}
