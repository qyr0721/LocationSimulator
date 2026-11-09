//
//  SettingsView.swift
//  LocationSimulator
//
//  Settings for device connection, pairing file, and background keep-alive.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UserDefaults.Keys.targetDeviceIP) private var targetDeviceIP = DeviceConnectionContext.defaultTargetIPAddress
    @AppStorage(UserDefaults.Keys.keepAliveLocation) private var keepAliveLocation = true
    @AppStorage(UserDefaults.Keys.keepAliveAudio) private var keepAliveAudio = false

    @State private var showPairingImporter = false
    @State private var showPairingCreator = false
    @State private var pairingImportMessage: String?
    @State private var pairingExists = PairingFileStore.exists

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Device Connection
                Section {
                    HStack {
                        Text("Device IP")
                        Spacer()
                        TextField("10.7.0.1", text: $targetDeviceIP)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .autocorrectionDisabled()
                    }

                    if targetDeviceIP != DeviceConnectionContext.defaultTargetIPAddress {
                        Text("Custom IP configured. Make sure the device is reachable at this address.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Default loopback VPN address (LocalDevVPN).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Connection")
                }

                // MARK: - Pairing File
                Section {
                    HStack {
                        Image(systemName: pairingExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(pairingExists ? .green : .red)
                        Text(pairingExists ? "Pairing file ready" : "No pairing file")
                            .foregroundStyle(pairingExists ? .primary : .secondary)
                    }

                    Button {
                        showPairingCreator = true
                    } label: {
                        Label("Create Pairing File (On-Device)", systemImage: "wand.and.stars")
                    }

                    Button("Import Pairing File") {
                        showPairingImporter = true
                    }

                    if pairingExists {
                        Button("Remove Pairing File", role: .destructive) {
                            try? PairingFileStore.remove()
                            pairingExists = PairingFileStore.exists
                            pairingImportMessage = "Pairing file removed."
                        }
                    }

                    if let pairingImportMessage {
                        Text(pairingImportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("Required for location simulation. Create one on-device (no computer needed) or import an existing file.")
                }

                // MARK: - Background Keep-Alive
                Section {
                    Toggle("Keep Alive via Location", isOn: $keepAliveLocation)
                    Toggle("Keep Alive via Silent Audio", isOn: $keepAliveAudio)

                    if !keepAliveLocation && !keepAliveAudio {
                        Text("Warning: The app may be suspended in the background without a keep-alive mechanism.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Background")
                } footer: {
                    Text("Location-based keep-alive requires \"Always\" location permission. Silent audio uses no audible sound but keeps the app running.")
                }

                // MARK: - About
                Section {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Based on", value: "StikDebug")
                    Link("StikDebug on GitHub", destination: URL(string: "https://github.com/StikDebug/StikDebug")!)
                    Link("License (AGPL-3.0)", destination: URL(string: "https://github.com/StikDebug/StikDebug/blob/main/LICENSE")!)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        BackgroundLocationManager.shared.configurationDidChange()
                        BackgroundAudioManager.shared.configurationDidChange()
                        dismiss()
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
            .sheet(isPresented: $showPairingCreator) {
                NavigationStack {
                    OnDevicePairingView(service: OnDevicePairingService.shared)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pairingFileImported)) { _ in
                pairingExists = PairingFileStore.exists
                pairingImportMessage = "Pairing file created and saved."
            }
            .onAppear {
                pairingExists = PairingFileStore.exists
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func importPairingFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try PairingFileStore.importFromPicker(url)
                pairingExists = PairingFileStore.exists
                pairingImportMessage = "Pairing file imported successfully."
            } catch {
                pairingImportMessage = "Import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            pairingImportMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
