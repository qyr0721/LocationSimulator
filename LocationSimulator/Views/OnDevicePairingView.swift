//
//  OnDevicePairingView.swift
//  LocationSimulator
//
//  UI for creating pairing files on-device (no computer required).
//  Adapted from StikDebug's OnDevicePairingView.swift.
//  Removed: Apple TV pairing, pairing file placement to other apps.
//

import SwiftUI

struct OnDevicePairingView: View {
    @ObservedObject var service: OnDevicePairingService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            content
        }
        .navigationTitle("Create Pairing File")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: service.phase)
        .onDisappear {
            service.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.phase {
        case .idle:
            Section {
                Button {
                    service.start()
                } label: {
                    Label("Pair This iPhone / iPad", systemImage: "iphone")
                }
            } footer: {
                Text("Create a pairing file without a computer. Your device must run iOS/iPadOS 27 or later. The app will advertise itself and guide you through Settings to complete pairing.")
            }

        case .discovering:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for a device to connect…")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                guideStep(1, "Open Settings on the device being paired.")
                guideStep(2, "Go to Privacy & Security › Developer Mode.")
                guideStep(3, "Tap Pair with \(service.hostname).")
                guideStep(4, "Enter the code shown below or in the notification.")
            } header: {
                Text("On the iPhone or iPad")
            } footer: {
                Text("For this device, the app stays active while you open Settings. For another device, keep this screen open to see its code.")
            }
            cancelSection

        case .waiting:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Confirming the pairing…")
                }
            }
            cancelSection

        case .pin(let pin):
            Section {
                VStack(spacing: 14) {
                    Text(service.mode == .localDevice
                         ? "Enter this code in Settings on this device"
                         : "Enter this code on the other device")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(pin)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .tracking(6)
                        .textSelection(.enabled)
                    ProgressView()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            cancelSection

        case .success(let name, let model, let isLocal):
            Section {
                Label("Pairing Complete", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if !name.isEmpty || !model.isEmpty {
                    Text([name, model].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                if isLocal {
                    Label("Pairing file saved — ready for location simulation", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            Section {
                Button("Done") {
                    dismiss()
                }
            }

        case .failed(let message):
            Section {
                Label("Pairing Failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section {
                Button("Try Again") {
                    service.reset()
                }
            }
        }
    }

    private var cancelSection: some View {
        Section {
            Button("Cancel", role: .cancel) {
                service.cancel()
            }
        }
    }

    private func guideStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.tint, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
