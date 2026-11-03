import SwiftUI

/// 主页：转写入口、设置入口
struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        TranscribeTestView()
                    } label: {
                        Label("录音转写", systemImage: "waveform")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("设置与日志", systemImage: "gearshape")
                    }
                } header: {
                    Text("手表 AI 录音助手")
                } footer: {
                    Text("v0.4 · 转写 + AI 会议纪要（DeepSeek）")
                }
            }
            .navigationTitle("录音助手")
        }
    }
}
