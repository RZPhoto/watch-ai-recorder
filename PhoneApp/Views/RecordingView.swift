import SwiftUI
import UIKit

/// 现场录音页：开始录音 → 停止 → 自动转写 → 进入 AI 纪要
struct RecordingView: View {
    @StateObject private var recorder = RecorderService()

    private enum Phase: Equatable {
        case idle          // 未开始
        case recording     // 录音中
        case transcribing  // 停止后转写中
        case done          // 转写完成
    }

    @State private var phase: Phase = .idle
    @State private var transcript = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            switch phase {
            case .idle:
                idleSection
            case .recording:
                recordingSection
            case .transcribing:
                VStack(spacing: 12) {
                    ProgressView("录音已保存，正在转写…")
                    Text("长录音会自动分段，耐心等待即可")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
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
        .onDisappear {
            // 离开页面时若还在录音，放弃本次录音
            if recorder.isRecording {
                recorder.cancel()
            }
            UIApplication.shared.isIdleTimerDisabled = false
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

            Text("锁屏或切到后台都会继续录音，停止后自动转写")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                Label("声音偏小，建议把手机移近发言人", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
        }
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
                    description: Text("录音文件已保存在手机上，可以稍后从「导入音频转写」重试")
                )
            } else {
                ScrollView {
                    Text(transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                NavigationLink {
                    SummaryView(transcript: transcript)
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
                phase = .idle
            } label: {
                Label("再录一段", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 动作

    private func startRecording() async {
        errorMessage = nil

        guard await RecorderService.requestMicPermission() else {
            errorMessage = "麦克风权限被拒绝。请到 设置 → 隐私与安全性 → 麦克风 中允许 Recorder 使用"
            return
        }

        do {
            try recorder.start()
            phase = .recording
            // 录音期间保持屏幕常亮
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

        // 录音太短没有转写价值，直接丢弃
        if duration < 1.0 {
            try? FileManager.default.removeItem(at: url)
            errorMessage = "录音太短（不足 1 秒），已放弃"
            phase = .idle
            return
        }

        phase = .transcribing
        Task {
            do {
                let text = try await TranscriptionService.shared.transcribe(url: url)
                transcript = text
            } catch {
                AppLogger.log("现场录音转写失败: \(error.localizedDescription)")
                errorMessage = "转写失败：\(error.localizedDescription)"
                transcript = ""
            }
            phase = .done
        }
    }

    // MARK: - 工具

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
