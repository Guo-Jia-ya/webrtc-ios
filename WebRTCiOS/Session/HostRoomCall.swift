//
//  HostRoomCall.swift
//  "手机当主机"时，这台 iPhone 自己也以客户端身份进房间
//
//  为什么需要它：
//    LocalTempServer 说的是我们自己定的**裸 WebSocket** 协议（HostedPage.swift），
//    而「加入临时服务器」那个入口说的是 socket.io —— 所以手机开了服务器之后，
//    用 App 里的「加入临时服务器」填 127.0.0.1 是进不去的（协议都不一样）。
//    以前只能点「在本机预览页面」，让 WKWebView 去加载网页；但 WKWebView 里
//    WebSocket 的 TLS 失败走不到 navigationDelegate 的证书回调，自签证书下经常连不上。
//    这里直接用原生 URLSessionWebSocketTask + 复用 WebRTCEngine，彻底绕开 WebView。
//
//  协议（和 HostedPage.swift 里那段 JS 完全一致）：
//    客户端 → 服务器：{"t":"hello","name":…} / {"t":"signal","to":…,"data":…} / {"t":"media",…} / {"t":"bye"}
//    服务器 → 客户端：{"t":"welcome","id":…,"peers":[…]} / {"t":"peer-join",…}
//                     {"t":"peer-leave","id":…} / {"t":"signal","from":…,"data":…} / {"t":"media",…}
//  注意发 offer 的方向和桌面网页相反：**后进来的新人主动向每个已存在的人发 offer**。
//

import Foundation
import WebRTC

final class HostRoomCall: ObservableObject {

    let engine = WebRTCEngine()

    @Published private(set) var remoteTracks: [String: RTCVideoTrack] = [:]
    @Published private(set) var localTrack: RTCVideoTrack?
    @Published private(set) var status = "准备中…"
    @Published private(set) var micOn = true
    @Published private(set) var cameraOn = true
    @Published private(set) var memberCount = 1

    var onEnded: ((String) -> Void)?

    private let url: URL
    private let name: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var myId = ""
    private var started = false
    private var closed = false

    init(port: UInt16, name: String) {
        var c = URLComponents()
        c.scheme = "wss"
        c.host = "127.0.0.1"        // 自己连自己，走回环，不绕局域网
        c.port = Int(port)
        c.path = "/signal"
        self.url = c.url ?? URL(string: "wss://127.0.0.1:8080/signal")!
        self.name = name
        bindEngine()
    }

    // MARK: 引擎 → socket

    private func bindEngine() {
        engine.onLocalDescription = { [weak self] peerId, payload in
            self?.send(["t": "signal", "to": peerId, "data": payload])
        }

        engine.onRemoteTrack = { [weak self] peerId, track in
            guard let self else { return }
            // 引擎保证回调在主线程
            self.remoteTracks[peerId] = track
            self.memberCount = self.remoteTracks.count + 1
        }

        engine.onPeerGone = { [weak self] peerId in
            guard let self else { return }
            self.remoteTracks.removeValue(forKey: peerId)
            self.memberCount = self.remoteTracks.count + 1
        }

        engine.onStatus = { [weak self] text in self?.status = text }
        engine.onError = { [weak self] text in self?.status = text }
    }

    // MARK: 生命周期

    /// 必须等本地媒体准备好再 hello，否则发出去的 offer 里没有音视频轨道
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
        openSocket()
    }

    private func openSocket() {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15

        // 主机用的是自签证书，必须挂信任 delegate，否则握手直接以 -1202 失败
        let s = URLSession(configuration: .default,
                           delegate: SharedSession.delegate,
                           delegateQueue: nil)
        session = s

        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
        status = "正在连接本机服务器…"

        // 连不上时别一直转圈
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, !self.closed, self.myId.isEmpty else { return }
            self.status = "连不上本机服务器，请先点「启动服务器」"
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                if !self.closed {
                    self.status = "与服务器的连接断开：\(err.localizedDescription)"
                }
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                @unknown default:
                    break
                }
                self.receive()
            }
        }
    }

    // MARK: 协议

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["t"] as? String else { return }

        switch type {
        case "welcome":
            myId = (msg["id"] as? String) ?? ""
            let peers = (msg["peers"] as? [[String: Any]]) ?? []
            for peer in peers {
                guard let id = peer["id"] as? String else { continue }
                // 新人主动向每个已在房里的人发 offer
                engine.connect(to: id, createOffer: true)
            }
            if peers.isEmpty {
                status = "已进入房间，等待其他人加入…"
            } else {
                status = "已进入房间，正在和 \(peers.count) 人建立连接…"
            }

        case "peer-join":
            let who = (msg["name"] as? String) ?? "有人"
            status = "\(who) 加入了房间"

        case "peer-leave":
            if let id = msg["id"] as? String { engine.removePeer(id) }

        case "signal":
            guard let from = msg["from"] as? String,
                  let payload = msg["data"] as? [String: Any] else { return }
            engine.handleSignal(from: from, data: payload)

        default:
            break
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] err in
            guard let err else { return }
            DispatchQueue.main.async {
                self?.status = "发送失败：\(err.localizedDescription)"
            }
        }
    }

    // MARK: 控制

    func toggleMic() {
        micOn.toggle()
        engine.setMicEnabled(micOn)
        send(["t": "media", "audio": micOn, "video": cameraOn])
    }

    func toggleCamera() {
        cameraOn.toggle()
        engine.setCameraEnabled(cameraOn)
        send(["t": "media", "audio": micOn, "video": cameraOn])
    }

    func switchCamera() {
        engine.switchCamera()
    }

    /// 主动离开：先 bye（服务器据此广播 peer-leave），再关本地
    func hangUp() {
        closed = true
        send(["t": "bye"])
        engine.teardown()

        let t = task
        task = nil
        // 让 bye 先送出去再断
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            t?.cancel(with: .normalClosure, reason: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.session?.invalidateAndCancel()
            self?.session = nil
        }
        started = false
    }

    private func finish(_ reason: String) {
        closed = true
        engine.teardown()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        started = false
        onEnded?(reason)
    }
}
