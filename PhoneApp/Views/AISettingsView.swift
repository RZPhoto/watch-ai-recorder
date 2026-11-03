import SwiftUI

/// AI 总结设置：填写并校验 DeepSeek API Key（存钥匙串）
struct AISettingsView: View {
    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var isVerifying = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        Form {
            Section {
                SecureField("sk-xxxxxxxx", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("DeepSeek API Key")
            } footer: {
                Text("在 platform.deepseek.com 的「API keys」页面创建，形如 sk-xxxx。Key 只保存在本机钥匙串，除了 DeepSeek 官方接口不会发送到任何其他地方。")
            }

            Section {
                Button {
                    save()
                } label: {
                    Label("保存 Key", systemImage: "checkmark.circle")
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await verify() }
                } label: {
                    HStack(spacing: 8) {
                        if isVerifying { ProgressView() }
                        Label(isVerifying ? "校验中…" : "校验 Key", systemImage: "bolt.horizontal")
                    }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying)

                if hasStoredKey {
                    Button(role: .destructive) {
                        KeychainStore.delete(KeychainStore.deepseekAPIKey)
                        apiKey = ""
                        hasStoredKey = false
                        show("已删除本机保存的 Key", isError: false)
                    } label: {
                        Label("删除已保存的 Key", systemImage: "trash")
                    }
                }
            } footer: {
                if let message {
                    Text(message)
                        .foregroundStyle(messageIsError ? .red : .green)
                }
            }

            Section("说明") {
                Text("• 只有点「生成会议纪要」时才会调用接口，不会后台自动上传\n• 一段 10 分钟会议（约 2500 字）成本约 0.01 元\n• 转写本身用的是苹果语音识别，和这里的 Key 无关")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AI 总结设置")
        .onAppear {
            apiKey = KeychainStore.get(KeychainStore.deepseekAPIKey) ?? ""
            hasStoredKey = KeychainStore.has(KeychainStore.deepseekAPIKey)
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.set(trimmed, for: KeychainStore.deepseekAPIKey)
        hasStoredKey = !trimmed.isEmpty
        AppLogger.log("AI 设置：已保存 DeepSeek Key（长度 \(trimmed.count)）")
        show("已保存到本机钥匙串", isError: false)
    }

    private func verify() async {
        isVerifying = true
        defer { isVerifying = false }
        do {
            try await SummaryService.shared.verifyKey(apiKey)
            show("Key 有效，可以正常调用", isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}
