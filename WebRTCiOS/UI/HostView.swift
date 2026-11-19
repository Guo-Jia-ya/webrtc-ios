//
//  HostView.swift
//  创建临时服务器：iPhone 当主机
//

import SwiftUI
import UIKit

struct HostView: View {
    @StateObject private var server = LocalTempServer()

    @AppStorage("wb.hostPort") private var portText = "8080"
    @AppStorage("wb.nickname") private var nickname = ""
    @State private var errorText: String?
    @State private var showPreview = false
    @State private var copied = false
    @State private var hostCall: HostRoomCall?

    var body: some View {
        ZStack {
            form

            // 通话页直接盖在这一页上（和两个大厅一致），不再用 fullScreenCover：
            // 这一页同时还有 .sheet（网页预览）和报错提示，多个模态呈现叠在一起时
            // SwiftUI 只会保住其中一个，实测会出现"进不了房间"或"预览打不开"。
            if let call = hostCall {
                HostCallView(call: call) { endCall() }
                    .zIndex(1)
            }
        }
        .navigationTitle(hostCall == nil ? "创建临时服务器" : "通话中")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hostCall != nil)
        .sheet(isPresented: $showPreview) {
            NavigationStack {
                WebPreview(url: URL(string: "https://127.0.0.1:\(server.port)/") ?? URL(string: "https://127.0.0.1:8080/")!)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("本机预览")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("关闭") { showPreview = false }
                        }
                    }
            }
        }
        .onDisappear {
            // 通话中时不能停服务器，否则通话当场断掉
            guard hostCall == nil else { return }
            // 离开这个页面就别占着端口了
            server.stop()
        }
    }

    private var form: some View {
        Form {
            if let errorText {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Button {
                            self.errorText = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: server.running ? "dot.radiowaves.left.and.right" : "stop.circle")
                        .foregroundStyle(server.running ? .green : .secondary)
                    Text(server.statusText)
                        .font(.subheadline)
                    Spacer()
                    if server.running {
                        Text("\(server.members.count) 人在线")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("端口")
                    Spacer()
                    TextField("8080", text: $portText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .disabled(server.running)
                        .frame(width: 90)
                }

                Button {
                    toggle()
                } label: {
                    HStack {
                        Spacer()
                        Text(server.running ? "停止服务器" : "启动服务器")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .foregroundStyle(server.running ? Color.red : Color.accentColor)
            }

            if server.running {
                Section {
                    Text(server.address)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Button {
                        UIPasteboard.general.string = server.address
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "已复制" : "复制地址", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } header: {
                    Text("把下面这个地址发给同一 Wi-Fi 下的人")
                } footer: {
                    Text("对方用浏览器打开后输入昵称即可进入，最多 4 人。首次打开会提示证书不受信任，点「高级 → 继续前往」。")
                }

                // 主机自己也要能进房间，否则"手机当主机"就只是当了个服务器，
                // 这台 iPhone 反而看不到画面。
                Section {
                    HStack {
                        Text("你的昵称")
                        Spacer()
                        TextField("昵称", text: $nickname)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(maxWidth: 160)
                    }

                    Button {
                        joinSelf()
                    } label: {
                        Label("用这台 iPhone 进入房间", systemImage: "video.fill")
                            .fontWeight(.semibold)
                    }

                    Button {
                        showPreview = true
                    } label: {
                        Label("在本机预览页面（网页版）", systemImage: "safari")
                    }
                } header: {
                    Text("自己加入")
                } footer: {
                    Text("「进入房间」是原生实现，和 app 里其它通话界面一致，推荐用这个；网页预览是备选，自签证书下 WKWebView 的 WebSocket 有时连不上。这里别用首页的「加入临时服务器」——那说的是 socket.io，进不了手机自己开的这个服务器。")
                }

                Section("房间里的人") {
                    if server.members.isEmpty {
                        Text("还没有人加入")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(server.members) { member in
                        Label(member.display, systemImage: "person.fill")
                            .font(.subheadline)
                    }
                }

                Section("最近日志") {
                    let lines = server.logs.suffix(8)
                    if lines.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Label("iPhone 必须保持在前台，切到别的 App 会被系统挂起，大厅随之断开。",
                      systemImage: "exclamationmark.triangle")
                Label("首次启动会弹「本地网络」权限，必须允许，否则别人连不上。",
                      systemImage: "hand.raised")
            } header: {
                Text("注意")
            }
            .font(.caption)
        }
    }

    /// 主机自己也进房：走原生 WebSocket + WebRTC，不依赖 WebView
    private func joinSelf() {
        guard server.running else {
            errorText = "请先点「启动服务器」"
            return
        }
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = nick.isEmpty ? "主机" : nick
        if nick.isEmpty { nickname = display }

        let call = HostRoomCall(port: server.port, name: display)
        // 注意：HostView 是 struct（值类型），这里不能用 [weak self] / guard let self，
        // 否则会报「'weak' may only be applied to class and class-bound protocol types」。
        // 捕获的是这个 View 的一份副本，而 @State 的存储是引用语义，赋值依然生效。
        call.onEnded = { reason in
            self.errorText = reason
            self.hostCall = nil
        }
        hostCall = call
        Task { await call.start() }
    }

    private func endCall() {
        hostCall?.hangUp()
        hostCall = nil
    }

    private func toggle() {
        if server.running {
            server.stop()
            return
        }
        guard let port = UInt16(portText), port > 0 else {
            errorText = "端口填得不对，建议 8080"
            return
        }
        do {
            try server.start(port: port)
        } catch {
            errorText = "启动失败：\(error.localizedDescription)"
        }
    }
}
