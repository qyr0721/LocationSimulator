//
//  UserDefaults+Keys.swift
//  LocationSimulator
//

import Foundation

extension UserDefaults {
    enum Keys {
        static let targetDeviceIP = "TunnelDeviceIP"
        static let keepAliveLocation = "keepAliveLocation"
        static let keepAliveAudio = "keepAliveAudio"
        static let chinaCoordinateCorrection = "chinaCoordinateCorrection"
        static let externalCoordinatesAreGCJ02 = "externalCoordinatesAreGCJ02"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }
}
