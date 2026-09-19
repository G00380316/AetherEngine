import Foundation
import Testing
@testable import AetherEngine

/// Sodalite#156, measured on an AirPlay route (device log 2026-09-19): turning subtitles off left the
/// native rendition SELECTED on the receiver. The readers stopped filling it, so the text went away,
/// and the Apple TV drew an empty caption box over the picture for the rest of the session. The log
/// shows the receiver still fetching that rendition after the off (`subs_1_380.vtt`, `subs_1_381.vtt`).
///
/// Cancelling the readers only stops FILLING a rendition; it does not stop anything from rendering it.
/// The deselect was there but narrowed to two cases the engine happened to know about, a remote-HLS
/// selection (AE#154) and an injected external rendition (#316). A host that asked for native
/// rendering has one in every other session too.
///
/// A sender-side `textStyleRules` hide is NOT an alternative here: it is a local text-renderer
/// instruction and never reaches the receiver, which is what made this read as "the text obeys but the
/// box does not".
struct Issue156ClearSubtitleDeselectsRenditionTests {

    private func subtitleSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine+Subtitles.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func clearSubtitleBody() throws -> String {
        let text = try subtitleSource()
        let start = try #require(text.range(of: "public func clearSubtitle() {"))
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        // Comments stripped: the rules below are about what the body DOES, and the body explains
        // itself by naming the very calls it must not make.
        return rest[..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("subtitles off deselects the legible group, whatever kind of selection it was")
    func clearSubtitleDeselects() throws {
        let body = try clearSubtitleBody()
        #expect(body.contains("item.select(nil, in: group)"))
        // The two conditions that used to gate it. Either one still standing means some session's
        // rendition is left selected again.
        #expect(!body.contains("RemoteHLSMediaSelection.ordinal(forTrackID:"))
        #expect(!body.contains("injectedSubtitleRenditionNames["))
    }

    @Test("the deselect does not clear the reapply ordinal, which would arm the carryover replay")
    func clearSubtitleLeavesTheReapplyOrdinalAlone() throws {
        // `nativeOrdinalToReplay` is guarded on `currentOrdinal == nil`, so clearing the ordinal here
        // would let the #170 replay re-select the rendition on the next session-preserving reload.
        let body = try clearSubtitleBody()
        #expect(!body.contains("setNativeSubtitleSelected"))
        #expect(!body.contains("nativeSubtitleReapplyOrdinal"))
    }

    @Test("that guard is what makes the ordinal matter, so it is pinned here too")
    func replayIsSuppressedByALiveOrdinal() {
        let table: [AetherEngine.NativeSubtitleTrackEntry] = []
        #expect(AetherEngine.nativeOrdinalToReplay(
            previousOrdinal: 2, matchesActiveTrack: false, previousActiveTrack: nil,
            currentOrdinal: nil, table: table) == 2)
        #expect(AetherEngine.nativeOrdinalToReplay(
            previousOrdinal: 2, matchesActiveTrack: false, previousActiveTrack: nil,
            currentOrdinal: 0, table: table) == nil)
    }
}
