//
//  LocationFFIBridge.swift
//  LocationSimulator
//
//  FFI bridge to the idevice library for GPS location simulation.
//  Extracted and adapted from StikDebug's IdeviceFFIBridge.swift.
//

import Foundation
import Darwin
import idevice

// MARK: - Status Codes

enum LocationSimulationStatus {
    static let ok: Int32 = 0
    static let invalidIP: Int32 = 1
    static let pairingRead: Int32 = 2
    static let providerCreate: Int32 = 3
    static let remoteServer: Int32 = 9
    static let locationSimulation: Int32 = 10
    static let locationSet: Int32 = 11
    static let locationClear: Int32 = 12

    static func description(for code: Int32) -> String {
        switch code {
        case ok: return "OK"
        case invalidIP: return "Invalid device IP address"
        case pairingRead: return "Failed to read pairing file"
        case providerCreate: return "Failed to create tunnel provider"
        case remoteServer: return "Failed to connect to remote server"
        case locationSimulation: return "Failed to create location simulation service"
        case locationSet: return "Failed to set simulated location"
        case locationClear: return "Failed to clear simulated location"
        default: return "Unknown error (\(code))"
        }
    }
}

// MARK: - Connection State

enum LocationSimulationState {
    static var adapter: OpaquePointer?
    static var handshake: OpaquePointer?
    static var remoteServer: OpaquePointer?
    static var locationSimulation: OpaquePointer?

    static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }
}

// MARK: - Command Queue

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "com.locationsimulator.sim", qos: .userInitiated)
}

// MARK: - Notification

extension Notification.Name {
    static let locationTunnelConnected = Notification.Name("locationTunnelConnected")
    static let pairingFileImported = Notification.Name("pairingFileImported")
}

// MARK: - Core FFI Functions

/// Simulate GPS location on the connected iOS device.
/// - Parameters:
///   - deviceIP: Target device IP (e.g. "10.7.0.1" for loopback VPN)
///   - latitude: Latitude to simulate
///   - longitude: Longitude to simulate
///   - pairingFile: Path to the pairing file (.plist / .mobiledevicepairing)
/// - Returns: 0 on success, error code otherwise
func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    // If we already have an active simulation session, just update coordinates
    if let locationSimulation = LocationSimulationState.locationSimulation {
        if let ffiError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(ffiError)
            LocationSimulationState.cleanup()
        } else {
            return LocationSimulationStatus.ok
        }
    }

    // Build socket address
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(RemotePairingPortResolver.resolve(targetIPAddress: deviceIP)).bigEndian

    let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    guard inetResult == 1 else {
        return LocationSimulationStatus.invalidIP
    }

    // Read pairing file
    var pairingHandle: OpaquePointer?
    let pairingError = pairingFile.withCString { rp_pairing_file_read($0, &pairingHandle) }
    if let pairingError {
        idevice_error_free(pairingError)
        return LocationSimulationStatus.pairingRead
    }

    guard let pairingHandle else {
        return LocationSimulationStatus.pairingRead
    }

    defer { rp_pairing_file_free(pairingHandle) }

    // Create tunnel via RemotePairing
    let providerError = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            tunnel_create_rppairing(
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.stride),
                "LocationSimulator",
                pairingHandle,
                nil,
                nil,
                &LocationSimulationState.adapter,
                &LocationSimulationState.handshake
            )
        }
    }

    if let providerError {
        idevice_error_free(providerError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.providerCreate
    }

    // Connect to RemoteServiceDiscovery
    let remoteServerError = remote_server_connect_rsd(
        LocationSimulationState.adapter,
        LocationSimulationState.handshake,
        &LocationSimulationState.remoteServer
    )
    if let remoteServerError {
        idevice_error_free(remoteServerError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.remoteServer
    }

    // Create location simulation service
    let locationSimulationError = location_simulation_new(
        LocationSimulationState.remoteServer,
        &LocationSimulationState.locationSimulation
    )
    if let locationSimulationError {
        idevice_error_free(locationSimulationError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSimulation
    }

    // Remote server handle is consumed by location_simulation_new
    LocationSimulationState.remoteServer = nil

    // Set the simulated location
    let locationSetError = location_simulation_set(
        LocationSimulationState.locationSimulation,
        latitude,
        longitude
    )
    if let locationSetError {
        idevice_error_free(locationSetError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSet
    }

    // Post connection notification
    NotificationCenter.default.post(
        name: .locationTunnelConnected,
        object: "Connected to \(deviceIP)"
    )
    return LocationSimulationStatus.ok
}

/// Clear the simulated GPS location, restoring real location.
/// - Returns: 0 on success, error code otherwise
func clear_simulated_location() -> Int32 {
    guard let locationSimulation = LocationSimulationState.locationSimulation else {
        return LocationSimulationStatus.locationClear
    }

    let ffiError = location_simulation_clear(locationSimulation)
    LocationSimulationState.cleanup()

    if let ffiError {
        idevice_error_free(ffiError)
        return LocationSimulationStatus.locationClear
    }

    return LocationSimulationStatus.ok
}
