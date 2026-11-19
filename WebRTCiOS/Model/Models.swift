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

    /// 按昵称去重。
    ///
    /// 服务端的大厅名单以 socket id 为键。同一个昵称连续进出几次，如果前一条连接
    /// 断得慢（客户端 emit 了 lobby-leave 但没等它发出去就 cancel，或者上一条 socket
    /// 还在 20 秒宽限期里），名单里就会并排出现两三个同名栏。
    /// 这里在客户端再兜一层：同名只留一行，优先"在线"的、其次是新连接、最后才是自己那条。
    static func dedupe(_ list: [LobbyUser], prefer sid: String?) -> [LobbyUser] {
        var result: [LobbyUser] = []
        var indexOf: [String: Int] = [:]

        for user in list {
            guard let idx = indexOf[user.name] else {
                indexOf[user.name] = result.count
                result.append(user)
                continue
            }
            let old = result[idx]
            if user.sid == sid {
                result[idx] = user                   // 我自己那条永远算数
            } else if old.sid == sid {
                continue                             // 别把"我"覆盖掉
            } else if user.online && !old.online {
                result[idx] = user                   // 在线的优先于"重连中"的
            } else if user.online == old.online {
                result[idx] = user                   // 同状态取后到的（更新的连接）
            }
        }
        return result
    }
}

/// 能私聊的对象（聊天面板「发起私聊」用）。
/// 私聊在服务端是按 socket id 转发的，所以这里只留 sid 和昵称。
struct ChatPeer: Identifiable, Hashable {
    let sid: String
    let name: String
    var id: String { sid }
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
