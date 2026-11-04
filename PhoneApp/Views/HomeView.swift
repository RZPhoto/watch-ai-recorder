import SwiftUI
import SwiftData

/// 主页：录音入口、历史记录、设置入口
struct HomeView: View {
    @Query(sort: \MeetingRecord.createdAt, order: .reverse) private var records: [MeetingRecord]
    @ObservedObject private var jobs = TranscriptionJobManager.shared
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            List {
                if jobs.state == .running || jobs.pendingCheckpoint != nil {
                    jobSection
                }

                Section {
                    NavigationLink {
                        RecordingView()
                    } label: {
                        Label("现场录音", systemImage: "mic.circle.fill")
                    }
                    NavigationLink {
                        TranscribeTestView()
                    } label: {
                        Label("导入音频转写", systemImage: "waveform")
                    }
                } header: {
                    Text("手表 AI 录音助手")
                }

                Section {
                    NavigationLink {
                        HistoryView()
                    } label: {
                        HStack {
                            Label("历史记录", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            if !records.isEmpty {
                                Text("\(records.count) 条")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("设置与日志", systemImage: "gearshape")
                    }
                }

            }
            .navigationTitle("录音助手")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("v0.6.1")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .task {
                TranscriptionJobManager.shared.configure(container: modelContext.container)
                TranscriptionJobManager.shared.loadPendingCheckpoint()
            }
        }
    }

    /// 转写进行中 / 有断点可续
    @ViewBuilder
    private var jobSection: some View {
        Section {
            if jobs.state == .running {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("后台转写中", systemImage: "waveform.badge.mic")
                            .font(.subheadline)
                        Spacer()
                        Text("\(Int(jobs.progress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: jobs.progress)
                        .progressViewStyle(.linear)
                    Text("\(jobs.completedSegments)/\(jobs.totalSegments) 段 · \(jobs.characters) 字 · 可锁屏")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if let cp = jobs.pendingCheckpoint {
                Button {
                    TranscriptionJobManager.shared.resumePending()
                } label: {
                    HStack {
                        Label("有未完成的转写（\(cp.percent)%）", systemImage: "arrow.clockwise.circle")
                        Spacer()
                        Text("继续")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
            }
        } header: {
            Text("转写任务")
        } footer: {
            if jobs.state == .running {
                Text("离开 App 或锁屏都不会中断，完成后自动出现在历史记录")
            }
        }
    }
}
