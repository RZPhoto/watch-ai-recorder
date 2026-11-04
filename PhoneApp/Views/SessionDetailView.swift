import SwiftUI
import SwiftData

/// 会话详情：AI 分析结果 + 原始转写文本
struct SessionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var session: Session
    @State private var isReanalyzing = false

    var body: some View {
        List {
            if session.status == .failed {
                Section {
                    Label(session.errorMessage ?? "处理失败", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if isReanalyzing {
                Section { ProgressView("AI 分析中…") }
            }

            if let insights = session.insights, !insights.isEmpty {
                ForEach(InsightKind.allCases, id: \.self) { kind in
                    if let insight = insights.first(where: { $0.kind == kind }) {
                        Section(kind.label) {
                            if kind == .keyPoints || kind == .todos {
                                Text(insight.content)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                            } else {
                                Text(insight.content)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    isReanalyzing = true
                    Task {
                        await SessionProcessor.shared.reanalyze(session: session, in: modelContext)
                        isReanalyzing = false
                    }
                } label: {
                    Label(session.status == .failed ? "重试分析" : "重新 AI 分析",
                          systemImage: "arrow.clockwise")
                }
                .disabled(isReanalyzing || session.rawTranscript.isEmpty)
            }

            if !session.rawTranscript.isEmpty {
                Section("原文（\(session.rawTranscript.count) 字）") {
                    Text(session.rawTranscript)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            } else if session.status == .transcribing {
                Section { ProgressView("转写中…") }
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
