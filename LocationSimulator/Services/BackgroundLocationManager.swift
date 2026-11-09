//
//  BackgroundLocationManager.swift
//  LocationSimulator
//
//  Keeps the app alive in the background via continuous location updates.
//  Extracted from StikDebug.
//

import CoreLocation
import UIKit

final class BackgroundLocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocationManager()

    private let locationManager = CLLocationManager()
    private var isRunning = false
    private var activityCount = 0
    private var isRequestingAuthorization = false

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = CLLocationDistanceMax
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func configurationDidChange() {
        refreshRunningState()
    }

    func requestStart() {
        activityCount += 1
        refreshRunningState()
    }

    func requestStop() {
        activityCount = max(activityCount - 1, 0)
        refreshRunningState()
    }

    func requestAuthorizationIfNeeded() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return
        case .notDetermined:
            isRequestingAuthorization = true
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            restoreAudioFallback()
        @unknown default:
            restoreAudioFallback()
        }
    }

    private func refreshRunningState() {
        let shouldRun = activityCount > 0 && UserDefaults.standard.bool(forKey: UserDefaults.Keys.keepAliveLocation)
        guard shouldRun != isRunning else { return }

        isRunning = shouldRun
        guard shouldRun else {
            locationManager.stopUpdatingLocation()
            return
        }

        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            restoreAudioFallback()
        @unknown default:
            restoreAudioFallback()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            isRequestingAuthorization = false
            if isRunning {
                manager.startUpdatingLocation()
            }
        case .denied, .restricted:
            if isRunning || isRequestingAuthorization {
                isRequestingAuthorization = false
                restoreAudioFallback()
            }
        case .notDetermined:
            return
        @unknown default:
            if isRunning || isRequestingAuthorization {
                isRequestingAuthorization = false
                restoreAudioFallback()
            }
        }
    }

    private func restoreAudioFallback() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: UserDefaults.Keys.keepAliveLocation)
        defaults.set(true, forKey: UserDefaults.Keys.keepAliveAudio)
        refreshRunningState()
        BackgroundAudioManager.shared.configurationDidChange()

        showAlert(
            title: "Location Access Refused",
            message: "Location access was refused. Open Settings to enable it, or the app will use silent audio to stay alive.",
            showOk: false,
            showTryAgain: true,
            primaryButtonText: "Settings"
        ) { openSettings in
            guard openSettings,
                  let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            UIApplication.shared.open(settingsURL)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location fixes may fail (e.g. no GPS indoors) — that's fine.
        // The manager just needs to be running, not actually fix a location.
    }
}
