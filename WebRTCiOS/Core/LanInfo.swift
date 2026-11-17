//
//  LanInfo.swift
//  取本机局域网 IPv4
//

import Foundation

/// iOS 上"本机 IP"不能靠 hostname 解析，只能用 getifaddrs 遍历网卡。
/// 优先级参考了桌面端的 lan-ip.js：家用网段 192.168 > 10.x > 172.16-31。
enum LanInfo {
    static func currentIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }

        var candidates: [(ip: String, score: Int)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let cur = cursor {
            let ifa = cur.pointee
            cursor = ifa.ifa_next

            guard let sockAddr = ifa.ifa_addr,
                  sockAddr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ifa.ifa_name)
            if name == "lo0" { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(sockAddr,
                                 socklen_t(sockAddr.pointee.sa_len),
                                 &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }

            let ip = String(cString: host)
            let score: Int
            if ip.hasPrefix("192.168.") { score = 3 }
            else if ip.hasPrefix("10.") { score = 2 }
            else if ip.hasPrefix("172.") { score = 1 }
            else { continue }   // 169.254 / 其他一律不用

            candidates.append((ip, score))
        }

        return candidates.sorted { $0.score > $1.score }.first?.ip
    }
}
