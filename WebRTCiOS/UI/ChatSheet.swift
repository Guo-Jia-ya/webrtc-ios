//
//  ChatSheet.swift
//  大厅聊天面板：消息流 + 文字 / 语音 / 文件三种发送方式
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
    @State private var showPicker = false
    @State private var preview: PreviewItem?
    @State private var player: AVAudioPlayer?
    @State private var playingId: String?
    @State private var loadingId: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                Divider()
                composer
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("大厅聊天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        .sheet(isPresented: $showPicker) {
            DocumentPicker { url in
                Task { await chat.sendFile(localURL: url) }
            }
        }
        .sheet(item: $preview) { item in
            ShareSheet(items: [item.url])
        }
    }

    // MARK: 消息流

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if chat.messages.isEmpty {
                        Text("还没有消息，说点什么吧")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                    ForEach(chat.messages) { msg in
                        row(msg)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
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

                    TextField("说点什么…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)

                    Button { showPicker = true } label: {
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
            preview = PreviewItem(url: local)
        }
    }
}

// MARK: - 附件预览（能"存储到文件"、用别的 App 打开）

struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

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
