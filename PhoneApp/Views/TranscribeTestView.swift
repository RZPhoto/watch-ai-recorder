import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

/// 导入音频转写：选择一个音频文件 → 转写 → 显示中文文本
/// v0.6.1：转写交给 App 级任务管理器，导入后可以直接离开页面/锁屏
struct TranscribeTestView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var jobs = TranscriptionJobManager.shared
    @State private var showingImporter = false
    @State private var isTranscribing = false
    @State private var transcript = ""
    @State private var errorMessage: String?
    @State private var pendingRecord: MeetingRecord?

    var body: some View {
        VStack(spacing: 16) {
            if isTranscribing {
                if jobs.totalSegments > 0 {
                    ProgressView(value: jobs.progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(jobs.progress * 100))% · \(jobs.completedSegments)/\(jobs.totalSegments) 段 · 已识别 \(jobs.characters) 字")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("正在分析音频…")
                }
                Text("可以退出本页或锁屏，转写会在后台继续")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    showingImporter = true
                } label: {
                    Label("选择音频文件（m4a / mp3 / wav）", systemImage: "folder.badge.plus")
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
                NavigationLink {
                    SummaryView(transcript: transcript, record: pendingRecord)
                } label: {
                    Label("生成会议纪要", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            } else if !isTranscribing {
                ContentUnavailableView(
                    "暂无转写结果",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("选择一个中文音频文件开始转写")
                )
            }
        }
        .padding()
        .navigationTitle("导入音频转写")
        .onAppear(perform: syncWithJob)
        .onChange(of: jobs.state) { _, _ in syncWithJob() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: audioTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    private func syncWithJob() {
        switch jobs.state {
        case .running:
            isTranscribing = true
        case .finished:
            guard let result = jobs.outcome else { return }
            transcript = result.text
            pendingRecord = jobs.lastRecord
            isTranscribing = false
            jobs.resetState()
        case .failed(let message):
            errorMessage = message
            isTranscribing = false
            jobs.resetState()
        case .idle:
            break
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
            Task { await prepareAndStart(at: url) }
        }
    }

    private func prepareAndStart(at sourceURL: URL) async {
        errorMessage = nil
        transcript = ""
        pendingRecord = nil

        do {
            // fileImporter 返回 security-scoped URL，先拷进沙盒（同时充当历史记录的音频副本）
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

            let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
            let savedURL = RecorderService.recordingsDirectory
                .appendingPathComponent("import-\(UUID().uuidString.prefix(8))")
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: sourceURL, to: savedURL)

            let asset = AVURLAsset(url: savedURL)
            let duration = (try? await asset.load(.duration).seconds) ?? 0

            AppLogger.log("导入音频：\(sourceURL.lastPathComponent)（\(String(format: "%.1f", duration)) 秒）")
            jobs.resetState()
            jobs.start(audioURL: savedURL, duration: duration, titlePrefix: "导入 \(sourceURL.lastPathComponent)")
            isTranscribing = true
        } catch {
            AppLogger.log("导入失败: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }
}
