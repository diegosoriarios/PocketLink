import Foundation

public enum LocalIPAddress {
    /// Returns the Mac's primary IPv4 address (dotted quad), preferring
    /// hardware interfaces (en*) and skipping loopback and link-local
    /// addresses. Returns nil when no usable IPv4 address exists.
    public static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(interface: String, address: String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            current = item.pointee.ifa_next
            guard let sa = item.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            candidates.append((name, String(cString: host)))
        }

        let usable = candidates.filter { !$0.address.hasPrefix("169.254.") }
        let pool = usable.isEmpty ? candidates : usable
        let sorted = pool.sorted { lhs, rhs in
            let lhsPreferred = lhs.interface.hasPrefix("en")
            let rhsPreferred = rhs.interface.hasPrefix("en")
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.interface < rhs.interface
        }
        return sorted.first?.address
    }
}
