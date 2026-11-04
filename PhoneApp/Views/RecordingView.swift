import SwiftUI
import SwiftData
import UIKit

/// 现场录音页：开始录音 → 停止 → 自动转写 → 进入 AI 纪要
///
/// v0.6.1：录音与转写都改为 App 级单例，退出页面不再中断；
/// 转写进度实时可见，锁屏后由后台保活继续跑。
struct RecordingView: View {
    @ObservedObject private var recorder = RecorderService.shared
    @ObservedObject private var jobs = TranscriptionJobManager.shared
    @Environment(\.modelContext) private var modelContext

    private enum Phase: Equatable {
        case idle          // 未开始
        case recording     // 录音中
        case transcribing  // 停止后转写中
        case done          // 转写完成
    }

    @State private var phase: Phase = .idle
    @State private var transcript = ""
    @State private var errorMessage: String?
    @State private var pendingRecord: MeetingRecord?

    var body: some View {
        VStack(spacing: 20) {
            switch phase {
            case .idle:
                idleSection
            case .recording:
                recordingSection
            case .transcribing:
                transcribingSection
            case .done:
                resultSection
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding()
        .navigationTitle("现场录音")
        .onAppear(perform: syncWithJob)
        .onChange(of: jobs.state) { _, _ in syncWithJob() }
        .onDisappear {
            // 离开页面不再放弃录音/转写：两者都由 App 级服务持有，会继续运行
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// 把界面状态对齐到正在进行的任务（重进页面、后台跑完回来时都能接上）
    private func syncWithJob() {
        switch jobs.state {
        case .running:
            phase = .transcribing
            errorMessage = nil
        case .finished:
            guard let result = jobs.outcome else { return }
            lastOutcomeSnapshot = result
            transcript = result.text
            pendingRecord = jobs.lastRecord
            phase = .done
            jobs.resetState()
        case .failed(let message):
            errorMessage = message
            phase = .done
            jobs.resetState()
        case .idle:
            break
        }
    }

    // MARK: - 各阶段界面

    private var idleSection: some View {
        VStack(spacing: 28) {
            Image(systemName: "mic.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Button {
                Task { await startRecording() }
            } label: {
                Label("开始录音", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)

            Text("锁屏、切后台、退出本页都会继续录音，停止后自动转写")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var recordingSection: some View {
        VStack(spacing: 28) {
            Text(timeString(recorder.elapsed))
                .font(.system(size: 44, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())

            levelMeter

            if recorder.isTooQuiet {
                Label("声音偏小：把手机朝向说话人、距离 1 米内，识别效果会好很多",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                Button {
                    recorder.isPaused ? recorder.resume() : recorder.pause()
                } label: {
                    Label(recorder.isPaused ? "继续" : "暂停",
                          systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    discardRecording()
                } label: {
                    Label("放弃", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }

            Button {
                stopAndTranscribe()
            } label: {
                Label("停止并转写", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)

            Text("录音中离开本页或锁屏都不会中断")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var transcribingSection: some View {
        VStack(spacing: 16) {
            if jobs.totalSegments > 0 {
                ProgressView(value: jobs.progress)
                    .progressViewStyle(.linear)

                Text("\(Int(jobs.progress * 100))% · 第 \(jobs.completedSegments)/\(jobs.totalSegments) 段 · 已识别 \(jobs.characters) 字")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("正在分析音频…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Label("可以退出本页或锁屏，转写会在后台继续",
                  systemImage: "lock.rotation")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(role: .destructive) {
                jobs.cancel()
                phase = .idle
            } label: {
                Text("取消转写")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    /// 24 格 LED 风格电平条，随音量点亮
    private var levelMeter: some View {
        HStack(spacing: 3) {
            ForEach(0..<24, id: \.self) { i in
                Capsule()
                    .fill(Double(i) / 24.0 < recorder.level
                          ? Color.red
                          : Color.secondary.opacity(0.2))
                    .frame(width: 6, height: 14)
            }
        }
    }

    private var resultSection: some View {
        VStack(spacing: 16) {
            if transcript.isEmpty {
                ContentUnavailableView(
                    "转写失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text("录音文件已保存在手机上，可以在主页「历史记录」或「导入音频转写」里重试")
                )
            } else {
                if let result = jobs.outcome ?? lastOutcomeSnapshot {
                    Text("共 \(result.characters) 字 · 有效段 \(result.totalSegments - result.emptySegments)/\(result.totalSegments)（\(Int(result.coverage * 100))%）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                NavigationLink {
                    SummaryView(transcript: transcript, record: pendingRecord)
                } label: {
                    Label("生成会议纪要", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                transcript = ""
                errorMessage = nil
                pendingRecord = nil
                phase = .idle
            } label: {
                Label("再录一段", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
    }

    /// resetState() 会清空 outcome，界面用这个快照兜住统计信息
    @State private var lastOutcomeSnapshot: TranscriptionOutcome?

    // MARK: - 动作

    private func startRecording() async {
        errorMessage = nil
        transcript = ""
        pendingRecord = nil
        lastOutcomeSnapshot = nil

        guard await RecorderService.requestMicPermission() else {
            errorMessage = "麦克风权限被拒绝。请到 设置 → 隐私与安全性 → 麦克风 中允许 Recorder 使用"
            return
        }

        do {
            try recorder.start()
            phase = .recording
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func discardRecording() {
        recorder.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .idle
    }

    private func stopAndTranscribe() {
        let duration = recorder.elapsed
        guard let url = recorder.stop() else {
            phase = .idle
            return
        }
        UIApplication.shared.isIdleTimerDisabled = false

        if duration < 1.0 {
            try? FileManager.default.removeItem(at: url)
            errorMessage = "录音太短（不足 1 秒），已放弃"
            phase = .idle
            return
        }

        jobs.resetState()
        lastOutcomeSnapshot = nil
        phase = .transcribing
        jobs.start(audioURL: url, duration: duration, titlePrefix: "录音")
    }

    // MARK: - 工具

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
