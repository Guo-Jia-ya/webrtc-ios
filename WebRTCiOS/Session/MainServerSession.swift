//
//  MainServerSession.swift
//  加入主服务器：登录 → 大厅 → 呼叫 / 接听 → 去临时服务器开房间
//
//  协议要点（servers/main/）：
//    · 登录走 HTTP POST /api/login，拿 JWT（本客户端只用于展示，socket 侧不校验）
//    · 大厅与呼叫走 socket.io :3007
//    · 主服务器**不传音视频**，call-started 只回 {roomId, baseUrl}
//      → 客户端必须拿着 baseUrl 再连一次临时服务器，在那儿做 mesh-join
//  这是整个 iOS 端最容易漏的一步：只连 3007 是通不了话的。
//

import Foundation

@MainActor
final class MainServerSession: ObservableObject {

    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var lobby: [LobbyUser] = []
    @Published private(set) var myName = ""
    @Published var banner: String?
    @Published var incoming: IncomingCall?
    @Published var joinRequest: JoinRequestInfo?
    @Published var call: MeshCall?
    @Published var busy = false

    private var socket: SocketIOClient?
    private var videoSocket: SocketIOClient?
    private var endpoint: Endpoint?
    private var userId = ""

    /// 大厅里除我以外的人
    var others: [LobbyUser] {
        let mine = socket?.socketId
        return lobby.filter { $0.sid != mine }
    }

    // MARK: 登录

    func login(host: String, account: String, password: String) async {
        guard let ep = Endpoint.parse(host, defaultScheme: "http", defaultPort: 3007) else {
            banner = "服务器地址无效，示例：192.168.1.5 或 192.168.1.5:3007"
            return
        }
        guard !account.isEmpty, !password.isEmpty else {
            banner = "请填写账号和密码"
            return
        }

        busy = true
        banner = nil
        defer { busy = false }

        do {
            let result = try await MainServerAPI.login(endpoint: ep, id: account, password: password)
            endpoint = ep
            userId = result.userId
            myName = result.name
            openSocket()
        } catch {
            banner = error.localizedDescription
        }
    }

    private func openSocket() {
        guard let ep = endpoint else { return }
        socket?.close()

        let s = SocketIOClient(endpoint: ep, tag: "main")
        socket = s

        s.onConnect = { [weak self] _ in
            guard let self else { return }
            self.banner = nil
            self.phase = .inLobby
            // 重连后必须重新登记，否则别人名单里没有我
            s.emit("lobby-join", ["name": self.myName, "userId": self.userId])
        }
        s.onDisconnect = { [weak self] reason in
            self?.banner = "与主服务器的连接断开：\(reason)"
            self?.phase = .idle
        }
        s.onError = { [weak self] msg in self?.banner = msg }

        bindLobbyEvents(s)
        s.connect()
    }

    private func bindLobbyEvents(_ s: SocketIOClient) {
        s.on("lobby-state") { [weak self] payload in
            guard let self, let arr = payload as? [Any] else { return }
            let list = arr.compactMap { LobbyUser(json: $0) }
            self.lobby = LobbyUser.dedupe(list, prefer: s.socketId)
        }

        s.on("incoming-call") { [weak self] payload in
            self?.incoming = IncomingCall(json: payload)
        }

        s.on("call-started") { [weak self] payload in
            guard let self, let d = payload as? [String: Any],
                  let roomId = d["roomId"] as? String else { return }
            self.beginCall(roomId: roomId, baseUrl: (d["baseUrl"] as? String) ?? "")
        }

        s.on("join-approved") { [weak self] payload in
            guard let self, let d = payload as? [String: Any],
                  let roomId = d["roomId"] as? String else { return }
            self.beginCall(roomId: roomId, baseUrl: (d["baseUrl"] as? String) ?? "")
        }

        s.on("call-rejected") { [weak self] payload in
            let d = payload as? [String: Any]
            self?.banner = "\((d?["name"] as? String) ?? "对方")拒绝了通话"
            self?.phase = .inLobby
        }

        s.on("call-failed") { [weak self] payload in
            let d = payload as? [String: Any]
            self?.banner = (d?["reason"] as? String) ?? "呼叫失败"
            if self?.phase != .inCall { self?.phase = .inLobby }
        }

        s.on("call-cancelled") { [weak self] payload in
            let d = payload as? [String: Any]
            self?.banner = (d?["reason"] as? String) ?? "对方取消了呼叫"
            self?.incoming = nil
            self?.phase = .inLobby
        }

        // 有人想加入我正在的房间：房间里每个人都得同意
        s.on("join-request") { [weak self] payload in
            self?.joinRequest = JoinRequestInfo(json: payload)
        }

        s.on("join-cancelled") { [weak self] _ in
            self?.joinRequest = nil
        }

        s.on("peer-joining") { [weak self] payload in
            let d = payload as? [String: Any]
            self?.banner = "\((d?["name"] as? String) ?? "有人")加入了房间"
        }

        s.on("peer-offline") { [weak self] payload in
            let d = payload as? [String: Any]
            self?.banner = "\((d?["name"] as? String) ?? "对方")掉线了"
        }

        s.on("room-gone") { [weak self] payload in
            let d = payload as? [String: Any]
            self?.banner = (d?["reason"] as? String) ?? "房间已解散"
            self?.phase = .inLobby
        }
    }

    // MARK: 呼叫

    func callUser(_ user: LobbyUser) {
        guard phase == .inLobby else { return }
        socket?.emit("call-user", ["target": user.sid])
        banner = "正在呼叫 \(user.name)…"
    }

    func answerIncoming(_ accept: Bool) {
        guard let inc = incoming else { return }
        socket?.emit("call-response", ["callId": inc.callId, "accept": accept])
        incoming = nil
        if accept { phase = .connecting } else { phase = .inLobby }
    }

    func answerJoinRequest(_ accept: Bool) {
        guard let req = joinRequest else { return }
        socket?.emit("join-response", ["requestId": req.requestId, "accept": accept])
        joinRequest = nil
    }

    // MARK: 通话：连临时服务器

    private func beginCall(roomId: String, baseUrl: String) {
        // 已经在通话里就不再建第二条（call-started / join-approved 有时会先后到达）
        guard call == nil else { return }
        incoming = nil
        joinRequest = nil

        guard let ep = Endpoint.parse(baseUrl, defaultScheme: "https", defaultPort: 8080) else {
            banner = "临时服务器地址无效：\(baseUrl)"
            phase = .inLobby
            return
        }

        phase = .connecting
        videoSocket?.close()

        let vs = SocketIOClient(endpoint: ep, tag: "main-mesh")
        videoSocket = vs

        vs.onConnect = { [weak self, weak vs] _ in
            guard let self, let vs else { return }
            let call = MeshCall(socket: vs, roomId: roomId, name: self.myName, ownsSocket: true)
            call.onEnded = { [weak self] reason in
                guard let self else { return }
                self.banner = reason
                self.call = nil
                self.videoSocket = nil
                // 通知主服务器释放房间名额，否则名单里会一直显示"通话中"
                self.socket?.emit("hang-up")
                self.phase = .inLobby
            }
            self.call = call
            self.phase = .inCall
            Task { await call.start() }
        }

        vs.onError = { [weak self] msg in self?.banner = "临时服务器：\(msg)" }
        vs.onDisconnect = { [weak self] reason in
            self?.banner = "与临时服务器的连接断开：\(reason)"
        }

        vs.connect()

        // 最常见的故障：大厅那台机器没开临时服务器（8080）
        let display = ep.display
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.phase == .connecting else { return }
            self.banner = "连不上临时服务器 \(display)。请确认开大厅的那台机器上「临时服务器」已经启动。"
        }
    }

    // MARK: 离开

    func hangUp() {
        call?.hangUp()
        call = nil
        videoSocket = nil
        socket?.emit("hang-up")
        phase = .inLobby
    }

    func leave() {
        if let active = call {
            // MeshCall 自己会对 ownsSocket 的通话连接做延迟关闭（先把 hang-up 送出去）
            active.hangUp()
        } else {
            // 还在 connecting、没有 MeshCall 时，这里兜住那条连接
            videoSocket?.close()
        }
        call = nil
        videoSocket = nil
        if let s = socket {
            s.emit("lobby-leave")
            // 主服务器收到断线就立刻把人从名单里删掉，但 lobby-leave 这一帧
            // 也得有机会发出去：它同时给了服务端一个"这是正常退出"的信号。
            s.close(after: 0.3)
        }
        socket = nil
        lobby = []
        incoming = nil
        joinRequest = nil
        banner = nil
        phase = .idle
    }
}
