import SwiftUI

/// 主页：转写入口、设置入口
struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
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
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("设置与日志", systemImage: "gearshape")
                    }
                } header: {
                    Text("手表 AI 录音助手")
                } footer: {
                    Text("v0.5.1 · 现场录音 + 分段转写 + AI 纪要")
                }
            }
            .navigationTitle("录音助手")
        }
    }
}
