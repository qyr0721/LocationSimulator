//
//  DeviceConnectionContext.swift
//  LocationSimulator
//

import Foundation

enum DeviceConnectionContext {
    /// 默认使用 127.0.0.1 直连，无需 VPN
    static let defaultTargetIPAddress = "127.0.0.1"

    static var targetIPAddress: String {
        let stored = UserDefaults.standard
            .string(forKey: UserDefaults.Keys.targetDeviceIP)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else {
            return defaultTargetIPAddress
        }
        return stored
    }

    /// 隧道 IP（仅在 VPN 模式下使用）
    static let tunnelIPAddress = "10.7.0.1"
}
