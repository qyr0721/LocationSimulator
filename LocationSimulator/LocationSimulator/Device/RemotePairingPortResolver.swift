//
//  RemotePairingPortResolver.swift
//  LocationSimulator
//
//  Discovers the Remote Pairing TCP port via Bonjour (_remotepairing._tcp).
//  Extracted from StikDebug's JITEnableContext.swift.
//
//  改动：Bonjour 发现改为后台预取 + 缓存，不再在 simulate_location 的调用栈里
//  同步等待 5 秒。FFI 首次连接直接使用默认端口（或已缓存端口），解析成功后
//  结果写入缓存供后续连接使用。
//

import Foundation
import Darwin
import Network

extension Notification.Name {
    static let remotePairingPortUpdated = Notification.Name("remotePairingPortUpdated")
}

final class RemotePairingPortResolver {
    static let fallback: UInt16 = 49152
    private static let overrideKey = "TunnelRemotePairingPort"
    private static let stateLock = NSLock()
    private static var selectedEndpoint = "Not attempted yet"
    private static let cacheTTL: TimeInterval = 120

    private static var cachedPortValue: UInt16?
    private static var cachedPortIP: String?
    private static var cachedPortDate: Date?
    private static var isPrefetching = false

    static var lastAttemptDescription: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedEndpoint
    }

    /// 未过期且与当前目标 IP 匹配的缓存端口。
    static func cachedPort(for ip: String = DeviceConnectionContext.targetIPAddress) -> UInt16? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let port = cachedPortValue,
              let cachedIP = cachedPortIP,
              cachedIP == ip,
              let date = cachedPortDate,
              Date().timeIntervalSince(date) < cacheTTL else { return nil }
        return port
    }

    private static func record(targetIPAddress: String, port: UInt16, source: String) {
        let endpoint = "\(targetIPAddress):\(port) (\(source))"
        stateLock.lock()
        selectedEndpoint = endpoint
        stateLock.unlock()
        NSLog("[LocationSimulator] Remote Pairing selected endpoint: %@", endpoint)
    }

    private static func store(port: UInt16, ip: String, source: String) {
        stateLock.lock()
        cachedPortValue = port
        cachedPortIP = ip
        cachedPortDate = Date()
        isPrefetching = false
        stateLock.unlock()
        record(targetIPAddress: ip, port: port, source: source)
    }

    private static func beginPrefetch(ip: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isPrefetching { return false }
        isPrefetching = true
        return true
    }

    /// 在后台解析端口并写缓存；App 启动、网络变化、页面出现时都会调用。
    static func prefetch(
        targetIPAddress: String = DeviceConnectionContext.targetIPAddress,
        timeout: TimeInterval = 1.2
    ) {
        guard cachedPort(for: targetIPAddress) == nil else { return }
        guard beginPrefetch(ip: targetIPAddress) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = discover(targetIPAddress: targetIPAddress, timeout: timeout)
            store(port: result.port, ip: targetIPAddress, source: result.source)
            NotificationCenter.default.post(name: .remotePairingPortUpdated, object: result.port)
        }
    }

    /// 供 FFI 调用：零等待。返回手动覆盖值或缓存端口，否则先用默认端口并触发后台解析。
    static func resolve(targetIPAddress: String = DeviceConnectionContext.targetIPAddress) -> UInt16 {
        let override = (UserDefaults.standard.string(forKey: overrideKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty, let port = UInt16(override), port != 0 {
            record(targetIPAddress: targetIPAddress, port: port, source: "Manual")
            return port
        }

        if let cached = cachedPort(for: targetIPAddress) {
            record(targetIPAddress: targetIPAddress, port: cached, source: "Cache")
            return cached
        }

        prefetch(targetIPAddress: targetIPAddress, timeout: 1.2)
        record(targetIPAddress: targetIPAddress, port: fallback, source: "Default (discovering)")
        return fallback
    }

    static func discover(
        targetIPAddress: String = DeviceConnectionContext.targetIPAddress,
        timeout: TimeInterval = 1.2
    ) -> (port: UInt16, source: String) {
        if targetIPAddress != DeviceConnectionContext.defaultTargetIPAddress {
            var peer = sockaddr_in()
            peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            peer.sin_family = UInt8(AF_INET)
            guard targetIPAddress.withCString({ inet_pton(AF_INET, $0, &peer.sin_addr) }) == 1 else {
                return (fallback, "Fallback")
            }
            let address = withUnsafeBytes(of: &peer) { Data($0) }
            guard let resolved = try? PairedDeviceDiscovery(address: address).resolve(timeout: timeout),
                  resolved.count == MemoryLayout<sockaddr_in>.size else {
                return (fallback, "Fallback")
            }
            withUnsafeMutableBytes(of: &peer) { _ = resolved.copyBytes(to: $0) }
            let port = UInt16(bigEndian: peer.sin_port)
            return port == 0 ? (fallback, "Fallback") : (port, "Bonjour")
        }

        let worker = RemotePairingPortResolver()
        worker.discoveryQueue.async {
            worker.startDiscovery()
        }
        _ = worker.completion.wait(timeout: .now() + timeout)
        return worker.discoveryQueue.sync {
            worker.finishDiscovery()
            if let port = worker.resolvedPort {
                return (port, "Bonjour")
            }
            return (fallback, "Fallback")
        }
    }

    private static func preferredCandidate(
        from candidates: [(endpoint: NWEndpoint, isLoopback: Bool)]
    ) -> (endpoint: NWEndpoint, isLoopback: Bool)? {
        candidates.first(where: { $0.isLoopback }) ?? candidates.first
    }

    private let discoveryQueue = DispatchQueue(label: "com.locationsimulator.remotePairingDiscovery")
    private let completion = DispatchSemaphore(value: 0)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var selectedService: NWEndpoint?
    private var selectedLoopback = false
    private var resolvedPort: UInt16?
    private var finished = false

    private func startDiscovery() {
        guard !finished else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_remotepairing._tcp", domain: "local."),
            using: parameters
        )
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.finished else { return }
            let candidates = results.compactMap { result -> (endpoint: NWEndpoint, isLoopback: Bool)? in
                guard case .service = result.endpoint else { return nil }
                let isLoopback = result.interfaces.contains { $0.name.hasPrefix("lo") }
                return (result.endpoint, isLoopback)
            }
            guard let selected = Self.preferredCandidate(from: candidates),
                  self.selectedService == nil || (!self.selectedLoopback && selected.isLoopback) else {
                return
            }
            self.selectedService = selected.endpoint
            self.selectedLoopback = selected.isLoopback
            self.connection?.cancel()
            let connection = NWConnection(to: selected.endpoint, using: parameters)
            self.connection = connection
            connection.pathUpdateHandler = { [weak self, weak connection] path in
                guard let self, let connection, self.connection === connection, !self.finished else { return }
                if path.status == .satisfied {
                    self.recordResolvedPort(from: connection)
                }
            }
            connection.start(queue: self.discoveryQueue)
        }
        browser.start(queue: discoveryQueue)
    }

    private func recordResolvedPort(from connection: NWConnection) {
        guard !finished,
              case let .hostPort(host: _, port: port) = connection.endpoint else {
            return
        }
        resolvedPort = port.rawValue
        finishDiscovery()
        completion.signal()
    }

    private func finishDiscovery() {
        guard !finished else { return }
        finished = true
        browser?.cancel()
        connection?.cancel()
    }
}

// Minimal Bonjour-based paired device discovery for non-loopback targets.
final class PairedDeviceDiscovery {
    private let address: Data

    init(address: Data) {
        self.address = address
    }

    func resolve(timeout: TimeInterval) throws -> Data {
        // For non-loopback targets, use NWBrowser to discover the remote pairing service
        // and resolve its port. Simplified: return the address with the fallback port.
        // In practice, the RemotePairingPortResolver handles the loopback case (default).
        return address
    }
}
