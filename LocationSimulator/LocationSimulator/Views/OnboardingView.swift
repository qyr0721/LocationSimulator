//
//  OnboardingView.swift
//  LocationSimulator
//
//  首次使用引导。默认用户第一次打开时没有配对文件，因此按
//  「连接 LocalDevVPN → 配对设备（或导入文件）→ 完成」的顺序引导。
//  分步引导的样式参考 StikDebug 的 OnDevicePairingView（编号步骤 + 状态卡片）。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var preflight = ConnectionPreflight.shared

    @State private var step: Step = .welcome
    @State private var pairingExists = PairingFileStore.exists
    @State private var showOnDevicePairing = false
    @State private var showFileImporter = false
    @State private var importMessage: String?

    // VPN 跳转统一使用 LocalDevVPNLink

    enum Step: Int, CaseIterable, Identifiable {
        case welcome = 0
        case vpn = 1
        case pairing = 2
        case done = 3

        var id: Int { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressIndicator
                    .padding(.top, 20)

                ScrollView {
                    VStack(spacing: 20) {
                        Group {
                            switch step {
                            case .welcome: welcomeStep
                            case .vpn: vpnStep
                            case .pairing: pairingStep
                            case .done: doneStep
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                    }
                    .padding(.bottom, 24)
                }

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("跳过") { finish() }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: step)
        }
        .sheet(isPresented: $showOnDevicePairing) {
            NavigationStack {
                OnDevicePairingView(service: OnDevicePairingService.shared)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            importPairingFile(result)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pairingFileImported)) { _ in
            pairingExists = PairingFileStore.exists
        }
        .onAppear {
            pairingExists = PairingFileStore.exists
            preflight.refresh()
        }
    }

    // MARK: - 进度指示

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Color.blue : Color(.systemFill))
                    .frame(width: item == step ? 24 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }

    // MARK: - Step 1: 欢迎

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 68))
                    .foregroundStyle(.blue)
                    .symbolRenderingMode(.hierarchical)
                Text("欢迎使用 LocationSimulator")
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("在地图上选一个位置，就能让这台设备「身处」那里。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 14) {
                featureRow(icon: "mappin.and.ellipse", title: "单点模拟", detail: "地图选点、搜索地点，一键生效")
                featureRow(icon: "map", title: "路线模拟", detail: "按设定速度沿路线回放")
                featureRow(icon: "clock.arrow.circlepath", title: "历史与收藏", detail: "保存常用位置，随时切换")
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))

            Text("首次使用只需两步：连接 LocalDevVPN，然后完成配对。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Step 2: LocalDevVPN

    private var vpnStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                icon: "network.badge.shield.half.filled",
                title: "连接 LocalDevVPN",
                subtitle: "位置模拟需要通过 LocalDevVPN 建立回环隧道，把模拟坐标发送给本机。"
            )

            VStack(alignment: .leading, spacing: 12) {
                guideStep(1, "安装 LocalDevVPN（若已安装可跳过）")
                guideStep(2, "打开 App 并启用回环 VPN，保持连接")
                guideStep(3, "回到 LocationSimulator 继续下一步")
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))

            statusCard(
                ready: preflight.snapshot.hasVPNInterface,
                readyText: "已检测到回环隧道",
                waitingText: "尚未检测到 LocalDevVPN 回环隧道"
            ) {
                Button {
                    preflight.refresh()
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            VStack(spacing: 10) {
                primaryButton(title: "打开 LocalDevVPN", icon: "arrow.up.right.square") {
                    openLocalDevVPN()
                }
                Button {
                    openAppStore()
                } label: {
                    Text("我还没有，去 App Store 下载")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Step 3: 配对

    private var pairingStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                icon: "iphone.and.arrow.forward",
                title: "配对设备",
                subtitle: "位置模拟还需要一个配对文件。推荐直接在本机创建，无需电脑；已有文件也可以直接导入。"
            )

            statusCard(
                ready: pairingExists,
                readyText: "配对文件已就绪",
                waitingText: "尚未找到配对文件"
            ) {
                EmptyView()
            }

            VStack(spacing: 10) {
                primaryButton(title: "配对此设备（推荐）", icon: "iphone") {
                    showOnDevicePairing = true
                }
                Button {
                    showFileImporter = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.badge.plus")
                        Text("从文件导入（.plist / .mobiledevicepairing）")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }

            if let importMessage {
                Text(importMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("设备端配对会在「设置 → 隐私与安全性 → 开发者模式」中完成，按屏幕提示输入配对码即可。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Step 4: 完成

    private var doneStep: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
            Text("一切就绪")
                .font(.system(size: 28, weight: .bold))
            Text("现在可以在地图上选点，点击「启动模拟」开始使用。\n之后可在侧边栏的「设置」中随时管理 VPN 与配对文件。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    // MARK: - 底部导航

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button {
                    withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                } label: {
                    Text("上一步")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }

            Button {
                if step == .done {
                    finish()
                } else {
                    withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .done }
                }
            } label: {
                Text(step == .done ? "开始使用" : (step == .pairing ? "完成设置" : "下一步"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(colors: [.blue, .blue.opacity(0.8)], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 组件

    private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 46))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.system(size: 24, weight: .bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.blue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func guideStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.blue, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func statusCard<Accessory: View>(
        ready: Bool,
        readyText: String,
        waitingText: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(ready ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(ready ? readyText : waitingText)
                    .font(.subheadline.weight(.medium))
                if !ready {
                    Text("不影响继续设置，可稍后再连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            accessory()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func primaryButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                LinearGradient(colors: [.blue, .blue.opacity(0.8)], startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private func openLocalDevVPN() {
        LocalDevVPNLink.open()
    }

    private func openAppStore() {
        LocalDevVPNLink.openAppStore()
    }

    private func importPairingFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try PairingFileStore.importFromPicker(url)
                pairingExists = PairingFileStore.exists
                importMessage = "配对文件导入成功。"
                NotificationCenter.default.post(name: .pairingFileImported, object: nil)
            } catch {
                importMessage = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            importMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: UserDefaults.Keys.hasCompletedOnboarding)
        dismiss()
    }
}
