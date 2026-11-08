# LocationSimulator

A standalone iOS GPS location simulation app, extracted from [StikDebug](https://github.com/StikDebug/StikDebug).

Simulate your iOS device's GPS location with a map-based interface, route playback, coordinate import, and background keep-alive.

## Features

- **Map Pin** — Tap anywhere on the map to drop a pin and simulate that GPS location
- **Location Search** — Search for addresses and points of interest
- **Route Simulation** — Plan a driving route between two points and play it back with realistic speeds (uses OpenStreetMap speed limit data)
- **Coordinate Import** — Import coordinates from GPX, KML, GeoJSON, JSON, CSV, or plain text files
- **Bookmarks** — Save and manage favorite locations
- **Background Keep-Alive** — Silent audio or location-based keep-alive to maintain simulation in the background
- **Resend Loop** — Automatically re-sends the simulated location every 4 seconds to maintain the spoof

## Requirements

- **iOS 17.4+** (uses the RemotePairing / RSD tunnel API)
- A **pairing file** (`.plist` or `.mobiledevicepairing`) for your device
- A **loopback VPN** such as [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) (for on-device simulation)
- **macOS with Xcode 16+** to build
- **XcodeGen** to generate the Xcode project (or create one manually)

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

## Usage

### 1. Import Pairing File

Open **Settings** (gear icon) and tap **Import Pairing File**. Select your `.mobiledevicepairing` or `.plist` pairing file.

> How to get a pairing file: See [PAIRING.md](https://github.com/StikDebug/StikDebug/blob/main/PAIRING.md) in the StikDebug project, or use SideStore/AltStore pairing tools.

### 2. Set Up VPN

Launch **LocalDevVPN** (or your preferred loopback VPN) and enable it. The default device IP is `10.7.0.1`.

> For non-loopback setups (e.g., Wi-Fi), change the device IP in Settings.

### 3. Simulate Location

- **Single pin**: Tap the map to drop a pin, then tap **Simulate Location**
- **Route**: Tap the route icon (top-left toolbar), enter start/end points, then tap **Play Route**
- **Import**: Tap the import icon to load coordinates from a file

### 4. Stop Simulation

Tap **Stop** to clear the simulated location and restore real GPS.

## Architecture

```
LocationSimulator/
├── App/
│   ├── LocationSimulatorApp.swift    # App entry point
│   └── Info.plist
├── Views/
│   ├── LocationSimulationView.swift  # Main map UI (search, pin, route, import)
│   └── SettingsView.swift            # Device IP, pairing, keep-alive settings
├── Services/
│   ├── LocationSimulationSession.swift  # Simulation state management
│   ├── BackgroundLocationManager.swift  # Location-based keep-alive
│   └── BackgroundAudioManager.swift     # Silent audio keep-alive
├── Device/
│   ├── LocationFFIBridge.swift       # FFI bridge to idevice library
│   ├── RemotePairingPortResolver.swift # Bonjour port discovery
│   └── DeviceConnectionContext.swift  # Device IP configuration
├── Support/
│   ├── PairingFileStore.swift        # Pairing file management
│   ├── AlertPresenter.swift          # UIKit alert helper
│   └── UserDefaults+Keys.swift       # Settings keys
└── Native/
    ├── idevice.h                     # C FFI header
    ├── libidevice_ffi.a              # Compiled Rust FFI library
    └── module.modulemap              # Clang module map
```

### How It Works

1. The app establishes a RemotePairing tunnel to the iOS device (via loopback VPN)
2. It connects to the device's RemoteServiceDiscovery (RSD) service
3. It uses the `location_simulation` API to set/clear GPS coordinates
4. A resend timer re-sends the location every 4 seconds to maintain the spoof
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
