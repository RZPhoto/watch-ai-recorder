import SwiftUI

/// 主页：M1 阶段只放转写验证入口和设置入口
struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        TranscribeTestView()
                    } label: {
                        Label("转写验证", systemImage: "waveform")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("设置与日志", systemImage: "gearshape")
                    }
                } header: {
                    Text("手表 AI 录音助手")
                } footer: {
                    Text("v0.2 · M1 阶段：支持长音频分段转写")
                }
            }
            .navigationTitle("录音助手")
        }
    }
}
