import Foundation
import SwiftUI
import SwiftData
import UIKit

/// 未完成转写的断点（写成 JSON 存沙盒，App 被杀后还能续）
struct TranscriptionCheckpoint: Codable, Identifiable {
    var id: String
    var audioFileName: String
    var titlePrefix: String
    var createdAt: Date
    var duration: Double
    var totalSegments: Int
    /// 段序号（字符串形式）→ 该段文本
    var segments: [String: String]

    var completedCount: Int { segments.count }
    var percent: Int {
        guard totalSegments > 0 else { return 0 }
        return min(100, Int(Double(completedCount) / Double(totalSegments) * 100))
    }
}

/// 转写任务管理器（v0.6.1 新增）
///
/// 解决的问题：原来转写是视图里的一个 Task，退出页面即被取消，锁屏后 App 挂起也会中断。
/// 现在：
/// - 转写任务挂在单例上，与页面生命周期解绑，退出页面不影响
/// - 转写期间播放静音音频保活，锁屏也能继续跑
/// - 每完成一段写一次断点文件，App 被杀后下次启动可"继续转写"
/// - 完成后统一创建历史记录，不再依赖某个页面还在不在
@MainActor
final class TranscriptionJobManager: ObservableObject {
    static let shared = TranscriptionJobManager()

    enum State: Equatable {
        case idle
        case running
        case finished
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var completedSegments = 0
    @Published private(set) var totalSegments = 0
    @Published private(set) var characters = 0
    @Published private(set) var currentFileName = ""
    @Published private(set) var outcome: TranscriptionOutcome?
    /// 本次转写创建的历史记录（页面据此跳到纪要页）
    @Published private(set) var lastRecord: MeetingRecord?
    /// 存在未完成的断点（App 重启后用于"继续转写"入口）
    @Published private(set) var pendingCheckpoint: TranscriptionCheckpoint?

    private var container: ModelContainer?
    private var task: Task<Void, Never>?
    private var checkpoint: TranscriptionCheckpoint?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    // MARK: - 配置与断点

    func configure(container: ModelContainer) {
        self.container = container
    }

    private static var jobsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptionJobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func checkpointURL(id: String) -> URL {
        jobsDirectory.appendingPathComponent("\(id).json")
    }

    /// 启动时调用：找出上次没跑完的任务
    func loadPendingCheckpoint() {
        guard state != .running else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.jobsDirectory,
                                                                 includingPropertiesForKeys: nil)) ?? []
        let decoded: [TranscriptionCheckpoint] = files.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let cp = try? JSONDecoder().decode(TranscriptionCheckpoint.self, from: data) else { return nil }
            return cp
        }
        pendingCheckpoint = decoded.max(by: { $0.createdAt < $1.createdAt })
        if let cp = pendingCheckpoint {
            AppLogger.log("发现未完成转写：\(cp.audioFileName)，\(cp.percent)%（\(cp.completedCount)/\(cp.totalSegments) 段）")
        }
    }

    // MARK: - 启动 / 继续 / 取消

    func start(audioURL: URL, duration: TimeInterval, titlePrefix: String = "录音") {
        guard state != .running else {
            AppLogger.log("已有转写任务在跑，忽略新的启动请求")
            return
        }
        let cp = TranscriptionCheckpoint(id: UUID().uuidString,
                                         audioFileName: audioURL.lastPathComponent,
                                         titlePrefix: titlePrefix,
                                         createdAt: .now,
                                         duration: duration,
                                         totalSegments: 0,
                                         segments: [:])
        checkpoint = cp
        pendingCheckpoint = cp
        saveCheckpoint(cp)
        run(audioURL: audioURL, resume: [:], titlePrefix: titlePrefix)
    }

    /// 继续上次没跑完的任务
    func resumePending() {
        guard state != .running else { return }
        guard let cp = pendingCheckpoint ?? loadLatestCheckpoint() else { return }
        let url = RecorderService.recordingsDirectory.appendingPathComponent(cp.audioFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLogger.log("续转失败：音频文件已不存在 \(cp.audioFileName)")
            clearCheckpoint(cp.id)
            pendingCheckpoint = nil
            state = .failed("原音频文件已被删除，无法继续转写")
            return
        }
        var resume: [Int: String] = [:]
        for (key, value) in cp.segments where !value.isEmpty {
            if let index = Int(key) { resume[index] = value }
        }
        checkpoint = cp
        AppLogger.log("续转：\(cp.audioFileName)，已完成 \(resume.count)/\(cp.totalSegments) 段")
        run(audioURL: url, resume: resume, titlePrefix: cp.titlePrefix)
    }

    func cancel() {
        task?.cancel()
        task = nil
        SilentAudioKeeper.shared.stop()
        endBackgroundExecution()
        state = .idle
        AppLogger.log("转写任务已取消（断点保留，可继续）")
    }

    // MARK: - 核心流程

    private func run(audioURL: URL, resume: [Int: String], titlePrefix: String) {
        state = .running
        completedSegments = resume.count
        totalSegments = checkpoint?.totalSegments ?? 0
        characters = resume.values.reduce(0) { $0 + $1.count }
        progress = 0
        outcome = nil
        currentFileName = audioURL.lastPathComponent

        beginBackgroundExecution()
        SilentAudioKeeper.shared.start()

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await TranscriptionService.shared.transcribe(
                    url: audioURL,
                    resumeCheckpoint: resume,
                    progress: { info in
                        Task { @MainActor [weak self] in
                            self?.apply(progress: info)
                        }
                    },
                    onSegmentFinished: { index, text in
                        Task { @MainActor [weak self] in
                            self?.persist(segment: index, text: text)
                        }
                    }
                )
                self.finish(result: result, audioURL: audioURL, titlePrefix: titlePrefix)
            } catch is CancellationError {
                self.state = .idle
                self.stopKeepAlive()
            } catch {
                self.fail(error: error)
            }
        }
    }

    private func apply(progress info: TranscriptionProgress) {
        totalSegments = info.total
        completedSegments = info.completed
        characters = info.characters
        progress = info.total > 0 ? Double(info.completed) / Double(info.total) : 0
        if var cp = checkpoint {
            cp.totalSegments = info.total
            checkpoint = cp
            pendingCheckpoint = cp
        }
    }

    private func persist(segment index: Int, text: String) {
        guard var cp = checkpoint else { return }
        cp.segments[String(index)] = text
        checkpoint = cp
        pendingCheckpoint = cp
        saveCheckpoint(cp)
    }

    private func finish(result: TranscriptionOutcome, audioURL: URL, titlePrefix: String) {
        outcome = result
        state = .finished
        progress = 1
        characters = result.characters
        stopKeepAlive()

        if let container, !result.text.isEmpty {
            let timeText = Date.now.formatted(.dateTime.month().day().hour().minute())
            let record = MeetingRecord(duration: result.duration > 0 ? result.duration : (checkpoint?.duration ?? 0),
                                       audioFileName: audioURL.lastPathComponent,
                                       title: "\(titlePrefix) \(timeText)",
                                       rawTranscript: result.text)
            container.mainContext.insert(record)
            try? container.mainContext.save()
            lastRecord = record
        }

        if let cp = checkpoint {
            clearCheckpoint(cp.id)
        }
        checkpoint = nil
        pendingCheckpoint = nil
        AppLogger.log("转写任务完成：\(result.characters) 字，空段 \(result.emptySegments)/\(result.totalSegments)，已生成历史记录")
    }

    private func fail(error: Error) {
        state = .failed(error.localizedDescription)
        stopKeepAlive()
        AppLogger.log("转写任务失败：\(error.localizedDescription)（断点已保留）")
    }

    func resetState() {
        guard state != .running else { return }
        state = .idle
        outcome = nil
    }

    // MARK: - 断点文件

    private func saveCheckpoint(_ cp: TranscriptionCheckpoint) {
        guard let data = try? JSONEncoder().encode(cp) else { return }
        try? data.write(to: Self.checkpointURL(id: cp.id), options: .atomic)
    }

    private func clearCheckpoint(_ id: String) {
        try? FileManager.default.removeItem(at: Self.checkpointURL(id: id))
    }

    private func loadLatestCheckpoint() -> TranscriptionCheckpoint? {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.jobsDirectory,
                                                                 includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> TranscriptionCheckpoint? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(TranscriptionCheckpoint.self, from: data)
        }.max(by: { $0.createdAt < $1.createdAt })
    }

    // MARK: - 后台保活

    private func beginBackgroundExecution() {
        endBackgroundExecution()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Transcription") { [weak self] in
            Task { @MainActor in self?.endBackgroundExecution() }
        }
    }

    private func endBackgroundExecution() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func stopKeepAlive() {
        SilentAudioKeeper.shared.stop()
        endBackgroundExecution()
    }
}
