import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Pure byte-level tests for the HDR10+ (ST 2094-40) carriage scan that `AetherEngine.probeDetectingHDR10Plus`
/// and `HLSSegmentProducer` share. No demuxer, no decoder, no media.
///
/// The two carriages tested here are the two FFmpeg actually produces, verified against the pinned
/// `~/Dev/FFmpegBuild/build/ffmpeg-src` tree:
///
/// - in-band ITU-T T.35 SEI in the video bitstream, which is where HEVC HDR10+ lives and which no demuxer
///   parses (`hevc/hevcdec.c` surfaces it only post-decode as `AV_FRAME_DATA_DYNAMIC_HDR_PLUS`), and
/// - `AV_PKT_DATA_DYNAMIC_HDR10_PLUS` packet side data, which `matroskadec.c` alone attaches, from a
///   BlockAdditional carrying the same T.35 payload.
@Suite("HDR10PlusMetadataScan: T.35 signature and packet side data")
struct HDR10PlusMetadataScanTests {

    /// country_code 0xB5 (US), provider_code 0x003C (Samsung), provider_oriented_code 0x0001,
    /// application_identifier 0x04. The same four fields `matroskadec.c` gates its BlockAdditional
    /// conversion on, in the same order.
    static let signature: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]

    @Test("The signature is found at the head of a packet payload")
    func signatureAtHead() {
        let payload = Self.signature + [0x01, 0x02, 0x03]
        #expect(HDR10PlusMetadataScan.bytesCarrySignature(payload))
    }

    @Test("The signature is found in the middle, where a real SEI NAL puts it")
    func signatureInMiddle() {
        let payload: [UInt8] = [0x00, 0x00, 0x01, 0x4E, 0x01, 0x04, 0x2F] + Self.signature + [0x00, 0xFF]
        #expect(HDR10PlusMetadataScan.bytesCarrySignature(payload))
    }

    @Test("The signature is found at the very end of the payload")
    func signatureAtTail() {
        let payload: [UInt8] = [0xAA, 0xBB, 0xCC] + Self.signature
        #expect(HDR10PlusMetadataScan.bytesCarrySignature(payload))
    }

    @Test("A payload without the signature does not match")
    func absentSignature() {
        let payload: [UInt8] = Array(repeating: 0xB5, count: 64)
        #expect(!HDR10PlusMetadataScan.bytesCarrySignature(payload))
    }

    @Test("A prefix of the signature that runs off the end of the payload does not match")
    func truncatedSignature() {
        let payload: [UInt8] = [0x00, 0x00] + Self.signature.dropLast()
        #expect(!HDR10PlusMetadataScan.bytesCarrySignature(payload))
    }

    @Test("A payload shorter than the signature is rejected without reading past it")
    func payloadShorterThanSignature() {
        #expect(!HDR10PlusMetadataScan.bytesCarrySignature([]))
        #expect(!HDR10PlusMetadataScan.bytesCarrySignature([0xB5, 0x00, 0x3C, 0x00, 0x01]))
    }

    @Test("A Dolby Vision T.35 payload (provider 0x003B) is not mistaken for HDR10+")
    func dolbyProviderDoesNotMatch() {
        // Dolby's provider_code is 0x003B, one below Samsung's. A scan that only checked the country code
        // would report every P5/P8 RPU carried in a T.35 SEI as HDR10+.
        let payload: [UInt8] = [0xB5, 0x00, 0x3B, 0x00, 0x01, 0x04, 0x11, 0x22]
        #expect(!HDR10PlusMetadataScan.bytesCarrySignature(payload))
    }

    @Test("A packet carrying AV_PKT_DATA_DYNAMIC_HDR10_PLUS side data is detected without an in-band SEI")
    func packetSideDataIsDetected() {
        guard let packet = av_packet_alloc() else {
            Issue.record("av_packet_alloc failed")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&p)
        }
        // Payload bytes are irrelevant to this carriage: matroskadec strips the T.35 header and stores a
        // decoded AVDynamicHDRPlus, so the scan must key off the side-data TYPE, not the bytes.
        var size = 0
        guard let hdrplus = av_dynamic_hdr_plus_alloc(&size) else {
            Issue.record("av_dynamic_hdr_plus_alloc failed")
            return
        }
        let added = av_packet_add_side_data(
            packet, AV_PKT_DATA_DYNAMIC_HDR10_PLUS,
            UnsafeMutableRawPointer(hdrplus).assumingMemoryBound(to: UInt8.self), size)
        guard added >= 0 else {
            av_free(hdrplus)
            Issue.record("av_packet_add_side_data failed: \(added)")
            return
        }
        #expect(HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet))
    }

    @Test("A packet with neither carriage is not detected")
    func emptyPacketIsNotDetected() {
        guard let packet = av_packet_alloc() else {
            Issue.record("av_packet_alloc failed")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&p)
        }
        var payload: [UInt8] = Array(repeating: 0x00, count: 32)
        payload.withUnsafeMutableBufferPointer { buf in
            packet.pointee.data = buf.baseAddress
            packet.pointee.size = Int32(buf.count)
            #expect(!HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet))
            packet.pointee.data = nil
            packet.pointee.size = 0
        }
    }

    @Test("A packet with the in-band signature is detected")
    func packetInBandIsDetected() {
        guard let packet = av_packet_alloc() else {
            Issue.record("av_packet_alloc failed")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&p)
        }
        var payload: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x4E, 0x01] + Self.signature + [0x2A, 0x80]
        payload.withUnsafeMutableBufferPointer { buf in
            packet.pointee.data = buf.baseAddress
            packet.pointee.size = Int32(buf.count)
            #expect(HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet))
            packet.pointee.data = nil
            packet.pointee.size = 0
        }
    }
}
