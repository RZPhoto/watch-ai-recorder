import Foundation
import Speech
import AVFAudio

enum TranscribeError: LocalizedError {
    case speechNotAuthorized
    case micNotAuthorized
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized: return "未获得语音识别权限，请到 设置-隐私与安全性-语音识别 中允许"
        case .micNotAuthorized: return "未获得麦克风权限，请到 设置-隐私与安全性-麦克风 中允许"
        case .recognizerUnavailable: return "中文语音识别服务不可用，请稍后重试"
        }
    }
}

/// M1 转写服务：把 m4a 音频文件转写为中文文本。
/// 优先本机识别（requiresOnDeviceRecognition），设备不支持时自动回退到苹果服务器识别。
final class TranscriptionService {
    static let shared = TranscriptionService()

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

        // 决定识别模式：优先本机
        var onDevice = forceOnline ? false : (recognizer.supportsOnDeviceRecognition == true)
        AppLogger.log("开始转写 \(url.lastPathComponent)，本机识别: \(onDevice)")

        do {
            return try await runRecognition(recognizer: recognizer, url: url, onDevice: onDevice)
        } catch {
            // 本机识别失败（部分设备不支持）时回退到服务器识别
            if onDevice {
                AppLogger.log("本机识别失败: \(error.localizedDescription)，回退服务器识别")
                onDevice = false
                return try await runRecognition(recognizer: recognizer, url: url, onDevice: false)
            }
            throw error
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
                        AppLogger.log("转写完成，共 \(accumulated.count) 字")
                        cont.resume(returning: accumulated)
                    }
                } else if let error {
                    // 已有部分结果时不要浪费，返回已识别文本
                    if !accumulated.isEmpty {
                        hasResumed = true
                        AppLogger.log("转写中断但有部分结果: \(error.localizedDescription)")
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
