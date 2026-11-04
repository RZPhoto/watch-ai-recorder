import SwiftUI
import SwiftData

/// 历史记录列表：所有已转写的录音/导入记录
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MeetingRecord.createdAt, order: .reverse) private var records: [MeetingRecord]

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "还没有记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("完成一次录音或导入转写后，记录会出现在这里")
                )
            } else {
                List {
                    ForEach(records) { record in
                        NavigationLink {
                            HistoryDetailView(record: record)
                        } label: {
                            HistoryRow(record: record)
                        }
                    }
                    .onDelete { indexes in
                        for index in indexes {
                            modelContext.delete(records[index])
                        }
                        try? modelContext.save()
                        AppLogger.log("历史记录：删除 \(indexes.count) 条")
                    }
                }
            }
        }
        .navigationTitle("历史记录")
    }
}

struct HistoryRow: View {
    let record: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.hasSummary ? record.title : "待生成纪要")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if record.hasSummary {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
            }
            HStack {
                Text(record.createdAt.formatted(.dateTime.month().day().hour().minute()))
                Text("·")
                Text("\(Int(record.duration / 60))分\(Int(record.duration.truncatingRemainder(dividingBy: 60)))秒")
                Spacer()
                Text("\(record.rawTranscript.count) 字")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 历史记录详情：回看纪要、重新生成、导出
struct HistoryDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var record: MeetingRecord

    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        List {
            if isGenerating {
                Section { ProgressView("重新生成纪要中…") }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }

            if record.hasSummary {
                Section("标题") {
                    Text(record.title).font(.headline)
                }
                Section("概述") {
                    Text(record.summaryText).textSelection(.enabled)
                }
                if !record.keyPoints.isEmpty {
                    Section("要点") {
                        ForEach(record.keyPoints.indices, id: \.self) { i in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                                Text(record.keyPoints[i])
                            }
                        }
                    }
                }
                if !record.todos.isEmpty {
                    Section("待办") {
                        ForEach(record.todos.indices, id: \.self) { i in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "square").foregroundStyle(.secondary)
                                Text(record.todos[i])
                            }
                        }
                    }
                }
                if !record.cleanTranscript.isEmpty {
                    Section("校对后全文") {
                        Text(record.cleanTranscript)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Section {
                    Text("这条记录还没有生成 AI 纪要")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    regenerate()
                } label: {
                    Label(record.hasSummary ? "重新生成纪要" : "生成会议纪要", systemImage: "sparkles")
                }
                .disabled(isGenerating || record.rawTranscript.isEmpty)

                if record.hasSummary {
                    Button {
                        UIPasteboard.general.string = record.markdown
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "已复制到剪贴板" : "复制纪要 Markdown", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: record.markdown) {
                        Label("分享 / 存到文件", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                if !record.audioFileName.isEmpty {
                    Text("原始音频已保存：\(record.audioFileName)")
                }
            }

            Section("原始转写（\(record.rawTranscript.count) 字）") {
                Text(record.rawTranscript.isEmpty ? "（空）" : record.rawTranscript)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(record.hasSummary ? record.title : "录音详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func regenerate() {
        isGenerating = true
        errorMessage = nil
        Task {
            defer { isGenerating = false }
            do {
                let summary = try await SummaryService.shared.summarize(transcript: record.rawTranscript)
                record.apply(summary: summary)
                try? modelContext.save()
                AppLogger.log("历史记录：重新生成纪要「\(record.title)」")
            } catch {
                AppLogger.log("历史记录：重新生成失败 \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }
}
