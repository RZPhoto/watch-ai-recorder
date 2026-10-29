import SwiftUI
import UniformTypeIdentifiers

/// M1 验收界面：选择一个 m4a 音频文件 → 转写 → 显示中文文本
struct TranscribeTestView: View {
    @State private var showingImporter = false
    @State private var isTranscribing = false
    @State private var transcript = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            if isTranscribing {
                ProgressView("转写中，请稍候…")
                    .padding()
            } else {
                Button {
                    showingImporter = true
                } label: {
                    Label("选择音频文件（m4a）", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
            }

            if let errorMessage {
                Text("出错了：\(errorMessage)")
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
            }

            if !transcript.isEmpty {
                ScrollView {
                    Text(transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
            } else if !isTranscribing {
                ContentUnavailableView(
                    "暂无转写结果",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("选择一个中文音频文件开始验证")
                )
            }
        }
        .padding()
        .navigationTitle("转写验证")
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: audioTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    private var audioTypes: [UTType] {
        var types: [UTType] = [.audio]
        if let m4a = UTType(filenameExtension: "m4a") { types.insert(m4a, at: 0) }
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await transcribeFile(at: url) }
        }
    }

    private func transcribeFile(at sourceURL: URL) async {
        isTranscribing = true
        errorMessage = nil
        transcript = ""
        defer { isTranscribing = false }

        do {
            // fileImporter 返回的是 security-scoped URL，先拷贝到沙盒临时目录
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            try FileManager.default.copyItem(at: sourceURL, to: tmpURL)
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            AppLogger.log("M1 验证：开始转写 \(sourceURL.lastPathComponent)")
            let text = try await TranscriptionService.shared.transcribe(url: tmpURL)
            transcript = text
        } catch {
            AppLogger.log("M1 验证失败: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }
}
