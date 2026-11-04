import Foundation

/// LLM 分析服务：OpenAI 兼容接口（默认 DeepSeek），输出结构化 JSON
final class LLMService {
    struct Analysis: Codable {
        var title: String
        var summary: String
        var keyPoints: [String]
        var todos: [Todo]
        var topics: [String]

        struct Todo: Codable {
            var task: String
            var due: String?
        }
    }

    struct LLMError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - 配置（设置页可改）

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "llm.baseURL") ?? "https://api.deepseek.com/v1" }
        set { UserDefaults.standard.set(newValue, forKey: "llm.baseURL") }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: "llm.model") ?? "deepseek-chat" }
        set { UserDefaults.standard.set(newValue, forKey: "llm.model") }
    }
    static var apiKey: String {
        get { KeychainHelper.get("llm.apiKey") }
        set { KeychainHelper.set(newValue, for: "llm.apiKey") }
    }
    static var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - 分析

    func analyze(transcript: String) async throws -> Analysis {
        guard Self.isConfigured else {
            throw LLMError(message: "尚未配置 LLM API Key，请到设置页填写")
        }
        // 超长文本截断：保留前 3000 + 后 5000 字符
        var text = transcript
        if text.count > 8000 {
            text = String(text.prefix(3000)) + "\n……（中间省略）……\n" + String(text.suffix(5000))
        }

        let systemPrompt = """
        你是会议助手。根据用户提供的对话转写文本，只依据文本内容输出 JSON，字段如下：
        {"title":"20字内标题","summary":"3句以内总结","keyPoints":["要点"],
         "todos":[{"task":"任务描述","due":"YYYY-MM-DD或null"}],"topics":["话题"]}
        文本中不存在的信息一律不要编造，对应字段返回空值或空数组。
        """

        let body: [String: Any] = [
            "model": Self.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.3,
            "response_format": ["type": "json_object"]
        ]

        guard let url = URL(string: Self.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw LLMError(message: "Base URL 无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Self.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 失败重试 2 次
        var lastError = ""
        for attempt in 1...3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LLMError(message: "无效响应")
                }
                guard http.statusCode == 200 else {
                    let detail = String(data: data, encoding: .utf8) ?? ""
                    throw LLMError(message: "HTTP \(http.statusCode)：\(detail.prefix(300))")
                }
                // 解析 OpenAI 格式响应，再解析内层 JSON
                guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = outer["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw LLMError(message: "响应格式异常")
                }
                guard let jsonData = content.data(using: .utf8),
                      let analysis = try? JSONDecoder().decode(Analysis.self, from: jsonData) else {
                    throw LLMError(message: "AI 返回内容无法解析：\(content.prefix(200))")
                }
                AppLogger.log("LLM 分析成功：title=\(analysis.title)，待办 \(analysis.todos.count) 条")
                return analysis
            } catch {
                lastError = error.localizedDescription
                AppLogger.log("LLM 分析第 \(attempt) 次失败：\(lastError)")
                if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        throw LLMError(message: lastError)
    }
}
