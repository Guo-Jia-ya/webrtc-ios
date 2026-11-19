//
//  TempJoinView.swift
//  加入别人开的临时服务器（别人在桌面端点「临时服务器」，或者用 iPhone 当主机）
//
//  和 MainServerView 一样，用"一层 ZStack + 三层"的结构：
//    0 层：填写页 或 大厅名单
//    1 层：通话页
//    2 层：来电 / 加入申请卡片（盖在房间界面之上，不影响通话）
//

import SwiftUI

struct TempJoinView: View {
    @StateObject private var session = TempServerSession()

    @AppStorage("wb.tempHost") private var host = ""
    @AppStorage("wb.nickname") private var nickname = ""
    @State private var draftName = ""
    @State private var pendingLeave = false
    @State private var showChat = false
    @FocusState private var focused: Field?

    private enum Field { case host, name }

    private var inCall: Bool { session.call != nil }

    var body: some View {
        ZStack {
            content

            if let call = session.call {
                CallView(call: call) { session.hangUp() }
                    .zIndex(1)
            }

            prompts
        }
        .navigationTitle(inCall ? "通话中" : "临时服务器")
        .navigationBarTitleDisplayMode(.inline)
        // 通话中禁用返回：避免误触把通话页弹掉（人还在房间里，界面却没了）
        .navigationBarBackButtonHidden(inCall)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let chat = session.chat {
                    ChatToolbarButton(chat: chat) {
                        chat.markRead()
                        showChat = true
                    }
                }
            }
        }
        .sheet(isPresented: $showChat) {
            if let chat = session.chat {
                ChatSheet(chat: chat)
            }
        }
        .onAppear {
            if draftName.isEmpty { draftName = nickname }
            pendingLeave = false
        }
        .onDisappear { scheduleLeave() }
    }

    @ViewBuilder
    private var content: some View {
        if session.phase == .idle {
            joinForm
        } else {
            lobby
        }
    }

    @ViewBuilder
    private var prompts: some View {
        if let inc = session.incoming {
            PromptCard(title: "来电",
                       message: "\(inc.fromName) 想和你通话",
                       systemImage: "phone.arrow.down.left",
                       primaryTitle: "接听",
                       secondaryTitle: "拒绝",
                       accent: .green,
                       onPrimary: { session.answerIncoming(true) },
                       onSecondary: { session.answerIncoming(false) })
                .zIndex(2)
        } else if let req = session.joinRequest {
            PromptCard(title: "加入申请",
                       message: "\(req.requesterName) 想加入当前通话（\(req.size)/\(req.max) 人）",
                       systemImage: "person.badge.plus",
                       primaryTitle: "同意",
                       secondaryTitle: "拒绝",
                       accent: .orange,
                       onPrimary: { session.answerJoinRequest(true) },
                       onSecondary: { session.answerJoinRequest(false) })
                .zIndex(2)
        }
    }

    private var joinForm: some View {
        Form {
            Section {
                TextField("192.168.1.5:8080", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .host)
                    .onSubmit { focused = .name }
            } header: {
                Text("大厅地址")
            } footer: {
                Text("临时服务器是 https，端口默认 8080。地址后面带不带斜杠都行。")
            }

            Section("你的昵称") {
                TextField("昵称", text: $draftName)
                    .focused($focused, equals: .name)
                    .onSubmit { submit() }
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if session.busy {
                            ProgressView().padding(.trailing, 6)
                        }
                        Text(session.busy ? "连接中…" : "进入大厅")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(session.busy || host.isEmpty || draftName.isEmpty)
            }

            if let banner = session.banner {
                Section {
                    Text(banner).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func submit() {
        focused = nil
        nickname = draftName
        session.join(host: host, name: draftName)
    }

    private var lobby: some View {
        List {
            if let banner = session.banner {
                Section {
                    Text(banner).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                if session.others.isEmpty {
                    Text("大厅里暂时只有你一个人")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(session.others) { user in
                    UserRow(user: user, isMe: false) {
                        session.callUser(user)
                    }
                }
            } header: {
                Text("在线（\(session.others.count) 人）")
            }

            Section {
                Button("离开大厅", role: .destructive) {
                    session.leave()
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 侧滑返回 / 点返回箭头时也得把人从大厅名单里撤掉。
    /// 延迟 0.7 秒再确认，期间又 onAppear 了说明只是被暂时盖住。
    private func scheduleLeave() {
        guard !showChat else { return }
        pendingLeave = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard self.pendingLeave else { return }
            self.pendingLeave = false
            self.session.leave()
        }
    }
}
