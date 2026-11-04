import Foundation
import SwiftData

/// 历史记录：一次录音/导入转写的完整档案（v0.6 新增）
/// 转写完成后创建，AI 纪要生成后回填；音频文件保留在 Documents/Recordings
@Model
final class MeetingRecord {
    var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    /// 音频文件名（位于 Documents/Recordings），导入音频时可能为空
    var audioFileName: String
    var title: String
    var summaryText: String
    var keyPointsJSON: String
    var todosJSON: String
    var rawTranscript: String
    var cleanTranscript: String
    var markdown: String
    var hasSummary: Bool
    var updatedAt: Date

    init(id: UUID = UUID(),
         createdAt: Date = .now,
         duration: TimeInterval = 0,
         audioFileName: String = "",
         title: String = "未命名录音",
         summaryText: String = "",
         keyPointsJSON: String = "[]",
         todosJSON: String = "[]",
         rawTranscript: String = "",
         cleanTranscript: String = "",
         markdown: String = "",
         hasSummary: Bool = false,
         updatedAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.title = title
        self.summaryText = summaryText
        self.keyPointsJSON = keyPointsJSON
        self.todosJSON = todosJSON
        self.rawTranscript = rawTranscript
        self.cleanTranscript = cleanTranscript
        self.markdown = markdown
        self.hasSummary = hasSummary
        self.updatedAt = updatedAt
    }

    // MARK: - 数组字段的便捷读写

    var keyPoints: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(keyPointsJSON.utf8))) ?? [] }
        set { keyPointsJSON = String(data: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
    }

    var todos: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(todosJSON.utf8))) ?? [] }
        set { todosJSON = String(data: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
    }

    /// 转写完成时调用（纪要尚未生成）
    func fill(transcript: String, duration: TimeInterval, audioFileName: String) {
        self.rawTranscript = transcript
        if duration > 0 { self.duration = duration }
        if !audioFileName.isEmpty { self.audioFileName = audioFileName }
        updatedAt = .now
    }

    /// AI 纪要生成后调用
    func apply(summary: MeetingSummary) {
        title = summary.title
        summaryText = summary.summary
        keyPoints = summary.keyPoints
        todos = summary.todos
        cleanTranscript = summary.cleanTranscript ?? ""
        markdown = summary.markdown
        hasSummary = true
        updatedAt = .now
    }
}
