import Foundation
import AVFAudio

/// iPhone 本机录音（手表端就绪前的录音入口，复用同样的参数）
@MainActor
final class AudioRecorderService: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentURL: URL?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
        session.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    AppLogger.log("录音被拒绝：无麦克风权限")
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inapp-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.record()
            recorder = rec
            currentURL = url
            elapsed = 0
            isRecording = true
            AppLogger.log("App 内录音开始")
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let rec = self.recorder else { return }
                    self.elapsed = rec.currentTime()
                }
            }
        } catch {
            AppLogger.log("录音启动失败：\(error.localizedDescription)")
        }
    }

    /// 停止录音，返回 (文件地址, 时长)
    func stop() -> (url: URL, duration: TimeInterval)? {
        timer?.invalidate()
        timer = nil
        guard let rec = recorder, let url = currentURL else { return nil }
        let duration = rec.currentTime()
        rec.stop()
        recorder = nil
        currentURL = nil
        isRecording = false
        AppLogger.log("App 内录音停止，时长 \(Int(duration)) 秒")
        return (url, duration)
    }
}
