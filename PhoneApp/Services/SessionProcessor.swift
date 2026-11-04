import Foundation
import SwiftData

/// 处理流水线：音频文件 → 转写 → LLM 分析 → 落库
@MainActor
final class SessionProcessor {
    static let shared = SessionProcessor()

    func processFile(at sourceURL: URL,
                     duration: TimeInterval,
                     in context: ModelContext) async -> Session {
        // 1. 建会话记录
        let session = Session(duration: duration, status: .transcribing)
        context.insert(session)
        try? context.save()

        do {
            // 2. 把音频拷贝到持久目录
            let audioDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Audio/\(session.id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
            let audioURL = audioDir.appendingPathComponent("source.m4a")
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: sourceURL, to: audioURL)
            session.audioPath = "Audio/\(session.id.uuidString)/source.m4a"
            try? context.save()

            // 3. 转写
            AppLogger.log("会话 \(session.id.uuidString.prefix(8)) 开始转写")
            let text = try await TranscriptionService.shared.transcribe(url: audioURL)
            session.rawTranscript = text
            try? context.save()

            guard !text.isEmpty else {
                session.status = .failed
                session.errorMessage = "转写结果为空"
                try? context.save()
                return session
            }

            // 4. LLM 分析（配置了 Key 才做；没配置则直接完成）
            if LLMService.isConfigured {
                session.status = .analyzing
                try? context.save()
                let analysis = try await LLMService().analyze(transcript: text)
                session.title = analysis.title.isEmpty ? session.title : analysis.title
                context.insert(Insight(kind: .summary, content: analysis.summary, session: session))
                if !analysis.keyPoints.isEmpty {
                    context.insert(Insight(kind: .keyPoints,
                                           content: analysis.keyPoints.joined(separator: "\n• "),
                                           session: session))
                }
                if !analysis.todos.isEmpty {
                    let todoText = analysis.todos
                        .map { "\($0.task)\($0.due.map { "（截止 \($0)）" } ?? "")" }
                        .joined(separator: "\n• ")
                    context.insert(Insight(kind: .todos, content: "• " + todoText, session: session))
                }
                if !analysis.topics.isEmpty {
                    context.insert(Insight(kind: .topics,
                                           content: analysis.topics.joined(separator: "、"),
                                           session: session))
                }
            } else {
                AppLogger.log("未配置 LLM Key，跳过 AI 分析")
            }

            session.status = .done
            try? context.save()
            AppLogger.log("会话 \(session.id.uuidString.prefix(8)) 处理完成")
        } catch {
            AppLogger.log("会话 \(session.id.uuidString.prefix(8)) 处理失败：\(error.localizedDescription)")
            session.status = .failed
            session.errorMessage = error.localizedDescription
            try? context.save()
        }
        return session
    }

    /// 对已有会话重新做 LLM 分析
    func reanalyze(session: Session, in context: ModelContext) async {
        guard !session.rawTranscript.isEmpty else { return }
        session.status = .analyzing
        session.errorMessage = nil
        try? context.save()
        do {
            let analysis = try await LLMService().analyze(transcript: session.rawTranscript)
            session.title = analysis.title.isEmpty ? session.title : analysis.title
            // 清掉旧 Insight 重新写入
            session.insights?.forEach { context.delete($0) }
            context.insert(Insight(kind: .summary, content: analysis.summary, session: session))
            if !analysis.keyPoints.isEmpty {
                context.insert(Insight(kind: .keyPoints,
                                       content: analysis.keyPoints.joined(separator: "\n• "),
                                       session: session))
            }
            if !analysis.todos.isEmpty {
                let todoText = analysis.todos
                    .map { "\($0.task)\($0.due.map { "（截止 \($0)）" } ?? "")" }
                    .joined(separator: "\n• ")
                context.insert(Insight(kind: .todos, content: "• " + todoText, session: session))
            }
            if !analysis.topics.isEmpty {
                context.insert(Insight(kind: .topics,
                                       content: analysis.topics.joined(separator: "、"),
                                       session: session))
            }
            session.status = .done
            try? context.save()
        } catch {
            session.status = .failed
            session.errorMessage = error.localizedDescription
            try? context.save()
        }
    }
}
