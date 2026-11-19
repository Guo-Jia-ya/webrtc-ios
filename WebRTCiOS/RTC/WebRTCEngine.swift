//
//  WebRTCEngine.swift
//  房间内的 Mesh 通话引擎
//
//  拓扑：N 个成员两两建一条 PeerConnection（全连接）。
//  谁来发 offer？—— 以**桌面网页**为准（servers/temp/public/mesh.js）：
//  已经在房里的人收到 user-joined 后主动发起，后进来的人只回答。
//  这样任何时刻一条链路上只有一个 offer，天然避开"双方同时 offer"的 glare；
//  万一还是撞上了，handleSignal 里会把主动的一方降级成应答方兜底。
//  注意：手机当主机时用的那套裸 WebSocket 协议规则相反（新人主动 offer，见 HostedPage.swift），
//  HostRoomCall 里按那一套来。
//
//  另一个刻意的选择：**不做 trickle ICE**。
//  正常 WebRTC 是 SDP 和 ICE 候选分多条消息发，候选可能比 SDP 先到，接收方
//  还没有 remoteDescription 就会 add() 失败，表现为"连上了但没画面"，极难排查。
//  这里等 ICE 收集完成（或 2.5 秒超时）后把带候选的完整 SDP 一次发过去。
//  局域网里候选收集几乎瞬间完成，代价可以忽略。
//

import Foundation
import AVFoundation
import CoreMedia
import WebRTC

final class WebRTCEngine: NSObject {

    // MARK: 对外回调（全部在主线程）

    /// 收到某人的远端画面
    var onRemoteTrack: ((_ peerId: String, _ track: RTCVideoTrack) -> Void)?
    /// 某人离开
    var onPeerGone: ((_ peerId: String) -> Void)?
    /// 需要把 SDP 发出去：(peerId, ["sdp": ["type": .., "sdp": ..]])
    var onLocalDescription: ((_ peerId: String, _ payload: [String: Any]) -> Void)?
    /// 连接状态文字（"已连接" / "连接失败" …）
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: 内部状态

    private var factory: RTCPeerConnectionFactory?
    private var capturer: RTCCameraVideoCapturer?

    private(set) var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?

    private var peers: [String: RTCPeerConnection] = [:]
    private var peerIdOf: [ObjectIdentifier: String] = [:]
    private var pendingIce: [String: [RTCIceCandidate]] = [:]
    /// 已经发过 SDP 的 peer（避免 ICE complete 与超时定时器重复发送）
    private var descriptionSent: Set<String> = []

    private(set) var isMicOn = true
    private(set) var isCameraOn = true
    private var usingFrontCamera = true
    private var prepared = false

    // MARK: 权限

    static func requestPermissions() async -> (video: Bool, audio: Bool) {
        async let v = request(.video)
        async let a = request(.audio)
        return await (v, a)
    }

    private static func request(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: media) { ok in cont.resume(returning: ok) }
            }
        default: return false
        }
    }

    // MARK: 准备本地媒体

    func prepare() throws {
        guard !prepared else { return }
        prepared = true

        // 音频会话：不用 .voiceChat 会有明显的回声和音量过小问题
        let rtcAudio = RTCAudioSession.sharedInstance()
        rtcAudio.useManualAudio = true
        rtcAudio.isAudioEnabled = true
        let av = AVAudioSession.sharedInstance()
        try? av.setCategory(.playAndRecord, mode: .voiceChat,
                            options: [.allowBluetooth, .defaultToSpeaker])
        try? av.setActive(true)

        // 用指定初始化器，参数显式给默认编解码工厂（部分版本的 framework 不暴露无参 init）
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        let f = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
        factory = f

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        let audioSource = f.audioSource(with: constraints)
        localAudioTrack = f.audioTrack(with: audioSource, trackId: "audio0")

        let videoSource = f.videoSource()
        let cam = RTCCameraVideoCapturer(delegate: videoSource)
        capturer = cam
        localVideoTrack = f.videoTrack(with: videoSource, trackId: "video0")

        try startCapture(front: true)
    }

    private func startCapture(front: Bool) throws {
        guard let cam = capturer else { return }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == (front ? .front : .back) }) ?? devices.first else {
            throw NSError(domain: "wb.rtc", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "找不到摄像头"])
        }

        // 挑一个 640x480 附近、帧率不超过 30 的格式
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let target = formats.min { a, b in
            let da = abs(dim(a).w - 640) + abs(dim(a).h - 480) / 4
            let db = abs(dim(b).w - 640) + abs(dim(b).h - 480) / 4
            return da < db
        }
        let fps = 30

        if let format = target {
            cam.startCapture(with: device, format: format, fps: fps) { [weak self] error in
                if let error {
                    DispatchQueue.main.async { self?.onError?("摄像头启动失败：\(error.localizedDescription)") }
                }
            }
        }
        usingFrontCamera = (device.position == .front)
    }

    private func dim(_ format: AVCaptureDevice.Format) -> (w: Int32, h: Int32) {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return (d.width, d.height)
    }

    func switchCamera() {
        guard let cam = capturer else { return }
        cam.stopCapture { [weak self] in
            guard let self else { return }
            try? self.startCapture(front: !self.usingFrontCamera)
        }
    }

    // MARK: 建链

    /// - Parameter createOffer: 我是发起方（新人）时为 true
    func connect(to peerId: String, createOffer: Bool) {
        guard peers[peerId] == nil, let factory else { return }

        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        cfg.iceServers = []          // 同一局域网，主机候选直连，不需要 STUN
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: cfg, constraints: constraints, delegate: self) else { return }

        peers[peerId] = pc
        peerIdOf[ObjectIdentifier(pc)] = peerId
        descriptionSent.remove(peerId)

        if let audio = localAudioTrack { pc.add(audio, streamIds: ["stream0"]) }
        if let video = localVideoTrack { pc.add(video, streamIds: ["stream0"]) }

        if createOffer { makeOffer(peerId, pc: pc) }
    }

    private func makeOffer(_ peerId: String, pc: RTCPeerConnection) {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"],
            optionalConstraints: nil)

        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            if let error {
                self.report("创建 offer 失败：\(error.localizedDescription)")
                return
            }
            guard let sdp else { return }
            pc.setLocalDescription(sdp) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.report("setLocalDescription 失败：\(error.localizedDescription)")
                    return
                }
                self.scheduleDescription(peerId, pc: pc)
            }
        }
    }

    private func makeAnswer(_ peerId: String, pc: RTCPeerConnection) {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"],
            optionalConstraints: nil)

        pc.answer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            if let error {
                self.report("创建 answer 失败：\(error.localizedDescription)")
                return
            }
            guard let sdp else { return }
            pc.setLocalDescription(sdp) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.report("setLocalDescription(answer) 失败：\(error.localizedDescription)")
                    return
                }
                self.scheduleDescription(peerId, pc: pc)
            }
        }
    }

    /// 等 ICE 收集完成再发；同时挂一个 2.5 秒兜底，避免某些网络下永远不 complete
    private func scheduleDescription(_ peerId: String, pc: RTCPeerConnection) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak pc] in
            guard let self, let pc else { return }
            self.sendDescription(peerId, pc: pc)
        }
    }

    private func sendDescription(_ peerId: String, pc: RTCPeerConnection) {
        guard peers[peerId] != nil, !descriptionSent.contains(peerId) else { return }
        guard let sdp = pc.localDescription else { return }
        descriptionSent.insert(peerId)
        let payload: [String: Any] = [
            "sdp": ["type": (sdp.type == .offer ? "offer" : "answer"), "sdp": sdp.sdp]
        ]
        DispatchQueue.main.async { [weak self] in
            self?.onLocalDescription?(peerId, payload)
        }
    }

    // MARK: 收对端信令

    func handleSignal(from peerId: String, data: [String: Any]) {
        if let sdpDict = data["sdp"] as? [String: Any],
           let typeText = sdpDict["type"] as? String,
           let sdpText = sdpDict["sdp"] as? String {

            let desc = RTCSessionDescription(type: typeText == "offer" ? .offer : .answer, sdp: sdpText)

            if desc.type == .offer {
                // 双方同时发了 offer（glare）：谁先到谁赢，我们放弃自己那份、
                // 把自己降级成纯应答方。iOS 与桌面网页的"谁发起"规则已经对齐，
                // 正常不会再撞，但网络抖动 / 重连时仍可能撞上，这里必须兜住。
                if let existing = peers[peerId],
                   existing.signalingState == .haveLocalOffer ||
                   existing.signalingState == .haveLocalPrAnswer {
                    existing.close()
                    peers.removeValue(forKey: peerId)
                    peerIdOf.removeValue(forKey: ObjectIdentifier(existing))
                    descriptionSent.remove(peerId)
                }
                if peers[peerId] == nil { connect(to: peerId, createOffer: false) }
                guard let pc = peers[peerId] else { return }
                pc.setRemoteDescription(desc) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.report("setRemoteDescription(offer) 失败：\(error.localizedDescription)")
                        return
                    }
                    self.drainIce(peerId, into: pc)
                    self.makeAnswer(peerId, pc: pc)
                }
            } else {
                guard let pc = peers[peerId] else { return }
                pc.setRemoteDescription(desc) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.report("setRemoteDescription(answer) 失败：\(error.localizedDescription)")
                        return
                    }
                    self.drainIce(peerId, into: pc)
                }
            }
            return
        }

        // 网页端会 trickle 候选，我们虽然不是 trickle，也要能收
        if let cand = data["candidate"] as? [String: Any],
           let sdp = cand["candidate"] as? String, !sdp.isEmpty {
            let mid = cand["sdpMid"] as? String
            // JSONSerialization 给的是 NSNumber，不能直接 as? Int32
            let index = (cand["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
            let ice = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
            guard let pc = peers[peerId] else { return }
            if pc.remoteDescription != nil {
                pc.add(ice) { _ in }
            } else {
                pendingIce[peerId, default: []].append(ice)
            }
        }
    }

    private func drainIce(_ peerId: String, into pc: RTCPeerConnection) {
        guard let list = pendingIce[peerId] else { return }
        for ice in list { pc.add(ice) { _ in } }
        pendingIce[peerId] = []
    }

    // MARK: 控制

    func setMicEnabled(_ on: Bool) {
        isMicOn = on
        localAudioTrack?.isEnabled = on
    }

    func setCameraEnabled(_ on: Bool) {
        isCameraOn = on
        localVideoTrack?.isEnabled = on
        if let cam = capturer {
            if on {
                try? startCapture(front: usingFrontCamera)
            } else {
                cam.stopCapture { }
            }
        }
    }

    func removePeer(_ peerId: String) {
        if let pc = peers.removeValue(forKey: peerId) {
            peerIdOf.removeValue(forKey: ObjectIdentifier(pc))
            pc.close()
        }
        pendingIce[peerId] = nil
        descriptionSent.remove(peerId)
        DispatchQueue.main.async { [weak self] in
            self?.onPeerGone?(peerId)
        }
    }

    func teardown() {
        for (_, pc) in peers {
            peerIdOf.removeValue(forKey: ObjectIdentifier(pc))
            pc.close()
        }
        peers.removeAll()
        pendingIce.removeAll()
        descriptionSent.removeAll()
        capturer?.stopCapture { }
        capturer = nil
        localVideoTrack = nil
        localAudioTrack = nil
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        prepared = false
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCEngine: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        guard let peerId = peerIdOf[ObjectIdentifier(peerConnection)] else { return }
        let text: String
        switch newState {
        case .checking: text = "正在建立连接…"
        case .connected, .completed: text = "已连接"
        case .disconnected: text = "连接不稳定"
        case .failed: text = "连接失败"
        case .closed: text = "已断开"
        default: text = ""
        }
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("\(peerId.prefix(4))… \(text)")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        // 收集完成 —— 立刻把完整 SDP 发出去，不必等 2.5 秒兜底
        if newState == .complete,
           let peerId = peerIdOf[ObjectIdentifier(peerConnection)] {
            sendDescription(peerId, pc: peerConnection)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // 非 trickle：候选已经包含在 localDescription 里，这里不单独发
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        guard let peerId = peerIdOf[ObjectIdentifier(peerConnection)],
              let track = rtpReceiver.track as? RTCVideoTrack else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onRemoteTrack?(peerId, track)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}
}
