import Foundation

/// AI 总结结果：结构固定，便于界面分区展示
struct MeetingSummary: Decodable {
    let title: String
    let summary: String
    let keyPoints: [String]
    let todos: [String]
    /// 校对后的全文（补标点、修错字）；模型未返回时为 nil
    let cleanTranscript: String?

    /// 网络或解析异常时的兜底展示（把模型原文放进 summary）
    static func plain(_ text: String) -> MeetingSummary {
        MeetingSummary(title: "会议纪要", summary: text, keyPoints: [], todos: [], cleanTranscript: nil)
    }

    /// 拼成可直接分享的 Markdown 文本
    var markdown: String {
        var lines: [String] = ["# \(title)", "", summary]
        if !keyPoints.isEmpty {
            lines.append("")
            lines.append("## 要点")
            lines.append(contentsOf: keyPoints.map { "- \($0)" })
        }
        if !todos.isEmpty {
            lines.append("")
            lines.append("## 待办")
            lines.append(contentsOf: todos.map { "- [ ] \($0)" })
        }
        if let cleanTranscript, !cleanTranscript.isEmpty {
            lines.append("")
            lines.append("## 会议全文")
            lines.append(cleanTranscript)
        }
        return lines.joined(separator: "\n")
    }
}

enum SummaryError: LocalizedError {
    case missingAPIKey
    case badResponse(Int, String)
    case malformedResponse
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "还没配置 DeepSeek API Key。请到 设置与日志 → AI 总结设置 里填入 sk- 开头的 Key"
        case .badResponse(let code, let body):
            if code == 401 {
                return "API Key 无效或已失效（401），请到设置页重新填写"
            }
            if code == 402 {
                return "DeepSeek 账户余额不足（402），请充值后再试"
            }
            if code == 429 {
                return "请求太频繁（429），等几秒再试"
            }
            return "请求失败（\(code)）：\(body)"
        case .malformedResponse:
            return "接口返回格式异常，请稍后重试"
        case .emptyTranscript:
            return "转写内容为空，没有可总结的文字"
        }
    }
}

/// 会议纪要服务：调用 DeepSeek Chat Completions 生成结构化纪要
final class SummaryService {
    static let shared = SummaryService()

    private let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private let modelsEndpoint = URL(string: "https://api.deepseek.com/models")!
    private let model = "deepseek-chat"

    private static let systemPrompt = """
    你是中文会议纪要助手。用户会给你一段会议录音的自动转写文本，可能有错别字、缺标点、断句错误。

    请完成三件事：
    1. 校对全文：补全标点、正确分句、修正明显的语音识别错字（例如把"整理成绩"改成"整理成纪要"），保留原意，不删减实质内容
    2. 整理成结构化纪要
    3. 提取待办事项

    只输出一个 JSON 对象，不要输出任何解释文字，不要使用 Markdown 代码块。JSON 结构严格如下：
    {
      "title": "会议标题，不超过 20 字，从内容推断",
      "summary": "两到四句话的总体概述",
      "keyPoints": ["讨论要点，每条一句话，3 到 8 条"],
      "todos": ["待办事项，带负责人和时间（原文提到才写）"],
      "cleanTranscript": "校对后的完整文字，保留全部内容，只补标点和改错字"
    }

    要求：
    - 全部使用简体中文
    - 不要编造原文没有的信息，不确定的内容宁可不写
    - todos 必须是可以执行的具体动作：凡是原文提到、有明确交付物或时间节点的事项都要列进去（包括规划要做的工作），不要把讨论过程和背景描述当成待办
    - 同一件事合并成一条，不要拆成多条重复项
    """

    /// 生成会议纪要
    func summarize(transcript: String) async throws -> MeetingSummary {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummaryError.emptyTranscript }

        let key = try apiKey()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.2,
            "max_tokens": 2000,
            "stream": false,
            "response_format": ["type": "json_object"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        AppLogger.log("AI 总结：发送 \(text.count) 字，请求 DeepSeek")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        guard statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            AppLogger.log("AI 总结失败：HTTP \(statusCode)")
            throw SummaryError.badResponse(statusCode, String(bodyText.prefix(300)))
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            AppLogger.log("AI 总结失败：响应结构异常")
            throw SummaryError.malformedResponse
        }

        let summary = Self.parse(content)
        AppLogger.log("AI 总结完成：\(summary.keyPoints.count) 条要点，\(summary.todos.count) 条待办")
        return summary
    }

    /// 校验 Key 是否可用（只查模型列表，不消耗 token）
    func verifyKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummaryError.missingAPIKey }

        var request = URLRequest(url: modelsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw SummaryError.badResponse(statusCode, String(bodyText.prefix(200)))
        }
    }

    private func apiKey() throws -> String {
        guard let key = KeychainStore.get(KeychainStore.deepseekAPIKey),
              !key.isEmpty else {
            throw SummaryError.missingAPIKey
        }
        return key
    }

    /// 解析模型输出：容错处理 ```json 包裹、前后多余文字
    private static func parse(_ content: String) -> MeetingSummary {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = text.range(of: "```") {
            var stripped = String(text[start.upperBound...])
            if stripped.hasPrefix("json") {
                stripped = String(stripped.dropFirst(4))
            }
            if let end = stripped.range(of: "```") {
                stripped = String(stripped[..<end.lowerBound])
            }
            text = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 再退一步：直接截取第一个 { 到最后一个 }
        if !text.hasPrefix("{"), let first = text.firstIndex(of: "{"),
           let last = text.lastIndex(of: "}") {
            text = String(text[first...last])
        }

        guard let data = text.data(using: .utf8) else {
            return .plain(content)
        }
        do {
            let summary = try JSONDecoder().decode(MeetingSummary.self, from: data)
            return summary
        } catch {
            AppLogger.log("AI 总结 JSON 解析失败，使用原文兜底：\(error.localizedDescription)")
            return .plain(content)
        }
    }
}
