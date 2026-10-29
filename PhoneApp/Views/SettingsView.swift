import SwiftUI

/// 设置页：M1 阶段提供日志查看（无 Mac 环境的主要排障入口）和清除数据
struct SettingsView: View {
    @State private var logText = ""
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(logText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button {
                    logText = AppLogger.readAll()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = logText
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Spacer()
                Button(role: .destructive) {
                    AppLogger.clear()
                    logText = "（日志为空）"
                } label: {
                    Label("清空日志", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .padding()
        }
        .navigationTitle("设置与日志")
        .onAppear { logText = AppLogger.readAll() }
    }
}
