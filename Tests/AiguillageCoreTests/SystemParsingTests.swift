import Foundation
import Testing
@testable import AiguillageCore

@Suite struct SystemParsingTests {
    // Shape of `scutil --dns` on this machine with Tailscale, plus our resolver.
    let scutil = """
    DNS configuration

    resolver #1
      nameserver[0] : 198.18.0.2
      flags    : Supplemental, Request A records
      reach    : 0x00000002 (Reachable)
      order    : 1

    resolver #2
      search domain[0] : tail2b4475.ts.net
      nameserver[0] : 100.100.100.100
      nameserver[1] : fd7a:115c:a1e0::53
      if_index : 25 (utun6)
      flags    : Supplemental, Request A records, Request AAAA records
      reach    : 0x00000003 (Reachable,Transient Connection)
      order    : 101800

    resolver #3
      nameserver[0] : 10.53.0.1
      if_index : 15 (en0)
      flags    : Request A records
      order    : 200000

    resolver #4
      domain   : tail2b4475.ts.net.
      nameserver[0] : 100.100.100.100
      if_index : 25 (utun6)
      order    : 101801

    resolver #5
      domain   : local
      options  : mdns
      timeout  : 5
      order    : 300000

    DNS configuration (for scoped queries)

    resolver #1
      nameserver[0] : 10.53.0.1
      if_index : 15 (en0)
      flags    : Scoped, Request A records
    """

    @Test func parsesUnscopedResolvers() {
        let rs = parseScutilDNS(scutil)
        #expect(rs.count == 5)
        #expect(rs[1].interface == "utun6")
        #expect(rs[1].nameservers == ["100.100.100.100", "fd7a:115c:a1e0::53"])
        #expect(rs[1].order == 101800)
        #expect(rs[3].domain == "tail2b4475.ts.net.")
        #expect(!rs[3].isMatchAll)
        #expect(!rs[4].isMatchAll) // mdns
    }

    @Test func matchAllPriority() {
        let all = matchAllResolversByPriority(parseScutilDNS(scutil))
        #expect(all.map(\.number) == [1, 2, 3])
        #expect(all.first?.nameservers == ["198.18.0.2"])
        // Tailscale ahead of us when our order is higher.
        let worse = scutil.replacingOccurrences(of: "order    : 1\n", with: "order    : 150000\n")
        let all2 = matchAllResolversByPriority(parseScutilDNS(worse))
        #expect(all2.first?.nameservers.first == "100.100.100.100")
    }

    let netstat = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    default            10.53.0.1          UGScg                 en0
    default            link#25            UCSIg               utun6
    0/1                198.18.0.2         UGSc                utun9
    0/1                10.8.0.1           UGSc                utun7
    100.64/10          link#25            UCS                 utun6
    128.0/1            198.18.0.2         UGSc                utun9
    128.0/1            10.8.0.1           UGSc                utun7
    10.53/21           link#15            UCS                   en0      !
    """

    @Test func defaultRouteHoldersIgnoreScopedRoutes() {
        let routes = parseNetstatRoutes(netstat)
        #expect(routes.count == 8)
        #expect(routes[1].isScoped)
        let holders = defaultRouteHolders(routes, excluding: "utun9")
        #expect(holders == ["en0", "utun7"]) // utun6 (Tailscale) only has a scoped default
        #expect(defaultRouteHolders(routes).contains("utun9"))
    }
}
