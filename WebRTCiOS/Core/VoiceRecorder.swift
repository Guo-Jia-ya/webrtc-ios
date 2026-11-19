//
//  VoiceRecorder.swift
//  大厅聊天的语音条录制（AAC / m4a，最长 60 秒）
//
//  只负责"录到本地文件 + 给时长"，上传和发送交给 ChatService。
//

import Foundation
import AVFoundation

final class VoiceRecorder: NSObject, ObservableObject {

    @Published private(set) var recording = false
    @Published private(set) var seconds: Double = 0

    /// 单个语音条上限（服务端也限制 300 秒，这里按产品习惯收在 60 秒）
    private let maxSeconds: Double = 60

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    // MARK: 权限

    func requestPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                session.requestRecordPermission { ok in cont.resume(returning: ok) }
            }
        @unknown default:
            return false
        }
    }

    // MARK: 录

    @discardableResult
    func start() async -> Bool {
        if recording { return true }
        guard await requestPermission() else { return false }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wbc-voice-\(UUID().uuidString.prefix(8)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else { return false }
            recorder = r
            fileURL = url
            seconds = 0
            recording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, let r = self.recorder else { return }
                    self.seconds = r.currentTime
                    // 到上限自动收尾，避免录出超长文件
                    if self.seconds >= self.maxSeconds { _ = self.finish() }
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// 结束录音，返回 (文件, 时长)。太短（<0.6 秒）当作误触，直接丢弃。
    func finish() -> (URL, Double)? {
        timer?.invalidate()
        timer = nil
        guard let r = recorder, let url = fileURL else { return nil }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        fileURL = nil
        recording = false
        seconds = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if duration < 0.6 {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return (url, duration)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        recording = false
        seconds = 0
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
