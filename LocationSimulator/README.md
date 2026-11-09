# LocationSimulator

A standalone iOS GPS location simulation app, extracted from [StikDebug](https://github.com/StikDebug/StikDebug).

Simulate your iOS device's GPS location with a map-based interface, route playback, coordinate import, and background keep-alive.

## Features

- **First-Run Guide** — On first launch, a step-by-step guide walks you through connecting LocalDevVPN (with an App Store fallback) and creating a pairing file. On-device pairing is recommended, file import is still available.
- **Map Pin** — Tap anywhere on the map to drop a pin and simulate that GPS location
- **Live Updates** — While simulating, changing the coordinate (map tap, search, history/favorites, manual input) is pushed to the device immediately — no need to stop and restart
- **Location Search** — Search for addresses and points of interest
- **Route Simulation** — Plan a route by tapping the map, searching places, or starting from your current location, then play it back with realistic speeds (uses OpenStreetMap speed limit data)
- **Coordinate Import** — Import coordinates from GPX, KML, GeoJSON, JSON, CSV, or plain text files
- **History & Favorites** — Rename entries, add/remove with swipe actions
- **Fast Connection Check** — Network/VPN status is monitored continuously; starting a simulation performs an instant preflight gate instead of waiting for a slow Bonjour lookup
- **Background Keep-Alive** — Silent audio or location-based keep-alive to maintain simulation in the background
- **Resend Loop** — Automatically re-sends the simulated location every 4 seconds to maintain the spoof

## Requirements

- **iOS 17.4+** (uses the RemotePairing / RSD tunnel API)
- A **pairing file** (`.plist` or `.mobiledevicepairing`) for your device
- A **loopback VPN** such as [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) (for on-device simulation)
- **macOS with Xcode 16+** to build
- **XcodeGen** to generate the Xcode project (or create one manually)

## First Launch

The app assumes you have no pairing file yet and shows a full-screen guide:

1. **LocalDevVPN** — open the VPN app with `localdevvpn://enable`, or jump to the App Store if it isn't installed.
2. **Pairing** — "Pair This Device" creates a pairing file on-device (no computer needed); "Import from File" accepts an existing `.plist` / `.mobiledevicepairing`.
3. **Done** — the guide is dismissed and won't appear again. You can re-open it from **设置 → 关于 → 重新查看使用引导**.

The connection banner on the home page shows readiness in real time and blocks a simulation start while the VPN or pairing file is missing.

## Building

### Using XcodeGen (recommended)

```bash
# Install XcodeGen if you don't have it
brew install xcodegen

# Generate the Xcode project
cd LocationSimulator
xcodegen generate

# Open in Xcode
open LocationSimulator.xcodeproj
```

Then in Xcode:
1. Select the **LocationSimulator** target
2. Go to **Signing & Capabilities** and set your Apple ID / team
3. Set a unique **Bundle Identifier** (e.g., `com.yourname.LocationSimulator`)
4. Build and run on your device (Cmd+R)

### Manual Xcode Project Setup

If you prefer not to use XcodeGen:

1. Create a new iOS App project in Xcode (SwiftUI, iOS 17.4+)
2. Add all source files from `LocationSimulator/` to the project
3. Add `Native/libidevice_ffi.a` to **Link Binary With Libraries**
4. Set `HEADER_SEARCH_PATHS` to `$(SRCROOT)/LocationSimulator/Native`
5. Set `LIBRARY_SEARCH_PATHS` to `$(SRCROOT)/LocationSimulator/Native`
6. Add linker flags: `-lidevice_ffi -lc++ -lz`
7. Configure `Info.plist` with the background modes and location permissions (see `LocationSimulator/App/Info.plist`)

### xtool / SwiftPM

`python3 build_locsim_xtool.py` at the repository root converts the sources into a SwiftPM package for [xtool](https://github.com/xtool-org/xtool). It picks up all `*.swift` files automatically, so newly added source files need no manual registration.

## Usage

### 1. Import Pairing File

Open **Settings** (gear icon) and tap **Import Pairing File**. Select your `.mobiledevicepairing` or `.plist` pairing file. On iOS 27+ you can also use **创建配对文件（设备端）**.

> How to get a pairing file: See [PAIRING.md](https://github.com/StikDebug/StikDebug/blob/main/PAIRING.md) in the StikDebug project, or use SideStore/AltStore pairing tools.

### 2. Set Up VPN

Launch **LocalDevVPN** (or your preferred loopback VPN) and enable it. The default device IP is `10.7.0.1`.

> For non-loopback setups (e.g., Wi-Fi), change the device IP in Settings.

### 3. Simulate Location

- **Single pin**: Tap the map to drop a pin, then tap **启动模拟**. Change the pin while simulating and the new location takes effect immediately.
- **Route**: Open 路线模拟 from the drawer, tap the map / search a place / use the location button to set the start, then tap **开始模拟**.
- **Import**: Tap the import icon to load coordinates from a file (available in the legacy map view).

### 4. Manage History & Favorites

Open the clock / star buttons next to the search bar. Swipe right on a row to rename it, swipe left to delete it (or add it to favorites from history).

### 5. Stop Simulation

Tap **停止模拟** to clear the simulated location and restore real GPS.

## Architecture

```
LocationSimulator/
├── App/
│   ├── LocationSimulatorApp.swift        # App entry point + first-run guide
│   └── Info.plist
├── Views/
│   ├── MainDrawerView.swift              # Three-layer drawer navigation
│   ├── OnboardingView.swift              # First-run guide (VPN → pairing)
│   ├── PointSimulationView.swift         # Point simulation: search, map, history, favorites
│   ├── RouteSimulationView.swift         # Route simulation: search, waypoints, playback
│   ├── SettingsDrawerView.swift          # Settings page used by the drawer
│   ├── SettingsView.swift                # Legacy English settings (not mounted)
│   ├── OnDevicePairingView.swift         # On-device pairing guide
│   └── LocationSimulationView.swift      # Legacy English map view (not mounted)
├── Services/
│   ├── LocationSimulationSession.swift  # Simulation state + live coordinate updates
│   ├── ConnectionPreflight.swift        # Instant connection gate + VPN link helpers
│   ├── OnDevicePairingService.swift     # On-device pairing implementation
│   ├── BackgroundLocationManager.swift  # Location-based keep-alive
│   └── BackgroundAudioManager.swift     # Silent audio keep-alive
├── Device/
│   ├── LocationFFIBridge.swift          # FFI bridge to idevice library
│   ├── RemotePairingPortResolver.swift  # Bonjour port discovery (cached / async)
│   └── DeviceConnectionContext.swift    # Device IP configuration
├── Support/
│   ├── MapLegalHider.swift              # Hides MapKit's Legal link on the map
│   ├── PairingFileStore.swift           # Pairing file management
│   ├── ChinaCoordinateTransform.swift   # GCJ-02 / WGS-84 conversion
│   ├── AlertPresenter.swift             # UIKit alert helper
│   └── UserDefaults+Keys.swift          # Settings keys
└── Native/
    ├── idevice.h                        # C FFI header
    ├── libidevice_ffi.a                 # Compiled Rust FFI library
    └── module.modulemap                 # Clang module map
```

> `LocationSimulationView.swift` and `SettingsView.swift` are the original StikDebug-style English views, kept for reference but not mounted by `MainDrawerView`. Apple map attribution is retained as text in **设置 → 关于**.

### How It Works

1. The app establishes a RemotePairing tunnel to the iOS device (via loopback VPN)
2. It connects to the device's RemoteServiceDiscovery (RSD) service
3. It uses the `location_simulation` API to set/clear GPS coordinates
4. A resend timer re-sends the current coordinate every 4 seconds to maintain the spoof
5. Background keep-alive mechanisms prevent iOS from suspending the app

## Supported Coordinate Import Formats

| Format | Extension | Notes |
|--------|-----------|-------|
| GPX | `.gpx` | Waypoints, track points, route points |
| KML | `.kml` | `<coordinates>` elements |
| GeoJSON | `.geojson`, `.json` | FeatureCollection, GeometryCollection |
| JSON | `.json` | `lat`/`lon` or `latitude`/`longitude` keys |
| CSV | `.csv` | With or without header row (lat/lon columns) |
| Plain Text | `.txt` | Space/comma/semicolon separated coordinate pairs |

## License

This project is extracted from [StikDebug](https://github.com/StikDebug/StikDebug) and is licensed under **AGPL-3.0**. See [LICENSE](https://github.com/StikDebug/StikDebug/blob/main/LICENSE) for details.

Speed limit data is provided by [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors (ODbL).

## Credits

- [StikDebug](https://github.com/StikDebug/StikDebug) — Original project
- [idevice](https://github.com/jkcoxson/idevice) — Rust library for iOS device communication
- [OpenStreetMap](https://www.openstreetmap.org/) — Speed limit data for route simulation
