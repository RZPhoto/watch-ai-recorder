import Foundation
import Speech
import AVFAudio
import AVFoundation

enum TranscribeError: LocalizedError {
    case speechNotAuthorized
    case micNotAuthorized
    case recognizerUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized: return "未获得语音识别权限，请到 设置-隐私与安全性-语音识别 中允许"
        case .micNotAuthorized: return "未获得麦克风权限，请到 设置-隐私与安全性-麦克风 中允许"
        case .recognizerUnavailable: return "中文语音识别服务不可用，请稍后重试"
        case .exportFailed(let reason): return "音频分段失败：\(reason)"
        }
    }
}

/// 转写服务：把 m4a 音频文件转写为中文文本。
///
/// 策略（v0.3.1）：
/// - 苹果服务器识别优先（本机识别对文件转写有截断 bug），失败/离线时回退本机识别
/// - 超过 30 秒的音频切分逐段转写，规避苹果单次请求约 1 分钟上限
/// - 每段结果做截断复检：字数远低于时长应有字数时换引擎重跑，取更完整结果
/// - 跳过 <1 秒的碎片段；单段失败只跳过不中断整体
/// - 单次识别带超时保护，避免回调不触发时界面永久卡住
final class TranscriptionService {
    static let shared = TranscriptionService()

    /// 单段最大时长（秒）
    private static let chunkSeconds: Double = 30
    /// 低于该时长的碎片段直接跳过
    private static let minSegmentSeconds: Double = 1.0
    /// 中文正常语速约每秒 3~4 字；结果字数低于 时长×该系数 时视为疑似截断
    private static let minCharsPerSecond: Double = 1.5

    // MARK: - 权限

    private func requestPermissions() async throws {
        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        AppLogger.log("语音识别权限状态: \(speechStatus.rawValue)")
        guard speechStatus == .authorized else { throw TranscribeError.speechNotAuthorized }

        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
        AppLogger.log("麦克风权限状态: \(micGranted)")
        guard micGranted else { throw TranscribeError.micNotAuthorized }
    }

    // MARK: - 对外接口

    /// 转写一个音频文件，返回全文文本
    func transcribe(url: URL) async throws -> String {
        try await requestPermissions()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            throw TranscribeError.recognizerUnavailable
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        AppLogger.log("音频时长 \(String(format: "%.1f", duration)) 秒，文件 \(url.lastPathComponent)")

        if duration <= Self.chunkSeconds {
            return try await transcribeSegment(recognizer: recognizer, url: url, length: duration)
        }

        // 长音频：切分为多段，逐段转写后拼接；单段失败跳过不中断
        let segmentCount = Int((duration / Self.chunkSeconds).rounded(.up))
        AppLogger.log("长音频切分为 \(segmentCount) 段（服务器识别优先）")
        var parts: [String] = []
        for index in 0..<segmentCount {
            let start = Double(index) * Self.chunkSeconds
            let end = min(start + Self.chunkSeconds, duration)
            let length = end - start
            guard length >= Self.minSegmentSeconds else {
                AppLogger.log("第 \(index + 1) 段仅 \(String(format: "%.1f", length)) 秒，跳过")
                continue
            }
            let segmentURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("seg-\(index)-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            do {
                try await exportSegment(of: url, from: start, length: length, to: segmentURL)
            } catch {
                AppLogger.log("第 \(index + 1) 段导出失败，跳过：\(error.localizedDescription)")
                continue
            }
            defer { try? FileManager.default.removeItem(at: segmentURL) }

            AppLogger.log("转写第 \(index + 1)/\(segmentCount) 段（\(Int(start))s–\(Int(end))s）")
            do {
                let text = try await transcribeSegment(recognizer: recognizer, url: segmentURL, length: length)
                if !text.isEmpty { parts.append(text) }
            } catch {
                // 单段彻底失败：记录并继续，不拖垮整体
                AppLogger.log("第 \(index + 1) 段转写失败，跳过：\(error.localizedDescription)")
            }
        }
        let joined = parts.joined()
        AppLogger.log("分段转写完成，共 \(joined.count) 字")
        return joined
    }

    // MARK: - 单段转写（含引擎回退与截断复检）

    /// 服务器识别优先；失败回退本机；任一结果疑似截断时换引擎复检，取更完整的
    private func transcribeSegment(recognizer: SFSpeechRecognizer, url: URL, length: TimeInterval) async throws -> String {
        let timeout = max(20.0, length * 3 + 10)
        var text = ""

        do {
            text = try await runRecognition(recognizer: recognizer, url: url, onDevice: false, timeout: timeout)
            AppLogger.log("服务器识别本段 \(text.count) 字")
            if Double(text.count) < length * Self.minCharsPerSecond {
                AppLogger.log("服务器结果偏短，本机识别复检")
                if let retry = try? await runRecognition(recognizer: recognizer, url: url, onDevice: true, timeout: timeout),
                   retry.count > text.count {
                    text = retry
                    AppLogger.log("复检结果更完整（\(retry.count) 字），采用")
                }
            }
        } catch {
            AppLogger.log("服务器识别失败：\(error.localizedDescription)，回退本机识别")
            text = try await runRecognition(recognizer: recognizer, url: url, onDevice: true, timeout: timeout)
            AppLogger.log("本机识别本段 \(text.count) 字")
            if Double(text.count) < length * Self.minCharsPerSecond {
                AppLogger.log("本机结果疑似截断，服务器识别复检")
                if let retry = try? await runRecognition(recognizer: recognizer, url: url, onDevice: false, timeout: timeout),
                   retry.count > text.count {
                    text = retry
                    AppLogger.log("复检结果更完整（\(retry.count) 字），采用")
                }
            }
        }
        return text
    }

    // MARK: - 底层

    /// 用 AVAssetExportSession 把音频的指定时间段导出为独立 m4a
    private func exportSegment(of source: URL, from start: Double, length: Double, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscribeError.exportFailed("无法创建导出会话")
        }
        export.outputURL = destination
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600)
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed:
                    cont.resume()
                default:
                    cont.resume(throwing: TranscribeError.exportFailed(export.error?.localizedDescription ?? "未知原因"))
                }
            }
        }
    }

    /// 识别任务的持有者：避免用 objc 关联对象，同时保证 task 不被提前释放
    private final class RecognitionBridge {
        private let lock = NSLock()
        private var text = ""
        private var finished = false
        var task: SFSpeechRecognitionTask?

        func append(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            text = value
        }

        /// 只允许收尾一次；调用方负责 resume continuation
        func finishIfNeeded() -> String? {
            lock.lock(); defer { lock.unlock() }
            if finished { return nil }
            finished = true
            return text
        }
    }

    private func runRecognition(recognizer: SFSpeechRecognizer,
                                url: URL,
                                onDevice: Bool,
                                timeout: TimeInterval) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation

        let bridge = RecognitionBridge()
        let label = onDevice ? "本机" : "服务器"

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            bridge.task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    bridge.append(result.bestTranscription.formattedString)
                    if result.isFinal, let text = bridge.finishIfNeeded() {
                        AppLogger.log("单次识别完成（\(label)），\(text.count) 字")
                        bridge.task = nil
                        cont.resume(returning: text)
                    }
                } else if let error {
                    // 有部分结果就先返回，别浪费已识别的文字
                    if let text = bridge.finishIfNeeded(), !text.isEmpty {
                        AppLogger.log("识别中断但有部分结果（\(label)）：\(error.localizedDescription)")
                        bridge.task = nil
                        cont.resume(returning: text)
                    } else {
                        bridge.task = nil
                        cont.resume(throwing: error)
                    }
                }
            }

            // 超时保护：回调一直不来时用已有结果收尾，避免界面永久卡住
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard let text = bridge.finishIfNeeded() else { return }
                bridge.task?.cancel()
                bridge.task = nil
                if text.isEmpty {
                    AppLogger.log("识别超时（\(label)），无结果")
                    cont.resume(throwing: TranscribeError.recognizerUnavailable)
                } else {
                    AppLogger.log("识别超时（\(label)），返回已识别的 \(text.count) 字")
                    cont.resume(returning: text)
                }
            }
        }
    }
}
