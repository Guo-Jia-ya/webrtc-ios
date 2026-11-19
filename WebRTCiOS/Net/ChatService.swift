//
//  ChatService.swift
//  大厅聊天：文字 / 语音 / 文件
//
//  协议与桌面网页、安卓端完全一致（见 servers/shared/chat-relay.js、chat-upload.js）：
//    发送：socket.emit("chat-send", { to: "lobby", kind: "text"|"voice"|"file",
//                                   text, file: {url,name,size,type}, duration })
//    接收：socket.on("chat-message", msg)  —— 服务器回显，自己发的也会回来一份
//    报错：socket.on("chat-error", { reason })
//    上传：POST <base><上传路径>?name=<名字>&type=<MIME>，请求体就是文件字节本身，
//          返回 { status:0, file:{ id,name,size,type,url } }
//          主服务器挂 /api/chat/upload，临时服务器挂 /chat/upload
//
//  为什么必须服务端回显、本地不抢先插入：顺序唯一，也不用去重。
//  局域网往返几毫秒，看不出来。
//

import Foundation
import Combine

struct ChatFile: Equatable {
    let url: String        // 服务器相对地址，形如 /uploads/files/2026-11-19/ab12-截图.png
    let name: String
    let size: Int
    let type: String

    var dict: [String: Any] {
        ["url": url, "name": name, "size": size, "type": type]
    }

    var sizeText: String {
        if size <= 0 { return "" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.0f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / 1024 / 1024)
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Kind: String { case text, voice, file }

    let id: String
    let ts: Date
    let kind: Kind
    let to: String
    let fromSid: String
    let fromName: String
    let text: String
    let file: ChatFile?
    let duration: Double

    init?(json: Any?) {
        guard let d = json as? [String: Any], let id = d["id"] as? String else { return nil }
        self.id = id
        // 服务器给的是毫秒时间戳
        let ms = (d["ts"] as? NSNumber)?.doubleValue ?? (Date().timeIntervalSince1970 * 1000)
        self.ts = Date(timeIntervalSince1970: ms / 1000)
        self.kind = Kind(rawValue: (d["kind"] as? String) ?? "text") ?? .text
        self.to = (d["to"] as? String) ?? "lobby"
        let from = d["from"] as? [String: Any]
        self.fromSid = (from?["sid"] as? String) ?? ""
        self.fromName = (from?["name"] as? String) ?? "对方"
        self.text = (d["text"] as? String) ?? ""
        if let f = d["file"] as? [String: Any], let u = f["url"] as? String {
            self.file = ChatFile(url: u,
                                 name: (f["name"] as? String) ?? "文件",
                                 size: (f["size"] as? NSNumber)?.intValue ?? 0,
                                 type: (f["type"] as? String) ?? "")
        } else {
            self.file = nil
        }
        self.duration = (d["duration"] as? NSNumber)?.doubleValue ?? 0
    }

    var durationText: String {
        let s = Int(duration.rounded())
        return s <= 0 ? "语音" : (s < 60 ? "\(s)″" : "\(s / 60)′\(s % 60)″")
    }

    var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: ts)
    }
}

@MainActor
final class ChatService: ObservableObject {

    /// 公共频道的会话键。私聊用 "p:<对方 sid>"，与安卓 / 网页端保持一致。
    static let LOBBY = "lobby"

    /// 会话 -> 消息（每个会话最多 100 条，只存在内存里，重连即清空）
    @Published private(set) var store: [String: [ChatMessage]] = [:]
    /// 会话 -> 未读数
    @Published private(set) var unreadMap: [String: Int] = [:]
    /// 会话 -> 显示名（私聊用对方的昵称）
    @Published private(set) var titles: [String: String] = [:]
    /// 会话出现顺序（公共频道永远排第一）
    @Published private(set) var order: [String] = []
    /// 大厅里在线的人：用来"发起私聊"，也用来给还叫不出名字的会话补昵称
    @Published private(set) var peers: [ChatPeer] = []
    /// 当前正在看的会话
    @Published var current: String = ChatService.LOBBY
    @Published private(set) var sending = false
    /// 出错时的提示（界面上弹一条灰条，不打断输入）
    @Published var errorText: String?

    /// 面板是否正在显示：显示时不累加未读
    var visible = false

    let baseURL: URL
    private let uploadPath: String
    private let socket: SocketIOClient
    private let nameProvider: () -> String

    var mySid: String? { socket.socketId }
    var myName: String { nameProvider() }

    /// 大厅角标：所有会话的未读之和
    var unread: Int { unreadMap.values.reduce(0, +) }

    init(socket: SocketIOClient,
         baseURL: URL,
         uploadPath: String,
         name: @escaping () -> String) {
        self.socket = socket
        self.baseURL = baseURL
        self.uploadPath = uploadPath
        self.nameProvider = name
        bind()
    }

    private func bind() {
        socket.on("chat-message") { [weak self] payload in
            self?.ingest(payload)
        }
        socket.on("chat-error") { [weak self] payload in
            guard let self else { return }
            let d = payload as? [String: Any]
            self.errorText = (d?["reason"] as? String) ?? "消息发送失败"
        }
    }

    // MARK: 会话

    func messages(in conv: String) -> [ChatMessage] {
        store[conv] ?? []
    }

    func unread(of conv: String) -> Int {
        unreadMap[conv] ?? 0
    }

    func title(for conv: String) -> String {
        if conv == ChatService.LOBBY { return "公共频道" }
        if let t = titles[conv], !t.isEmpty { return t }
        if conv.hasPrefix("p:") {
            let sid = String(conv.dropFirst(2))
            if let p = peers.first(where: { $0.sid == sid }) { return p.name }
            return "私聊 " + String(sid.prefix(4))
        }
        return "会话"
    }

    /// 打开一个会话：清未读、记名字，没有消息也先占一个位置
    func open(_ conv: String, title name: String? = nil) {
        current = conv
        if let name, !name.isEmpty { titles[conv] = name }
        if !order.contains(conv) { order.append(conv) }
        unreadMap[conv] = 0
        visible = true
    }

    /// 公共频道 + 已经开过的私聊（按出现顺序）
    func conversations() -> [String] {
        var out: [String] = [ChatService.LOBBY]
        for c in order where c != ChatService.LOBBY {
            if !out.contains(c) { out.append(c) }
        }
        return out
    }

    /// 大厅名单变了就同步过来：私聊列表的"在线的人"和会话昵称都靠它
    func setPeers(_ list: [ChatPeer]) {
        peers = list
        for p in list {
            let key = "p:" + p.sid
            if titles[key] == nil { titles[key] = p.name }
        }
    }

    func markRead() {
        visible = true
        unreadMap[current] = 0
    }

    private func ingest(_ payload: Any?) {
        guard let msg = ChatMessage(json: payload) else { return }
        // 服务端理论上不回重，但重连补发时可能出现同一 id，挡一下
        guard !store.values.contains(where: { list in list.contains(where: { $0.id == msg.id }) })
        else { return }

        let mine = msg.fromSid == (mySid ?? "")
        let conv: String
        if msg.to.isEmpty || msg.to == "lobby" {
            conv = ChatService.LOBBY
        } else {
            // 自己发的：to 是对方；收到的：from 是对方
            conv = "p:" + (mine ? msg.to : msg.fromSid)
        }

        var list = store[conv] ?? []
        list.append(msg)
        if list.count > 100 { list.removeFirst(list.count - 100) }
        store[conv] = list
        if !order.contains(conv) { order.append(conv) }

        if conv != ChatService.LOBBY {
            if !mine {
                titles[conv] = msg.fromName
            } else if titles[conv] == nil || titles[conv] == "私聊" {
                titles[conv] = peers.first(where: { $0.sid == msg.to })?.name
                    ?? titles[conv] ?? "私聊"
            }
        }

        if !mine && !(visible && current == conv) {
            unreadMap[conv, default: 0] += 1
        }
    }

    // MARK: 发送

    /// 当前会话对应的收件人：公共频道是 "lobby"，私聊是对方 sid
    private var sendTo: String {
        current == ChatService.LOBBY ? "lobby" : String(current.dropFirst(2))
    }

    func sendText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard validTarget() else { return }
        socket.emit("chat-send", ["to": sendTo, "kind": "text", "text": t])
    }

    /// 录音结束后调用：先上传，再广播一条 voice 消息
    func sendVoice(localURL: URL, duration: Double) async {
        guard validTarget() else { return }
        let to = sendTo
        sending = true
        defer { sending = false }
        do {
            let file = try await upload(fileURL: localURL, mime: "audio/m4a")
            socket.emit("chat-send", [
                "to": to,
                "kind": "voice",
                "file": file.dict,
                "duration": duration
            ])
        } catch {
            errorText = "语音发送失败：\(error.localizedDescription)"
        }
    }

    func sendFile(localURL: URL) async {
        guard validTarget() else { return }
        let to = sendTo
        sending = true
        defer { sending = false }
        let name = localURL.lastPathComponent
        let mime = ChatService.mimeType(of: localURL)
        do {
            let file = try await upload(fileURL: localURL, mime: mime)
            socket.emit("chat-send", ["to": to, "kind": "file", "file": file.dict])
        } catch {
            errorText = "「\(name)」发送失败：\(error.localizedDescription)"
        }
    }

    /// 私聊对象可能已经下线（sid 变了也算下线）：先在名单里核对一遍，
    /// 免得消息发出去只换来一句"对方已离线"。
    private func validTarget() -> Bool {
        guard current != ChatService.LOBBY else { return true }
        let sid = String(current.dropFirst(2))
        if peers.contains(where: { $0.sid == sid }) { return true }
        errorText = "\(title(for: current)) 已经不在大厅了，这条消息没有发出"
        return false
    }

    // MARK: 上传 / 下载

    private func upload(fileURL: URL, mime: String) async throws -> ChatFile {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw NSError(domain: "wb.chat", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "读不到这个文件"])
        }
        return try await upload(data: data, name: fileURL.lastPathComponent, mime: mime)
    }

    private func upload(data: Data, name: String, mime: String) async throws -> ChatFile {
        guard !data.isEmpty else {
            throw NSError(domain: "wb.chat", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "文件是空的"])
        }
        var comps = URLComponents(url: baseURL.appendingPathComponent(uploadPath),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "type", value: mime)
        ]
        guard let url = comps?.url else {
            throw NSError(domain: "wb.chat", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "上传地址拼不出来"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        // 服务器收的就是裸字节，不是 multipart
        req.setValue(mime.isEmpty ? "application/octet-stream" : mime,
                     forHTTPHeaderField: "Content-Type")
        req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        req.httpBody = data

        let (respData, resp) = try await SharedSession.insecure.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw NSError(domain: "wb.chat", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "服务器返回了无法解析的内容（HTTP \(code)）"])
        }
        if let status = obj["status"] as? NSNumber, status.intValue != 0 {
            let msg = (obj["message"] as? String) ?? "上传被拒绝"
            throw NSError(domain: "wb.chat", code: status.intValue,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let f = obj["file"] as? [String: Any], let u = f["url"] as? String else {
            throw NSError(domain: "wb.chat", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "服务器没有返回文件地址"])
        }
        return ChatFile(url: u,
                        name: (f["name"] as? String) ?? name,
                        size: (f["size"] as? NSNumber)?.intValue ?? data.count,
                        type: (f["type"] as? String) ?? mime)
    }

    /// 服务器给的 url 是站内相对地址，这里补上前缀
    func absoluteURL(for file: ChatFile) -> URL? {
        if file.url.hasPrefix("http://") || file.url.hasPrefix("https://") {
            return URL(string: file.url)
        }
        return URL(string: file.url, relativeTo: baseURL)?.absoluteURL
    }

    /// 下载到临时目录（自签证书走 SharedSession 的信任 delegate）
    func download(_ file: ChatFile) async -> URL? {
        guard let url = absoluteURL(for: file) else { return nil }
        do {
            let (tmp, _) = try await SharedSession.insecure.download(from: url)
            let name = file.name.isEmpty ? "chat-\(UUID().uuidString)" : file.name
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("wbc-\(UUID().uuidString.prefix(6))-\(name)")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: tmp, to: dst)
            return dst
        } catch {
            errorText = "下载失败：\(error.localizedDescription)"
            return nil
        }
    }

    static func mimeType(of url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a": return "audio/m4a"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "txt", "md": return "text/plain"
        case "mp4", "mov": return "video/mp4"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}
