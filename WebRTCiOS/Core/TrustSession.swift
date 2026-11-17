//
//  TrustSession.swift
//  自签证书信任
//

import Foundation

/// 临时服务器用的是自签证书（桌面端 certs/cert.pem 也是自签）。
/// iOS 默认会以 -1202（证书不受信任）直接拒绝连接，
/// 所以凡是访问 8080 的 URLSession 都必须挂上这个 delegate。
final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum SharedSession {
    /// delegate 必须被强引用持有，否则 URLSession 会丢回调
    static let delegate = TrustAllDelegate()

    static let insecure: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }()
}
