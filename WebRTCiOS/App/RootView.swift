//
//  RootView.swift
//  启动页：和桌面端 launcher.html 一一对应的三个入口
//

import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header

                    EntryCard(title: "加入主服务器",
                              subtitle: "用账号登录，看在线名单，呼叫或加入通话",
                              systemImage: "person.2.fill",
                              tint: .blue) {
                        MainServerView()
                    }

                    EntryCard(title: "创建临时服务器",
                              subtitle: "这台 iPhone 当主机，别人用浏览器打开地址即可加入",
                              systemImage: "wifi.router.fill",
                              tint: .green) {
                        HostView()
                    }

                    EntryCard(title: "加入临时服务器",
                              subtitle: "输入对方大厅的地址，填个昵称就能进",
                              systemImage: "arrow.down.right.circle.fill",
                              tint: .orange) {
                        TempJoinView()
                    }

                    notes
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("WebRTC 客户端")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("局域网 WebRTC")
                .font(.title2.bold())
            Text("iOS 原生客户端 · 三个入口与桌面端一致")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("主服务器的通话是 P2P，服务器只帮忙牵线", systemImage: "info.circle")
            Label("创建临时服务器时，iPhone 必须保持在前台", systemImage: "exclamationmark.triangle")
            Label("对方浏览器首次打开会提示证书不受信任，点「继续前往」", systemImage: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }
}

#Preview {
    RootView()
}
