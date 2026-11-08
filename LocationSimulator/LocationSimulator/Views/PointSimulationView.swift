//
//  PointSimulationView.swift
//  LocationSimulator
//
//  Layer 1: Point location simulation with map picker, search, history, favorites.
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Search Completer Wrapper

final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        DispatchQueue.main.async { self.results = completer.results }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async { self.results = [] }
    }
}

// MARK: - Location Manager for getting user position

final class UserLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var userCoordinate: CLLocationCoordinate2D?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async { self.userCoordinate = loc.coordinate }
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - Connection Status Banner

struct ConnectionStatusBanner: View {
    @ObservedObject var session: LocationSimulationSession
    @State private var showVPNAlert = false

    var body: some View {
        if let error = session.lastError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("设备未连接")
                        .font(.subheadline.weight(.semibold))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("连接 VPN") {
                    showVPNAlert = true
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
            .padding(12)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .alert("连接 LocalDevVPN", isPresented: $showVPNAlert) {
                Button("打开 LocalDevVPN") {
                    if let url = URL(string: "localdevvpn://enable?scheme=locationsimulator") {
                        UIApplication.shared.open(url) { ok in
                            if !ok {
                                UIApplication.shared.open(URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!)
                            }
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("位置模拟需要 LocalDevVPN 回环隧道。请确保已安装并启用 LocalDevVPN，且 WiFi 已连接。")
            }
        } else if session.isSimulating {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在模拟位置")
                        .font(.subheadline.weight(.semibold))
                    Text(session.connectionStatus ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "location.fill")
                    .foregroundStyle(.blue)
            }
            .padding(12)
            .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Main View

struct PointSimulationView: View {
    var onMenuTap: () -> Void = {}

    @StateObject private var session = LocationSimulationSession.shared
    @StateObject private var searchCompleter = SearchCompleter()
    @StateObject private var locationProvider = UserLocationProvider()

    // MARK: - Coordinate State
    @State private var latitude: String = ""
    @State private var longitude: String = ""
    @State private var altitude: String = "50.0"

    // MARK: - Jitter State
    @State private var enableMicroDrift: Bool = false
    @State private var driftRadius: String = "5.0"

    // MARK: - Search State
    @State private var searchText: String = ""
    @State private var showSearchResults: Bool = false

    // MARK: - Map
    @State private var mapCameraPosition: MapCameraPosition = .automatic
    @State private var selectedMapCoord: CLLocationCoordinate2D?

    // MARK: - History / Favorites
    @State private var historyItems: [LocationItem] = LocationItem.loadHistory()
    @State private var favoriteItems: [LocationItem] = LocationItem.loadFavorites()
    @State private var showHistory: Bool = false
    @State private var showFavorites: Bool = false

    // MARK: - Favorite Dialog
    @State private var showFavoriteDialog: Bool = false
    @State private var favoriteNote: String = ""

    // MARK: - Keyboard
    @FocusState private var focusedField: CoordinateField?
    enum CoordinateField { case lat, lon, alt, drift }

    // MARK: - UI State
    @State private var isSimulating: Bool = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Search bar
                    searchBar

                    // Map with user location
                    mapSection

                    // Connection status
                    ConnectionStatusBanner(session: session)

                    // Start button
                    startButton

                    // Coordinate form
                    coordinateSection

                    // Jitter section
                    jitterSection

                    // Action buttons
                    actionButtons
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onMenuTap) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("LocationSimulator")
                        .font(.system(size: 20, weight: .bold))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                    }
                    .fontWeight(.semibold)
                }
            }
            // Search results overlay
            .overlay {
                if showSearchResults && !searchCompleter.results.isEmpty {
                    searchResultsOverlay
                }
            }
            // Favorite dialog
            .alert("收藏位置", isPresented: $showFavoriteDialog) {
                TextField("备注（可选）", text: $favoriteNote)
                Button("保存") { saveFavorite() }
                Button("取消", role: .cancel) { favoriteNote = "" }
            } message: {
                Text("为该位置添加备注，留空则以坐标命名")
            }
            // History sheet
            .sheet(isPresented: $showHistory) {
                LocationHistorySheet(
                    items: historyItems,
                    onSelect: { item in
                        latitude = String(format: "%.6f", item.latitude)
                        longitude = String(format: "%.6f", item.longitude)
                        altitude = String(format: "%.1f", item.altitude)
                        selectedMapCoord = item.coordinate
                        showHistory = false
                    },
                    onFavorite: { item in
                        if !favoriteItems.contains(item) {
                            favoriteItems.append(item)
                            LocationItem.saveFavorites(favoriteItems)
                        }
                    },
                    title: "历史记录"
                )
            }
            // Favorites sheet
            .sheet(isPresented: $showFavorites) {
                LocationHistorySheet(
                    items: favoriteItems,
                    onSelect: { item in
                        latitude = String(format: "%.6f", item.latitude)
                        longitude = String(format: "%.6f", item.longitude)
                        altitude = String(format: "%.1f", item.altitude)
                        selectedMapCoord = item.coordinate
                        showFavorites = false
                    },
                    onFavorite: { item in
                        favoriteItems.removeAll { $0 == item }
                        LocationItem.saveFavorites(favoriteItems)
                    },
                    title: "收藏"
                )
            }
            .onAppear {
                locationProvider.request()
                if latitude.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if let userCoord = locationProvider.userCoordinate, latitude.isEmpty {
                            latitude = String(format: "%.6f", userCoord.latitude)
                            longitude = String(format: "%.6f", userCoord.longitude)
                            selectedMapCoord = userCoord
                            mapCameraPosition = .region(MKCoordinateRegion(
                                center: userCoord,
                                latitudinalMeters: 800,
                                longitudinalMeters: 800
                            ))
                        } else if latitude.isEmpty {
                            // Default to Beijing if no location available
                            latitude = "39.9042"
                            longitude = "116.4074"
                        }
                    }
                }
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索地点、地址...", text: $searchText)
                    .font(.subheadline)
                    .focused($focusedField, equals: .lat) // reuse focus to dismiss
                    .submitLabel(.search)
                    .onChange(of: searchText) { _, newValue in
                        if newValue.isEmpty {
                            showSearchResults = false
                            searchCompleter.update(query: "")
                        } else {
                            showSearchResults = true
                            searchCompleter.update(query: newValue)
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        showSearchResults = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button { showHistory = true } label: {
                Image(systemName: "clock")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 40)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button { showFavorites = true } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                    .frame(width: 40, height: 40)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Map Section

    private var mapSection: some View {
        MapReader { proxy in
            Map(position: $mapCameraPosition) {
                UserAnnotation()
                if let coord = selectedMapCoord {
                    Marker("选点", coordinate: coord)
                        .tint(.red)
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { screenPoint in
                if let coord = proxy.convert(screenPoint, from: .local) {
                    selectedMapCoord = coord
                    latitude = String(format: "%.6f", coord.latitude)
                    longitude = String(format: "%.6f", coord.longitude)
                }
            }
        }
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button(action: toggleSimulation) {
            HStack(spacing: 10) {
                Image(systemName: isSimulating ? "stop.circle.fill" : "location.fill")
                    .font(.system(size: 20, weight: .medium))
                Text(isSimulating ? "停止模拟" : "启动模拟")
                    .font(.system(size: 18, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: isSimulating ? [.red, .red.opacity(0.8)] : [.blue, .blue.opacity(0.8)],
                    startPoint: .leading, endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .shadow(color: (isSimulating ? Color.red : Color.blue).opacity(0.3), radius: 8, y: 4)
        }
    }

    // MARK: - Coordinate Section

    private var coordinateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("坐标", icon: "location")

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    CoordinateInputCard(title: "纬度", text: $latitude, placeholder: "39.9042", field: .lat, focused: $focusedField)
                    CoordinateInputCard(title: "经度", text: $longitude, placeholder: "116.4074", field: .lon, focused: $focusedField)
                }
                CoordinateInputCard(title: "海拔 (米)", text: $altitude, placeholder: "50.0", field: .alt, focused: $focusedField)
            }
        }
    }

    // MARK: - Jitter Section

    private var jitterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("微移与抖动", icon: "arrow.triangle.2.circlepath")

            // Micro drift toggle
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("模拟微移")
                        .font(.system(size: 15, weight: .medium))
                    Text("模拟 GPS 坐标的缓慢游走")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $enableMicroDrift)
                    .labelsHidden()
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if enableMicroDrift {
                CoordinateInputCard(title: "微移半径 (米)", text: $driftRadius, placeholder: "5.0", field: .drift, focused: $focusedField)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: enableMicroDrift)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            ActionButton(title: "地图采集", icon: "map", color: .blue) {
                focusedField = nil
                // Map is already visible; just scroll to it or highlight
            }
            ActionButton(title: "收藏", icon: "star.fill", color: .orange) {
                focusedField = nil
                favoriteNote = ""
                showFavoriteDialog = true
            }
        }
    }

    // MARK: - Search Results Overlay

    @ViewBuilder
    private var searchResultsOverlay: some View {
        if #available(iOS 26, *) {
            searchResultsListBase
                .glassEffect(in: .rect(cornerRadius: 16))
        } else {
            searchResultsListBase
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var searchResultsListBase: some View {
        VStack {
            Spacer().frame(height: 68)
            VStack(spacing: 0) {
                let results = Array(searchCompleter.results.prefix(5))
                ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                    Button {
                        selectSearchResult(result)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "location.circle")
                                .foregroundStyle(.blue)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    if index < results.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 16)
            Spacer()
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, 4)
    }

    // MARK: - Actions

    private func toggleSimulation() {
        focusedField = nil
        if isSimulating {
            session.stop()
            isSimulating = false
        } else {
            guard let lat = Double(latitude), let lon = Double(longitude) else {
                session.lastError = "请输入有效的经纬度"
                return
            }
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            session.startSimulation(at: coord)
            isSimulating = true

            // Add to history
            let item = LocationItem(latitude: lat, longitude: lon, altitude: Double(altitude) ?? 50.0)
            historyItems.insert(item, at: 0)
            if historyItems.count > 50 { historyItems.removeLast() }
            LocationItem.saveHistory(historyItems)
        }
    }

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        searchText = ""
        showSearchResults = false

        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: result))
        search.start { response, _ in
            guard let coord = response?.mapItems.first?.placemark.coordinate else { return }
            DispatchQueue.main.async {
                latitude = String(format: "%.6f", coord.latitude)
                longitude = String(format: "%.6f", coord.longitude)
                selectedMapCoord = coord
                mapCameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 500,
                    longitudinalMeters: 500
                ))
            }
        }
    }

    private func saveFavorite() {
        let lat = Double(latitude) ?? 0
        let lon = Double(longitude) ?? 0
        let alt = Double(altitude) ?? 0
        let note = favoriteNote.trimmingCharacters(in: .whitespaces)

        let item = LocationItem(
            latitude: lat,
            longitude: lon,
            altitude: alt,
            note: note.isEmpty ? nil : note
        )
        if !favoriteItems.contains(item) {
            favoriteItems.append(item)
            LocationItem.saveFavorites(favoriteItems)
        }
        favoriteNote = ""
    }
}

// MARK: - Coordinate Input Card (with keyboard Done)

struct CoordinateInputCard: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    let field: PointSimulationView.CoordinateField
    var focused: FocusState<PointSimulationView.CoordinateField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .font(.system(size: 16, weight: .medium))
                .keyboardType(.decimalPad)
                .focused(focused, equals: field)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let title: String
    let icon: String
    var color: Color = .blue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                Text(title)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Location Item Model

struct LocationItem: Identifiable, Equatable, Codable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let note: String?
    let timestamp: Date

    init(latitude: Double, longitude: Double, altitude: Double, note: String? = nil) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.note = note
        self.timestamp = Date()
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayName: String {
        if let note, !note.isEmpty { return note }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }

    static func == (lhs: LocationItem, rhs: LocationItem) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.00001 &&
        abs(lhs.longitude - rhs.longitude) < 0.00001
    }

    // MARK: Persistence

    private static let historyKey = "locationHistory"
    private static let favoritesKey = "locationFavorites"

    static func loadHistory() -> [LocationItem] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let items = try? JSONDecoder().decode([LocationItem].self, from: data) else { return [] }
        return items
    }

    static func saveHistory(_ items: [LocationItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    static func loadFavorites() -> [LocationItem] {
        guard let data = UserDefaults.standard.data(forKey: favoritesKey),
              let items = try? JSONDecoder().decode([LocationItem].self, from: data) else { return [] }
        return items
    }

    static func saveFavorites(_ items: [LocationItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
    }
}

// MARK: - History / Favorites Sheet

struct LocationHistorySheet: View {
    let items: [LocationItem]
    let onSelect: (LocationItem) -> Void
    let onFavorite: (LocationItem) -> Void
    var title: String = "历史记录"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("暂无记录")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
                ForEach(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayName)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(String(format: "%.5f, %.5f · 海拔 %.1fm", item.latitude, item.longitude, item.altitude))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                onFavorite(item)
                            } label: {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
