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
                    Text("v0.3.1 · 长音频分段 + 识别引擎自动回退")
                }
            }
            .navigationTitle("录音助手")
        }
    }
}
