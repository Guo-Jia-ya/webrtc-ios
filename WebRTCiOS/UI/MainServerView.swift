//
//  MainServerView.swift
//  加入主服务器：登录 → 大厅 → 呼叫 / 接听 / 进房间
//
//  页面结构刻意做成"一层 ZStack + 三个层"，而不是用 alert / fullScreenCover：
//    0 层：登录表单 或 大厅名单
//    1 层：通话页（CallView）—— 直接盖在大厅上，不经过任何 modal
//    2 层：来电 / 加入申请卡片 —— 盖在通话页之上
//  这样"人在房间里收到加入申请"时，卡片出现在房间界面上，答完仍然在房间里，
//  不会像以前那样被系统 alert 顶回大厅、还顺手替用户拒绝一次。
//

import SwiftUI

struct MainServerView: View {
    @StateObject private var session = MainServerSession()

    @AppStorage("wb.mainHost") private var host = ""
    @AppStorage("wb.mainAccount") private var account = ""
    @State private var password = ""
    @State private var pendingLeave = false
    @State private var showChat = false
    @FocusState private var focused: Field?

    private enum Field { case host, account, password }

    private var inCall: Bool { session.call != nil }

    var body: some View {
        ZStack {
            content

            // 通话页：直接在层里铺开，进来就不再依赖任何模态
            if let call = session.call {
                CallView(call: call) { session.hangUp() }
                    .zIndex(1)
            }

            // 来电 / 加入申请：永远画在最上面，不管当前在大厅还是房间
            prompts
        }
        .navigationTitle(inCall ? "通话中" : "主服务器")
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
        .onAppear { pendingLeave = false }
        .onDisappear { scheduleLeave() }
    }

    // MARK: 第 0 层

    @ViewBuilder
    private var content: some View {
        if session.phase == .idle {
            loginForm
        } else {
            lobby
        }
    }

    // MARK: 第 2 层：来电 / 加入申请

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

    // MARK: 登录

    private var loginForm: some View {
        Form {
            Section {
                TextField("192.168.1.5:3007", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .host)
                    .onSubmit { focused = .account }
            } header: {
                Text("服务器地址")
            } footer: {
                Text("填开主服务器那台机器的局域网 IP 即可，端口默认 3007，可以不写。")
            }

            Section {
                TextField("用户名", text: $account)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .account)
                    .onSubmit { focused = .password }

                SecureField("密码", text: $password)
                    .focused($focused, equals: .password)
                    .onSubmit { submit() }
            } header: {
                Text("账号")
            } footer: {
                Text("用桌面端注册过的账号即可登录。")
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if session.busy {
                            ProgressView().padding(.trailing, 6)
                        }
                        Text(session.busy ? "登录中…" : "登录")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(session.busy || host.isEmpty || account.isEmpty || password.isEmpty)
            }

            if let banner = session.banner {
                Section {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func submit() {
        focused = nil
        Task { await session.login(host: host, account: account, password: password) }
    }

    // MARK: 大厅

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
                    UserRow(user: user,
                            isMe: false,
                            onCall: { session.callUser(user) },
                            onMessage: {
                                // 直接从名单里拉一个私聊：和安卓端点气泡是一样的入口
                                session.chat?.open("p:" + user.sid, title: user.name)
                                showChat = true
                            })
                }
            } header: {
                Text("在线（\(session.others.count) 人）")
            } footer: {
                Text("点「呼叫」邀请空闲的人；对方已在通话中则会变成加入申请，由房间里每个人确认。")
            }

            Section {
                Button("退出大厅", role: .destructive) {
                    session.leave()
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    // MARK: 离开页面

    /// 返回上一页时把账号从大厅撤掉。
    /// 延迟 0.7 秒是为了区分"真的离开了"和"只是被别的东西暂时盖住了一下"。
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
