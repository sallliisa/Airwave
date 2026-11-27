import Foundation

/// The persisted Airwave 2 profile references presets in its managed library.
/// Resolve those references into self-contained effect state before writing v3 data.
struct LegacyAirwaveUpgrade {
    static let domain = "com.southneuhof.Airwave"
    static let profilesKey = "Airwave.DeviceProfiles.v1"
    static let completedKey = "Airwave.OnboardingV2.Completed"
    static let menuBarKey = "Airwave.Application.ShowInMenuBar"
    static let migrationKey = "Airwave.UpgradeTo3.Completed"
    private static let libraryMigrationKey = "Airwave.UpgradeTo3.PresetLibraryCompleted"
    private static let legacyKeys = [profilesKey, completedKey, menuBarKey]

    static func hasStagedPresets(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: libraryMigrationKey)
    }

    struct Source {
        let preferences: [String: Any]
        let library: URL

        var exists: Bool {
            LegacyAirwaveUpgrade.legacyKeys.contains { preferences[$0] != nil }
                || ["presets/presets.json", "Equalizer Presets/manifest.json"].contains { filename in
                    FileManager.default.fileExists(atPath: library.appending(path: filename).path)
                }
        }
    }

    private struct Profiles: Decodable {
        let schemaVersion: Int
        let profiles: [Profile]
    }

    private struct Profile: Decodable {
        let deviceUID: String
        let deviceName: String
        let hrirPresetID: UUID?
        let equalizerPresetID: UUID?
        let outputChannels: StereoOutputChannels?
    }

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { "Airwave 2 settings could not be imported. \(reason)" }
    }

    static func installedSource(defaults: UserDefaults, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                applicationSupport: URL = .applicationSupportDirectory) throws -> Source {
        let sandboxLibrary = home.appending(path: "Library/Containers/\(domain)/Data/Library", directoryHint: .isDirectory)
        let managedLibrary = sandboxLibrary.appending(path: "Application Support/Airwave", directoryHint: .isDirectory)
        let preferencesURL = sandboxLibrary.appending(path: "Preferences/\(domain).plist")
        let directPreferences = Dictionary(uniqueKeysWithValues: legacyKeys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        let direct = Source(preferences: directPreferences, library: applicationSupport.appending(path: "Airwave"))
        let bytes: Data
        do {
            bytes = try Data(contentsOf: preferencesURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if !directPreferences.isEmpty { return direct }
            let sandbox = Source(preferences: [:], library: managedLibrary)
            return sandbox.exists ? sandbox : direct
        }
        let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        guard let preferences = plist as? [String: Any] else {
            throw Failure(reason: "The previous preferences are unreadable.")
        }
        let source = Source(preferences: preferences, library: managedLibrary)
        return source.exists ? source : direct
    }

    @MainActor
    @discardableResult
    static func migrate(defaults: UserDefaults, store: ProfileStore, presetLibrary: PresetMigrationStore,
                        source: () throws -> Source) throws -> Bool {
        let needsProfiles = !defaults.bool(forKey: migrationKey)
        let needsLibrary = !defaults.bool(forKey: libraryMigrationKey)
        guard needsProfiles || needsLibrary else { return false }
        let old = try source()
        guard old.exists else { return false }
        let entries = PresetMigrationStore.legacyEntries(at: old.library)
        let libraryResult = Result {
            if needsLibrary {
                try presetLibrary.mergeLegacy(entries)
                defaults.set(true, forKey: libraryMigrationKey)
            }
        }
        if needsProfiles { try migrateProfiles(from: old, entries: entries, defaults: defaults, store: store) }
        try libraryResult.get()
        return true
    }

    @MainActor
    private static func migrateProfiles(from old: Source, entries: [PresetMigrationStore.Entry],
                                        defaults: UserDefaults, store: ProfileStore) throws {
        if let data = old.preferences[profilesKey] {
            guard let encoded = data as? Data else {
                throw Failure(reason: "The previous device profiles have an unsupported format.")
            }
            let legacy = try JSONDecoder().decode(Profiles.self, from: encoded)
            guard legacy.schemaVersion == 1 else {
                throw Failure(reason: "The previous device profiles have an unsupported version.")
            }
            var profiles = try store.load()
            let missing = legacy.profiles.filter { profiles[$0.deviceUID] == nil }
            if !missing.isEmpty {
                for profile in missing {
                    let slots = chain(for: profile, entries: entries)
                    profiles[profile.deviceUID] = DeviceProfile(name: profile.deviceName, sampleRate: nil,
                                                                slots: slots, outputChannels: profile.outputChannels)
                }
                try store.save(profiles)
            }
        }

        ShellModel.applyUpgradePreferences(
            to: defaults, completed: old.preferences[completedKey] as? Bool,
            showsMenuBar: old.preferences[menuBarKey] as? Bool
        )
        defaults.set(true, forKey: migrationKey)
    }

    private static func chain(for profile: Profile, entries: [PresetMigrationStore.Entry]) -> [EffectSlot] {
        var slots: [EffectSlot] = []
        if let id = profile.hrirPresetID {
            slots.append(slot(.airwaveSpatial, name: "Spatial", manufacturer: "Airwave", presetID: id, entries: entries))
        }
        if let id = profile.equalizerPresetID {
            slots.append(slot(.airwaveEqualizer, name: "Equalizer", manufacturer: "Airwave", presetID: id, entries: entries))
        }
        return slots
    }

    private static func slot(_ component: ComponentID, name: String, manufacturer: String,
                             presetID: UUID, entries: [PresetMigrationStore.Entry]) -> EffectSlot {
        var slot = EffectSlot(EffectComponent(id: component, name: name, manufacturer: manufacturer))
        if let preset = entries.first(where: { $0.component == component && $0.id == presetID }) {
            slot.state = preset.state
        } else {
            slot.isBypassed = true
            slot.migrationIssue = "The Airwave 2 preset is unavailable. Choose a preset to restore this effect."
        }
        return slot
    }
}
