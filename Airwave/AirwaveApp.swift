import SwiftUI

@main
struct AirwaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MenuBarViewModel.shared
    @StateObject private var menuVisibility = MenuBarVisibilityManager.shared

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
        MenuBarExtra(isInserted: menuBarInsertionBinding) {
            AirwaveMenuView()
                .environmentObject(viewModel)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarInsertionBinding: Binding<Bool> {
        Binding(
            get: { menuVisibility.isVisible },
            set: { value in
                guard value != menuVisibility.isVisible else { return }
                DispatchQueue.main.async { menuVisibility.setVisible(value) }
            }
        )
    }
}
