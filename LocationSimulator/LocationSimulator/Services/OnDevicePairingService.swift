//
//  OnDevicePairingService.swift
//  LocationSimulator
//
//  Creates pairing files on-device (no computer required).
//  Adapted from StikDebug's OnDevicePairingService.swift.
//  Removed: Apple TV pairing, pairing file placement to other apps.
//

import Combine
import Darwin
import Foundation
import Network
import UserNotifications
import idevice

// MARK: - Phase / Mode

enum OnDevicePairingPhase: Equatable {
    case idle
    case discovering
    case waiting
    case pin(String)
    case success(name: String, model: String, isLocal: Bool)
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .discovering, .waiting, .pin:
            return true
        default:
            return false
        }
    }
}

enum OnDevicePairingMode: Equatable {
    case localDevice
    case otherDevice
}

// MARK: - Service

@MainActor
final class OnDevicePairingService: ObservableObject {
    static let shared = OnDevicePairingService()

    @Published private(set) var phase: OnDevicePairingPhase = .idle
    @Published private(set) var mode: OnDevicePairingMode?

    private let localNetwork = PairingLocalNetworkAuthorization()
    private var netService: NetService?
    private var listenerFD: Int32 = -1
    private var operationID: UUID?
    private var keepAliveRunning = false
    private(set) var hostname = "LocationSimulator"

    private init() {}

    /// Start advertising this device as a pairing host and wait for a peer to connect.
    func start() {
        guard phase == .idle else { return }

        mode = nil
        hostname = Self.makeHostname()
        let operationID = UUID()
        self.operationID = operationID
        phase = .discovering

        if #available(iOS 27.0, *) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        Task {
            guard await localNetwork.request() else {
                guard self.operationID == operationID else { return }
                self.operationID = nil
                self.phase = .failed("Local Network permission is required. Enable it in Settings, then try again.")
                return
            }

            guard self.operationID == operationID else { return }

            if #available(iOS 27.0, *) {
                BackgroundAudioManager.shared.requestStart()
                BackgroundLocationManager.shared.requestStart()
                self.keepAliveRunning = true
            }
            self.runPairing(operationID: operationID)
        }
    }

    func cancel() {
        operationID = nil
        stopAdvertising()
        closeListener()
        stopKeepAlive()
        mode = nil
        phase = .idle
    }

    func reset() {
        guard !phase.isRunning else { return }
        mode = nil
        phase = .idle
    }

    // MARK: - Pairing Flow

    private func runPairing(operationID: UUID) {
        let context = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        let hostname = self.hostname

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.performPairing(context: context, hostname: hostname, listenerReady: { fd, serviceID, txt in
                DispatchQueue.main.sync {
                    guard self.operationID == operationID else { return false }
                    self.listenerFD = Darwin.dup(fd)
                    self.startAdvertising(serviceID: serviceID, port: Self.listenerPort(fd), txt: txt)
                    return true
                }
            }, peerConnected: { isLocal in
                DispatchQueue.main.sync {
                    guard self.operationID == operationID else { return false }
                    self.mode = isLocal ? .localDevice : .otherDevice
                    self.phase = .waiting
                    if !isLocal {
                        self.stopKeepAlive()
                    }
                    return true
                }
            }, isActive: {
                DispatchQueue.main.sync { self.operationID == operationID }
            })

            DispatchQueue.main.async {
                guard self.operationID == operationID else { return }
                self.operationID = nil
                self.closeListener()
                self.stopAdvertising()
                self.stopKeepAlive()
                self.finish(result)
            }
        }
    }

    private func finish(_ result: OnDevicePairingResult) {
        switch result {
        case .success(let device):
            phase = .success(name: device.name, model: device.model, isLocal: device.isLocal)
            if device.isLocal {
                NotificationCenter.default.post(name: .pairingFileImported, object: nil)
            }
        case .failure(let message):
            phase = .failed(message)
        }
    }

    // MARK: - FFI Pairing (static, runs off main thread)

    nonisolated private static func performPairing(
        context: UInt,
        hostname: String,
        listenerReady: (Int32, String, [String: Data]) -> Bool,
        peerConnected: (Bool) -> Bool,
        isActive: () -> Bool
    ) -> OnDevicePairingResult {
        var host: OpaquePointer?
        var serviceIDPointer: UnsafeMutablePointer<CChar>?
        var txtPointer: UnsafeMutablePointer<UInt8>?
        var txtLength: UInt = 0
        var hostAltIRK = [UInt8](repeating: 0, count: 16)

        let prepareError = hostAltIRK.withUnsafeMutableBufferPointer { buffer in
            hostname.withCString { name in
                "Mac17,7".withCString { model in
                    pairable_host_prepare(
                        name,
                        model,
                        false,
                        &host,
                        &serviceIDPointer,
                        &txtPointer,
                        &txtLength,
                        buffer.baseAddress
                    )
                }
            }
        }

        if let prepareError {
            return .failure(consumePairingError(prepareError, fallback: "Failed to prepare pairing host"))
        }

        guard let host, let serviceIDPointer, let txtPointer else {
            pairable_host_free(host)
            idevice_string_free(serviceIDPointer)
            idevice_data_free(txtPointer, UInt(txtLength))
            return .failure("Pairing host did not return its Bonjour information.")
        }

        defer {
            pairable_host_free(host)
            idevice_string_free(serviceIDPointer)
            idevice_data_free(txtPointer, UInt(txtLength))
        }

        let serviceID = String(cString: serviceIDPointer)
        let txtData = Data(bytes: txtPointer, count: Int(txtLength))
        guard let txt = bonjourTXT(from: txtData) else {
            return .failure("Pairing host returned invalid Bonjour information.")
        }

        let listener: Int32
        do {
            listener = try makeListener()
        } catch {
            return .failure("Failed to start pairing listener: \(error.localizedDescription)")
        }
        defer { Darwin.close(listener) }

        guard listenerReady(listener, serviceID, txt) else {
            return .failure("Pairing was cancelled.")
        }

        let connection = Darwin.accept(listener, nil, nil)
        guard connection >= 0 else {
            return .failure(errno == EBADF ? "Pairing was cancelled." : "Failed to accept pairing connection: \(posixMessage())")
        }
        defer { Darwin.close(connection) }
        guard let phone = phoneAddress(for: connection), peerConnected(phone.1) else {
            return .failure("Pairing was cancelled or the device address was unavailable.")
        }
        let isLocal = phone.1

        var peer: UnsafeMutablePointer<RpPairingPeerDeviceC>?
        var pairingFile: OpaquePointer?
        let callbackContext = UnsafeMutableRawPointer(bitPattern: context)
        if let ffiError = pairable_host_accept_fd(
            host,
            connection,
            onDevicePairingPINCallback,
            callbackContext,
            &peer,
            &pairingFile
        ) {
            return .failure(consumePairingError(ffiError, fallback: "Pairing failed"))
        }

        guard let pairingFile else {
            rppairing_peer_device_free(peer)
            return .failure("Pairing completed without returning a pairing file.")
        }
        defer {
            rp_pairing_file_free(pairingFile)
            rppairing_peer_device_free(peer)
        }

        guard isActive() else { return .failure("Pairing was cancelled.") }
        let name = cString(peer?.pointee.name)
        let model = cString(peer?.pointee.model)
        return savePairingFile(
            pairingFile,
            name: name,
            model: model,
            isLocal: isLocal,
            isActive: isActive
        )
    }

    nonisolated private static func phoneAddress(for connection: Int32) -> (sockaddr_in, Bool)? {
        var peer = sockaddr_in()
        var local = sockaddr_in()
        var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        var localLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let peerResult = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getpeername(connection, $0, &peerLength)
            }
        }
        let localResult = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(connection, $0, &localLength)
            }
        }
        guard peerResult == 0, localResult == 0,
              peer.sin_family == sa_family_t(AF_INET), local.sin_family == sa_family_t(AF_INET) else { return nil }
        return (peer, peer.sin_addr.s_addr == local.sin_addr.s_addr)
    }

    nonisolated private static func savePairingFile(
        _ pairingFile: OpaquePointer,
        name: String,
        model: String,
        isLocal: Bool,
        isActive: () -> Bool
    ) -> OnDevicePairingResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(PairingFileStore.fileName)
        defer {
            if isLocal {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure("Failed to prepare pairing file export: \(error.localizedDescription)")
        }
        if let ffiError = fileURL.path.withCString({ rp_pairing_file_write(pairingFile, $0) }) {
            return .failure(consumePairingError(ffiError, fallback: "Failed to save pairing file"))
        }
        guard isActive() else { return .failure("Pairing was cancelled.") }
        if isLocal {
            do {
                try PairingFileStore.replace(with: fileURL)
            } catch {
                return .failure("Failed to store local pairing file: \(error.localizedDescription)")
            }
        }
        return .success(PairedDevice(
            name: name,
            model: model,
            isLocal: isLocal
        ))
    }

    // MARK: - Network Helpers

    private func startAdvertising(serviceID: String, port: UInt16, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: Int32(port)
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    private func closeListener() {
        guard listenerFD >= 0 else { return }
        Darwin.shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        listenerFD = -1
    }

    private func stopKeepAlive() {
        guard keepAliveRunning else { return }
        keepAliveRunning = false
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()
    }

    fileprivate func presentPIN(_ pin: String) {
        guard mode == .localDevice || mode == .otherDevice else { return }
        guard phase.isRunning else { return }
        phase = .pin(pin)

        if mode == .localDevice {
            let content = UNMutableNotificationContent()
            content.title = "Pairing code"
            content.body = "Enter \(pin) to finish pairing."
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "locationsimulator.pairing.pin", content: content, trigger: nil)
            )
        }
    }

    private static func makeHostname() -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var suffix = [characters[Int.random(in: 0..<26)], characters[Int.random(in: 26..<characters.count)]]
        suffix += (0..<4).map { _ in characters[Int.random(in: 0..<characters.count)] }
        suffix.shuffle()
        return "LocSim-\(String(suffix))"
    }

    nonisolated private static func makeListener() throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        var reuseAddress: Int32 = 1
        guard Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout.size(ofValue: reuseAddress))
        ) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }

        return fd
    }

    nonisolated private static func listenerPort(_ fd: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        return result == 0 ? UInt16(bigEndian: address.sin_port) : 0
    }

    nonisolated private static func bonjourTXT(from data: Data) -> [String: Data]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }

        return dictionary.reduce(into: [:]) { result, entry in
            if let value = entry.value as? String {
                result[entry.key] = Data(value.utf8)
            } else if let value = entry.value as? Data {
                result[entry.key] = value
            } else if let value = entry.value as? NSNumber {
                result[entry.key] = Data(value.stringValue.utf8)
            }
        }
    }
}

// MARK: - Supporting Types

private struct PairedDevice {
    let name: String
    let model: String
    let isLocal: Bool
}

private enum OnDevicePairingResult {
    case success(PairedDevice)
    case failure(String)
}

// MARK: - Local Network Authorization

@MainActor
private final class PairingLocalNetworkAuthorization {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Bool, Never>?

    func request() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            let listener = try? NWListener(using: parameters)
            listener?.service = NWListener.Service(name: "LocSimPairingProbe", type: "_locsimprobe._tcp")
            listener?.newConnectionHandler = { $0.cancel() }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.finish(false) }
                }
            }
            self.listener = listener

            let browser = NWBrowser(for: .bonjour(type: "_locsimprobe._tcp", domain: nil), using: parameters)
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.finish(false) }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if !results.isEmpty {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            self.browser = browser

            listener?.start(queue: .main)
            browser.start(queue: .main)

            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.finish(false)
            }
        }
    }

    private func finish(_ authorized: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        continuation.resume(returning: authorized)
    }
}

// MARK: - PIN Callback

private let onDevicePairingPINCallback: PairableHostPinCb = { pin, context in
    guard let pin, let context else { return }
    let service = Unmanaged<OnDevicePairingService>.fromOpaque(context).takeUnretainedValue()
    let value = String(cString: pin)
    DispatchQueue.main.async {
        service.presentPIN(value)
    }
}

// MARK: - C Helpers

private func consumePairingError(
    _ error: UnsafeMutablePointer<IdeviceFfiError>,
    fallback: String
) -> String {
    let message = error.pointee.message.flatMap { String(validatingUTF8: $0) } ?? fallback
    idevice_error_free(error)
    return message
}

private func cString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    pointer.flatMap { String(validatingUTF8: $0) } ?? ""
}

private func posixMessage() -> String {
    String(cString: strerror(errno))
}
