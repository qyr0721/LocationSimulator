//
//  LocationSimulatorApp.swift
//  LocationSimulator
//
//  Standalone GPS location simulation app for iOS 17.4+.
//  Extracted from StikDebug (https://github.com/StikDebug/StikDebug)
//  Licensed under AGPL-3.0
//

import SwiftUI

@main
struct LocationSimulatorApp: App {
    @AppStorage(UserDefaults.Keys.hasCompletedOnboarding) private var onboardingDone = false

    var body: some Scene {
        WindowGroup {
            MainDrawerView()
                .fullScreenCover(isPresented: Binding(
                    get: { !onboardingDone },
                    set: { presented in
                        // 引导关闭（完成或跳过）后不再自动弹出
                        if !presented { onboardingDone = true }
                    }
                )) {
                    OnboardingView()
                        .interactiveDismissDisabled()
                }
        }
    }
}
