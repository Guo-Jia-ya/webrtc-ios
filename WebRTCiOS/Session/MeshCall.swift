//
//  MeshCall.swift
//  把"一个 socket + 一个房间"接成一次通话
//
//  主服务器和临时服务器最终都走到这里：
//  主服务器只给 roomId 和临时服务器地址，客户端自己连过去开房间；
//  临时服务器上是同一个 socket 既当大厅又当信令通道。
//  两条路的 mesh 事件完全一样（offer / answer / ice-candidate / user-list / peer-left）。
//

import Foundation
import WebRTC

final class MeshCall: ObservableObject {

    let roomId: String
    let engine = WebRTCEngine()

    @Published private(set) var remoteTracks: [String: RTCVideoTrack] = [:]
    @Published private(set) var localTrack: RTCVideoTrack?
    @Published private(set) var status = "准备中…"
    @Published private(set) var micOn = true
    @Published private(set) var cameraOn = true
    @Published private(set) var memberCount = 1

    /// 通话结束（原因）
    var onEnded: ((String) -> Void)?

    private let socket: SocketIOClient
    private let name: String
    /// 这条 socket 是不是专为本次通话新建的。
    /// 临时服务器的场景下大厅和信令是同一个 socket，挂断时绝不能关掉它，
    /// 否则人会从大厅里一起消失。
    private let ownsSocket: Bool
    private var started = false

    init(socket: SocketIOClient, roomId: String, name: String, ownsSocket: Bool) {
        self.socket = socket
        self.roomId = roomId
        self.name = name
        self.ownsSocket = ownsSocket
        bindEngine()
        bindSocket()
    }

    // MARK: 引擎 → socket

    private func bindEngine() {
        engine.onLocalDescription = { [weak self] peerId, payload in
            guard let self else { return }
            let sdp = (payload["sdp"] as? [String: Any]) ?? [:]
            let type = (sdp["type"] as? String) ?? "offer"
            if type == "offer" {
                self.socket.emit("offer", ["to": peerId, "offer": sdp])
            } else {
                self.socket.emit("answer", ["to": peerId, "answer": sdp])
            }
        }

        engine.onRemoteTrack = { [weak self] peerId, track in
            self?.remoteTracks[peerId] = track
            self?.memberCount = (self?.remoteTracks.count ?? 0) + 1
        }

        engine.onPeerGone = { [weak self] peerId in
            self?.remoteTracks.removeValue(forKey: peerId)
            self?.memberCount = (self?.remoteTracks.count ?? 0) + 1
        }

        engine.onStatus = { [weak self] text in
            self?.status = text
        }

        engine.onError = { [weak self] text in
            self?.status = text
        }
    }

    // MARK: socket → 引擎

    private func bindSocket() {
        socket.on("joined") { [weak self] _ in
            self?.status = "已进入房间"
        }

        // 房间里已有的人：我作为新人主动给每个人发 offer
        socket.on("user-list") { [weak self] payload in
            guard let self, let ids = payload as? [String] else { return }
            for id in ids where id != self.socket.socketId {
                self.engine.connect(to: id, createOffer: true)
            }
            self.memberCount = ids.count + 1
        }

        socket.on("user-joined") { [weak self] payload in
            // 新人会主动发 offer 过来，这里只更新人数，不主动建链
            guard let self else { return }
            if let d = payload as? [String: Any], let id = d["peerId"] as? String,
               id != self.socket.socketId {
                self.status = "有人加入，等待对方建立连接…"
            }
        }

        socket.on("offer") { [weak self] payload in
            guard let self,
                  let d = payload as? [String: Any],
                  let from = d["from"] as? String,
                  let sdp = d["offer"] as? [String: Any] else { return }
            self.engine.handleSignal(from: from, data: ["sdp": sdp])
        }

        socket.on("answer") { [weak self] payload in
            guard let self,
                  let d = payload as? [String: Any],
                  let from = d["from"] as? String,
                  let sdp = d["answer"] as? [String: Any] else { return }
            self.engine.handleSignal(from: from, data: ["sdp": sdp])
        }

        socket.on("ice-candidate") { [weak self] payload in
            guard let self,
                  let d = payload as? [String: Any],
                  let from = d["from"] as? String,
                  let cand = d["candidate"] as? [String: Any] else { return }
            self.engine.handleSignal(from: from, data: ["candidate": cand])
        }

        socket.on("peer-left") { [weak self] payload in
            guard let self else { return }
            guard let d = payload as? [String: Any],
                  let peerId = d["peerId"] as? String else { return }
            self.engine.removePeer(peerId)
            let reason = (d["reason"] as? String) ?? "left"
            self.status = (reason == "offline") ? "对方掉线了" : "对方离开了"
        }

        socket.on("room-full") { [weak self] payload in
            let d = payload as? [String: Any]
            let max = (d?["max"] as? Int) ?? 4
            self?.finish("房间已满（最多 \(max) 人）")
        }

        socket.on("room-missing") { [weak self] _ in
            self?.finish("房间已解散")
        }

        socket.on("call-failed") { [weak self] payload in
            let d = payload as? [String: Any]
            self?.finish((d?["reason"] as? String) ?? "通话失败")
        }
    }

    // MARK: 生命周期

    /// 必须等本地媒体准备好再 join，否则发出去的 offer 里没有音视频轨道
    func start() async {
        let perm = await WebRTCEngine.requestPermissions()
        guard perm.video && perm.audio else {
            finish(!perm.video && !perm.audio
                   ? "没有摄像头和麦克风权限，请到设置里打开"
                   : (!perm.video ? "没有摄像头权限" : "没有麦克风权限"))
            return
        }
        do {
            try engine.prepare()
        } catch {
            finish("本地媒体初始化失败：\(error.localizedDescription)")
            return
        }
        localTrack = engine.localVideoTrack
        guard !started else { return }
        started = true
        socket.emit("mesh-join", [
            "roomId": roomId,
            "owner": socket.socketId ?? "",
            "name": name
        ])
    }

    func toggleMic() {
        micOn.toggle()
        engine.setMicEnabled(micOn)
        socket.emit("media-state", ["audio": micOn, "video": cameraOn])
    }

    func toggleCamera() {
        cameraOn.toggle()
        engine.setCameraEnabled(cameraOn)
        socket.emit("media-state", ["audio": micOn, "video": cameraOn])
    }

    func switchCamera() {
        engine.switchCamera()
    }

    /// 主动挂断：先告诉服务器释放名额，再关本地
    func hangUp() {
        socket.emit("hang-up")
        engine.teardown()
        if ownsSocket { socket.close() }
        started = false
    }

    private func finish(_ reason: String) {
        engine.teardown()
        if ownsSocket { socket.close() }
        started = false
        onEnded?(reason)
    }
}
