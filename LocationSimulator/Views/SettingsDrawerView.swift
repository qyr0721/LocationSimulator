//
//  SettingsDrawerView.swift
//  LocationSimulator
//
//  Layer 3: Settings page with pairing management.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsDrawerView: View {
    var onMenuTap: () -> Void = {}

    @AppStorage(UserDefaults.Keys.targetDeviceIP) private var targetDeviceIP = DeviceConnectionContext.defaultTargetIPAddress
    @AppStorage(UserDefaults.Keys.keepAliveLocation) private var keepAliveLocation = true
    @AppStorage(UserDefaults.Keys.keepAliveAudio) private var keepAliveAudio = false

    @ObservedObject private var preflight = ConnectionPreflight.shared

    @State private var showPairingImporter = false
    @State private var pairingImportMessage: String?
    @State private var pairingExists = PairingFileStore.exists
    @State private var showOnDevicePairing = false
    @State private var showOnboarding = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Connection status
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: preflight.snapshot.blockingIssue?.systemImage ?? "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(preflight.snapshot.isReady ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preflight.snapshot.statusText)
                                .font(.system(size: 15, weight: .medium))
                            Text("Wi-Fi \(preflight.snapshot.usesWiFi ? "已连接" : "未连接") · 回环隧道 \(preflight.snapshot.hasVPNInterface ? "已建立" : "未建立")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if preflight.isProbing { ProgressView().scaleEffect(0.8) }
                    }
                    if let issue = preflight.snapshot.blockingIssue {
                        Text(issue.message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        preflight.refresh()
                    } label: {
                        Label("重新检测连接", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("连接状态")
                } footer: {
                    Text("状态随网络变化实时更新；点击「启动模拟」时会立即校验，无需等待检查完成。")
                }

                // MARK: - Connection
                Section {
                    HStack {
                        Text("目标设备 IP")
                            .font(.system(size: 15))
                        Spacer()
                        TextField("IP 地址", text: $targetDeviceIP)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 140)
                    }
                } header: {
                    Text("连接")
                } footer: {
                    Text("LocalDevVPN 回环模式下默认 10.7.0.1")
                }

                // MARK: - Pairing
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(pairingExists ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: pairingExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(pairingExists ? .green : .red)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pairingExists ? "配对文件已导入" : "未导入配对文件")
                                .font(.system(size: 15, weight: .medium))
                            Text(pairingExists ? "可用于位置模拟" : "请先创建或导入")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)

                    Button {
                        showOnDevicePairing = true
                    } label: {
                        Label("创建配对文件（设备端）", systemImage: "iphone.and.arrow.forward")
                    }

                    Button("导入配对文件") {
                        showPairingImporter = true
                    }

                    if pairingExists {
                        Button("删除配对文件", role: .destructive) {
                            try? PairingFileStore.remove()
                            pairingExists = PairingFileStore.exists
                            pairingImportMessage = "配对文件已删除。"
                            preflight.refreshLocal()
                        }
                    }

                    if let msg = pairingImportMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("配对")
                } footer: {
                    Text("位置模拟需要配对文件。可在设备端创建，或从文件导入。")
                }

                // MARK: - Keep Alive
                Section {
                    Toggle(isOn: $keepAliveLocation) {
                        Label("位置保活", systemImage: "location.fill")
                    }
                    Toggle(isOn: $keepAliveAudio) {
                        Label("音频保活", systemImage: "speaker.fill")
                    }
                } header: {
                    Text("后台保活")
                } footer: {
                    Text("防止 App 在后台被挂起，保持模拟持续运行。")
                }

                // MARK: - About
                Section {
                    HStack {
                        Text("版本")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("基于")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("StikDebug (AGPL-3.0)")
                            .foregroundStyle(.secondary)
                    }
                    Button("重新查看使用引导") {
                        showOnboarding = true
                    }

                    // MARK: - Author
                    Link(destination: URL(string: "https://github.com/qyr0721")!) {
                        HStack(spacing: 12) {
                            Group {
                                if let img = UIImage(contentsOfFile: Bundle.main.path(forResource: "avatar", ofType: "jpg") ?? "") {
                                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                                } else if let img = UIImage(named: "avatar") {
                                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Image(systemName: "person.circle.fill")
                                        .resizable().aspectRatio(contentMode: .fit)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color(.separator), lineWidth: 1))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Hikari")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text("作者 · GitHub")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.right.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.blue)
                        }
                        .padding(.vertical, 4)
                    }

                    Text("地图数据 © Apple；路线限速数据 © OpenStreetMap contributors (ODbL)。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onMenuTap) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
            }
            .fileImporter(
                isPresented: $showPairingImporter,
                allowedContentTypes: PairingFileStore.supportedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                importPairingFile(result)
            }
            .sheet(isPresented: $showOnDevicePairing) {
                NavigationStack {
                    OnDevicePairingView(service: OnDevicePairingService.shared)
                }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView()
            }
            .onAppear {
                pairingExists = PairingFileStore.exists
                preflight.refresh()
            }
        }
    }

    private func importPairingFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try PairingFileStore.importFromPicker(url)
                pairingExists = PairingFileStore.exists
                pairingImportMessage = "配对文件导入成功。"
                NotificationCenter.default.post(name: .pairingFileImported, object: nil)
                preflight.refreshLocal()
            } catch {
                pairingImportMessage = "导入失败: \(error.localizedDescription)"
            }
        case .failure(let error):
            pairingImportMessage = "导入失败: \(error.localizedDescription)"
        }
    }
}
