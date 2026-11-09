//
//  LocationSimulationSession.swift
//  LocationSimulator
//
//  Manages the state of an active location simulation session and
//  dispatches actual FFI calls to the device via LocationFFIBridge.
//

import Foundation
import CoreLocation
import Combine
import UIKit

final class LocationSimulationSession: ObservableObject {
    static let shared = LocationSimulationSession()

    @Published private(set) var isActive = false
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D]?
    @Published var lastError: String?
    @Published var connectionStatus: String?

    /// Convenience alias for UI state
    var isSimulating: Bool { isActive }

    private var resendTimer: Timer?
    private var routeID: UUID?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    // MARK: - Device coordinate conversion

    /// Convert a map coordinate (GCJ-02 in China) to WGS-84 for the device.
    private func deviceCoordinate(from mapCoordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        ChinaCoordinateTransform.deviceCoordinate(fromMapCoordinate: mapCoordinate)
    }

    // MARK: - Point simulation

    /// Start simulating a fixed point location.
    func start(at coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        if !isActive {
            isActive = true
            BackgroundAudioManager.shared.requestStart()
            BackgroundLocationManager.shared.requestStart()
        }
    }

    /// Send the simulated location to the device via FFI (with coordinate transform).
    /// Returns 0 on success, error code otherwise.
    @discardableResult
    func sendToDevice(coordinate mapCoord: CLLocationCoordinate2D) -> Int32 {
        let device = deviceCoordinate(from: mapCoord)
        let ip = UserDefaults.standard.string(forKey: UserDefaults.Keys.targetDeviceIP) ?? DeviceConnectionContext.defaultTargetIPAddress
        let pairingPath = PairingFileStore.exists ? PairingFileStore.url.path : ""

        let code = simulate_location(ip, device.latitude, device.longitude, pairingPath)

        DispatchQueue.main.async {
            if code == 0 {
                self.lastError = nil
                self.connectionStatus = "已连接至 \(ip)"
                NotificationCenter.default.post(name: .locationTunnelConnected, object: "已连接至 \(ip)")
            } else {
                let msg = LocationSimulationStatus.description(for: code)
                self.lastError = "错误 \(code)：\(msg)"
                self.connectionStatus = nil
            }
        }
        return code
    }

    /// Start simulating + send to device + begin 4-second resend loop.
    func startSimulation(at mapCoord: CLLocationCoordinate2D) {
        start(at: mapCoord)

        LocationSimulationCommandQueue.shared.async {
            let code = self.sendToDevice(coordinate: mapCoord)
            DispatchQueue.main.async {
                if code == 0 {
                    self.startResendLoop()
                }
            }
        }
    }

    /// 模拟进行中实时更新坐标：立即向设备下发，并让重发循环使用新坐标。
    /// 地图选点、搜索、历史/收藏选择、手动输入经纬度都会走这里，无需停止再重启。
    func updateSimulation(to mapCoord: CLLocationCoordinate2D) {
        guard isActive else { return }
        coordinate = mapCoord
        LocationSimulationCommandQueue.shared.async { [weak self] in
            _ = self?.sendToDevice(coordinate: mapCoord)
        }
    }

    // MARK: - Resend loop

    /// 重发循环始终读取会话当前坐标，因此坐标变化后 4 秒内的自动重发也会用新值。
    private func startResendLoop() {
        resendTimer?.invalidate()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, let current = self.coordinate else { return }
            LocationSimulationCommandQueue.shared.async {
                _ = self.sendToDevice(coordinate: current)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    /// For route playback: start resending with an explicit operation (used for route interpolation).
    func startResending(at coordinate: CLLocationCoordinate2D, _ operation: @escaping () -> Void) {
        start(at: coordinate)
        resendTimer?.invalidate()
        let timer = Timer(timeInterval: 4, repeats: true) { _ in operation() }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    func pauseResending() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    // MARK: - Route simulation

    func startRoute(at coordinate: CLLocationCoordinate2D, coordinates: [CLLocationCoordinate2D]) -> UUID {
        let routeID = UUID()
        self.routeID = routeID
        routeCoordinates = coordinates
        start(at: coordinate)
        return routeID
    }

    func isCurrentRoute(_ routeID: UUID) -> Bool {
        self.routeID == routeID
    }

    func clearRoute() {
        routeID = nil
        routeCoordinates = nil
    }

    /// Full route playback: sends first coordinate immediately, then
    /// interpolates along the route and sends progressive updates.
    ///
    /// 采样率依据（与真实定位流保持同频）：
    /// iOS 的 CLLocationManager 在 kCLDistanceFilterNone 下由 GPS 芯片按约 1 Hz
    /// 输出定位，跑步/骑行类 App 每秒收到 1 个点、横向精度 5–15 米。
    /// 因此这里固定 1 Hz 推送 —— 每步前进 speed × 1s 米，而不是按「每 5 米一个点」，
    /// 后者在步行速度下会退化成 3.6 秒一个点，肉眼可见卡顿且速度显示失真。
    ///
    /// - Parameters:
    ///   - coordinates: Route waypoints (GCJ-02 map coordinates)
    ///   - speedMPS: Speed in meters per second (e.g. 1.4 for walking, 33 for driving)
    ///   - jitterMeters: Random position jitter in meters (0 = precise)
    func startRoutePlayback(
        coordinates: [CLLocationCoordinate2D],
        speedMPS: Double = 1.4,
        jitterMeters: Double = 0
    ) {
        guard coordinates.count >= 2 else { return }

        let samples = buildPlaybackSamples(from: coordinates, speedMPS: speedMPS)
        let routeID = startRoute(at: coordinates[0], coordinates: coordinates)

        LocationSimulationCommandQueue.shared.async {
            // 记录路线开始时刻，后面的每个采样点都按「开始时刻 + 偏移」绝对调度，
            // 这样 FFI 调用自身的耗时不会累积成时间漂移（否则 1 Hz 会慢慢变成 1.1、1.2 Hz）。
            let startTime = Date()
            _ = self.sendToDevice(coordinate: coordinates[0])

            self.routePlaybackTask = Task {
                for sample in samples.dropFirst() {
                    guard !Task.isCancelled, self.isCurrentRoute(routeID) else { return }

                    let deadline = startTime.addingTimeInterval(sample.offset)
                    // 真实 GPS 的输出周期并非严丝合缝的 1.000 s，而是 0.95–1.05 s 抖动。
                    // 这里叠加 ±60 ms，避免节拍过于机械（某些分析类 App 会看周期方差）。
                    let tick = Double.random(in: -0.06...0.06)
                    let targetTime = deadline.addingTimeInterval(tick)
                    let wait = targetTime.timeIntervalSinceNow
                    if wait > 0 {
                        try? await Task.sleep(for: .seconds(wait))
                    } else if -wait > 2.0 {
                        // 落后超过 2 秒：丢弃积压采样点，直接跳到当前应有的位置。
                        // 真实 GPS 只上报「最新位置」，绝不会补发一串历史点。
                        continue
                    }
                    guard !Task.isCancelled, self.isCurrentRoute(routeID) else { return }

                    let target = jitterMeters > 0
                        ? self.applyJitter(to: sample.coordinate, meters: jitterMeters)
                        : sample.coordinate

                    let code = await self.sendLocationUpdateAsync(coordinate: target)
                    guard self.isCurrentRoute(routeID) else { return }

                    if code != 0 {
                        await MainActor.run {
                            self.lastError = "路线回放失败（错误码 \(code)）"
                            self.startResendLoop()
                        }
                        return
                    }

                    await MainActor.run {
                        self.updateCoordinate(target)
                    }
                }

                // Route finished — keep resending the current (last) coordinate
                await MainActor.run {
                    guard self.isCurrentRoute(routeID) else { return }
                    self.clearRoute()
                    self.startResendLoop()
                }
            }
        }
    }

    private var routePlaybackTask: Task<Void, Never>?

    /// 真实 GPS 的定位输出周期（秒）。iOS 在最高精度下约为 1 Hz。
    static let fixInterval: TimeInterval = 1.0

    private struct PlaybackSample {
        let coordinate: CLLocationCoordinate2D
        /// 相对路线开始时刻的偏移（秒），用于绝对时间调度
        let offset: TimeInterval
    }

    /// 以 1 Hz 采样率构建回放序列。
    /// - stepDistance = 速度 × 1 秒，保证相邻采样点的时间间隔恒为 1 秒；
    /// - offset 为累计时间，回放时按绝对时刻调度，避免漂移；
    /// - 极端长路线（> 6 小时）放宽到 2 秒采样，防止样本数量爆炸。
    private func buildPlaybackSamples(
        from coordinates: [CLLocationCoordinate2D],
        speedMPS: Double
    ) -> [PlaybackSample] {
        guard coordinates.count > 1 else {
            return [PlaybackSample(coordinate: coordinates[0], offset: 0)]
        }

        let speed = max(0.1, speedMPS)

        var totalDistance: Double = 0
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            totalDistance += distance(from: start, to: end)
        }
        let interval = (totalDistance / speed) > 6 * 3600 ? 2.0 : Self.fixInterval
        let stepDistance = max(0.2, speed * interval)

        var samples: [PlaybackSample] = [PlaybackSample(coordinate: coordinates[0], offset: 0)]
        var elapsed: TimeInterval = 0

        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            let legDistance = distance(from: start, to: end)
            guard legDistance > 0.05 else { continue }

            let steps = max(1, Int(ceil(legDistance / stepDistance)))
            let stepTime = legDistance / speed / Double(steps)

            for i in 1...steps {
                let fraction = Double(i) / Double(steps)
                elapsed += stepTime
                samples.append(PlaybackSample(
                    coordinate: interpolate(from: start, to: end, fraction: fraction),
                    offset: elapsed
                ))
            }
        }
        return samples
    }

    private func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func interpolate(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D,
        fraction: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * fraction,
            longitude: a.longitude + (b.longitude - a.longitude) * fraction
        )
    }

    /// Apply GPS-like random jitter to a coordinate (circular, uniform within radius).
    private func applyJitter(to coordinate: CLLocationCoordinate2D, meters: Double) -> CLLocationCoordinate2D {
        // 圆内均匀分布：半径取 sqrt 抽样，避免点过度集中在中心
        let angle = Double.random(in: 0..<(2 * Double.pi))
        let radius = meters * sqrt(Double.random(in: 0...1))
        let north = radius * cos(angle)
        let east = radius * sin(angle)
        let latOffset = north / 111_320.0
        let lonScale = max(0.01, cos(coordinate.latitude * .pi / 180))
        let lonOffset = east / (111_320.0 * lonScale)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + latOffset,
            longitude: coordinate.longitude + lonOffset
        )
    }

    /// Async wrapper for sending a location update.
    private func sendLocationUpdateAsync(coordinate: CLLocationCoordinate2D) async -> Int32 {
        await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: self.sendToDevice(coordinate: coordinate))
            }
        }
    }

    // MARK: - Update coordinate (for route playback)

    func updateCoordinate(_ coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }

    // MARK: - Stop

    func stop() {
        routePlaybackTask?.cancel()
        routePlaybackTask = nil
        pauseResending()
        clearRoute()
        guard isActive else { return }

        // Clear simulated location on device
        LocationSimulationCommandQueue.shared.async {
            _ = clear_simulated_location()
        }

        isActive = false
        coordinate = nil
        connectionStatus = nil
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()
    }

    // MARK: - Background task

    func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
