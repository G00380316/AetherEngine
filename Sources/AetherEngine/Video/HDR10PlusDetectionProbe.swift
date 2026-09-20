import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Bounds for the pre-playback HDR10+ (ST 2094-40) carriage scan, `AetherEngine.probe(url:detecting:)` with
/// `.hdr10Plus`.
///
/// Separate from `LoadOptions` and from the lightweight `probe(url:)` path, exactly like
/// `AtmosDetectionOptions`: a host opts into reading real video packets without the default probe changing
/// behaviour or cost.
///
/// Unlike the Atmos pass this one opens no decoder. It reads demuxed video packets and looks for the T.35
/// signature (see `HDR10PlusMetadataScan`), so its cost is I/O and a memory scan, not decode.
public struct HDR10PlusDetectionOptions: Sendable, Equatable {
    /// Stop after this many video packets have been scanned. Default 32.
    ///
    /// HDR10+ metadata is per frame, so a carrying source almost always confirms on the very first video
    /// packet; the budget exists for the source that starts with a run of frames without the SEI, and for
    /// the adversarial one that never has it.
    public var maxPackets: Int

    /// Stop after this many cumulative video-packet bytes. Default 16 MiB.
    ///
    /// This is the cap that actually binds on the content the feature targets: one UHD HEVC keyframe runs to
    /// several MB, so a handful of packets can cross it long before `maxPackets` does. 16 MiB leaves room for
    /// a keyframe plus the frames after it on a 4K remux while staying finite on a hostile source.
    public var maxBytes: Int64

    /// Soft wall-clock budget, checked BETWEEN packet reads. NOT preemptive: one blocking `av_read_frame()`
    /// on a stalled remote socket can still overrun it, the same AVIO-layer limitation `Demuxer.seekBounded`
    /// documents. Default 2 seconds.
    public var timeBudget: TimeInterval

    public init(
        maxPackets: Int = 32,
        maxBytes: Int64 = 16 * 1024 * 1024,
        timeBudget: TimeInterval = 2.0
    ) {
        self.maxPackets = maxPackets
        self.maxBytes = maxBytes
        self.timeBudget = timeBudget
    }
}

/// Result of the bounded HDR10+ carriage scan. Internal: hosts read the enriched `SourceProbe` instead. It
/// exists at module visibility so the stop conditions are unit-testable without media.
struct HDR10PlusDetectionOutcome: Sendable, Equatable {
    enum StopReason: Sendable, Equatable {
        /// No video stream at the resolved index, or the source has no video at all.
        case noVideoTrack
        /// The T.35 signature (or Matroska's decoded side data) was seen. The only positive answer.
        case found
        /// `maxPackets` video packets were scanned without a hit.
        case packetCap
        /// `maxBytes` cumulative video-packet bytes were scanned without a hit.
        case byteCap
        /// `timeBudget` elapsed (checked between reads) without a hit.
        case timeCap
        /// The demuxer reached EOF without a hit (a source short enough to scan whole).
        case demuxEOF
        /// `Demuxer.readPacket()` threw. Tolerated, never rethrown.
        case demuxError
    }

    let stopReason: StopReason
    let packetsRead: Int
    let bytesRead: Int64

    /// A negative is never authoritative and is never published as one: only `.found` sets the flag, and the
    /// flag is only ever set, never cleared. Every other reason means "not seen inside this budget", which
    /// for a cap is genuinely inconclusive and for EOF is only as conclusive as the source is short.
    var carriesHDR10Plus: Bool { stopReason == .found }
}

/// Which extra, strictly more expensive detail a probe should resolve on top of the container metadata.
///
/// Each member costs real reads past `avformat_find_stream_info`, which is why the base `probe(url:)` never
/// does any of it. They combine into one pass over one open handle, so a host that badges both Atmos and
/// HDR10+ pays one connection rather than two.
public struct ProbeDetail: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Authoritative E-AC-3 JOC (Dolby Atmos) via a bounded decode pass. See `AtmosDetectionOptions`.
    public static let atmos = ProbeDetail(rawValue: 1 << 0)

    /// HDR10+ (ST 2094-40) carriage via a bounded packet scan. See `HDR10PlusDetectionOptions`.
    public static let hdr10Plus = ProbeDetail(rawValue: 1 << 1)
}

extension AetherEngine {

    /// Pure stop-condition check for the scan loop, in cap priority order (packets, bytes, time). `nil` while
    /// inside all three budgets.
    nonisolated static func hdr10PlusScanCapReached(
        packetsRead: Int,
        bytesRead: Int64,
        elapsed: TimeInterval,
        options: HDR10PlusDetectionOptions
    ) -> HDR10PlusDetectionOutcome.StopReason? {
        if packetsRead >= options.maxPackets { return .packetCap }
        if bytesRead >= options.maxBytes { return .byteCap }
        if elapsed >= options.timeBudget { return .timeCap }
        return nil
    }

    /// Packet ceiling for the AVDISCARD_ALL fuse, saturating rather than trapping: `maxPackets` is public and
    /// `Int.max` is a plausible "no limit" value to pass.
    nonisolated static func hdr10PlusForeignPacketFuse(maxPackets: Int) -> Int {
        let (product, overflowed) = maxPackets.multipliedReportingOverflow(by: foreignPacketFuseMultiplier)
        return overflowed ? Int.max : product
    }

    /// The label an HDR10+ finding produces, given what the container already said.
    ///
    /// The same rule the running session applies in `handleHDR10PlusDetected`, in one place so probe and
    /// session cannot drift: `.hdr10` is the only format that moves, because the ST 2094-40 payload rides an
    /// HDR10 base. A Dolby Vision source keeps its label (Profile 7 and the 8.1 remuxes of it carry an HDR10+
    /// base layer under the RPU), an HLG or SDR one has no HDR10 base for the payload to describe, and
    /// `SourceProbe.carriesHDR10PlusMetadata` carries the evidence in all of those cases.
    nonisolated static func hdr10PlusUpgradedFormat(_ detected: VideoFormat) -> VideoFormat {
        detected == .hdr10 ? .hdr10Plus : detected
    }

    /// Bounded scan for HDR10+ carriage on `videoIndex`. Opens no decoder: it reads demuxed packets and asks
    /// `HDR10PlusMetadataScan` about each one, stopping at the first hit or the first cap.
    ///
    /// Deliberately runs BEFORE any queue-flushing seek, unlike `detectAtmos`. `avformat_find_stream_info`
    /// leaves the packets it read queued, `av_read_frame` hands those back first, and at the head of a
    /// container those are video packets: the common case is answered out of bytes that are already paid for,
    /// with no further I/O at all. (The Atmos pass has to throw that queue away precisely because what it
    /// needs is audio, which may sit far into the file.)
    ///
    /// `Demuxer.readPacket()` failures fold into `.demuxError` rather than propagating: an unreadable stream
    /// fails to confirm HDR10+, it does not fail the probe.
    nonisolated static func detectHDR10Plus(
        demuxer: Demuxer,
        videoIndex: Int32,
        options: HDR10PlusDetectionOptions
    ) -> HDR10PlusDetectionOutcome {
        guard videoIndex >= 0, let stream = demuxer.stream(at: videoIndex),
              let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO else {
            return HDR10PlusDetectionOutcome(stopReason: .noVideoTrack, packetsRead: 0, bytesRead: 0)
        }

        // Matroska's BlockAdditional carriage is attached by the demuxer to the packet, so the scan needs the
        // packets themselves either way; dropping the other streams keeps the byte budget spent on video.
        demuxer.discardAllStreamsExcept([videoIndex])

        let start = DispatchTime.now()
        var packetsRead = 0
        var bytesRead: Int64 = 0
        var packetsSeen = 0
        let fuse = Self.hdr10PlusForeignPacketFuse(maxPackets: options.maxPackets)

        while true {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            if let cap = Self.hdr10PlusScanCapReached(
                packetsRead: packetsRead, bytesRead: bytesRead, elapsed: elapsed, options: options
            ) {
                return HDR10PlusDetectionOutcome(stopReason: cap, packetsRead: packetsRead, bytesRead: bytesRead)
            }

            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                return HDR10PlusDetectionOutcome(
                    stopReason: .demuxError, packetsRead: packetsRead, bytesRead: bytesRead)
            }
            guard let pkt = packet else {
                return HDR10PlusDetectionOutcome(
                    stopReason: .demuxEOF, packetsRead: packetsRead, bytesRead: bytesRead)
            }

            var found = false
            packetsSeen += 1
            if pkt.pointee.stream_index == videoIndex {
                packetsRead += 1
                bytesRead += Int64(pkt.pointee.size)
                found = HDR10PlusMetadataScan.packetCarriesHDR10Plus(pkt)
            }
            av_packet_unref(pkt)
            av_packet_free_safe(pkt)

            if found {
                return HDR10PlusDetectionOutcome(
                    stopReason: .found, packetsRead: packetsRead, bytesRead: bytesRead)
            }

            // AVDISCARD_ALL is advisory, so a container that keeps handing back foreign packets still ends.
            if packetsSeen >= fuse {
                return HDR10PlusDetectionOutcome(
                    stopReason: .packetCap, packetsRead: packetsRead, bytesRead: bytesRead)
            }
        }
    }
}
