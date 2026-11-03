import Foundation
import AVFoundation

/// 现场录音服务：AVAudioRecorder 输出 m4a（AAC），带计时与电平表
/// 录音文件保存在 Documents/Recordings，为后续历史记录功能留数据
final class RecorderService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// 归一化音量 0~1，驱动界面电平条
    @Published private(set) var level: Double = 0
    /// 平滑平均音量（EMA），用于判断"整体声音是否偏小"
    @Published private(set) var averageLevel: Double = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?

    /// 录音保存目录（Documents/Recordings）
    static let recordingsDirectory: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 请求麦克风权限（granted / denied / undetermined 三态）
    static func requestMicPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                session.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func start() throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = Self.recordingsDirectory
            .appendingPathComponent(formatter.string(from: Date()))
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.isMeteringEnabled = true
        newRecorder.delegate = self
        guard newRecorder.record() else {
            throw NSError(domain: "RecorderService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "录音启动失败，请重试"])
        }

        recorder = newRecorder
        fileURL = url
        elapsed = 0
        level = 0
        isRecording = true
        isPaused = false
        startTimer()
        AppLogger.log("开始现场录音：\(url.lastPathComponent)")
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        isPaused = true
        AppLogger.log("现场录音暂停")
    }

    func resume() {
        guard isRecording, isPaused else { return }
        recorder?.record()
        isPaused = false
        AppLogger.log("现场录音继续")
    }

    /// 结束录音并返回音频文件地址（文件保留在沙盒内，不删除）
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        timer?.invalidate()
        timer = nil
        let duration = elapsed
        recorder?.stop()
        recorder = nil
        isRecording = false
        isPaused = false
        level = 0
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
        AppLogger.log("结束现场录音：\(String(format: "%.1f", duration)) 秒，文件已保存")
        return fileURL
    }

    /// 放弃录音：停止并删除文件
    func cancel() {
        guard isRecording else { return }
        let url = stop()
        if let url {
            try? FileManager.default.removeItem(at: url)
            AppLogger.log("放弃现场录音，文件已删除")
        }
        fileURL = nil
    }

    /// 录音超过 4 秒且整体音量偏低：提示用户把手机移近发言人
    var isTooQuiet: Bool {
        isRecording && !isPaused && elapsed > 4 && averageLevel < 0.18
    }

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            AppLogger.log("现场录音异常结束（编码器出错）")
        }
    }

    // MARK: - 计时与电平

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            r.updateMeters()
            let db = r.averagePower(forChannel: 0)
            self.level = min(max((Double(db) + 50) / 50, 0), 1)
            self.averageLevel = self.averageLevel * 0.95 + self.level * 0.05
            self.elapsed = r.currentTime
        }
    }
}
