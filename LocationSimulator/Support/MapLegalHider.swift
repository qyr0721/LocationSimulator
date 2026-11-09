//
//  MapLegalHider.swift
//  LocationSimulator
//
//  SwiftUI 的 Map 会在左下角自动插入 Legal / attribution 链接，
//  MapKit 没有提供公开开关。这个透明 UIViewRepresentable 挂到 Map 上后，
//  会在视图层级里找到 attribution 视图并隐藏它。
//
//  注意：Apple 地图数据的署名仍以文字形式保留在「设置 → 关于」。
//

import SwiftUI
import UIKit

struct MapLegalHider: UIViewRepresentable {
    func makeUIView(context: Context) -> LegalHiderView {
        let view = LegalHiderView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.startScanning()
        return view
    }

    func updateUIView(_ uiView: LegalHiderView, context: Context) {
        uiView.startScanning()
    }

    static func dismantleUIView(_ uiView: LegalHiderView, coordinator: ()) {
        uiView.stopScanning()
    }
}

final class LegalHiderView: UIView {
    private var timer: Timer?
    private var attempts = 0
    private var lastScanDate: Date = .distantPast
    private static let maxTimerFires = 16

    func startScanning() {
        // Map 会在布局完成后才创建 attribution 视图，所以前几秒持续扫描
        guard timer == nil else { return }
        attempts = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.attempts += 1
            self.scan(force: true)
            if self.attempts >= Self.maxTimerFires { self.stopScanning() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.async { [weak self] in self?.scan(force: true) }
    }

    func stopScanning() {
        timer?.invalidate()
        timer = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 地图重建 / 页面切换后 attribution 可能重新出现
        scan(force: false)
    }

    private func scan(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastScanDate) > 0.45 else { return }
        lastScanDate = now
        if let root = window ?? superview?.window {
            hideAttribution(in: root)
        }
    }

    private func hideAttribution(in view: UIView) {
        let className = NSStringFromClass(type(of: view))
        if className.localizedCaseInsensitiveContains("attribution") ||
            className.localizedCaseInsensitiveContains("legal") {
            hide(view)
        } else if let label = view as? UILabel,
                  let text = label.text,
                  text.localizedCaseInsensitiveContains("legal") {
            hide(view)
        } else if let button = view as? UIButton,
                  let text = button.titleLabel?.text,
                  text.localizedCaseInsensitiveContains("legal") {
            hide(view)
        }
        for subview in view.subviews {
            hideAttribution(in: subview)
        }
    }

    private func hide(_ view: UIView) {
        view.isHidden = true
        view.alpha = 0
    }
}
