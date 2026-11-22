/// Minimal DNS message handling: header, first question, A records, and the empty AAAA reply.

public enum DNSType {
    public static let a: UInt16 = 1
    public static let cname: UInt16 = 5
    public static let aaaa: UInt16 = 28
}

public enum DNSRcode {
    public static let noError: UInt8 = 0
    public static let serverFailure: UInt8 = 2
    public static let nameError: UInt8 = 3 // NXDOMAIN
}

public struct DNSMessage: Equatable {
    public let id: UInt16
    public let flags: UInt16
    public let questionCount: Int
    public let answerCount: Int
    public let authorityCount: Int
    public let additionalCount: Int
    /// First question, if any.
    public let questionName: String?
    public let questionType: UInt16?
    public let questionClass: UInt16?
    /// Byte offset just after the first question.
    public let questionEnd: Int

    public var isResponse: Bool { flags & 0x8000 != 0 }
    public var rcode: UInt8 { UInt8(flags & 0x000f) }
    public var isTruncated: Bool { flags & 0x0200 != 0 }

    public init?(_ b: [UInt8]) {
        guard b.count >= 12 else { return nil }
        id = read16(b, 0)
        flags = read16(b, 2)
        questionCount = Int(read16(b, 4))
        answerCount = Int(read16(b, 6))
        authorityCount = Int(read16(b, 8))
        additionalCount = Int(read16(b, 10))
        if questionCount > 0 {
            guard let (name, next) = DNS.readName(b, at: 12), next + 4 <= b.count else { return nil }
            questionName = name
            questionType = read16(b, next)
            questionClass = read16(b, next + 2)
            questionEnd = next + 4
        } else {
            questionName = nil
            questionType = nil
            questionClass = nil
            questionEnd = 12
        }
    }
}

public enum DNSAnswerKind: Equatable {
    /// NOERROR with at least one answer.
    case positive
    /// NXDOMAIN, SERVFAIL, other errors, or NOERROR without answers.
    case negative
    /// Not a parseable DNS response.
    case invalid
}

public enum DNS {
    /// Reads a (possibly compressed) domain name. Returns the dotted name and the offset after it
    /// in the original position (pointers are followed but do not move that offset past 2 bytes).
    public static func readName(_ b: [UInt8], at start: Int) -> (String, Int)? {
        var labels: [String] = []
        var i = start
        var end: Int? = nil
        var jumps = 0
        while true {
            guard i < b.count else { return nil }
            let len = Int(b[i])
            if len == 0 {
                i += 1
                break
            }
            if len & 0xC0 == 0xC0 {
                guard i + 1 < b.count, jumps < 32 else { return nil }
                if end == nil { end = i + 2 }
                i = (len & 0x3f) << 8 | Int(b[i + 1])
                jumps += 1
                continue
            }
            guard len <= 63, i + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(i + 1)..<(i + 1 + len)], as: UTF8.self))
            i += 1 + len
        }
        return (labels.joined(separator: "."), end ?? i)
    }

    public static func encodeName(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            out.append(UInt8(bytes.count))
            out += bytes
        }
        out.append(0)
        return out
    }

    /// Builds a standard recursive query with one question.
    public static func buildQuery(id: UInt16, name: String, type: UInt16) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 12)
        write16(&b, 0, id)
        write16(&b, 2, 0x0100) // RD
        write16(&b, 4, 1)
        b += encodeName(name)
        b += [UInt8(type >> 8), UInt8(type & 0xff), 0, 1] // class IN
        return b
    }

    /// For an AAAA query: a NOERROR reply with the question echoed and no records (same ID).
    /// Returns nil if the query has no single question.
    public static func emptyResponse(to query: [UInt8]) -> [UInt8]? {
        guard let m = DNSMessage(query), !m.isResponse, m.questionCount == 1 else { return nil }
        var b = Array(query[0..<m.questionEnd])
        let opcode = m.flags & 0x7800
        let rd = m.flags & 0x0100
        write16(&b, 2, 0x8000 | opcode | rd | 0x0080) // QR, opcode, RD, RA, rcode 0
        write16(&b, 4, 1)
        write16(&b, 6, 0)
        write16(&b, 8, 0)
        write16(&b, 10, 0)
        return b
    }

    public static func isAAAAQuery(_ query: [UInt8]) -> Bool {
        guard let m = DNSMessage(query), !m.isResponse else { return false }
        return m.questionType == DNSType.aaaa
    }

    public static func classify(response: [UInt8]) -> DNSAnswerKind {
        guard let m = DNSMessage(response), m.isResponse else { return .invalid }
        if m.rcode == DNSRcode.noError && m.answerCount > 0 { return .positive }
        return .negative
    }

    /// Extracts the A records of the answer section.
    public static func aRecords(in response: [UInt8]) -> [IPv4] {
        aRecordsWithTTL(in: response).map(\.ip)
    }

    /// Extracts the A records of the answer section with their TTL (seconds). Records reached
    /// through a CNAME chain are included: they all answer the question name.
    public static func aRecordsWithTTL(in response: [UInt8]) -> [(ip: IPv4, ttl: UInt32)] {
        guard let m = DNSMessage(response), m.isResponse, m.questionCount <= 1 else { return [] }
        var i = m.questionEnd
        var out: [(IPv4, UInt32)] = []
        for _ in 0..<m.answerCount {
            guard let (_, next) = readName(response, at: i), next + 10 <= response.count else { break }
            let type = read16(response, next)
            let ttl = read32(response, next + 4)
            let rdlen = Int(read16(response, next + 8))
            let rdata = next + 10
            guard rdata + rdlen <= response.count else { break }
            if type == DNSType.a && rdlen == 4 {
                out.append((IPv4(bytes: response, at: rdata), ttl))
            }
            i = rdata + rdlen
        }
        return out
    }
}
