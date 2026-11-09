//
//  ConnectionPreflight.swift
//  LocationSimulator
//
//  毫秒级连接预检。
//  旧逻辑在点「启动模拟」后才做 5 秒 Bonjour 发现，用户往往在检查完成前
//  就已经点开了位置模拟。这里改成：常驻监听网络状态 + 同步读取本机接口，
//  点击时做一次零等待的即时判定，端口发现放到后台预取并缓存。
//

import Foundation
import Network
import Darwin
import UIKit

// MARK: - 可拦截的问题

enum PreflightIssue: Identifiable, Equatable {
    case missingPairingFile
    case networkUnavailable
    case vpnNotConnected

    var id: String {
        switch self {
        case .missingPairingFile: return "missingPairingFile"
        case .networkUnavailable: return "networkUnavailable"
        case .vpnNotConnected: return "vpnNotConnected"
        }
    }

    var title: String {
        switch self {
        case .missingPairingFile: return "还没有配对文件"
        case .networkUnavailable: return "网络不可用"
        case .vpnNotConnected: return "VPN 未连接"
        }
    }

    var message: String {
        switch self {
        case .missingPairingFile:
            return "请先在「设置 → 配对」中配对设备，或导入已有的配对文件。"
        case .networkUnavailable:
            return "请连接 Wi-Fi 或蜂窝网络后再启动模拟。"
        case .vpnNotConnected:
            return "请先连接 LocalDevVPN 建立回环隧道。"
        }
    }

    var systemImage: String {
        switch self {
        case .missingPairingFile: return "doc.badge.xmark"
        case .networkUnavailable: return "wifi.exclamationmark"
        case .vpnNotConnected: return "shield.slash"
        }
    }
}

// MARK: - 状态快照

struct PreflightSnapshot {
    var hasPairingFile: Bool
    var hasVPNInterface: Bool
    var hasNetwork: Bool
    var usesWiFi: Bool
    var usesCellular: Bool
    /// nil = 尚未探测；false 只作提示，不作为拦截依据
    var deviceReachable: Bool?
    var updatedAt: Date

    /// 硬门槛只拦最确定的问题。VPN 不是必需条件 —— 默认走 127.0.0.1 直连。
    /// 仅当用户手动设置了 10.7.0.x 时才要求 VPN。
    var blockingIssue: PreflightIssue? {
        guard hasPairingFile else { return .missingPairingFile }
        guard hasNetwork else { return .networkUnavailable }
        // 只有目标 IP 是隧道 IP 时才要求 VPN
        let targetIP = DeviceConnectionContext.targetIPAddress
        if targetIP.hasPrefix("10.7.0.") && !hasVPNInterface {
            return .vpnNotConnected
        }
        return nil
    }

    var isReady: Bool { blockingIssue == nil }

    var statusText: String {
        if let blockingIssue { return blockingIssue.title }
        if deviceReachable == false { return "设备服务暂未响应" }
        return "已就绪"
    }

    var statusColor: Bool { blockingIssue == nil }
}

// MARK: - 连接预检

final class ConnectionPreflight: ObservableObject {
    static let shared = ConnectionPreflight()

    @Published private(set) var snapshot: PreflightSnapshot
    @Published private(set) var isProbing = false

    private var observers: [NSObjectProtocol] = []
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.locationsimulator.preflight.path")
    private let probeQueue = DispatchQueue(label: "com.locationsimulator.preflight.probe")
    private var probeConnection: NWConnection?
    private var probeGeneration = 0
    private var lastProbeDate: Date = .distantPast

    // 以下状态只在主线程读写（NWPathMonitor 回调已切回主线程）
    private var pathSatisfied = false
    private var pathWiFi = false
    private var pathCellular = false

    private struct InterfaceFlags {
        var hasVPN = false
        var hasAnyUp = false
    }

    private init() {
        let flags = Self.interfaceFlags()
        snapshot = PreflightSnapshot(
            hasPairingFile: PairingFileStore.exists,
            hasVPNInterface: flags.hasVPN,
            hasNetwork: flags.hasAnyUp,
            usesWiFi: false,
            usesCellular: false,
            deviceReachable: nil,
            updatedAt: Date()
        )

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.apply(path: path) }
        }
        monitor.start(queue: monitorQueue)

        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .pairingFileImported,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshLocal()
        })

        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - 对外接口

    /// 点击「启动模拟」时调用：零等待，用当前已知状态立即判定。
    /// 不会发起任何网络请求，因此不会因为检查慢而让用户误启动。
    @discardableResult
    func instantGate() -> PreflightIssue? {
        refreshLocal()
        return snapshot.blockingIssue
    }

    /// 页面出现 / App 回到前台时调用：刷新本地状态并异步探测设备端口。
    func refresh() {
        refreshLocal()
        probeDevice()
        RemotePairingPortResolver.prefetch()
    }

    func refreshLocal() {
        snapshot = makeSnapshot()
    }

    // MARK: - 内部

    private func makeSnapshot() -> PreflightSnapshot {
        let flags = Self.interfaceFlags()
        return PreflightSnapshot(
            hasPairingFile: PairingFileStore.exists,
            hasVPNInterface: flags.hasVPN,
            hasNetwork: flags.hasAnyUp || pathSatisfied,
            usesWiFi: pathWiFi,
            usesCellular: pathCellular,
            deviceReachable: snapshot.deviceReachable,
            updatedAt: Date()
        )
    }

    private func apply(path: NWPath) {
        pathSatisfied = path.status == .satisfied
        pathWiFi = path.usesInterfaceType(.wifi)
        pathCellular = path.usesInterfaceType(.cellular)
        refreshLocal()
        RemotePairingPortResolver.prefetch()
        probeDevice()
    }

    /// 短超时 TCP 探活，仅用于状态展示，不阻塞任何操作。需在主线程调用。
    private func probeDevice() {
        let now = Date()
        guard now.timeIntervalSince(lastProbeDate) > 0.5 else { return }
        lastProbeDate = now

        let ip = DeviceConnectionContext.targetIPAddress
        let port = RemotePairingPortResolver.cachedPort(for: ip) ?? RemotePairingPortResolver.fallback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        probeConnection?.cancel()
        probeGeneration += 1
        let generation = probeGeneration
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: .tcp)
        probeConnection = connection
        isProbing = true

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async { self.finishProbe(true, generation: generation) }
            case .failed:
                DispatchQueue.main.async { self.finishProbe(false, generation: generation) }
            default:
                break
            }
        }
        connection.start(queue: probeQueue)
        probeQueue.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            DispatchQueue.main.async { self?.finishProbe(false, generation: generation) }
        }
    }

    private func finishProbe(_ reachable: Bool, generation: Int) {
        guard generation == probeGeneration else { return }
        probeConnection?.cancel()
        probeConnection = nil
        var updated = snapshot
        updated.deviceReachable = reachable
        updated.updatedAt = Date()
        snapshot = updated
        isProbing = false
    }

    /// 同步读取本机接口，精确检测回环隧道是否已建立。
    /// 关键改进：不只看 utun 接口是否存在（iOS 系统始终有 utun0），
    /// 而是检查是否有 utun 接口绑定了隧道 IP（10.7.0.1）。
    /// 参考 StikDebug 的检测方式：通过 getifaddrs 遍历地址列表，
    /// 匹配目标隧道 IP 而非仅接口名前缀。
    private static func interfaceFlags() -> InterfaceFlags {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return InterfaceFlags() }
        defer { freeifaddrs(first) }

        var result = InterfaceFlags()
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            let flags = entry.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            // 精确检测：utun 接口上绑定了隧道 IP（10.7.0.1）才算隧道已建立
            if name.hasPrefix("utun") {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result_getname = getnameinfo(
                    address, socklen_t(address.pointee.sa_len),
                    &hostname, socklen_t(hostname.count),
                    nil, 0, NI_NUMERICHOST
                )
                if result_getname == 0 {
                    let ip = String(cString: hostname)
                    // 检查是否是回环隧道 IP（10.7.0.x 子网）
                    if ip.hasPrefix("10.7.0.") {
                        result.hasVPN = true
                    }
                }
            }
            if name.hasPrefix("en") || name.hasPrefix("utun") { result.hasAnyUp = true }
        }
        return result
    }
}

// MARK: - VPN 连接（引导页、状态条、拦截弹窗共用）
// 打开外部 LocalDevVPN 应用建立回环隧道。

enum LocalDevVPNLink {
    static func open() {
        // 尝试打开 LocalDevVPN app（URL scheme）
        if let url = URL(string: "localdevvpn://"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            return
        }
        // fallback: 打开 App Store 搜索页
        if let storeURL = URL(string: "itms-apps://itunes.apple.com/search?term=LocalDevVPN&entity=software") {
            UIApplication.shared.open(storeURL)
        }
    }
}
