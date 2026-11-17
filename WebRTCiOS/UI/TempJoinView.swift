//
//  TempJoinView.swift
//  加入别人开的临时服务器（别人在桌面端点「临时服务器」，或者用 iPhone 当主机）
//

import SwiftUI

struct TempJoinView: View {
    @StateObject private var session = TempServerSession()

    @AppStorage("wb.tempHost") private var host = ""
    @AppStorage("wb.nickname") private var nickname = ""
    @State private var draftName = ""
    @FocusState private var focused: Field?

    private enum Field { case host, name }

    var body: some View {
        Group {
            if session.phase == .idle {
                joinForm
            } else {
                lobby
            }
        }
        .navigationTitle("临时服务器")
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
        .onAppear {
            if draftName.isEmpty { draftName = nickname }
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
