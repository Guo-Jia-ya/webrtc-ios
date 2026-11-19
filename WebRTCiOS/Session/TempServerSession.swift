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

    private var socket: SocketIOClient?
    private var endpoint: Endpoint?

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

        s.onConnect = { [weak self] _ in
            guard let self else { return }
            self.busy = false
            self.phase = .inLobby
            s.emit("lobby-join", ["name": nick])
        }
        s.onDisconnect = { [weak self] reason in
            self?.banner = "与临时服务器的连接断开：\(reason)"
            self?.phase = .idle
            self?.busy = false
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
            self?.banner = "\((d?["name"] as? String) ?? "对方")拒绝了通话"
            self?.phase = .inLobby
        }

        s.on("call-failed") { [weak self] payload in
            let d = payload as? [String: Any]
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

    private func beginMesh(roomId: String) {
        guard let s = socket else { return }
        // 已经在通话里就不要再建一条（call-started / join-approved 有可能先后都到）
        guard call == nil else { return }
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
        lobby = []
        incoming = nil
        joinRequest = nil
        banner = nil
        phase = .idle
    }
}
