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
        .navigationTitle("创建配对文件")
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
                    Label("配对此 iPhone / iPad", systemImage: "iphone")
                }
            } footer: {
                Text("无需电脑即可创建配对文件。设备需运行 iOS/iPadOS 27 或更高版本。App 将广播自身并引导您在设置中完成配对。")
            }

        case .discovering:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("等待设备连接…")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                guideStep(1, "在需要配对的设备上打开「设置」")
                guideStep(2, "进入「隐私与安全性 → 开发者模式」")
                guideStep(3, "点击「与 \(service.hostname) 配对」")
                guideStep(4, "输入下方或通知中显示的配对码")
            } header: {
                Text("在 iPhone 或 iPad 上操作")
            } footer: {
                Text("配对本机时，App 会保持活跃直到您完成设置。配对其他设备时，请保持此页面打开以查看配对码。")
            }
            cancelSection

        case .waiting:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在确认配对…")
                }
            }
            cancelSection

        case .pin(let pin):
            Section {
                VStack(spacing: 14) {
                    Text(service.mode == .localDevice
                         ? "请在本机设置中输入此配对码"
                         : "请在另一台设备上输入此配对码")
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
                Label("配对完成", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if !name.isEmpty || !model.isEmpty {
                    Text([name, model].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                if isLocal {
                    Label("配对文件已保存 — 可以开始位置模拟了", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            Section {
                Button("完成") {
                    dismiss()
                }
            }

        case .failed(let message):
            Section {
                Label("配对失败", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section {
                Button("重试") {
                    service.reset()
                }
            }
        }
    }

    private var cancelSection: some View {
        Section {
            Button("取消", role: .cancel) {
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
