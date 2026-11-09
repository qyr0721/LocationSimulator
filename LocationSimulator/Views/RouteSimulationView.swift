//
//  RouteSimulationView.swift
//  LocationSimulator
//
//  Layer 2: Route/trajectory simulation.
//  Create routes on map, simulate with customizable jitter.
//  与点模拟页保持一致的卡片式设计，新增地点搜索与「从当前定位开始选点」。
//

import SwiftUI
import MapKit
import CoreLocation

struct RouteSimulationView: View {
    var onMenuTap: () -> Void = {}

    @StateObject private var session = LocationSimulationSession.shared
    @StateObject private var locationProvider = UserLocationProvider()
    @StateObject private var searchCompleter = SearchCompleter()
    @ObservedObject private var preflight = ConnectionPreflight.shared

    // MARK: - Route State
    @State private var waypoints: [RouteWaypoint] = []
    @State private var routePolyline: MKPolyline?
    @State private var isSimulating: Bool = false
    @State private var routeName: String = ""

    // MARK: - Map State
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074),
            latitudinalMeters: 5000,
            longitudinalMeters: 5000
        )
    )

    // MARK: - Search State
    @State private var searchText: String = ""
    @State private var showSearchResults: Bool = false

    // MARK: - Speed / Jitter State
    @State private var speedMode: SpeedMode = .walking
    @State private var customSpeed: String = "30"
    @State private var jitterEnabled: Bool = true
    @State private var jitterRange: String = "5.0"
    @State private var showWaypointList: Bool = false

    @State private var locationHint: String?
    @State private var preflightIssue: PreflightIssue?

    /// 速度以 km/h 展示，回放内部使用 m/s
    enum SpeedMode: String, CaseIterable {
        case walking = "步行"
        case cycling = "骑行"
        case driving = "驾车"
        case custom  = "自定义"

        var speedKPH: Double {
            switch self {
            case .walking: return 5.0
            case .cycling: return 15.0
            case .driving: return 40.0
            case .custom:  return 30.0
            }
        }

        var icon: String {
            switch self {
            case .walking: return "figure.walk"
            case .cycling: return "bicycle"
            case .driving: return "car"
            case .custom:  return "speedometer"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                mapContent

                VStack(spacing: 12) {
                    topBar

                    if showSearchResults && !searchCompleter.results.isEmpty {
                        searchResultsCard
                    }

                    if let hint = locationHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer()

                    bottomPanel
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onMenuTap) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("路线模拟")
                        .font(.system(size: 20, weight: .bold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showWaypointList = true
                        } label: {
                            Label("航点列表", systemImage: "list.bullet")
                        }
                        Button {
                            undoLastWaypoint()
                        } label: {
                            Label("撤销上一个点", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(waypoints.isEmpty)
                        Button {
                            clearRoute()
                        } label: {
                            Label("清除路线", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showWaypointList) {
                waypointListSheet
            }
            .alert("暂不能启动模拟", isPresented: Binding(
                get: { preflightIssue != nil },
                set: { presented in if !presented { preflightIssue = nil } }
            )) {
                if preflightIssue == .vpnNotConnected {
                    Button("打开 LocalDevVPN") { LocalDevVPNLink.open() }
                }
                Button("好", role: .cancel) {}
            } message: {
                if let issue = preflightIssue {
                    Text("\(issue.title)：\(issue.message)")
                }
            }
            .onAppear {
                locationProvider.request()
                preflight.refresh()
            }
            .onChange(of: locationProvider.userLocationReady) { _, ready in
                guard ready, waypoints.isEmpty, let coord = locationProvider.userCoordinate else { return }
                withAnimation {
                    position = .region(MKCoordinateRegion(
                        center: coord,
                        latitudinalMeters: 1200,
                        longitudinalMeters: 1200
                    ))
                }
            }
        }
    }

    // MARK: - Map

    private var mapContent: some View {
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()

                if waypoints.count >= 2 {
                    MapPolyline(coordinates: waypoints.map(\.coordinate))
                        .stroke(.blue.opacity(0.8), lineWidth: 5)
                }

                ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    Marker(
                        index == 0 ? "起点" : (index == waypoints.count - 1 ? "终点" : "途经\(index)"),
                        coordinate: waypoint.coordinate
                    )
                    .tint(index == 0 ? .green : (index == waypoints.count - 1 ? .red : .blue))
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottomLeading) {
                // 与主页一致，去掉 MapKit 自动插入的左下角 Legal 链接
                MapLegalHider()
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
            .onTapGesture { screenPoint in
                if let coord = proxy.convert(screenPoint, from: .local) {
                    appendWaypoint(coord)
                }
            }
        }
    }

    // MARK: - Top Bar（搜索 + 从定位开始）

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索地点，加入路线", text: $searchText)
                    .font(.subheadline)
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
                        searchCompleter.update(query: "")
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

            Button {
                useCurrentLocationAsStart()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 40)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var searchResultsCard: some View {
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
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.blue)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                if index < results.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Bottom Panel

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Label("\(waypoints.count) 个航点", systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    undoLastWaypoint()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(waypoints.isEmpty)
                if !routeName.isEmpty {
                    Text(routeName)
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            speedSelector
            jitterSection

            HStack(spacing: 12) {
                Button(action: clearRoute) {
                    Label("清除", systemImage: "trash")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button(action: toggleSimulation) {
                    Label(
                        isSimulating ? "停止模拟" : "开始模拟",
                        systemImage: isSimulating ? "stop.fill" : "play.fill"
                    )
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: isSimulating
                                ? [.red, .red.opacity(0.8)]
                                : (waypoints.count >= 2 ? [.blue, .blue.opacity(0.8)] : [.gray, .gray.opacity(0.8)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .shadow(color: (isSimulating ? Color.red : Color.blue).opacity(0.25), radius: 8, y: 4)
                }
                .disabled(waypoints.count < 2 && !isSimulating)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Speed Selector

    private var speedSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("移动速度", icon: "speedometer")

            HStack(spacing: 8) {
                ForEach(SpeedMode.allCases, id: \.self) { mode in
                    Button {
                        speedMode = mode
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 16))
                            Text(mode.rawValue)
                                .font(.caption)
                        }
                        .foregroundStyle(speedMode == mode ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(speedMode == mode ? Color.blue : Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }

            if speedMode == .custom {
                HStack {
                    Text("自定义速度 (km/h)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("30", text: $customSpeed)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 15, weight: .medium))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Jitter Section

    private var jitterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("随机抖动")
                        .font(.system(size: 15, weight: .medium))
                    Text("在路线附近随机偏移，提高模拟真实性")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $jitterEnabled)
                    .labelsHidden()
            }

            if jitterEnabled {
                HStack {
                    Text("抖动范围 (米)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("5.0", text: $jitterRange)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 15, weight: .medium))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Waypoint List Sheet

    private var waypointListSheet: some View {
        NavigationStack {
            List {
                if waypoints.isEmpty {
                    Text("还没有航点，点击地图或搜索地点添加")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
                ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    HStack {
                        Text("\(index + 1)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(index == 0 ? Color.green : (index == waypoints.count - 1 ? Color.red : Color.blue))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(index == 0 ? "起点" : (index == waypoints.count - 1 ? "终点" : "途经点 \(index)"))
                                .font(.system(size: 15, weight: .medium))
                            Text(String(format: "%.5f, %.5f", waypoint.coordinate.latitude, waypoint.coordinate.longitude))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            waypoints.remove(at: index)
                            updateRoute()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("航点列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showWaypointList = false }
                }
            }
        }
    }

    // MARK: - Helpers

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

    private func appendWaypoint(_ coordinate: CLLocationCoordinate2D) {
        waypoints.append(RouteWaypoint(coordinate: coordinate))
        updateRoute()
    }

    private func undoLastWaypoint() {
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
        updateRoute()
    }

    private func updateRoute() {
        guard waypoints.count >= 2 else {
            routePolyline = nil
            return
        }
        let coords = waypoints.map(\.coordinate)
        routePolyline = MKPolyline(coordinates: coords, count: coords.count)
    }

    private func useCurrentLocationAsStart() {
        guard let coord = locationProvider.userCoordinate else {
            locationProvider.request()
            showHint("尚未获取到定位，请允许定位权限后重试")
            return
        }
        let start = RouteWaypoint(coordinate: coord)
        if waypoints.isEmpty {
            waypoints.append(start)
        } else {
            waypoints[0] = start
        }
        updateRoute()
        withAnimation {
            position = .region(MKCoordinateRegion(
                center: coord,
                latitudinalMeters: 1200,
                longitudinalMeters: 1200
            ))
        }
        showHint("已以当前位置为起点")
    }

    private func showHint(_ text: String) {
        locationHint = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if locationHint == text { locationHint = nil }
        }
    }

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        searchText = ""
        showSearchResults = false
        searchCompleter.update(query: "")

        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            let coord = item.placemark.coordinate
            DispatchQueue.main.async {
                appendWaypoint(coord)
                withAnimation {
                    position = .region(MKCoordinateRegion(
                        center: coord,
                        latitudinalMeters: 1200,
                        longitudinalMeters: 1200
                    ))
                }
                showHint("已加入：\(result.title)")
            }
        }
    }

    private func clearRoute() {
        waypoints.removeAll()
        routePolyline = nil
        if isSimulating {
            session.stop()
            isSimulating = false
        }
    }

    private func toggleSimulation() {
        if isSimulating {
            session.stop()
            isSimulating = false
            return
        }
        guard waypoints.count >= 2 else { return }
        if let issue = preflight.instantGate() {
            preflightIssue = issue
            return
        }

        let speedKPH: Double
        if speedMode == .custom {
            speedKPH = Double(customSpeed) ?? 30.0
        } else {
            speedKPH = speedMode.speedKPH
        }
        // UI 以 km/h 展示，回放内部使用 m/s
        let speedMPS = max(0.3, speedKPH / 3.6)
        let jitter: Double = jitterEnabled ? (Double(jitterRange) ?? 5.0) : 0

        session.startRoutePlayback(
            coordinates: waypoints.map(\.coordinate),
            speedMPS: speedMPS,
            jitterMeters: jitter
        )
        isSimulating = true
    }
}

// MARK: - Route Waypoint Model

struct RouteWaypoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}
