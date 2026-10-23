import Foundation
import Darwin

/// Finds NovaStar network controllers on the Mac's own networks.
/// Every IPv4 interface that is up (not loopback, link-local or VPN) gives a subnet; subnets larger than /22 are
/// narrowed to the /24 around the Mac's address. Each host is tried on TCP 5200 (non-blocking connects, many at
/// once), and every host that accepts is asked for its identification registers 0x00000000 / 0x00000002 —
/// only hosts that answer as a NovaStar controller are reported.
nonisolated enum ControllerDiscovery {
    struct Subnet: Sendable, Hashable {
        let interface: String
        let address: UInt32       // the Mac's own address, host order
        let mask: UInt32
        var network: UInt32 { address & mask }
        var text: String { "\(ControllerDiscovery.text(network))/\(mask.nonzeroBitCount) (\(interface))" }
    }

    struct Found: Sendable {
        let ip: String
        let id: ControllerModels.ID
    }

    struct Result: Sendable {
        let subnets: [Subnet]
        let found: [Found]
        let openButSilent: [String]     // TCP 5200 open, but no NovaStar answer (busy or another device)
    }

    static func text(_ address: UInt32) -> String {
        "\(address >> 24 & 0xFF).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }

    /// IPv4 subnets of the Mac's active interfaces.
    static func subnets() -> [Subnet] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [Subnet] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let a = ifa.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
                  let m = ifa.ifa_netmask else { continue }
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { continue }   // VPN
            let address = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if address >> 16 == 0xA9FE { continue }                       // 169.254.x.x: no DHCP, no manual address
            if mask.nonzeroBitCount < 22 { mask = 0xFFFF_FF00 }          // big networks: only the /24 around the Mac
            let subnet = Subnet(interface: name, address: address, mask: mask)
            if !out.contains(where: { $0.network == subnet.network && $0.mask == subnet.mask }) { out.append(subnet) }
        }
        return out
    }

    static func hosts(_ subnet: Subnet) -> [UInt32] {
        let broadcast = subnet.network | ~subnet.mask
        guard broadcast > subnet.network + 1 else { return [] }
        return (subnet.network + 1 ..< broadcast).filter { $0 != subnet.address }
    }

    /// Hosts that accept a TCP connection on `port`. Connects are started in batches and waited for together.
    static func openPorts(_ hosts: [UInt32], port: UInt16 = 5200, timeoutMs: Int = 800, batch: Int = 128) -> [UInt32] {
        var result: [UInt32] = []
        var start = 0
        while start < hosts.count {
            var pending: [(fd: Int32, host: UInt32)] = []
            for host in hosts[start..<min(start + batch, hosts.count)] {
                let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { continue }
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr = in_addr(s_addr: host.bigEndian)
                let r = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if r == 0 || errno == EINPROGRESS { pending.append((fd, host)) } else { Darwin.close(fd) }
            }
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while !pending.isEmpty {
                let left = Int32(deadline.timeIntervalSinceNow * 1000)
                guard left > 0 else { break }
                var polls = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
                guard Darwin.poll(&polls, nfds_t(polls.count), left) > 0 else { break }
                var still: [(fd: Int32, host: UInt32)] = []
                for (i, p) in polls.enumerated() {
                    if p.revents != 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                        if err == 0 { result.append(pending[i].host) }
                        Darwin.close(p.fd)
                    } else {
                        still.append(pending[i])
                    }
                }
                pending = still
            }
            for p in pending { Darwin.close(p.fd) }
            start += batch
        }
        return result
    }

    /// Scans every subnet and identifies the hosts with TCP 5200 open.
    static func scan() async -> Result {
        let nets = subnets()
        let open: [UInt32] = await Task.detached(priority: .userInitiated) {
            var all = Set<UInt32>()
            for subnet in nets { all.formUnion(openPorts(hosts(subnet))) }
            return all.sorted()
        }.value
        var found: [Found] = []
        var silent: [String] = []
        for host in open {
            let ip = text(host)
            if let id = try? await ControllerModels.identify(.network(ip)) {
                found.append(Found(ip: ip, id: id))
            } else {
                silent.append(ip)
            }
        }
        return Result(subnets: nets, found: found, openButSilent: silent)
    }
}
