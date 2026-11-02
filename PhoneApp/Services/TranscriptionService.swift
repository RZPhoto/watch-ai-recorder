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
/// 优先本机识别（requiresOnDeviceRecognition），失败或疑似截断时回退到苹果服务器识别。
/// 超过 45 秒的音频自动切分逐段转写，规避苹果单次识别请求约 1 分钟的上限。
final class TranscriptionService {
    static let shared = TranscriptionService()

    /// 单段最大时长（秒）。苹果单次识别约 1 分钟上限，留出余量。
    private static let chunkSeconds: Double = 45
    /// 中文正常语速约每秒 3~4 字；结果字数低于 时长×该系数 时视为疑似截断。
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

    // MARK: - 转写

    /// 转写一个音频文件，返回全文文本
    /// - Parameters:
    ///   - url: 音频文件地址（需可读，security-scoped 的文件请先拷贝到沙盒临时目录）
    ///   - forceOnline: 强制使用苹果服务器识别（默认 false，优先本机）
    func transcribe(url: URL, forceOnline: Bool = false) async throws -> String {
        try await requestPermissions()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            throw TranscribeError.recognizerUnavailable
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        AppLogger.log("音频时长 \(String(format: "%.1f", duration)) 秒，文件 \(url.lastPathComponent)")

        let onDevice = forceOnline ? false : (recognizer.supportsOnDeviceRecognition == true)

        if duration <= Self.chunkSeconds {
            AppLogger.log("单段转写，本机识别: \(onDevice)")
            let text = try await recognizeWithFallback(recognizer: recognizer, url: url, onDevice: onDevice)

            // 疑似截断复检：本机识别结果字数远低于该时长应有的字数时，改用服务器识别再试一次
            if !forceOnline, onDevice, Double(text.count) < duration * Self.minCharsPerSecond {
                AppLogger.log("结果仅 \(text.count) 字，疑似被截断，改用服务器识别复检")
                if let retry = try? await runRecognition(recognizer: recognizer, url: url, onDevice: false),
                   retry.count > text.count {
                    AppLogger.log("服务器识别更完整（\(retry.count) 字），采用该结果")
                    return retry
                }
            }
            AppLogger.log("转写完成，共 \(text.count) 字")
            return text
        }

        // 长音频：切分为多段，逐段转写后拼接
        let segmentCount = Int((duration / Self.chunkSeconds).rounded(.up))
        AppLogger.log("长音频切分为 \(segmentCount) 段，本机识别: \(onDevice)")
        var parts: [String] = []
        for index in 0..<segmentCount {
            let start = Double(index) * Self.chunkSeconds
            let end = min(start + Self.chunkSeconds, duration)
            let segmentURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("seg-\(index)-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            try await exportSegment(of: url, from: start, length: end - start, to: segmentURL)
            defer { try? FileManager.default.removeItem(at: segmentURL) }

            AppLogger.log("转写第 \(index + 1)/\(segmentCount) 段（\(Int(start))s–\(Int(end))s）")
            let text = try await recognizeWithFallback(recognizer: recognizer, url: segmentURL, onDevice: onDevice)
            if !text.isEmpty { parts.append(text) }
        }
        let joined = parts.joined()
        AppLogger.log("分段转写完成，共 \(joined.count) 字")
        return joined
    }

    /// 单段转写：本机识别失败时回退到苹果服务器识别
    private func recognizeWithFallback(recognizer: SFSpeechRecognizer, url: URL, onDevice: Bool) async throws -> String {
        do {
            return try await runRecognition(recognizer: recognizer, url: url, onDevice: onDevice)
        } catch {
            if onDevice {
                AppLogger.log("本机识别失败: \(error.localizedDescription)，回退服务器识别")
                return try await runRecognition(recognizer: recognizer, url: url, onDevice: false)
            }
            throw error
        }
    }

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
                        AppLogger.log("单次识别完成，本段 \(accumulated.count) 字")
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
            objc_setAssociatedObject(request, "task", task, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}
