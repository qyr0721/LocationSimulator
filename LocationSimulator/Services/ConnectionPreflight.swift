//
//  ConnectionPreflight.swift
//  LocationSimulator
//
//  连接预检与隧道状态判定。
//
//  ── 状态判定依据（重要）──────────────────────────────────────────────
//  1. 隧道是否「已连接」只看一个事实：系统接口表（getifaddrs）中是否存在
//     状态为 UP 的 utun 接口，且其 IPv4 地址落在 LocalDevVPN 的隧道子网
//     10.7.0.0/24。这是内核层的确定性状态，不需要任何网络探测，因此
//     既不会延迟也不会因探测超时而误判。
//  2. 断开采用「防抖确认」：VPN 重新协商时接口会瞬时消失，若立即判定
//     未连接就会出现闪烁。因此必须有连续 2 次采样（间隔 1 秒）都拿不到
//     隧道地址，才确认「未连接」；已连接则一次成立立即生效。
//  3. 主状态只有「已连接 / 未连接」两种，不存在「暂未响应」这类模糊态。
//  4. 设备服务可达性（TCP 探活）只作为辅助信息：
//     - 端口未经 Bonjour 解析时一律标记 unknown，绝不用回退端口下结论；
//     - 连续 3 次探测失败才判定为无响应，避免单次抖动。
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

// MARK: - 隧道状态（严格两态）

/// 隧道连接状态。判定依据见文件头注释：只看 utun 上是否存在 10.7.0.x 地址。
enum TunnelStatus: Equatable {
    /// 已连接：存在 UP 的 utun 接口且绑定 10.7.0.0/24 内的 IPv4 地址
    case connected
    /// 未连接：上述条件不成立
    case disconnected
}

// MARK: - 设备服务状态（辅助信息，不参与主状态）

enum DeviceServiceState: Equatable {
    /// 端口尚未解析，无从判断 —— 不输出任何结论
    case unknown
    /// 最近一次探活成功
    case reachable
    /// 连续 3 次探活失败
    case unreachable
}

// MARK: - 状态快照

struct PreflightSnapshot {
    var hasPairingFile: Bool
    var tunnelStatus: TunnelStatus
    /// 检测到的隧道地址（如 10.7.0.1），未连接时为 nil
    var tunnelAddress: String?
    var hasNetwork: Bool
    var usesWiFi: Bool
    var usesCellular: Bool
    /// 辅助信息：设备服务可达性
    var deviceService: DeviceServiceState
    var updatedAt: Date

    /// 兼容旧调用点
    var hasVPNInterface: Bool { tunnelStatus == .connected }

    /// 只有目标 IP 属于隧道子网时，隧道才是硬性门槛
    static var requiresTunnel: Bool {
        DeviceConnectionContext.targetIPAddress.hasPrefix("10.7.0.")
    }

    /// 硬门槛只拦最确定的问题。
    var blockingIssue: PreflightIssue? {
        guard hasPairingFile else { return .missingPairingFile }
        guard hasNetwork else { return .networkUnavailable }
        if Self.requiresTunnel, tunnelStatus == .disconnected {
            return .vpnNotConnected
        }
        return nil
    }

    var isReady: Bool { blockingIssue == nil }

    // MARK: 展示文案（严格两态）

    /// 主状态标题：已连接 / 未连接
    var vpnTitle: String {
        tunnelStatus == .connected ? "LocalDevVPN 已连接" : "LocalDevVPN 未连接"
    }

    /// 主状态说明：写清判定依据，避免用户猜测
    var vpnDetail: String {
        switch tunnelStatus {
        case .connected:
            return "回环隧道已建立（\(tunnelAddress ?? "10.7.0.1")）"
        case .disconnected:
            return "未检测到 10.7.0.x 隧道地址，请打开 LocalDevVPN 并点击连接"
        }
    }

    /// 设置页 / 状态条主文案
    var statusText: String { vpnTitle }

    /// 设备服务辅助文案：仅在探测有明确结论时返回
    var deviceServiceText: String? {
        switch deviceService {
        case .unknown: return nil
        case .reachable: return "设备服务正常"
        case .unreachable: return "设备服务无响应"
        }
    }

    /// 是否需要在界面上展示隧道状态：
    /// 目标 IP 需要隧道，或隧道当前确实已连接（此时用户关心它是否还在）。
    var showsTunnelStatus: Bool {
        Self.requiresTunnel || tunnelStatus == .connected
    }
}

// MARK: - 连接预检

final class ConnectionPreflight: ObservableObject {
    static let shared = ConnectionPreflight()

    @Published private(set) var snapshot: PreflightSnapshot
    @Published private(set) var isProbing = false

    /// 断连需要连续确认的采样次数（配合 1 秒轮询 ≈ 2 秒确认窗口）
    private static let disconnectConfirmSamples = 2
    /// 隧道状态轮询间隔：getifaddrs 成本极低，1 Hz 足够且不会造成负担
    private static let tunnelPollInterval: TimeInterval = 1.0
    /// 探活超时：经隧道访问设备可能较慢，1.5 秒避免误判
    private static let probeTimeout: TimeInterval = 1.5
    /// 连续失败多少次才判定设备服务无响应
    private static let probeFailureThreshold = 3

    private var observers: [NSObjectProtocol] = []
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.locationsimulator.preflight.path")
    private let probeQueue = DispatchQueue(label: "com.locationsimulator.preflight.probe")
    private var probeConnection: NWConnection?
    private var probeGeneration = 0
    private var lastProbeDate: Date = .distantPast
    private var consecutiveProbeFailures = 0

    /// 断连防抖计数
    private var missingTunnelSamples = 0
    private var tunnelTimer: Timer?

    // 以下状态只在主线程读写
    private var pathSatisfied = false
    private var pathWiFi = false
    private var pathCellular = false

    private struct InterfaceState {
        var tunnelAddress: String?
        var anyUp = false
    }

    private init() {
        let initial = Self.inspectInterfaces()
        snapshot = PreflightSnapshot(
            hasPairingFile: PairingFileStore.exists,
            tunnelStatus: initial.tunnelAddress == nil ? .disconnected : .connected,
            tunnelAddress: initial.tunnelAddress,
            hasNetwork: initial.anyUp,
            usesWiFi: false,
            usesCellular: false,
            deviceService: .unknown,
            updatedAt: Date()
        )

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.apply(path: path) }
        }
        monitor.start(queue: monitorQueue)

        // 独立轮询：VPN 启停时 NWPathMonitor 不一定回调，这里 1 Hz 读接口表兜底
        let timer = Timer(timeInterval: Self.tunnelPollInterval, repeats: true) { [weak self] _ in
            self?.pollTunnel()
        }
        RunLoop.main.add(timer, forMode: .common)
        tunnelTimer = timer

        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 回到前台沿用防抖，避免 VPN 正在重连时闪一下「未连接」
            self?.refreshLocal()
            self?.probeDevice()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .pairingFileImported,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshLocal()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .remotePairingPortUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.probeDevice()
        })

        DispatchQueue.main.async { [weak self] in
            self?.refreshLocal()
            RemotePairingPortResolver.prefetch()
        }
    }

    deinit {
        tunnelTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - 对外接口

    /// 点击「启动模拟」时调用：同步重读接口表，零等待给出确定结论。
    /// 此处不做防抖 —— 用户点下按钮的这一刻，需要的是「事实」而不是「趋势」。
    @discardableResult
    func instantGate() -> PreflightIssue? {
        syncInterfaces(immediate: true)
        return snapshot.blockingIssue
    }

    /// 页面出现 / App 回到前台 / 用户点「重新检测」：立即采用当下事实
    func refresh() {
        syncInterfaces(immediate: true)
        RemotePairingPortResolver.prefetch()
        probeDevice()
    }

    /// 轻量刷新（网络变化、配对文件变化）：沿用断连防抖
    func refreshLocal() {
        syncInterfaces(immediate: false)
    }

    // MARK: - 隧道判定

    private func pollTunnel() {
        syncInterfaces(immediate: false)
    }

    /// 读取接口表并更新快照。
    /// - Parameter immediate: true 时直接采用本次结果（不做防抖确认）
    private func syncInterfaces(immediate: Bool) {
        let state = Self.inspectInterfaces()

        var next = snapshot
        next.hasPairingFile = PairingFileStore.exists
        next.hasNetwork = state.anyUp || pathSatisfied
        next.usesWiFi = pathWiFi
        next.usesCellular = pathCellular

        if let address = state.tunnelAddress {
            // 已连接：一次成立立即生效
            missingTunnelSamples = 0
            next.tunnelAddress = address
            next.tunnelStatus = .connected
        } else {
            missingTunnelSamples += 1
            let confirmed = immediate || missingTunnelSamples >= Self.disconnectConfirmSamples
            if confirmed {
                missingTunnelSamples = Self.disconnectConfirmSamples
                next.tunnelAddress = nil
                next.tunnelStatus = .disconnected
            }
        }

        // 只有实质变化才发布，避免 1 Hz 轮询引发的无意义 UI 重绘
        if next.hasNetwork != snapshot.hasNetwork
            || next.usesWiFi != snapshot.usesWiFi
            || next.usesCellular != snapshot.usesCellular
            || next.hasPairingFile != snapshot.hasPairingFile
            || next.tunnelStatus != snapshot.tunnelStatus
            || next.tunnelAddress != snapshot.tunnelAddress {
            next.updatedAt = Date()
            snapshot = next
        }
    }

    private func apply(path: NWPath) {
        pathSatisfied = path.status == .satisfied
        pathWiFi = path.usesInterfaceType(.wifi)
        pathCellular = path.usesInterfaceType(.cellular)
        refreshLocal()
        RemotePairingPortResolver.prefetch()
        probeDevice()
    }

    // MARK: - 设备服务探测（仅辅助）

    /// 只有在 Bonjour 已解析出真实端口时才探测。
    /// 用回退端口探测只会得到假阴性（明明连得上却报告无响应），因此宁可不判断。
    private func probeDevice() {
        guard let port = RemotePairingPortResolver.cachedPort() else {
            setDeviceService(.unknown)
            return
        }
        let now = Date()
        guard !isProbing, now.timeIntervalSince(lastProbeDate) >= 2 else { return }
        lastProbeDate = now

        let ip = DeviceConnectionContext.targetIPAddress
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
            case .failed, .waiting:
                DispatchQueue.main.async { self.finishProbe(false, generation: generation) }
            case .cancelled:
                DispatchQueue.main.async { self.cancelProbe(generation: generation) }
            default:
                break
            }
        }
        connection.start(queue: probeQueue)
        probeQueue.asyncAfter(deadline: .now() + Self.probeTimeout) { [weak self] in
            DispatchQueue.main.async { self?.finishProbe(false, generation: generation) }
        }
    }

    private func finishProbe(_ reachable: Bool, generation: Int) {
        guard generation == probeGeneration else { return }
        probeConnection?.cancel()
        probeConnection = nil
        isProbing = false

        if reachable {
            consecutiveProbeFailures = 0
            setDeviceService(.reachable)
        } else {
            consecutiveProbeFailures += 1
            if consecutiveProbeFailures >= Self.probeFailureThreshold {
                setDeviceService(.unreachable)
            }
        }
    }

    private func cancelProbe(generation: Int) {
        guard generation == probeGeneration else { return }
        probeConnection = nil
        isProbing = false
    }

    private func setDeviceService(_ state: DeviceServiceState) {
        guard snapshot.deviceService != state else { return }
        snapshot.deviceService = state
    }

    // MARK: - 接口表检测

    /// 同步读取本机接口表。
    /// - 隧道地址：utun 接口 + UP + IPv4 ∈ 10.7.0.0/24
    /// - anyUp：存在 UP 的 en*/utun 接口（用于判断网络是否可用）
    private static func inspectInterfaces() -> InterfaceState {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return InterfaceState() }
        defer { freeifaddrs(first) }

        var state = InterfaceState()
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            let flags = entry.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0 else { continue }

            if name.hasPrefix("en") || name.hasPrefix("utun") {
                state.anyUp = true
            }

            // 只关心 utun 上的 IPv4 地址
            guard name.hasPrefix("utun"),
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &hostname, socklen_t(hostname.count),
                nil, 0, NI_NUMERICHOST
            )
            guard rc == 0 else { continue }
            let ip = String(cString: hostname)
            if ip.hasPrefix("10.7.0.") {
                if state.tunnelAddress == nil { state.tunnelAddress = ip }
            }
        }
        return state
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
