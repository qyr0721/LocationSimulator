//
//  MainDrawerView.swift
//  LocationSimulator
//
//  Three-layer drawer navigation: Point Simulation / Route Simulation / Settings
//  UI style inspired by Fake Location app.
//

import SwiftUI
import NetworkExtension

// MARK: - Menu Items

enum DrawerMenu: String, CaseIterable, Identifiable {
    case pointSim = "点模拟"
    case routeSim = "路线模拟"
    case settings  = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pointSim: return "mappin.and.ellipse"
        case .routeSim: return "map"
        case .settings:  return "gearshape"
        }
    }

    var title: String { rawValue }
}

// MARK: - Main Drawer View

struct MainDrawerView: View {
    @State private var selectedMenu: DrawerMenu = .pointSim
    @State private var isDrawerOpen = false

    // Gesture state for drawer drag
    @State private var dragOffset: CGFloat = 0

    private let drawerWidth: CGFloat = 280

    var body: some View {
        ZStack(alignment: .leading) {
            // MARK: - Content Area
            contentArea
                .disabled(isDrawerOpen)
                .offset(x: isDrawerOpen ? drawerWidth + dragOffset : dragOffset)

            // MARK: - Drawer Overlay (dimmed background)
            if isDrawerOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isDrawerOpen = false
                        }
                    }
            }

            // MARK: - Drawer Panel
            drawerPanel
                .offset(x: isDrawerOpen ? dragOffset : -drawerWidth)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = value.translation.width
                        }
                        .onEnded { value in
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if value.translation.width > 80 {
                                    isDrawerOpen = true
                                } else if value.translation.width < -80 {
                                    isDrawerOpen = false
                                }
                                dragOffset = 0
                            }
                        }
                )
        }
        .environment(\.openDrawer, openDrawer)
        .environment(\.closeDrawer, closeDrawer)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch selectedMenu {
        case .pointSim:
            PointSimulationView(onMenuTap: openDrawer)
        case .routeSim:
            RouteSimulationView(onMenuTap: openDrawer)
        case .settings:
            SettingsDrawerView(onMenuTap: openDrawer)
        }
    }

    // MARK: - Drawer Panel

    private var drawerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("LocationSimulator")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 60)
                    .padding(.horizontal, 24)
                Text("位置模拟工具")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            }
            .padding(.bottom, 32)

            // Menu Items
            ForEach(DrawerMenu.allCases) { menu in
                DrawerMenuItem(
                    menu: menu,
                    isSelected: selectedMenu == menu
                ) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedMenu = menu
                        isDrawerOpen = false
                    }
                }
            }

            Spacer()

            // Footer
            Text("LocationSimulator v1.0")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .frame(width: drawerWidth)
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .ignoresSafeArea()
    }

    // MARK: - Actions

    private func openDrawer() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isDrawerOpen = true
        }
    }

    private func closeDrawer() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isDrawerOpen = false
        }
    }
}

// MARK: - Drawer Menu Item

struct DrawerMenuItem: View {
    let menu: DrawerMenu
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: menu.icon)
                    .font(.system(size: 20))
                    .frame(width: 28)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)

                Text(menu.title)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Environment Keys for Drawer

private struct OpenDrawerKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct CloseDrawerKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openDrawer: () -> Void {
        get { self[OpenDrawerKey.self] }
        set { self[OpenDrawerKey.self] = newValue }
    }
    var closeDrawer: () -> Void {
        get { self[CloseDrawerKey.self] }
        set { self[CloseDrawerKey.self] = newValue }
    }
}

// MARK: - Preview

#Preview {
    MainDrawerView()
}
