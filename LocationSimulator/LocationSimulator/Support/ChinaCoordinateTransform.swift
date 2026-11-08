//
//  ChinaCoordinateTransform.swift
//  LocationSimulator
//
//  Apple Maps serves AutoNavi (GCJ-02) map data inside mainland China, so the
//  coordinates MapKit hands back there are GCJ-02. The dt.simulatelocation
//  service used by location_simulation_set expects WGS-84. Passing GCJ-02
//  straight through shifts the simulated position by roughly 300-700 metres.
//
//  Convention:
//   - Every coordinate held in map state stays in the map datum (GCJ-02).
//   - deviceCoordinate(fromMapCoordinate:) converts GCJ-02 -> WGS-84 before sending.
//   - Coordinates imported from external sources default to WGS-84 and are
//     converted to GCJ-02 on ingestion so they land on the right map spot.
//

import Foundation
import CoreLocation

enum ChinaCoordinateTransform {
    private static let semiMajorAxis = 6_378_245.0
    private static let eccentricitySquared = 0.006_693_421_622_965_943

    static var correctionEnabled: Bool {
        guard UserDefaults.standard.object(forKey: UserDefaults.Keys.chinaCoordinateCorrection) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: UserDefaults.Keys.chinaCoordinateCorrection)
    }

    static var externalCoordinatesAreGCJ02: Bool {
        UserDefaults.standard.bool(forKey: UserDefaults.Keys.externalCoordinatesAreGCJ02)
    }

    static func isInMainlandChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.longitude > 73.66 && coordinate.longitude < 135.05
            && coordinate.latitude > 3.86 && coordinate.latitude < 53.55
    }

    // MARK: - WGS-84 -> GCJ-02

    static func gcj02(fromWGS84 coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInMainlandChina(coordinate) else { return coordinate }

        let x = coordinate.longitude - 105.0
        let y = coordinate.latitude - 35.0

        var deltaLatitude = latitudeOffset(x: x, y: y)
        var deltaLongitude = longitudeOffset(x: x, y: y)

        let radianLatitude = coordinate.latitude / 180.0 * .pi
        var magic = sin(radianLatitude)
        magic = 1 - eccentricitySquared * magic * magic
        let sqrtMagic = sqrt(magic)

        deltaLatitude = (deltaLatitude * 180.0)
            / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * sqrtMagic) * .pi)
        deltaLongitude = (deltaLongitude * 180.0)
            / (semiMajorAxis / sqrtMagic * cos(radianLatitude) * .pi)

        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + deltaLatitude,
            longitude: coordinate.longitude + deltaLongitude
        )
    }

    // MARK: - GCJ-02 -> WGS-84 (iterative inverse)

    static func wgs84(fromGCJ02 coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInMainlandChina(coordinate) else { return coordinate }

        var estimate = coordinate
        let tolerance = 1e-9

        for _ in 0..<10 {
            let roundTrip = gcj02(fromWGS84: estimate)
            let latitudeError = roundTrip.latitude - coordinate.latitude
            let longitudeError = roundTrip.longitude - coordinate.longitude

            if abs(latitudeError) < tolerance && abs(longitudeError) < tolerance {
                break
            }

            estimate = CLLocationCoordinate2D(
                latitude: estimate.latitude - latitudeError,
                longitude: estimate.longitude - longitudeError
            )
        }

        return estimate
    }

    // MARK: - Boundary helpers

    /// Map coordinate -> coordinate sent to the device (WGS-84).
    static func deviceCoordinate(fromMapCoordinate coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard correctionEnabled else { return coordinate }
        return wgs84(fromGCJ02: coordinate)
    }

    /// External coordinate -> map coordinate (GCJ-02).
    static func mapCoordinate(
        fromExternalCoordinate coordinate: CLLocationCoordinate2D,
        isGCJ02: Bool
    ) -> CLLocationCoordinate2D {
        guard correctionEnabled, !isGCJ02 else { return coordinate }
        return gcj02(fromWGS84: coordinate)
    }

    /// External coordinate -> coordinate sent to the device.
    static func deviceCoordinate(
        fromExternalCoordinate coordinate: CLLocationCoordinate2D,
        isGCJ02: Bool
    ) -> CLLocationCoordinate2D {
        guard correctionEnabled, isGCJ02 else { return coordinate }
        return wgs84(fromGCJ02: coordinate)
    }

    // MARK: - Offset polynomials

    private static func latitudeOffset(x: Double, y: Double) -> Double {
        var offset = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        offset += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        offset += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        offset += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return offset
    }

    private static func longitudeOffset(x: Double, y: Double) -> Double {
        var offset = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        offset += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        offset += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        offset += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return offset
    }
}
