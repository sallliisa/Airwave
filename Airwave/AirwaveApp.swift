import SwiftUI

@main
struct AirwaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MenuBarViewModel.shared
    @StateObject private var onboardingViewModel = OnboardingViewModel.shared

    init() {
        do {
            try SettingsSchemaV2Migrator(
                defaults: .standard,
                launchAtLogin: LaunchAtLoginManager.shared
            ).migrateIfNeeded()
        } catch {
            Logger.log("[Migration] Could not disable launch at login: \(error)")
        }
        _ = UpdateManager.shared
    }

    var body: some Scene {
        MenuBarExtra {
            AirwaveMenuView()
                .environmentObject(viewModel)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(viewModel)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 420)

        Window("Set Up Airwave", id: "onboarding") {
            OnboardingView(viewModel: onboardingViewModel)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 480)
    }
}
