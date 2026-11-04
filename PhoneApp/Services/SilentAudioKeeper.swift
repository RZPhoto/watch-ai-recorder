import Foundation
import AVFoundation

/// 转写期间的"后台保活"：用一条静音音频占住音频会话。
///
/// 背景：iOS 只允许"正在播放音频"的 App 在锁屏/切后台后继续运行。
/// 转写本身不是音频播放，锁屏后几十秒就会被系统挂起，长录音转写会中断。
/// 这里在转写期间循环播放一段全零采样（无声），配合 UIBackgroundModes: audio，
/// 让转写任务在锁屏后也能跑完；转写结束即停止，不影响其他 App（mixWithOthers）。
final class SilentAudioKeeper {
    static let shared = SilentAudioKeeper()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private(set) var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // mixWithOthers：用户此时听歌/听播客不会被我们打断
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)

            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: format)

            // 缓冲区本身是全零（AVAudioPCMBuffer 初始化即为静音），循环播放
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
                AppLogger.log("后台保活：无法创建静音缓冲区")
                return
            }
            buffer.frameLength = 44_100
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)

            try engine.start()
            player.play()

            self.engine = engine
            self.player = player
            isRunning = true
            AppLogger.log("后台保活：已启动（锁屏后转写继续）")
        } catch {
            AppLogger.log("后台保活启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        AppLogger.log("后台保活：已停止")
    }
}
