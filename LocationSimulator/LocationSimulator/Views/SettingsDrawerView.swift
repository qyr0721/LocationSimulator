//
//  SettingsDrawerView.swift
//  LocationSimulator
//
//  Layer 3: Settings page with pairing management.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsDrawerView: View {
    var onMenuTap: () -> Void = {}

    @AppStorage(UserDefaults.Keys.targetDeviceIP) private var targetDeviceIP = DeviceConnectionContext.defaultTargetIPAddress
    @AppStorage(UserDefaults.Keys.keepAliveLocation) private var keepAliveLocation = true
    @AppStorage(UserDefaults.Keys.keepAliveAudio) private var keepAliveAudio = false

    @State private var showPairingImporter = false
    @State private var pairingImportMessage: String?
    @State private var pairingExists = PairingFileStore.exists
    @State private var showOnDevicePairing = false

    var body: some View {
        NavigationStack {
            List {
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
                    Text("LocalDevVPN 回环模式下默认 127.0.0.1")
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
                OnDevicePairingView(service: OnDevicePairingService.shared)
            }
            .onAppear {
                pairingExists = PairingFileStore.exists
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
            } catch {
                pairingImportMessage = "导入失败: \(error.localizedDescription)"
            }
        case .failure(let error):
            pairingImportMessage = "导入失败: \(error.localizedDescription)"
        }
    }
}
