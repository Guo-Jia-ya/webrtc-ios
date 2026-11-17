//
//  Endpoint.swift
//  服务器地址归一化
//

import Foundation

/// 用户在输入框里可能填很多种样子，这里统一成一个可用的 baseURL：
///   "192.168.1.5"            → http://192.168.1.5:3007（主服务器默认）
///   "192.168.1.5:8080"       → http://192.168.1.5:8080
///   "http://192.168.1.5:3007/" → 同上，去掉多余路径
///   "https://192.168.1.5"    → https://192.168.1.5:8080
struct Endpoint: Equatable {
    let scheme: String   // http / https
    let host: String
    let port: Int

    var baseURL: URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.port = port
        return c.url ?? URL(string: "http://127.0.0.1")!
    }

    var display: String { "\(scheme)://\(host):\(port)" }

    /// - Parameters:
    ///   - defaultScheme: 没写协议时用哪个（主服务器 http，临时服务器 https）
    ///   - defaultPort:   没写端口时用哪个
    static func parse(_ raw: String, defaultScheme: String, defaultPort: Int) -> Endpoint? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        var scheme = defaultScheme
        if let r = s.range(of: "://") {
            scheme = String(s[s.startIndex..<r.lowerBound]).lowercased()
            s = String(s[r.upperBound...])
        }

        // 去掉路径部分（用户可能直接粘贴 http://ip:3007/HomePage.html）
        if let slash = s.firstIndex(of: "/") {
            s = String(s[s.startIndex..<slash])
        }

        var host = s
        var port = defaultPort
        if let colon = s.lastIndex(of: ":") {
            let portText = String(s[s.index(after: colon)...])
            if let n = Int(portText), n > 0, n <= 65535 {
                port = n
                host = String(s[s.startIndex..<colon])
            }
        }

        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        guard scheme == "http" || scheme == "https" else { return nil }
        return Endpoint(scheme: scheme, host: host, port: port)
    }

    /// socket.io 的 WebSocket 地址
    func socketIOURL() -> URL {
        var c = URLComponents()
        c.scheme = (scheme == "https") ? "wss" : "ws"
        c.host = host
        c.port = port
        c.path = "/socket.io/"
        c.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket")
        ]
        return c.url ?? baseURL
    }
}
