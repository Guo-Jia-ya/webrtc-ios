//
//  LocalTempServer.swift
//  在 iPhone 上跑一个临时服务器（HTTPS + WebSocket 信令 + 内嵌页面）
//
//  为什么必须要 HTTPS：
//    浏览器只在"安全上下文"（https 或 localhost）里允许 getUserMedia。
//    用 http://192.168.x.x:8080 打开，摄像头和麦克风会被直接禁用——
//    桌面版的临时服务器当年就是为了这个才配自签证书的，这里同理。
//
//  为什么别人用浏览器打开时会看到"证书不安全"：
//    手机上的证书是自签的（certs/temp-identity.p12），任何浏览器都不认识这个 CA。
//    只能点"高级 → 继续前往"。桌面版也一样。
//
//  iOS 的限制（桌面版没有）：
//   · 只能前台运行。切到别的 App，系统会在几十秒内挂起进程，连接全断。
//   · 第一次会弹"本地网络"权限，用户必须允许。
//

import Foundation
import Network
import Security
import CryptoKit

final class LocalTempServer: ObservableObject {

    struct Member: Identifiable, Hashable {
        let id: String
        let name: String
        var display: String { name.isEmpty ? "未命名" : name }
    }

    @Published private(set) var running = false
    @Published private(set) var port: UInt16 = 8080
    @Published private(set) var members: [Member] = []
    @Published private(set) var statusText = "未启动"
    @Published private(set) var logs: [String] = []

    /// 对方要打开的地址
    var address: String {
        let ip = LanInfo.currentIPv4() ?? "127.0.0.1"
        return "https://\(ip):\(port)/"
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "wb.local-temp-server")
    private var peers: [String: Peer] = [:]

    private final class Peer {
        let id: String
        let conn: NWConnection
        var buffer = Data()
        var upgraded = false
        var name = ""

        init(id: String, conn: NWConnection) {
            self.id = id
            self.conn = conn
        }
    }

    // MARK: - 生命周期

    func start(port: UInt16 = 8080) throws {
        stop()
        self.port = port

        let tls = NWProtocolTLS.Options()
        if let identity = Self.loadIdentity(),
           let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        } else {
            append("⚠️ 未能加载 temp-identity.p12，HTTPS 握手会失败")
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "wb.server", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "端口号无效"])
        }

        let l = try NWListener(using: params, on: nwPort)
        l.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.running = true
                    self.statusText = "已启动，等待其他人加入"
                    self.append("监听 \(port) 成功")
                case .failed(let error):
                    self.running = false
                    self.statusText = "启动失败：\(error.localizedDescription)"
                    self.append("监听失败：\(error.localizedDescription)")
                case .cancelled:
                    self.running = false
                    self.statusText = "已停止"
                default:
                    break
                }
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.start(queue: queue)
        listener = l

        statusText = "正在启动…"
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            guard let self else { return }
            for (_, peer) in self.peers { peer.conn.cancel() }
            self.peers.removeAll()
            DispatchQueue.main.async {
                self.members = []
                self.running = false
            }
        }
    }

    // MARK: - 连接

    private func accept(_ conn: NWConnection) {
        let peer = Peer(id: Self.randomId(), conn: conn)
        peers[peer.id] = peer

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.drop(peer.id, reason: "连接结束")
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(peer)
    }

    private func receive(_ peer: Peer) {
        peer.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                peer.buffer.append(data)
                self.process(peer)
            }
            if error != nil || isComplete {
                self.drop(peer.id, reason: "对端关闭")
                return
            }
            self.receive(peer)
        }
    }

    // MARK: - HTTP / WebSocket 分流

    private func process(_ peer: Peer) {
        if !peer.upgraded {
            guard let split = Self.findHeaderEnd(peer.buffer) else {
                if peer.buffer.count > 32 * 1024 {
                    drop(peer.id, reason: "请求头过大")
                }
                return
            }
            let headData = peer.buffer.subdata(in: split.head)
            peer.buffer.removeSubrange(split.all)

            guard let head = String(data: headData, encoding: .utf8) else {
                drop(peer.id, reason: "无法解析请求")
                return
            }
            handleHTTP(peer, head: head)

            // 普通 HTTP 请求处理完就关掉连接，没有后续帧可读
            guard peer.upgraded else { return }
        }
        drainFrames(peer)
    }

    private func handleHTTP(_ peer: Peer, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            drop(peer.id, reason: "空请求")
            return
        }
        let parts = requestLine.split(separator: " ")
        let path = parts.count >= 2 ? String(parts[1]) : "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if let upgrade = headers["upgrade"], upgrade.lowercased() == "websocket" {
            performUpgrade(peer, key: headers["sec-websocket-key"] ?? "")
            return
        }

        let cleanPath = path.split(separator: "?").first.map(String.init) ?? path
        if cleanPath == "/" || cleanPath == "/index.html" {
            let body = Data(HostedPage.html.utf8)
            send(peer, Self.httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: body))
        } else if cleanPath == "/favicon.ico" {
            send(peer, Self.httpResponse(status: "204 No Content", contentType: nil, body: Data()))
        } else {
            let body = Data("404 Not Found".utf8)
            send(peer, Self.httpResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: body))
        }
        append("\(peer.name.isEmpty ? "浏览器" : peer.name) 请求 \(cleanPath)")
    }

    private func performUpgrade(_ peer: Peer, key: String) {
        let accept = Self.acceptKey(key)
        // 这里必须拼字符串而不是用多行字符串字面量：
        // Swift 会吃掉 """ 前面那个换行，末尾就少一个 \n，握手直接失败。
        var response = "HTTP/1.1 101 Switching Protocols\r\n"
        response += "Upgrade: websocket\r\n"
        response += "Connection: Upgrade\r\n"
        response += "Sec-WebSocket-Accept: \(accept)\r\n"
        response += "\r\n"

        send(peer, Data(response.utf8))
        peer.upgraded = true
    }

    private func drainFrames(_ peer: Peer) {
        while let frame = WebSocketFrame.decode(from: &peer.buffer) {
            switch frame.opcode {
            case .text:
                handleText(peer, String(decoding: frame.payload, as: UTF8.self))
            case .ping:
                sendFrame(peer, opcode: .pong, payload: frame.payload)
            case .close:
                drop(peer.id, reason: "对方关闭连接")
                return
            default:
                break
            }
        }
    }

    // MARK: - 信令协议

    private func handleText(_ peer: Peer, _ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["t"] as? String else { return }

        switch type {
        case "hello":
            peer.name = (msg["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if peer.name.isEmpty { peer.name = "访客" }

            let existing = peers.values
                .filter { $0.id != peer.id && $0.upgraded && !$0.name.isEmpty }
                .map { ["id": $0.id, "name": $0.name] }

            sendJSON(peer, ["t": "welcome", "id": peer.id, "peers": existing])
            broadcast(["t": "peer-join", "id": peer.id, "name": peer.name], except: peer.id)
            publishMembers()
            append("\(peer.name) 进入房间")

        case "signal":
            guard let to = msg["to"] as? String, let target = peers[to] else { return }
            sendJSON(target, ["t": "signal", "from": peer.id, "data": msg["data"] ?? [:] ])

        case "media":
            broadcast(["t": "media",
                       "from": peer.id,
                       "audio": (msg["audio"] as? Bool) ?? true,
                       "video": (msg["video"] as? Bool) ?? true],
                      except: peer.id)

        case "bye":
            drop(peer.id, reason: "主动离开")

        default:
            break
        }
    }

    private func drop(_ id: String, reason: String) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.conn.cancel()

        if !peer.name.isEmpty {
            broadcast(["t": "peer-leave", "id": id], except: id)
            append("\(peer.name) 离开：\(reason)")
        }
        publishMembers()
    }

    private func publishMembers() {
        let list = peers.values
            .filter { $0.upgraded && !$0.name.isEmpty }
            .map { Member(id: $0.id, name: $0.name) }
            .sorted { $0.name < $1.name }
        DispatchQueue.main.async { [weak self] in
            self?.members = list
        }
    }

    // MARK: - 发送

    private func sendJSON(_ peer: Peer, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        sendFrame(peer, opcode: .text, payload: data)
    }

    private func sendFrame(_ peer: Peer, opcode: WebSocketFrame.Opcode, payload: Data) {
        let frame = WebSocketFrame.encode(opcode: opcode, payload: payload)
        peer.conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func broadcast(_ object: [String: Any], except id: String) {
        for (peerId, peer) in peers where peerId != id && peer.upgraded {
            sendJSON(peer, object)
        }
    }

    private func send(_ peer: Peer, _ data: Data) {
        peer.conn.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - 工具

    private func append(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logs.append(line)
            if self.logs.count > 40 { self.logs.removeFirst(self.logs.count - 40) }
        }
    }

    private static func randomId() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    private static func findHeaderEnd(_ data: Data) -> (head: Range<Int>, all: Range<Int>)? {
        guard let r = data.range(of: Data([13, 10, 13, 10])) else { return nil }
        return (0..<r.lowerBound, 0..<r.upperBound)
    }

    private static func httpResponse(status: String, contentType: String?, body: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Connection: close\r\n"
        head += "Cache-Control: no-store\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    /// Sec-WebSocket-Accept = base64(SHA1(key + 固定 GUID))
    private static func acceptKey(_ key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func loadIdentity() -> SecIdentity? {
        guard let url = Bundle.main.url(forResource: "temp-identity", withExtension: "p12"),
              let data = try? Data(contentsOf: url) else { return nil }

        let options = [kSecImportExportPassphrase as String: "webrtc"] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identity = first[kSecImportItemIdentity as String] else { return nil }
        return (identity as! SecIdentity)
    }
}
