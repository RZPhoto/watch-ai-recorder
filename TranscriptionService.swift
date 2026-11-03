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
/// v0.2.1 策略（依据 2026-11-03 真机日志修订）：
/// - 苹果服务器识别优先（质量稳定），失败/离线时回退本机识别
/// - 超过 30 秒的音频切分逐段转写，规避苹果单次请求约 1 分钟上限
/// - 每段结果做截断复检：字数远低于时长应有字数时换引擎重跑，取更完整结果
/// - 跳过 <1 秒的碎片段；单段失败只跳过不中断整体
final class TranscriptionService {
    static let shared = TranscriptionService()

    /// 单段最大时长（秒）
    private static let chunkSeconds: Double = 30
    /// 低于该时长的碎片段直接跳过
    private static let minSegmentSeconds: Double = 1.0
    /// 中文正常语速约每秒 3~4 字；结果字数低于 时长×该系数 时视为疑似截断
    private static let minCharsPerSecond: Double = 1.5
    /// objc 关联对象的 key
    private static let taskKey = NSObject()

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
            try await exportSegment(of: url, from: start, length: length, to: segmentURL)
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

    /// 服务器识别优先；失败回退本机；本机结果疑似截断时再用服务器复检
    private func transcribeSegment(recognizer: SFSpeechRecognizer, url: URL, length: TimeInterval) async throws -> String {
        var text = ""
        // 1) 服务器识别
        do {
            text = try await runRecognition(recognizer: recognizer, url: url, onDevice: false)
            AppLogger.log("服务器识别本段 \(text.count) 字")
        } catch {
            AppLogger.log("服务器识别失败：\(error.localizedDescription)，回退本机识别")
            // 2) 本机识别兜底（离线场景）
            text = try await runRecognition(recognizer: recognizer, url: url, onDevice: true)
            AppLogger.log("本机识别本段 \(text.count) 字")
            // 3) 本机结果疑似截断 → 再用服务器复检一次
            if Double(text.count) < length * Self.minCharsPerSecond {
                AppLogger.log("本机结果疑似截断，服务器识别复检")
                if let retry = try? await runRecognition(recognizer: recognizer, url: url, onDevice: false),
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

    private func runRecognition(recognizer: SFSpeechRecognizer, url: URL, onDevice: Bool) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var accumulated = ""
            var hasResumed = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }
                if let result {
                    accumulated = result.bestTranscription.formattedString
                    if result.isFinal {
                        hasResumed = true
                        AppLogger.log("单次识别完成（\(onDevice ? "本机" : "服务器")），\(accumulated.count) 字")
                        cont.resume(returning: accumulated)
                    }
                } else if let error {
                    // 已有部分结果时不要浪费，返回已识别文本
                    if !accumulated.isEmpty {
                        hasResumed = true
                        AppLogger.log("识别中断但有部分结果: \(error.localizedDescription)")
                        cont.resume(returning: accumulated)
                    } else {
                        hasResumed = true
                        cont.resume(throwing: error)
                    }
                }
            }
            // 保留 task 引用防止提前释放
            objc_setAssociatedObject(request, Self.taskKey, task, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}
