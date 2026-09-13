import Foundation

protocol LaunchAtLoginResetting: AnyObject {
    func enableForFirstRun() throws
}

struct SettingsSchemaV2Migrator {
    static let markerKey = "Airwave.SchemaV2.ResetCompleted"
    static let legacyKeys = [
        "Airwave.AppSettings",
        "Airwave.Onboarding.Version",
        "Airwave.Onboarding.Checkpoint",
        "Airwave.Onboarding.Completed",
        "Airwave.Onboarding.DismissedLaunch",
        "Airwave.Onboarding.CurrentLaunch",
        "SavedSystemOutputDeviceUID"
    ]

    let defaults: UserDefaults
    let launchAtLogin: LaunchAtLoginResetting

    @discardableResult
    func migrateIfNeeded() throws -> Bool {
        guard !defaults.bool(forKey: Self.markerKey) else { return false }
        try launchAtLogin.enableForFirstRun()
        Self.legacyKeys.forEach(defaults.removeObject(forKey:))
        defaults.set(true, forKey: Self.markerKey)
        return true
    }
}
