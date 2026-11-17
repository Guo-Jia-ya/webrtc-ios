//
//  MainServerView.swift
//  加入主服务器：登录 → 大厅 → 呼叫 / 接听
//

import SwiftUI

struct MainServerView: View {
    @StateObject private var session = MainServerSession()

    @AppStorage("wb.mainHost") private var host = ""
    @AppStorage("wb.mainAccount") private var account = ""
    @State private var password = ""
    @FocusState private var focused: Field?

    private enum Field { case host, account, password }

    var body: some View {
        Group {
            if session.phase == .idle {
                loginForm
            } else {
                lobby
            }
        }
        .navigationTitle("主服务器")
        .navigationBarTitleDisplayMode(.inline)
        .alert("来电", isPresented: Binding(
            get: { session.incoming != nil },
            set: { if !$0 { session.answerIncoming(false) } }
        )) {
            Button("拒绝", role: .cancel) { session.answerIncoming(false) }
            Button("接听") { session.answerIncoming(true) }
        } message: {
            Text("\(session.incoming?.fromName ?? "有人") 想和你通话")
        }
        .fullScreenCover(isPresented: Binding(
            get: { session.call != nil },
            set: { _ in }
        )) {
            if let call = session.call {
                CallView(call: call) { session.hangUp() }
            }
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
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            // 名单由服务端推送，这里只是给用户一个"重来一次"的手感
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        .alert("加入申请", isPresented: Binding(
            get: { session.joinRequest != nil },
            set: { if !$0 { session.answerJoinRequest(false) } }
        )) {
            Button("拒绝", role: .cancel) { session.answerJoinRequest(false) }
            Button("同意") { session.answerJoinRequest(true) }
        } message: {
            if let req = session.joinRequest {
                Text("\(req.requesterName) 想加入你所在的房间（当前 \(req.size)/\(req.max) 人）")
            }
        }
    }
}
