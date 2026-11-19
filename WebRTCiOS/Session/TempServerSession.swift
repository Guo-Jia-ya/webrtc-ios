//
//  TempServerSession.swift
//  加入临时服务器：一个 socket 同时当"大厅"和"信令通道"
//
//  和主服务器最大的区别：临时服务器自己带 mesh 信令，所以不需要第二条连接。
//  代价是挂断时**不能关这个 socket**（关了人就掉出大厅了），
//  MeshCall 的 ownsSocket 参数就是为这件事准备的。
//

import Foundation

@MainActor
final class TempServerSession: ObservableObject {

    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var lobby: [LobbyUser] = []
    @Published private(set) var myName = ""
    @Published var banner: String?
    @Published var incoming: IncomingCall?
    @Published var joinRequest: JoinRequestInfo?
    @Published var call: MeshCall?
    @Published var busy = false
    /// 大厅聊天（文字 / 语音 / 文件）。socket 建好之后才有。
    @Published private(set) var chat: ChatService?

    private var socket: SocketIOClient?
    private var endpoint: Endpoint?
    /// 我刚点了"呼叫"的那个人。
    /// 用来兜底：万一 call-started 因为掉线重连／事件丢失没收到，
    /// 从大厅名单里看出对方已经进房了，就自己跟进去，否则主叫会永远卡在大厅。
    private var pendingCallSid: String?
    /// 我呼叫时对方是不是空闲的。
    /// 只有"对方原本空闲、接听后新开房间"这种情况才允许兜底自动进房；
    /// 对方本来就在房间里（走的是"加入申请"，需要房间里每个人同意），绝不能自动跳进去。
    private var pendingCallWasFree = false

    var others: [LobbyUser] {
        let mine = socket?.socketId
        return lobby.filter { $0.sid != mine }
    }

    // MARK: 进大厅

    func join(host: String, name: String) {
        guard let ep = Endpoint.parse(host, defaultScheme: "https", defaultPort: 8080) else {
            banner = "地址无效，示例：192.168.1.5 或 192.168.1.5:8080"
            return
        }
        let nick = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty else {
            banner = "请先填一个昵称"
            return
        }

        endpoint = ep
        myName = nick
        banner = nil
        busy = true

        // 旧连接先"打个招呼"再走：只是 close 的话服务端可能要等到 pingTimeout
        // 才发现这人走了，期间用同一个昵称重新进来就并排多出一栏。
        if let old = socket {
            old.emit("lobby-leave")
            old.close(after: 0.35)
        }
        let s = SocketIOClient(endpoint: ep, tag: "temp")
        socket = s
        chat = ChatService(socket: s,
                           baseURL: ep.baseURL,
                           uploadPath: "/chat/upload",
                           name: { nick })

        s.onConnect = { [weak self] _ in
            guard let self else { return }
            self.busy = false
            self.phase = .inLobby
            s.emit("lobby-join", ["name": nick])
        }
        s.onDisconnect = { [weak self] reason in
            // 掉线不把人踢回填入页：socket.io 会自己重连，重连成功后 onConnect 里重新登记
            guard let self else { return }
            self.busy = false
            self.banner = "连接断开，正在重连…（\(reason)）"
        }
        s.onError = { [weak self] msg in
            self?.banner = msg
            self?.busy = false
        }

        bind(s)
        s.connect()
    }

    private func bind(_ s: SocketIOClient) {
        s.on("lobby-state") { [weak self] payload in
            guard let self, let arr = payload as? [Any] else { return }
            let list = arr.compactMap { LobbyUser(json: $0) }
            self.lobby = LobbyUser.dedupe(list, prefer: s.socketId)
            self.selfHealCall(list)
        }

        s.on("incoming-call") { [weak self] payload in
            self?.incoming = IncomingCall(json: payload)
        }

        s.on("call-started") { [weak self] payload in
            guard let self, let d = payload as? [String: Any],
                  let roomId = d["roomId"] as? String else { return }
            self.beginMesh(roomId: roomId)
        }

        // 点了一个"通话中"的人 → 房间里每个人都同意之后，服务端只回给申请人这一条。
        // 少了它，加入别人房间这条路就永远走不到 mesh-join。
        s.on("join-approved") { [weak self] payload in
            guard let self, let d = payload as? [String: Any],
                  let roomId = d["roomId"] as? String else { return }
            self.beginMesh(roomId: roomId)
        }

        s.on("call-rejected") { [weak self] payload in
            let d = payload as? [String: Any]
            self?.pendingCallSid = nil
            self?.pendingCallWasFree = false
            self?.banner = "\((d?["name"] as? String) ?? "对方")拒绝了通话"
            self?.phase = .inLobby
        }

        s.on("call-failed") { [weak self] payload in
            let d = payload as? [String: Any]
            self?.pendingCallSid = nil
            self?.pendingCallWasFree = false
            self?.banner = (d?["reason"] as? String) ?? "呼叫失败"
            if self?.phase == .connecting { self?.phase = .inLobby }
        }

        s.on("join-request") { [weak self] payload in
            self?.joinRequest = JoinRequestInfo(json: payload)
        }

        s.on("join-cancelled") { [weak self] _ in
            self?.joinRequest = nil
        }

        s.on("peer-joining") { [weak self] payload in
            let d = payload as? [String: Any]
            self?.banner = "\((d?["name"] as? String) ?? "有人")正在加入…"
        }
    }

    // MARK: 呼叫

    func callUser(_ user: LobbyUser) {
        guard phase == .inLobby else { return }
        pendingCallSid = user.sid
        pendingCallWasFree = !user.inCall
        socket?.emit("call-user", ["target": user.sid])
        banner = "正在呼叫 \(user.name)…"
    }

    func answerIncoming(_ accept: Bool) {
        guard let inc = incoming else { return }
        socket?.emit("call-response", ["callId": inc.callId, "accept": accept])
        incoming = nil
        phase = accept ? .connecting : .inLobby
    }

    func answerJoinRequest(_ accept: Bool) {
        guard let req = joinRequest else { return }
        socket?.emit("join-response", ["requestId": req.requestId, "accept": accept])
        joinRequest = nil
    }

    // MARK: 通话：在同一个 socket 上开房间

    /// 主叫兜底。
    ///
    /// 正常流程是"接听后服务器给双方各发一条 call-started"。但主叫这一侧还可能
    /// 因为别的原因收不到那条消息（典型是这期间 socket 抖了一下、重连换了 sid，
    /// 服务器那条消息就发到了旧 sid 上）。表现就是：被叫已经进房了，主叫还停在
    /// 大厅名单里，怎么点都没反应。
    /// 大厅快照里带着每个人的 roomId，所以主叫可以自己看出来"对方已经进房"，
    /// 直接跟进去，不依赖那条丢失的事件。
    private func selfHealCall(_ list: [LobbyUser]) {
        guard phase == .inLobby, pendingCallWasFree, let target = pendingCallSid else { return }
        guard let row = list.first(where: { $0.sid == target }),
              let roomId = row.roomId, !roomId.isEmpty else { return }
        pendingCallSid = nil
        pendingCallWasFree = false
        banner = "对方已接通，正在进入房间…"
        beginMesh(roomId: roomId)
    }

    private func beginMesh(roomId: String) {
        guard let s = socket else { return }
        // 已经在通话里就不要再建一条（call-started / join-approved 有可能先后都到）
        guard call == nil else { return }
        pendingCallSid = nil
        pendingCallWasFree = false
        incoming = nil
        joinRequest = nil

        let call = MeshCall(socket: s, roomId: roomId, name: myName, ownsSocket: false)
        call.onEnded = { [weak self] reason in
            guard let self else { return }
            self.banner = reason
            self.call = nil
            self.phase = .inLobby
        }
        self.call = call
        phase = .inCall
        Task { await call.start() }
    }

    func hangUp() {
        call?.hangUp()
        call = nil
        // socket 留着——大厅还要用
        phase = .inLobby
    }

    func leave() {
        call?.hangUp()
        call = nil
        if let s = socket {
            s.emit("lobby-leave")
            // 等 lobby-leave 真正发出去再断，否则服务端只看到断线，
            // 名单里这一行要等 20 秒宽限期才消失，期间同名重进就是两栏。
            s.close(after: 0.35)
        }
        socket = nil
        chat = nil
        pendingCallSid = nil
        lobby = []
        incoming = nil
        joinRequest = nil
        banner = nil
        phase = .idle
    }
}
