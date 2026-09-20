import Foundation
import AetherLibavcodec
import AetherLibavutil

/// Where HDR10+ (SMPTE ST 2094-40) can be seen in a demuxed packet, without decoding a frame.
///
/// One definition for both readers: the segment producer's per-packet scan during playback
/// (`HLSSegmentProducer.finalizeAndWriteVideo`) and the pre-playback pass behind
/// `AetherEngine.probeDetectingHDR10Plus`. They used to be one call site and a literal byte array; a probe
/// that answered differently from the session it precedes would be worse than no probe at all.
///
/// Two carriages, because FFmpeg produces exactly two (checked against the pinned FFmpeg tree):
///
/// - **In-band ITU-T T.35 SEI.** This is where HEVC HDR10+ lives, and NO demuxer parses it: `mov`, `mpegts`
///   and `matroska` hand the SEI through inside the video packet, and only `hevc/hevcdec.c` surfaces it,
///   post-decode, as `AV_FRAME_DATA_DYNAMIC_HDR_PLUS`. Hence the byte scan: it is the only way to see HDR10+
///   without opening a decoder.
/// - **`AV_PKT_DATA_DYNAMIC_HDR10_PLUS` packet side data.** `matroskadec.c` alone attaches this, from a
///   BlockAdditional whose T.35 header it has already stripped (the VP9/AV1-in-Matroska carriage). The bytes
///   are a decoded `AVDynamicHDRPlus` by then, so the signature scan cannot see it and the type has to be
///   asked for separately.
///
/// The byte scan is a signature match over the whole packet payload, not a NAL walk, and it can in principle
/// match those six bytes inside compressed slice data. That is the trade the producer has always made, and it
/// is kept here deliberately: one false positive mislabels a badge, while a NAL walk that disagrees with the
/// producer's scan would mislabel the session against its own probe.
enum HDR10PlusMetadataScan {

    /// `country_code` 0xB5 (US), `provider_code` 0x003C (Samsung), `provider_oriented_code` 0x0001,
    /// `application_identifier` 0x04: the four fields that open every ST 2094-40 T.35 payload, in bitstream
    /// order. `matroskadec.c` gates its BlockAdditional conversion on the same four values.
    ///
    /// All four are needed. Dolby's RPU rides a T.35 payload too, under provider code 0x003B, so a scan for
    /// the country code alone would call every Profile 5 / 8 source HDR10+.
    static let t35Signature: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]

    /// Whether the ST 2094-40 T.35 signature appears anywhere in `size` bytes at `data`.
    ///
    /// `nil` data, a non-positive size, or a payload shorter than the signature answer `false` without a read.
    static func bytesCarrySignature(_ data: UnsafePointer<UInt8>?, size: Int) -> Bool {
        guard let data, size >= t35Signature.count else { return false }
        return t35Signature.withUnsafeBufferPointer { needle -> Bool in
            memmem(data, size, needle.baseAddress, needle.count) != nil
        }
    }

    /// Array convenience for tests and call sites that already hold the bytes.
    static func bytesCarrySignature(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { bytesCarrySignature($0.baseAddress, size: $0.count) }
    }

    /// Whether this packet carries HDR10+ in either of the two carriages.
    ///
    /// Side data is asked first: it is a type lookup over a short list, while the signature scan walks the
    /// whole payload, and on the one container that produces side data the payload no longer holds the T.35
    /// header at all.
    static func packetCarriesHDR10Plus(_ packet: UnsafePointer<AVPacket>) -> Bool {
        var sideDataSize = 0
        if av_packet_get_side_data(packet, AV_PKT_DATA_DYNAMIC_HDR10_PLUS, &sideDataSize) != nil {
            return true
        }
        return bytesCarrySignature(packet.pointee.data, size: Int(packet.pointee.size))
    }
}
