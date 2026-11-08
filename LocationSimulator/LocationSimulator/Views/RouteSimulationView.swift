//
//  RouteSimulationView.swift
//  LocationSimulator
//
//  Layer 2: Route/trajectory simulation.
//  Create routes on map, simulate with customizable jitter.
//

import SwiftUI
import MapKit
import CoreLocation

struct RouteSimulationView: View {
    var onMenuTap: () -> Void = {}

    @StateObject private var session = LocationSimulationSession.shared

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

    // MARK: - Speed / Jitter State
    @State private var speedMode: SpeedMode = .walking
    @State private var customSpeed: String = "30"
    @State private var jitterEnabled: Bool = true
    @State private var jitterRange: String = "5.0"
    @State private var showWaypointList: Bool = false

    enum SpeedMode: String, CaseIterable {
        case walking = "步行"
        case cycling = "骑行"
        case driving = "驾车"
        case custom  = "自定义"

        var speed: Double {
            switch self {
            case .walking: return 5.0
            case .cycling: return 15.0
            case .driving: return 40.0
            case .custom: return 30.0
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
                // Map
                mapContent

                // Bottom Panel
                bottomPanel
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
                            clearRoute()
                        } label: {
                            Label("清除路线", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showWaypointList) {
                waypointListSheet
            }
        }
    }

    // MARK: - Map

    private var mapContent: some View {
        MapReader { proxy in
            Map(position: $position) {
                // Route polyline
                if waypoints.count >= 2 {
                    MapPolyline(coordinates: waypoints.map(\.coordinate))
                        .stroke(.blue.opacity(0.7), lineWidth: 4)
                }

                // Waypoint markers
                ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    Marker(
                        index == 0 ? "起点" : (index == waypoints.count - 1 ? "终点" : "途经\(index)"),
                        coordinate: waypoint.coordinate
                    )
                    .tint(index == 0 ? .green : (index == waypoints.count - 1 ? .red : .blue))
                }
            }
            .onTapGesture { screenPoint in
                if let coord = proxy.convert(screenPoint, from: .local) {
                    let waypoint = RouteWaypoint(coordinate: coord)
                    waypoints.append(waypoint)
                    updateRoute()
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Bottom Panel

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            // Waypoint count
            HStack {
                Label("\(waypoints.count) 个航点", systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !routeName.isEmpty {
                    Text(routeName)
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            // Speed selector
            speedSelector

            // Jitter settings
            jitterSection

            // Control buttons
            HStack(spacing: 12) {
                Button(action: clearRoute) {
                    Label("清除", systemImage: "trash")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button(action: toggleSimulation) {
                    Label(
                        isSimulating ? "停止模拟" : "开始模拟",
                        systemImage: isSimulating ? "stop.fill" : "play.fill"
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(waypoints.count >= 2 ? Color.blue : Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(waypoints.count < 2)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Speed Selector

    private var speedSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("移动速度")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

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

    // MARK: - Actions

    private func updateRoute() {
        guard waypoints.count >= 2 else {
            routePolyline = nil
            return
        }
        let coords = waypoints.map(\.coordinate)
        routePolyline = MKPolyline(coordinates: coords, count: coords.count)
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
        guard waypoints.count >= 2 else { return }

        if isSimulating {
            session.stop()
            isSimulating = false
        } else {
            let coords = waypoints.map(\.coordinate)
            let speed: Double
            if speedMode == .custom {
                speed = Double(customSpeed) ?? 30.0
            } else {
                speed = speedMode.speed
            }
            let jitter: Double = jitterEnabled ? (Double(jitterRange) ?? 5.0) : 0

            // Start full route playback with speed and jitter
            session.startRoutePlayback(
                coordinates: coords,
                speedMPS: speed,
                jitterMeters: jitter
            )
            isSimulating = true
        }
    }
}

// MARK: - Route Waypoint Model

struct RouteWaypoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}
