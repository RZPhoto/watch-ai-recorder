import Foundation
import SwiftData

enum SessionStatus: String, Codable {
    case transcribing   // 转写中
    case analyzing      // AI 分析中
    case done           // 完成
    case failed         // 失败

    var label: String {
        switch self {
        case .transcribing: return "转写中"
        case .analyzing: return "分析中"
        case .done: return "完成"
        case .failed: return "失败"
        }
    }
}

enum InsightKind: String, Codable {
    case summary, keyPoints, todos, topics

    var label: String {
        switch self {
        case .summary: return "摘要"
        case .keyPoints: return "要点"
        case .todos: return "待办"
        case .topics: return "话题"
        }
    }
}

@Model
final class Session {
    var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    var status: SessionStatus
    var title: String
    var rawTranscript: String
    var errorMessage: String?
    /// 音频文件相对 Documents 的路径，如 Audio/{id}/source.m4a
    var audioPath: String
    @Relationship(deleteRule: .cascade, inverse: \Insight.session)
    var insights: [Insight]?

    init(id: UUID = UUID(),
         createdAt: Date = .now,
         duration: TimeInterval = 0,
         status: SessionStatus = .transcribing,
         title: String = "未命名录音",
         rawTranscript: String = "",
         errorMessage: String? = nil,
         audioPath: String = "") {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.status = status
        self.title = title
        self.rawTranscript = rawTranscript
        self.errorMessage = errorMessage
        self.audioPath = audioPath
    }
}

@Model
final class Insight {
    var id: UUID
    var kindRaw: String
    var content: String
    var createdAt: Date
    var session: Session?

    @Transient var kind: InsightKind {
        get { InsightKind(rawValue: kindRaw) ?? .summary }
        set { kindRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), kind: InsightKind, content: String, createdAt: Date = .now, session: Session? = nil) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.content = content
        self.createdAt = createdAt
        self.session = session
    }
}
