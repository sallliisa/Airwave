import Foundation

/// The persisted Airwave 2 profile references presets in its managed library.
/// Resolve those references into self-contained effect state before writing v3 data.
struct LegacyAirwaveUpgrade {
    static let domain = "com.southneuhof.Airwave"
    static let profilesKey = "Airwave.DeviceProfiles.v1"
    static let completedKey = "Airwave.OnboardingV2.Completed"
    static let menuBarKey = "Airwave.Application.ShowInMenuBar"
    static let migrationKey = "Airwave.UpgradeTo3.Completed"
    private static let legacyKeys = [profilesKey, completedKey, menuBarKey]

    struct Source {
        let preferences: [String: Any]
        let library: URL

        var exists: Bool {
            LegacyAirwaveUpgrade.legacyKeys.contains { preferences[$0] != nil }
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

    private struct SpatialPreset: Decodable {
        let id: UUID
        let name: String
        let fileURL: URL
    }

    private struct EqualizerManifest: Decodable {
        let presets: [EqualizerPreset]
    }

    private struct EqualizerPreset: Decodable {
        let id: UUID
        let filename: String
        let displayName: String
    }

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { "Airwave 2 settings could not be imported. \(reason)" }
    }

    static func installedSource(defaults: UserDefaults, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                applicationSupport: URL = .applicationSupportDirectory) throws -> Source {
        let sandboxLibrary = home.appending(path: "Library/Containers/\(domain)/Data/Library", directoryHint: .isDirectory)
        let preferencesURL = sandboxLibrary.appending(path: "Preferences/\(domain).plist")
        let bytes: Data
        do {
            bytes = try Data(contentsOf: preferencesURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let preferences = Dictionary(uniqueKeysWithValues: legacyKeys.compactMap { key in
                defaults.object(forKey: key).map { (key, $0) }
            })
            return Source(preferences: preferences, library: applicationSupport.appending(path: "Airwave"))
        }
        let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        guard let preferences = plist as? [String: Any] else {
            throw Failure(reason: "The previous preferences are unreadable.")
        }
        let source = Source(preferences: preferences, library: sandboxLibrary.appending(path: "Application Support/Airwave"))
        if source.exists { return source }
        let direct = Dictionary(uniqueKeysWithValues: legacyKeys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        return Source(preferences: direct, library: applicationSupport.appending(path: "Airwave"))
    }

    @MainActor
    @discardableResult
    static func migrate(defaults: UserDefaults, store: ProfileStore, source: () throws -> Source) throws -> Bool {
        guard !defaults.bool(forKey: migrationKey) else { return false }
        let old = try source()
        guard old.exists else { return false }

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
                let spatialDirectory = old.library.appending(path: "presets", directoryHint: .isDirectory)
                let eqDirectory = old.library.appending(path: "Equalizer Presets", directoryHint: .isDirectory)
                let decoder = JSONDecoder()
                let spatial = missing.contains { $0.hrirPresetID != nil }
                    ? try decoder.decode([SpatialPreset].self, from: Data(contentsOf: spatialDirectory.appending(path: "presets.json")))
                    : []
                let equalizers = missing.contains { $0.equalizerPresetID != nil }
                    ? try decoder.decode(EqualizerManifest.self, from: Data(contentsOf: eqDirectory.appending(path: "manifest.json"))).presets
                    : []
                for profile in missing {
                    let slots = try chain(for: profile, spatial: spatial, spatialDirectory: spatialDirectory,
                                          equalizers: equalizers, eqDirectory: eqDirectory)
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
        return true
    }

    private static func chain(for profile: Profile, spatial: [SpatialPreset], spatialDirectory: URL,
                              equalizers: [EqualizerPreset], eqDirectory: URL) throws -> [EffectSlot] {
        var slots: [EffectSlot] = []
        if let id = profile.hrirPresetID {
            guard let preset = spatial.first(where: { $0.id == id }) else {
                throw Failure(reason: "A Spatial preset for \(profile.deviceName) is missing.")
            }
            let wav = try presetData(filename: preset.fileURL.lastPathComponent, in: spatialDirectory)
            slots.append(try slot(.airwaveSpatial, name: "Spatial", manufacturer: "Airwave", state: [
                "AirwaveSpatial.presetName": preset.name,
                "AirwaveSpatial.impulseResponse": wav,
                "AirwaveSpatial.bypass": false
            ]))
        }
        if let id = profile.equalizerPresetID {
            guard let preset = equalizers.first(where: { $0.id == id }) else {
                throw Failure(reason: "An Equalizer preset for \(profile.deviceName) is missing.")
            }
            let bytes = try presetData(filename: preset.filename, in: eqDirectory)
            let selection = EqualizerAUState.Preset(name: preset.displayName, filename: preset.filename, data: bytes)
            slots.append(try slot(.airwaveEqualizer, name: "Equalizer", manufacturer: "South Neuhof",
                                  state: EqualizerAUState.document(preset: selection, context: nil)))
        }
        return slots
    }

    private static func slot(_ component: ComponentID, name: String, manufacturer: String,
                             state: [String: Any]) throws -> EffectSlot {
        var slot = EffectSlot(EffectComponent(id: component, name: name, manufacturer: manufacturer))
        slot.state = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        return slot
    }

    private static func presetData(filename: String, in directory: URL) throws -> Data {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            throw Failure(reason: "A managed preset filename is invalid.")
        }
        let file = directory.appending(path: filename, directoryHint: .notDirectory)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 64 * 1_024 * 1_024 else {
            throw Failure(reason: "The managed preset \(filename) cannot be opened.")
        }
        return try Data(contentsOf: file)
    }
}
