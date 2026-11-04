import Foundation
import Speech
import AVFoundation

enum TranscribeError: LocalizedError {
    case speechNotAuthorized
    case micNotAuthorized
    case recognizerUnavailable
    case exportFailed(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized: return "未获得语音识别权限，请到 设置-隐私与安全性-语音识别 中允许"
        case .micNotAuthorized: return "未获得麦克风权限，请到 设置-隐私与安全性-麦克风 中允许"
        case .recognizerUnavailable: return "中文语音识别服务不可用，请稍后重试"
        case .exportFailed(let reason): return "音频分段失败：\(reason)"
        case .emptyAudio: return "音频为空或无法读取"
        }
    }
}

/// 一段待转写的音频窗口
struct TranscriptionSegment: Sendable {
    let index: Int
    let start: Double
    let end: Double
    var length: Double { max(0, end - start) }
}

/// 进度快照（跨线程传递用）
struct TranscriptionProgress: Sendable {
    let completed: Int
    let total: Int
    let characters: Int
}

/// 转写结果
struct TranscriptionOutcome: Sendable {
    let text: String
    let totalSegments: Int
    let emptySegments: Int
    let duration: Double

    var characters: Int { text.count }
    /// 有内容产出的段占比（用于判断录音是否拾音过弱）
    var coverage: Double {
        totalSegments == 0 ? 0 : Double(totalSegments - emptySegments) / Double(totalSegments)
    }
}

/// 转写服务 v2（v0.6.1 重写）
///
/// 针对 v0.5.2 真机暴露的三个问题做了改造：
/// 1. 速度：原来 179 段串行，每段 2 秒左右，89 分钟录音要 6 分钟。现在 4 路并发，
///    单段只发一次请求，只有"极短结果"才扩窗复检，整体约 3~4 倍提速。
/// 2. 缺失：原来分段固定 30 秒且失败直接跳过；现在 45 秒一段（上下文更完整），
///    空结果/极短结果会用前后各扩 4 秒的窗口重跑一次，把被切断的语音捞回来；
///    末尾碎片段自动并入上一段而不是丢弃。
/// 3. 不准：本机识别对文件转写明显更差（v0.3.1 已证实），现在只做网络异常兜底，
///    正常路径一律走苹果服务器识别，并开启自动标点与会议词表。
final class TranscriptionService: @unchecked Sendable {
    static let shared = TranscriptionService()

    /// 单段最长时长。苹果服务器识别单次上限约 1 分钟，45 秒留出安全余量
    static let chunkSeconds: Double = 45
    /// 同时进行的识别路数（苹果服务器一般能承受 3~5 路）
    static let concurrency = 4
    /// 低于该时长的碎片段并入上一段
    static let minSegmentSeconds: Double = 3.0
    /// 结果字数低于 时长×该值 视为"疑似丢失"，需要扩窗复检
    static let weakCharsPerSecond: Double = 0.35

    private let locale = Locale(identifier: "zh-CN")

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

    /// 转写音频文件
    /// - Parameters:
    ///   - resumeCheckpoint: 已完成的分段（段序号 → 文本），用于断点续转
    ///   - progress: 进度回调，可能来自后台线程
    ///   - onSegmentFinished: 每段完成回调（段序号, 文本），用于落盘断点
    func transcribe(url: URL,
                    resumeCheckpoint: [Int: String] = [:],
                    progress: (@Sendable (TranscriptionProgress) -> Void)? = nil,
                    onSegmentFinished: (@Sendable (Int, String) -> Void)? = nil) async throws -> TranscriptionOutcome {
        try await requestPermissions()

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0.6 else { throw TranscribeError.emptyAudio }
        AppLogger.log("音频时长 \(String(format: "%.1f", duration)) 秒，文件 \(url.lastPathComponent)")

        let segments = Self.makeSegments(duration: duration)
        let resumedCount = resumeCheckpoint.keys.filter { $0 < segments.count }.count
        AppLogger.log("切分为 \(segments.count) 段（每段 \(Int(Self.chunkSeconds))s，\(Self.concurrency) 路并发，续转 \(resumedCount) 段）")

        let run = SegmentRun(segments: segments, resumed: resumeCheckpoint)
        var initial = await run.snapshot()
        progress?(TranscriptionProgress(completed: initial.completed,
                                       total: segments.count,
                                       characters: initial.characters))

        try await withThrowingTaskGroup(of: Void.self) { group in
            let workers = min(Self.concurrency, max(1, segments.count - resumedCount))
            for _ in 0..<workers {
                group.addTask { [weak self] in
                    guard let self else { return }
                    while true {
                        try Task.checkCancellation()
                        guard let segment = await run.claim() else { break }
                        let text = await self.transcribe(segment: segment, of: url, duration: duration)
                        let snap = await run.record(text: text, for: segment.index)
                        onSegmentFinished?(segment.index, text)
                        progress?(TranscriptionProgress(completed: snap.completed,
                                                       total: segments.count,
                                                       characters: snap.characters))
                    }
                }
            }
            try await group.waitForAll()
        }

        let final = await run.snapshot()
        AppLogger.log("转写完成：\(final.completed)/\(segments.count) 段，空段 \(final.emptyCount) 段，共 \(final.characters) 字，覆盖率 \(Int(final.coverage * 100))%")

        return TranscriptionOutcome(text: final.text,
                                    totalSegments: segments.count,
                                    emptySegments: final.emptyCount,
                                    duration: duration)
    }

    // MARK: - 分段

    /// 按固定窗口切分；最后一段若过短则并入上一段（避免出现 0.8 秒碎片段）
    static func makeSegments(duration: Double) -> [TranscriptionSegment] {
        guard duration > 0 else { return [] }
        var segments: [TranscriptionSegment] = []
        var start = 0.0
        var index = 0
        while start < duration - 0.2 {
            var end = min(start + chunkSeconds, duration)
            let remaining = duration - end
            // 剩余不足一个最小时长时，直接并到这一段里
            if remaining > 0 && remaining < minSegmentSeconds {
                end = duration
            }
            segments.append(TranscriptionSegment(index: index, start: start, end: end))
            index += 1
            start = end
        }
        return segments
    }

    // MARK: - 单段转写

    private func transcribe(segment: TranscriptionSegment, of source: URL, duration: Double) async -> String {
        // 1) 标准窗口
        var text = await recognizeWindow(source: source,
                                         start: segment.start,
                                         length: segment.length)

        // 2) 结果异常少：前后各扩 4 秒重跑，捞回被切在边界上的语音
        let weakThreshold = max(4.0, segment.length * Self.weakCharsPerSecond)
        if Double(text.count) < weakThreshold && segment.length > 6 {
            let expandedStart = max(0, segment.start - 4)
            let expandedEnd = min(duration, segment.end + 4)
            let expanded = await recognizeWindow(source: source,
                                                 start: expandedStart,
                                                 length: expandedEnd - expandedStart)
            if expanded.count > text.count {
                AppLogger.log("第 \(segment.index + 1) 段扩窗复检：\(text.count) → \(expanded.count) 字")
                text = expanded
            }
        }
        return text
    }

    /// 导出一段音频并识别；网络异常时回退本机识别，"没人说话"不重试
    private func recognizeWindow(source: URL, start: Double, length: Double) async -> String {
        guard length >= 0.6 else { return "" }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        do {
            try await Self.exportSegment(of: source, from: start, length: length, to: destination)
        } catch {
            AppLogger.log("切片导出失败（\(Int(start))s）：\(error.localizedDescription)")
            return ""
        }
        defer { try? FileManager.default.removeItem(at: destination) }

        let timeout = max(25, length * 2 + 12)
        do {
            return try await runRecognition(url: destination, onDevice: false, timeout: timeout)
        } catch {
            if Self.isSpeechAbsent(error) {
                return ""
            }
            AppLogger.log("服务器识别异常（\(Int(start))s）：\(error.localizedDescription)，回退本机")
            let fallback = (try? await runRecognition(url: destination, onDevice: true, timeout: timeout)) ?? ""
            return fallback
        }
    }

    /// "没有检测到语音"属于正常情况（静音段），不需要回退引擎
    private static func isSpeechAbsent(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain" || ns.domain == "SFSpeechErrorDomain" {
            if [1101, 1110, 203, 216].contains(ns.code) { return true }
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("no speech") || message.contains("没有检测到语音")
    }

    // MARK: - 底层识别

    /// 识别任务持有者：保证回调与超时竞争时只收尾一次
    private final class RecognitionBridge {
        private let lock = NSLock()
        private var text = ""
        private var finished = false
        var task: SFSpeechRecognitionTask?

        func append(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            text = value
        }

        func finishIfNeeded() -> String? {
            lock.lock(); defer { lock.unlock() }
            if finished { return nil }
            finished = true
            return text
        }
    }

    private func runRecognition(url: URL, onDevice: Bool, timeout: TimeInterval) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscribeError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = [
            "会议纪要", "待办事项", "项目沟通会", "转写", "录音", "预算",
            "上线", "需求", "排期", "验收", "原型", "黑名单", "推荐引擎", "小程序"
        ]

        let bridge = RecognitionBridge()
        let label = onDevice ? "本机" : "服务器"

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            bridge.task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    bridge.append(result.bestTranscription.formattedString)
                    if result.isFinal, let text = bridge.finishIfNeeded() {
                        bridge.task = nil
                        cont.resume(returning: text)
                    }
                } else if let error {
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

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard let text = bridge.finishIfNeeded() else { return }
                bridge.task?.cancel()
                bridge.task = nil
                if text.isEmpty {
                    cont.resume(throwing: TranscribeError.recognizerUnavailable)
                } else {
                    AppLogger.log("识别超时（\(label)），返回已识别的 \(text.count) 字")
                    cont.resume(returning: text)
                }
            }
        }
    }

    /// 用 AVAssetExportSession 把指定时间段导出为独立 m4a
    private static func exportSegment(of source: URL, from start: Double, length: Double, to destination: URL) async throws {
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
}

// MARK: - 并发取段与结果收集

/// 线程安全的分段队列 + 结果拼装器
private actor SegmentRun {
    struct Snapshot {
        let completed: Int
        let emptyCount: Int
        let characters: Int
        let coverage: Double
        let text: String
    }

    private let segments: [TranscriptionSegment]
    private var nextIndex = 0
    private var texts: [Int: String]

    init(segments: [TranscriptionSegment], resumed: [Int: String]) {
        self.segments = segments
        var seeded: [Int: String] = [:]
        for (index, text) in resumed where index >= 0 && index < segments.count {
            seeded[index] = text
        }
        self.texts = seeded
        // 续转时跳过已完成的段
        self.nextIndex = 0
    }

    func claim() -> TranscriptionSegment? {
        while nextIndex < segments.count {
            let segment = segments[nextIndex]
            nextIndex += 1
            if texts[segment.index] == nil { return segment }
        }
        return nil
    }

    func record(text: String, for index: Int) -> Snapshot {
        texts[index] = text
        return makeSnapshot()
    }

    func snapshot() -> Snapshot { makeSnapshot() }

    private func makeSnapshot() -> Snapshot {
        let completed = texts.count
        let empty = texts.values.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let joined = segments.compactMap { texts[$0.index] }.joined()
        return Snapshot(completed: completed,
                        emptyCount: empty,
                        characters: joined.count,
                        coverage: segments.isEmpty ? 0 : Double(segments.count - empty) / Double(segments.count),
                        text: joined)
    }
}
