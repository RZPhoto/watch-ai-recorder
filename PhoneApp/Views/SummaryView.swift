import SwiftUI
import SwiftData

/// 会议纪要页：把转写文本交给 DeepSeek，生成标题 / 概述 / 要点 / 待办
/// 传入 record 时（v0.6），生成结果会自动存入历史记录
struct SummaryView: View {
    let transcript: String
    var record: MeetingRecord?

    @Environment(\.modelContext) private var modelContext
    @State private var summary: MeetingSummary?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var copiedTranscript = false

    var body: some View {
        List {
            if let summary {
                Section("标题") {
                    Text(summary.title)
                        .font(.headline)
                }

                Section("概述") {
                    Text(summary.summary)
                        .font(.body)
                }

                if !summary.keyPoints.isEmpty {
                    Section("要点") {
                        ForEach(summary.keyPoints.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Text(summary.keyPoints[index])
                            }
                        }
                    }
                }

                if !summary.todos.isEmpty {
                    Section("待办") {
                        ForEach(summary.todos.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "square")
                                    .foregroundStyle(.secondary)
                                Text(summary.todos[index])
                            }
                        }
                    }
                }

                Section {
                    Button {
                        UIPasteboard.general.string = summary.markdown
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "已复制到剪贴板" : "复制纪要", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }

                    ShareLink(item: summary.markdown) {
                        Label("分享 / 存到文件", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let cleaned = summary?.cleanTranscript, !cleaned.isEmpty {
                Section {
                    Text(cleaned)
                        .font(.footnote)
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = cleaned
                        copiedTranscript = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedTranscript = false }
                    } label: {
                        Label(copiedTranscript ? "已复制" : "复制校对后文字",
                              systemImage: copiedTranscript ? "checkmark" : "doc.on.doc")
                    }

                    DisclosureGroup("查看原始转写（\(transcript.count) 字，未校对）") {
                        Text(transcript)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("校对后全文")
                }
            } else {
                Section("转写原文（\(transcript.count) 字）") {
                    Text(transcript)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("会议纪要")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    Task { await generate() }
                } label: {
                    HStack(spacing: 8) {
                        if isGenerating {
                            ProgressView()
                        }
                        Text(isGenerating ? "生成中…" : (summary == nil ? "生成会议纪要" : "重新生成"))
                        Image(systemName: "sparkles")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating)
                .padding()
            }
            .background(.bar)
        }
    }

    private func generate() async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            summary = try await SummaryService.shared.summarize(transcript: transcript)
            // v0.6：写入历史记录
            if let record {
                record.apply(summary: summary)
                try? modelContext.save()
                AppLogger.log("纪要已存入历史记录：\(record.title)")
            }
        } catch {
            AppLogger.log("生成纪要失败：\(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }
}
