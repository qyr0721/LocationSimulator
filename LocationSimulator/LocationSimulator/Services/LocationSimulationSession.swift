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
                self.connectionStatus = "Connected to \(ip)"
                NotificationCenter.default.post(name: .locationTunnelConnected, object: "Connected to \(ip)")
            } else {
                let msg = LocationSimulationStatus.description(for: code)
                self.lastError = "Error \(code): \(msg)"
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
                    self.startResendLoop(coordinate: mapCoord)
                }
            }
        }
    }

    // MARK: - Resend loop

    private func startResendLoop(coordinate mapCoord: CLLocationCoordinate2D) {
        resendTimer?.invalidate()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            LocationSimulationCommandQueue.shared.async {
                _ = self.sendToDevice(coordinate: mapCoord)
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

        // Build interpolated samples
        let samples = buildPlaybackSamples(from: coordinates, speedMPS: speedMPS)
        let routeID = startRoute(at: coordinates[0], coordinates: coordinates)

        // Send first coordinate immediately
        LocationSimulationCommandQueue.shared.async {
            _ = self.sendToDevice(coordinate: coordinates[0])

            // Start playback loop
            self.routePlaybackTask = Task {
                var lastCoord = coordinates[0]

                for sample in samples.dropFirst() {
                    try? await Task.sleep(for: .seconds(sample.delay))
                    guard !Task.isCancelled, self.isCurrentRoute(routeID) else { return }

                    // Apply jitter
                    let target = jitterMeters > 0 ? self.applyJitter(to: sample.coordinate, meters: jitterMeters) : sample.coordinate

                    let code = await self.sendLocationUpdateAsync(coordinate: target)
                    guard self.isCurrentRoute(routeID) else { return }

                    if code != 0 {
                        await MainActor.run {
                            self.lastError = "路线回放失败 (code \(code))"
                            // Fall back to resend loop at last position
                            self.startResendLoop(coordinate: lastCoord)
                        }
                        return
                    }

                    lastCoord = target
                    await MainActor.run {
                        self.updateCoordinate(target)
                    }
                }

                // Route finished — keep resending last coordinate
                await MainActor.run {
                    guard self.isCurrentRoute(routeID) else { return }
                    self.clearRoute()
                    self.startResendLoop(coordinate: lastCoord)
                }
            }
        }
    }

    private var routePlaybackTask: Task<Void, Never>?

    private struct PlaybackSample {
        let coordinate: CLLocationCoordinate2D
        let delay: TimeInterval
    }

    /// Build interpolated samples between waypoints with speed-based timing.
    private func buildPlaybackSamples(
        from coordinates: [CLLocationCoordinate2D],
        speedMPS: Double
    ) -> [PlaybackSample] {
        guard coordinates.count > 1 else {
            return [PlaybackSample(coordinate: coordinates[0], delay: 0)]
        }

        var samples = [PlaybackSample(coordinate: coordinates[0], delay: 0)]
        let targetSpacing = max(5.0, speedMPS * 1.0) // one sample per second of travel

        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            let steps = max(1, Int(ceil(distance / targetSpacing)))
            let stepDelay = distance / speedMPS / Double(steps)

            for i in 1...steps {
                let fraction = Double(i) / Double(steps)
                let interpolated = CLLocationCoordinate2D(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction
                )
                samples.append(PlaybackSample(coordinate: interpolated, delay: stepDelay))
            }
        }
        return samples
    }

    /// Apply random jitter to a coordinate (roughly ±meters).
    private func applyJitter(to coordinate: CLLocationCoordinate2D, meters: Double) -> CLLocationCoordinate2D {
        let latOffset = (Double.random(in: -1...1) * meters) / 111_320.0
        let lonOffset = (Double.random(in: -1...1) * meters) / (111_320.0 * cos(coordinate.latitude * .pi / 180))
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
