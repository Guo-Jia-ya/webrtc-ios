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

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var unread = 0
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

    private func ingest(_ payload: Any?) {
        guard let msg = ChatMessage(json: payload) else { return }
        // 服务端理论上不回重，但重连补发时可能出现同一 id，挡一下
        guard !messages.contains(where: { $0.id == msg.id }) else { return }
        messages.append(msg)
        if messages.count > 300 { messages.removeFirst(messages.count - 300) }
        if !visible && msg.fromSid != (mySid ?? "") { unread += 1 }
    }

    func markRead() {
        unread = 0
        visible = true
    }

    // MARK: 发送

    func sendText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        socket.emit("chat-send", ["to": "lobby", "kind": "text", "text": t])
    }

    /// 录音结束后调用：先上传，再广播一条 voice 消息
    func sendVoice(localURL: URL, duration: Double) async {
        sending = true
        defer { sending = false }
        do {
            let file = try await upload(fileURL: localURL, mime: "audio/m4a")
            socket.emit("chat-send", [
                "to": "lobby",
                "kind": "voice",
                "file": file.dict,
                "duration": duration
            ])
        } catch {
            errorText = "语音发送失败：\(error.localizedDescription)"
        }
    }

    func sendFile(localURL: URL) async {
        sending = true
        defer { sending = false }
        let name = localURL.lastPathComponent
        let mime = ChatService.mimeType(of: localURL)
        do {
            let file = try await upload(fileURL: localURL, mime: mime)
            socket.emit("chat-send", ["to": "lobby", "kind": "file", "file": file.dict])
        } catch {
            errorText = "「\(name)」发送失败：\(error.localizedDescription)"
        }
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
