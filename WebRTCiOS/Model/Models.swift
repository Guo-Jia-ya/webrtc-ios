//
//  Models.swift
//  与两套服务器对齐的数据结构
//

import Foundation

/// 大厅里的一行。
/// 主服务器的 lobby-state 只有 sid/userId/name/roomId/roomSize；
/// 临时服务器多一个 online（掉线宽限期里的占位行）。
struct LobbyUser: Identifiable, Hashable {
    let sid: String
    let name: String
    let userId: String?
    let roomId: String?
    let roomSize: Int
    let online: Bool

    var id: String { sid }
    var inCall: Bool { roomId != nil }

    var subtitle: String {
        if !online { return "重连中…" }
        if inCall { return "通话中 \(roomSize) 人" }
        return "空闲"
    }

    init?(json: Any?) {
        guard let d = json as? [String: Any], let sid = d["sid"] as? String else { return nil }
        self.sid = sid
        self.name = (d["name"] as? String) ?? "匿名"
        self.userId = d["userId"] as? String
        self.roomId = d["roomId"] as? String
        if let size = d["roomSize"] as? Int {
            self.roomSize = size
        } else if let n = d["roomSize"] as? NSNumber {
            self.roomSize = n.intValue
        } else {
            self.roomSize = 0
        }
        // 主服务器不发 online，缺省当作在线
        if let on = d["online"] as? Bool {
            self.online = on
        } else {
            self.online = true
        }
    }
}

struct IncomingCall {
    let callId: String
    let fromSid: String
    let fromName: String

    init?(json: Any?) {
        guard let d = json as? [String: Any],
              let callId = d["callId"] as? String else { return nil }
        self.callId = callId
        if let from = d["from"] as? [String: Any] {
            self.fromSid = (from["sid"] as? String) ?? ""
            self.fromName = (from["name"] as? String) ?? "对方"
        } else {
            self.fromSid = ""
            self.fromName = "对方"
        }
    }
}

struct JoinRequestInfo: Identifiable {
    let requestId: String
    let roomId: String
    let requesterName: String
    let size: Int
    let max: Int

    var id: String { requestId }

    init?(json: Any?) {
        guard let d = json as? [String: Any],
              let requestId = d["requestId"] as? String else { return nil }
        self.requestId = requestId
        self.roomId = (d["roomId"] as? String) ?? ""
        if let r = d["requester"] as? [String: Any] {
            self.requesterName = (r["name"] as? String) ?? "有人"
        } else {
            self.requesterName = "有人"
        }
        self.size = (d["size"] as? Int) ?? 0
        self.max = (d["max"] as? Int) ?? 4
    }
}

/// 主服务器登录返回
struct LoginResult {
    let token: String
    let name: String
    let userId: String
}

enum SessionPhase {
    case idle
    case connecting
    case inLobby
    case inCall
}
