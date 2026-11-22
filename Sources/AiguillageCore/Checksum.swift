/// RFC 1071 Internet checksum helpers. Everything is computed from scratch (no incremental update).
public enum Checksum {
    /// Adds the 16-bit big-endian words of `bytes[range]` to `initial` (odd trailing byte padded with 0).
    public static func sum(_ bytes: [UInt8], _ range: Range<Int>, initial: UInt32 = 0) -> UInt32 {
        var acc = UInt64(initial)
        var i = range.lowerBound
        let end = range.upperBound
        while i + 1 < end {
            acc += UInt64(bytes[i]) << 8 | UInt64(bytes[i + 1])
            i += 2
        }
        if i < end {
            acc += UInt64(bytes[i]) << 8
        }
        while acc > 0xFFFF_FFFF {
            acc = (acc & 0xFFFF_FFFF) + (acc >> 32)
        }
        return UInt32(acc)
    }

    /// Folds a 32-bit accumulator into 16 bits and returns its one's complement.
    public static func finish(_ acc: UInt32) -> UInt16 {
        var s = acc
        while s > 0xFFFF {
            s = (s & 0xFFFF) + (s >> 16)
        }
        return ~UInt16(s)
    }

    public static func internet(_ bytes: [UInt8], _ range: Range<Int>) -> UInt16 {
        finish(sum(bytes, range))
    }

    /// Checksum of a TCP/UDP segment over IPv4 (pseudo-header + segment).
    public static func transport4(src: IPv4, dst: IPv4, proto: UInt8, _ bytes: [UInt8], _ segment: Range<Int>) -> UInt16 {
        var acc: UInt32 = 0
        acc += src.value >> 16
        acc += src.value & 0xFFFF
        acc += dst.value >> 16
        acc += dst.value & 0xFFFF
        acc += UInt32(proto)
        acc += UInt32(segment.count)
        return finish(sum(bytes, segment, initial: acc))
    }

    /// Checksum of a TCP/UDP segment over IPv6. `src`/`dst` are 16-byte addresses.
    public static func transport6(src: [UInt8], dst: [UInt8], proto: UInt8, _ bytes: [UInt8], _ segment: Range<Int>) -> UInt16 {
        var acc = sum(src, 0..<16)
        acc = sum(dst, 0..<16, initial: acc)
        let len = UInt32(segment.count)
        acc += len >> 16
        acc += len & 0xFFFF
        acc += UInt32(proto)
        return finish(sum(bytes, segment, initial: acc))
    }
}
