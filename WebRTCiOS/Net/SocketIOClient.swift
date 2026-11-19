//
//  SocketIOClient.swift
//  精简版 socket.io v4 客户端（engine.io v4 over WebSocket）
//
//  为什么要自己写：
//    桌面端两套服务器都用 socket.io（main/app.js、temp/server.js），
//    而 Swift 生态里没有官方客户端。这里只用到"连上 / 收事件 / 发事件 / 心跳"，
//    手写两百行比拉一个第三方库更可控，也少一层依赖。
//
//  协议速查（对着 Chrome 抓包就能核对）：
//    连接：GET /socket.io/?EIO=4&transport=websocket
//    ① 服务端 → 0{"sid":..,"pingInterval":25000,"pingTimeout":20000}
//    ② 客户端 → 40                     （进入默认命名空间）
//    ③ 服务端 → 40{"sid":"<socket id>"}  ← 这个 sid 就是 socket.id，后面要用
//    ④ 心跳：v4 是**服务端**发 2，客户端回 3
//    ⑤ 事件：42["事件名", 数据]，两个方向都是这个格式
//    ⑥ 错误：44{...}；服务端主动断开：41
//
//  注意：桌面端给 socket.io 设的是 `transports: ['websocket']` 等价的用法，
//  这里也强制 websocket，不走 polling 升级，省掉一整套握手。
//

import Foundation

final class SocketIOClient {

    typealias Handler = (Any?) -> Void

    private let url: URL
    private let tag: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var handlers: [String: [Handler]] = [:]

    private let lock = NSLock()
    private var queued: [String] = []          // 未连上时暂存的报文
    private var closedByUser = false
    private var reconnectAttempt = 0
    private let maxReconnect = 5

    private(set) var socketId: String?
    private(set) var isConnected = false

    /// 连上（含重连成功）时回调，参数是 socket.id。重连后要重新 join 大厅。
    var onConnect: ((String?) -> Void)?
    /// 断开时回调，参数是原因
    var onDisconnect: ((String) -> Void)?
    /// 协议层错误（比如 44 包）
    var onError: ((String) -> Void)?

    init(endpoint: Endpoint, tag: String) {
        self.url = endpoint.socketIOURL()
        self.tag = tag
    }

    deinit {
        closedByUser = true
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - 事件注册

    func on(_ event: String, _ handler: @escaping Handler) {
        lock.lock()
        handlers[event, default: []].append(handler)
        lock.unlock()
    }

    // MARK: - 连接

    func connect() {
        closedByUser = false
        openSocket()
    }

    private func openSocket() {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15

        // 临时服务器是自签证书，必须挂信任 delegate
        let s = URLSession(configuration: .default,
                           delegate: SharedSession.delegate,
                           delegateQueue: nil)
        session = s

        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.handleDrop("连接中断：\(err.localizedDescription)")
            case .success(let message):
                switch message {
                case .string(let text):
                    self.ingest(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.ingest(text) }
                @unknown default:
                    break
                }
                self.receive()
            }
        }
    }

    // MARK: - 协议解析

    private func ingest(_ text: String) {
        guard let first = text.first else { return }
        switch first {
        case "0":
            // engine.io 握手完成 → 请求进入默认命名空间
            rawSend("40")
        case "2":
            // 服务端 ping → 必须回 pong，否则 25 秒后会被判定超时
            rawSend("3")
        case "3":
            break
        case "4":
            parsePacket(String(text.dropFirst()))
        default:
            break
        }
    }

    private func parsePacket(_ s: String) {
        guard let type = s.first else { return }
        let body = String(s.dropFirst())

        switch type {
        case "0":   // 命名空间连接成功
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = obj["sid"] as? String {
                socketId = sid
            }
            lock.lock()
            isConnected = true
            reconnectAttempt = 0
            let pending = queued
            queued.removeAll()
            lock.unlock()

            // 先把握手期间攒下的事件按原顺序补发（比如 lobby-join）
            for packet in pending { rawSend(packet) }

            DispatchQueue.main.async { [weak self] in
                self?.onConnect?(self?.socketId)
            }

        case "1":   // 服务端断开
            handleDrop("服务器关闭了连接")

        case "2":   // 事件
            guard let data = body.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let name = arr.first as? String else { return }
            let payload: Any? = arr.count > 1 ? arr[1] : nil
            fire(name, payload)

        case "4":   // 连接被拒绝 / 出错
            DispatchQueue.main.async { [weak self] in
                self?.onError?(body.isEmpty ? "服务器拒绝连接" : body)
            }

        default:
            break
        }
    }

    private func fire(_ event: String, _ payload: Any?) {
        lock.lock()
        let list = handlers[event] ?? []
        lock.unlock()
        guard !list.isEmpty else { return }
        DispatchQueue.main.async {
            for h in list { h(payload) }
        }
    }

    // MARK: - 发送

    func emit(_ event: String, _ payload: Any? = nil) {
        let arr: [Any] = payload == nil ? [event] : [event, payload!]
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let text = String(data: data, encoding: .utf8) else { return }
        send("42" + text)
    }

    /// 连上之前先入队，连上后按顺序补发
    private func send(_ packet: String) {
        lock.lock()
        if !isConnected || task == nil {
            queued.append(packet)
            lock.unlock()
            return
        }
        lock.unlock()
        rawSend(packet)
    }

    /// 绕过队列（握手包、pong 专用）
    private func rawSend(_ packet: String) {
        task?.send(.string(packet)) { [weak self] err in
            guard let err else { return }
            DispatchQueue.main.async {
                self?.onError?("发送失败：\(err.localizedDescription)")
            }
        }
    }

    // MARK: - 断开

    private func handleDrop(_ reason: String) {
        lock.lock()
        let wasConnected = isConnected
        isConnected = false
        socketId = nil
        task = nil
        lock.unlock()

        session?.invalidateAndCancel()
        session = nil

        guard !closedByUser else { return }

        if wasConnected {
            DispatchQueue.main.async { [weak self] in
                self?.onDisconnect?(reason)
            }
        }

        // 服务端重启 / Wi-Fi 抖动时自动重连
        lock.lock()
        let attempt = reconnectAttempt
        if attempt < maxReconnect { reconnectAttempt += 1 }
        lock.unlock()

        guard attempt < maxReconnect else { return }
        let delay = min(Double(attempt + 1) * 1.5, 6.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closedByUser else { return }
            self.openSocket()
        }
    }

    /// 关闭连接。
    ///
    /// - Parameter delay: 延迟多少秒才真正断开。
    ///   `URLSessionWebSocketTask.send` 是**异步**的，emit 之后立刻 cancel 会把还没发出去的帧丢掉。
    ///   服务端收不到 `lobby-leave`，只能等 pingTimeout / TCP 断开才发现这人走了，
    ///   大厅里就会留下一个"幽灵"——也就是"退出后那一栏不消失、再进来多出一个同名栏"。
    ///   给 0.2~0.4 秒，局域网足够把最后一帧送出去。
    func close(after delay: TimeInterval = 0) {
        closedByUser = true            // 立刻禁止自动重连
        lock.lock()
        isConnected = false
        let t = task
        task = nil
        queued.removeAll()
        lock.unlock()

        let s = session
        session = nil

        if delay <= 0 {
            t?.cancel(with: .normalClosure, reason: nil)
            s?.invalidateAndCancel()
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            t?.cancel(with: .normalClosure, reason: nil)
            s?.invalidateAndCancel()
        }
    }
}
