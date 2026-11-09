//
//  BackgroundAudioManager.swift
//  LocationSimulator
//
//  Keeps the app alive in the background via silent audio playback.
//  Extracted from StikDebug.
//

import AVFoundation

final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var isRunning = false
    private var activityCount = 0
    private var forceCount = 0  // 强制保活计数（配对等关键流程使用，不受用户设置限制）
    private var healthCheckTimer: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    func configurationDidChange() {
        refreshRunningState()
    }

    func requestStart() {
        activityCount += 1
        refreshRunningState()
    }

    func requestStop() {
        activityCount = max(activityCount - 1, 0)
        refreshRunningState()
    }

    /// 强制保活（不受用户设置限制）——配对等关键流程必须保持 App 在后台活跃，
    /// 否则切到「设置」输入密码后 App 被挂起，收不到配对码通知。
    func requestForceStart() {
        forceCount += 1
        refreshRunningState()
    }

    func requestForceStop() {
        forceCount = max(forceCount - 1, 0)
        refreshRunningState()
    }

    private func refreshRunningState() {
        // 强制保活不受 keepAliveAudio 设置限制
        let shouldRun = forceCount > 0 || (activityCount > 0 && UserDefaults.standard.bool(forKey: UserDefaults.Keys.keepAliveAudio))
        guard shouldRun != isRunning else {
            if shouldRun {
                recoverIfNeeded()
            }
            return
        }

        isRunning = shouldRun
        if shouldRun {
            startEngine()
            startHealthCheck()
        } else {
            healthCheckTimer?.invalidate()
            healthCheckTimer = nil
            player.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func startEngine() {
        do {
            engine.stop()
            player.stop()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)

            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)

            scheduleSilence()
            try engine.start()
            player.play()
        } catch {
            NSLog("[LocationSimulator] BackgroundAudioManager error: %@", error.localizedDescription)
        }
    }

    private func scheduleSilence() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        // PCM buffer is zero-initialized — pure silence
        player.scheduleBuffer(buffer, at: nil, options: .loops)
    }

    private func startHealthCheck() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.recoverIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }

    private func recoverIfNeeded() {
        guard isRunning, !engine.isRunning || !player.isPlaying else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                try engine.start()
            }
            player.play()
        } catch {
            // Session still held by another app — will retry next tick
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended,
              isRunning else { return }

        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    @objc private func handleMediaServicesReset() {
        guard isRunning else { return }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        startEngine()
    }
}
