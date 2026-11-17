//
//  HostView.swift
//  创建临时服务器：iPhone 当主机
//

import SwiftUI
import UIKit

struct HostView: View {
    @StateObject private var server = LocalTempServer()

    @AppStorage("wb.hostPort") private var portText = "8080"
    @State private var errorText: String?
    @State private var showPreview = false
    @State private var copied = false

    var body: some View {
        Form {
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

                    Button {
                        showPreview = true
                    } label: {
                        Label("在本机预览页面", systemImage: "safari")
                    }
                } header: {
                    Text("把下面这个地址发给同一 Wi-Fi 下的人")
                } footer: {
                    Text("对方用浏览器打开后输入昵称即可进入，最多 4 人。首次打开会提示证书不受信任，点「高级 → 继续前往」。")
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
        .navigationTitle("创建临时服务器")
        .navigationBarTitleDisplayMode(.inline)
        .alert("出错了", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
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
            // 离开这个页面就别占着端口了
            server.stop()
        }
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
