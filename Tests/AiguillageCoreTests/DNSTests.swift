import Testing
@testable import AiguillageCore

/// Builds a response to `query` with the given rcode and A records (answer names compressed
/// as a pointer to the question, offset 12), optionally preceded by a CNAME.
func makeResponse(to query: [UInt8], rcode: UInt8 = 0, a: [(IPv4, UInt32)] = [], cname: String? = nil) -> [UInt8] {
    let m = DNSMessage(query)!
    var b = Array(query[0..<m.questionEnd])
    write16(&b, 2, 0x8180 | UInt16(rcode))
    write16(&b, 6, UInt16(a.count + (cname == nil ? 0 : 1)))
    write16(&b, 8, 0)
    write16(&b, 10, 0)
    var owner: [UInt8] = [0xc0, 0x0c]
    if let cname {
        let target = DNS.encodeName(cname)
        let targetOffset = b.count + 12
        b += owner + [0, 5, 0, 1, 0, 0, 0, 60, UInt8(target.count >> 8), UInt8(target.count & 0xff)] + target
        owner = [0xc0, UInt8(targetOffset)]
    }
    for (ip, ttl) in a {
        b += owner + [0, 1, 0, 1]
        b += [UInt8(ttl >> 24), UInt8(ttl >> 16 & 0xff), UInt8(ttl >> 8 & 0xff), UInt8(ttl & 0xff)]
        b += [0, 4] + ip.bytes
    }
    return b
}

@Suite struct DNSTests {
    @Test func parsesQuery() throws {
        let q = DNS.buildQuery(id: 0xBEEF, name: "api.anthropic.com", type: DNSType.a)
        let m = try #require(DNSMessage(q))
        #expect(m.id == 0xBEEF)
        #expect(!m.isResponse)
        #expect(m.questionCount == 1)
        #expect(m.questionName == "api.anthropic.com")
        #expect(m.questionType == DNSType.a)
        #expect(m.questionClass == 1)
        #expect(m.questionEnd == q.count)
    }

    @Test func rejectsGarbage() {
        #expect(DNSMessage([1, 2, 3]) == nil)
        // Question name running past the end.
        #expect(DNSMessage([0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 10, 0x61]) == nil)
        // Compression pointer loop.
        #expect(DNS.readName([0xc0, 0x00], at: 0) == nil)
    }

    @Test func emptyAAAAResponse() throws {
        var q = DNS.buildQuery(id: 0x1234, name: "example.com", type: DNSType.aaaa)
        // Add an EDNS OPT record in the additional section; it must not be echoed.
        write16(&q, 10, 1)
        q += [0, 0, 41, 0x10, 0, 0, 0, 0, 0, 0, 0]
        #expect(DNS.isAAAAQuery(q))
        let r = try #require(DNS.emptyResponse(to: q))
        let m = try #require(DNSMessage(r))
        #expect(m.id == 0x1234)
        #expect(m.isResponse)
        #expect(m.rcode == DNSRcode.noError)
        #expect(m.flags & 0x0100 != 0) // RD copied
        #expect(m.flags & 0x0080 != 0) // RA
        #expect(m.questionCount == 1 && m.answerCount == 0 && m.authorityCount == 0 && m.additionalCount == 0)
        #expect(m.questionName == "example.com")
        #expect(m.questionType == DNSType.aaaa)
        #expect(r.count == m.questionEnd)
        #expect(DNS.classify(response: r) == .negative)
        #expect(!DNS.isAAAAQuery(DNS.buildQuery(id: 1, name: "example.com", type: DNSType.a)))
        #expect(DNS.emptyResponse(to: r) == nil) // not for responses
    }

    @Test func classify() {
        let q = DNS.buildQuery(id: 7, name: "portal.train", type: DNSType.a)
        #expect(DNS.classify(response: makeResponse(to: q, a: [(IPv4(10, 0, 0, 1), 30)])) == .positive)
        #expect(DNS.classify(response: makeResponse(to: q, rcode: DNSRcode.nameError)) == .negative)
        #expect(DNS.classify(response: makeResponse(to: q, rcode: DNSRcode.serverFailure)) == .negative)
        #expect(DNS.classify(response: makeResponse(to: q)) == .negative) // NOERROR, empty
        #expect(DNS.classify(response: q) == .invalid) // a query is not a response
        #expect(DNS.classify(response: [0, 1]) == .invalid)
    }

    @Test func aRecordsThroughCNAMEWithTTL() {
        let q = DNS.buildQuery(id: 7, name: "api.anthropic.com", type: DNSType.a)
        let r = makeResponse(to: q, a: [(IPv4(160, 79, 104, 10), 300), (IPv4(160, 79, 104, 11), 20)], cname: "edge.cdn.example")
        let recs = DNS.aRecordsWithTTL(in: r)
        #expect(recs.map(\.ip) == [IPv4(160, 79, 104, 10), IPv4(160, 79, 104, 11)])
        #expect(recs.map(\.ttl) == [300, 20])
        #expect(DNSMessage(r)?.id == 7)
    }
}

@Suite struct DNSRaceTests {
    let q = DNS.buildQuery(id: 1, name: "x.example", type: DNSType.a)
    var positive: [UInt8] { makeResponse(to: q, a: [(IPv4(1, 2, 3, 4), 60)]) }
    var nx: [UInt8] { makeResponse(to: q, rcode: DNSRcode.nameError) }

    @Test func firstPositiveWins() {
        var r = DNSRaceState(linkCount: 2)
        #expect(r.received(positive, from: 1) == .reply(positive))
        #expect(r.finished)
        #expect(r.received(nx, from: 0) == .wait(startGrace: false, sendRemaining: false))
    }

    @Test func negativeWaitsForOtherLink() {
        var r = DNSRaceState(linkCount: 2)
        #expect(r.received(nx, from: 0) == .wait(startGrace: true, sendRemaining: true))
        #expect(r.received(positive, from: 1) == .reply(positive)) // portal name known to the other resolver
    }

    @Test func negativeReturnedAfterGrace() {
        var r = DNSRaceState(linkCount: 2)
        _ = r.received(nx, from: 1)
        #expect(r.graceExpired() == .reply(nx))
    }

    @Test func bothNegativePrefersPreferredLink() {
        var r = DNSRaceState(linkCount: 2)
        let servfail = makeResponse(to: q, rcode: DNSRcode.serverFailure)
        _ = r.received(servfail, from: 1)
        #expect(r.received(nx, from: 0) == .reply(nx))
    }

    @Test func allFailGivesUp() {
        var r = DNSRaceState(linkCount: 2)
        #expect(r.failed(0) == .wait(startGrace: false, sendRemaining: true))
        #expect(r.failed(1) == .giveUp)
    }

    @Test func singleLinkNegativeIsImmediate() {
        var r = DNSRaceState(linkCount: 1)
        #expect(r.received(nx, from: 0) == .reply(nx))
    }
}
