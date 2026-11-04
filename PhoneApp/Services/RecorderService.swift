import Foundation
import AVFoundation

/// 现场录音服务：AVAudioRecorder 输出 m4a（AAC），带计时与电平表
/// 录音文件保存在 Documents/Recordings，为后续历史记录功能留数据
///
/// v0.6.1：
/// - 改为单例，页面销毁不再中断录音（锁屏/返回主页都能继续录）
/// - 音频会话切到 .voiceChat 模式：系统会对麦克风做自动增益和噪声抑制，
///   手机放在桌上录会议时远场人声会被明显抬高，这是"听不清、内容缺失"的主因之一
/// - 采样率 48kHz / 128kbps，给识别引擎更完整的语音信息
final class RecorderService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = RecorderService()

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// 归一化音量 0~1，驱动界面电平条
    @Published private(set) var level: Double = 0
    /// 平滑平均音量（EMA），用于判断"整体声音是否偏小"
    @Published private(set) var averageLevel: Double = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var interruptionToken: NSObjectProtocol?
    /// 录音被系统（来电/闹钟）中断过，结束时视情况自动恢复
    private var wasInterruptedBySystem = false
    private(set) var fileURL: URL?

    override init() {
        super.init()
        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    deinit {
        if let token = interruptionToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// 来电/闹钟等系统中断：自动暂停；中断结束且系统允许时自动继续
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            if isRecording && !isPaused {
                wasInterruptedBySystem = true
                recorder?.pause()
                isPaused = true
                level = 0
                AppLogger.log("录音被系统中断（来电/闹钟/Siri），已自动暂停")
            }
        case .ended:
            guard wasInterruptedBySystem else { return }
            wasInterruptedBySystem = false
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                recorder?.record()
                isPaused = false
                AppLogger.log("中断结束，已自动继续录音")
            } else {
                AppLogger.log("中断结束，但系统不允许自动恢复，录音保持暂停")
            }
        @unknown default:
            break
        }
    }

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
        // .voiceChat 会启用系统级语音处理（自动增益 + 降噪 + 回声消除），
        // 远场录音的人声清晰度提升明显；.defaultToSpeaker 避免声音走听筒
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = Self.recordingsDirectory
            .appendingPathComponent(formatter.string(from: Date()))
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
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
