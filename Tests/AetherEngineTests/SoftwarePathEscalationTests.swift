// The last rung under a native session AVPlayer will not play (AE#561).
//
// Every recovery above it reloads the same item against the same bytes, which is the right answer to
// a transient and a loop against a segment Apple's parser refuses on its merits. This decides when
// the engine's own decoder is offered the session instead of the failure being made terminal.
import Foundation
import Testing
@testable import AetherEngine

@Suite("Software-path escalation (AE#561)")
struct SoftwarePathEscalationTests {

    private static func availability(
        escalated: Bool = false,
        path: DecodePath = .automatic,
        remoteHLS: Bool = false
    ) -> SoftwarePathEscalation.Availability {
        SoftwarePathEscalation.Availability(
            alreadyEscalated: escalated, preferredDecodePath: path, nativeRemoteHLS: remoteHLS)
    }

    @Test("A media failure on a fresh native session is escalated")
    func mediaFailureEscalates() {
        #expect(SoftwarePathEscalation.shouldEscalate(
            errorDomain: "CoreMediaErrorDomain", availability: Self.availability()))
    }

    /// The domain is the whole discriminator: a second decoder can disagree about the media, and
    /// cannot disagree about a source neither path can read.
    @Test("A source failure is not escalated, whatever its code")
    func sourceFailureIsNotEscalated() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: NSURLErrorDomain, availability: Self.availability()))
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: "AVFoundationErrorDomain", availability: Self.availability()))
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: nil, availability: Self.availability()))
    }

    @Test("The session spends its escalation once")
    func onlyOnce() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: "CoreMediaErrorDomain", availability: Self.availability(escalated: true)))
    }

    @Test("A session already on the software path has nowhere to escalate to")
    func alreadySoftware() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: "CoreMediaErrorDomain", availability: Self.availability(path: .software)))
    }

    /// The bypass has no local muxer and the engine decodes nothing on it, so #461 ignores the
    /// option there; escalating would spend a rebuild to arrive where it started.
    @Test("The remote-HLS bypass is not escalated")
    func remoteHLSIsRefused() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: "CoreMediaErrorDomain", availability: Self.availability(remoteHLS: true)))
    }

    @Test("No answer from the engine is never a reason to swallow a failure")
    func noAvailabilityRefuses() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: "CoreMediaErrorDomain", availability: nil))
    }

    @Test("The budget is spent by the first taker, not by the second")
    func budgetIsTakenOnce() {
        let budget = SoftwarePathEscalation.Budget()
        #expect(!budget.isSpent)
        #expect(budget.take())
        #expect(budget.isSpent)
        #expect(!budget.take())
    }

    /// Audit CORE-1: the rebuild is a full load(), and a stop() landing inside it unwinds that load
    /// with a CancellationError. The escalation read every throw as "the software path cannot serve
    /// this session" and published `.error` onto an engine the viewer had already left.
    @Test("A rebuild superseded by stop() leaves the engine idle, not in error", .timeLimit(.minutes(2)))
    @MainActor
    func supersededRebuildIsSilent() async throws {
        let origin = try ProbeHTTPTestOrigin(data: ProbeTestFixtures.hdr10Plus(), stage: .headers)
        defer { origin.stop() }
        let engine = try AetherEngine()
        engine.loadedURL = try #require(URL(string: "http://127.0.0.1:\(origin.port)/source.mkv"))

        let escalation = Task { @MainActor in
            await engine.escalateToSoftwarePath(SoftwarePathEscalation.Request(
                domain: SoftwarePathEscalation.mediaErrorDomain, code: 0,
                message: "item death at a frozen position", positionSeconds: 0))
        }
        // The rebuild's probe is parked on the origin, so the stop lands inside the load.
        try await waitFor { origin.blocked.entered }
        engine.stop()
        origin.stop()
        await escalation.value

        #expect(engine.state == .idle)
        #expect(engine.errorInfo == nil)
    }
}
