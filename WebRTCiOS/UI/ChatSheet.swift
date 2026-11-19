//
//  ChatSheet.swift
//  大厅聊天面板：公共频道 + 一对一私聊，文字 / 语音 / 文件三种发送方式
//
//  会话模型与桌面网页、安卓端完全一致（chat-relay.js）：
//    · to = "lobby"   → 公共频道，全大厅都收到
//    · to = <对方sid> → 私聊，只有对方和自己收到（服务器回显给自己）
//  私聊会话键统一是 "p:<对方sid>"，只是本地内存里的分组方式，不上线传输。
//

import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

struct ChatSheet: View {
    @ObservedObject var chat: ChatService
    @Environment(\.dismiss) private var dismiss

    @StateObject private var recorder = VoiceRecorder()
    @State private var draft = ""
    /// 会话切换层（纯 SwiftUI 层内浮层，不开新 modal —— 一个视图只能可靠地挂一个 modal）
    @State private var showConversations = false
    /// 文件选择 / 附件预览共用一个模态槽位。
    /// 之前是 .sheet(isPresented:) + .sheet(item:) 挂在同一个视图上，
    /// SwiftUI 只会保住其中一个，另一个点了没反应。
    @State private var modal: Modal?
    @State private var player: AVAudioPlayer?
    @State private var playingId: String?
    @State private var loadingId: String?

    enum Modal: Identifiable {
        case picker
        case share(URL)

        var id: String {
            switch self {
            case .picker: return "picker"
            case .share(let url): return url.absoluteString
            }
        }
    }

    private var isLobby: Bool { chat.current == ChatService.LOBBY }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    if !isLobby { privateBanner }
                    messageList
                    Divider()
                    composer
                }
                .background(Color(uiColor: .systemGroupedBackground))

                if showConversations {
                    conversationLayer
                }
            }
            .navigationTitle(chat.title(for: chat.current))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showConversations.toggle()
                    } label: {
                        Image(systemName: "list.bullet")
                            .overlay(alignment: .topTrailing) {
                                if chat.unread > 0 {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 3, y: -3)
                                }
                            }
                    }
                    .accessibilityLabel("切换会话")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear { chat.markRead() }
        .onDisappear {
            chat.visible = false
            recorder.cancel()
            player?.stop()
        }
        .sheet(item: $modal) { item in
            switch item {
            case .picker:
                DocumentPicker { url in
                    Task { await chat.sendFile(localURL: url) }
                }
            case .share(let url):
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: 私聊提示条

    private var privateBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.caption2)
            Text("只有你和 \(chat.title(for: chat.current)) 能看到")
                .font(.caption)
            Spacer()
            Button("回到公共频道") {
                chat.open(ChatService.LOBBY)
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: 会话切换

    private var conversationLayer: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { showConversations = false }

            VStack(spacing: 0) {
                HStack {
                    Text("会话")
                        .font(.headline)
                    Spacer()
                    Button {
                        showConversations = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                List {
                    Section("已打开的会话") {
                        ForEach(chat.conversations(), id: \.self) { conv in
                            conversationRow(conv)
                        }
                    }

                    Section {
                        if chat.peers.isEmpty {
                            Text("大厅里暂时没有别人")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(chat.peers) { peer in
                            Button {
                                chat.open("p:" + peer.sid, title: peer.name)
                                showConversations = false
                            } label: {
                                HStack(spacing: 10) {
                                    Text(String(peer.name.prefix(1)))
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(Color.accentColor.gradient, in: Circle())
                                    Text(peer.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "bubble.left.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    } header: {
                        Text("发起私聊")
                    } footer: {
                        Text("私聊消息只有你和对方能看到，不经过大厅里的其他人。")
                    }
                }
                .listStyle(.insetGrouped)
            }
            .frame(maxHeight: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }

    private func conversationRow(_ conv: String) -> some View {
        Button {
            chat.open(conv)
            showConversations = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: conv == ChatService.LOBBY ? "person.3.fill" : "person.fill")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background((conv == ChatService.LOBBY ? Color.gray : Color.accentColor).gradient,
                                in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.title(for: conv))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if let last = chat.messages(in: conv).last {
                        Text(preview(last))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if chat.unread(of: conv) > 0 {
                    Text("\(chat.unread(of: conv))")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                }
                if conv == chat.current {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func preview(_ msg: ChatMessage) -> String {
        switch msg.kind {
        case .text: return msg.text
        case .voice: return "语音 \(msg.durationText)"
        case .file: return "文件 \(msg.file?.name ?? "")"
        }
    }

    // MARK: 消息流

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    let list = chat.messages(in: chat.current)
                    if list.isEmpty {
                        Text(isLobby ? "还没有消息，说点什么吧" : "和 \(chat.title(for: chat.current)) 的私聊，只有你们两个人能看到")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                            .padding(.top, 40)
                    }
                    ForEach(list) { msg in
                        row(msg)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages(in: chat.current).count) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: chat.current) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func row(_ msg: ChatMessage) -> some View {
        let mine = msg.fromSid == (chat.mySid ?? "")
        return HStack {
            if mine { Spacer(minLength: 44) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !mine {
                    Text(msg.fromName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                content(msg, mine: mine)
                Text(msg.timeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !mine { Spacer(minLength: 44) }
        }
    }

    @ViewBuilder
    private func content(_ msg: ChatMessage, mine: Bool) -> some View {
        switch msg.kind {
        case .text:
            Text(msg.text)
                .font(.subheadline)
                .foregroundStyle(mine ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14))

        case .voice:
            Button {
                play(msg)
            } label: {
                HStack(spacing: 8) {
                    if loadingId == msg.id {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: playingId == msg.id ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 20))
                    }
                    Text(msg.durationText)
                        .font(.subheadline)
                        .monospacedDigit()
                }
                .foregroundStyle(mine ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

        case .file:
            Button {
                open(msg)
            } label: {
                HStack(spacing: 8) {
                    if loadingId == msg.id {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 18))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(msg.file?.name ?? "文件")
                            .font(.subheadline)
                            .lineLimit(1)
                        if let s = msg.file?.sizeText, !s.isEmpty {
                            Text(s).font(.caption2).foregroundStyle(mine ? Color.white.opacity(0.8) : .secondary)
                        }
                    }
                }
                .foregroundStyle(mine ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 输入区

    private var composer: some View {
        VStack(spacing: 0) {
            if let err = chat.errorText {
                HStack(spacing: 8) {
                    Text(err).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button { chat.errorText = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }

            if recorder.recording {
                HStack(spacing: 10) {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                    Text(String(format: "%.1f″", recorder.seconds))
                        .font(.subheadline)
                        .monospacedDigit()
                    Text("录音中，最长 60 秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { recorder.cancel() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button {
                        sendVoice()
                    } label: {
                        Label("发送", systemImage: "paperplane.fill")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                HStack(spacing: 10) {
                    Button {
                        Task {
                            let ok = await recorder.start()
                            if !ok { chat.errorText = "无法录音，请检查麦克风权限" }
                        }
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 18))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)

                    TextField(isLobby ? "说点什么…" : "私聊 \(chat.title(for: chat.current))…",
                              text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)

                    Button { modal = .picker } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)

                    Button {
                        chat.sendText(draft)
                        draft = ""
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 17))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? Color.secondary : Color.accentColor)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            if chat.sending {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("上传中…").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(.bar)
    }

    // MARK: 动作

    private func sendVoice() {
        guard let (url, duration) = recorder.finish() else {
            chat.errorText = "录得太短了，长按再说一句"
            return
        }
        Task { await chat.sendVoice(localURL: url, duration: duration) }
    }

    private func play(_ msg: ChatMessage) {
        guard let file = msg.file else { return }
        if playingId == msg.id {
            player?.stop()
            playingId = nil
            return
        }
        player?.stop()
        loadingId = msg.id
        Task {
            guard let local = await chat.download(file) else {
                loadingId = nil
                return
            }
            loadingId = nil
            do {
                let p = try AVAudioPlayer(contentsOf: local)
                player = p
                p.play()
                playingId = msg.id
                // 播完把状态收回来
                let seconds = max(0.5, p.duration)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if playingId == msg.id { playingId = nil }
            } catch {
                chat.errorText = "这段语音打不开"
            }
        }
    }

    private func open(_ msg: ChatMessage) {
        guard let file = msg.file else { return }
        loadingId = msg.id
        Task {
            defer { loadingId = nil }
            guard let local = await chat.download(file) else { return }
            modal = .share(local)
        }
    }
}

// MARK: - 附件预览（能"存储到文件"、用别的 App 打开）

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - 文件选择

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            // asCopy: true 已经把文件复制到沙盒里，直接读就行
            onPick(url)
        }
    }
}
