import AudioToolbox
import Foundation

@MainActor
enum AudioUnitPresetUpgrade {
    static func migrate(from store: PresetMigrationStore, defaults: UserDefaults,
                        instantiate: EffectCatalog.Instantiate) async throws {
        guard !defaults.bool(forKey: "Airwave.UpgradeTo3.AudioUnitPresetsCompleted") else { return }
        var firstError: Error?
        for (component, effectName) in [(ComponentID.airwaveSpatial, "Spatial"), (.airwaveEqualizer, "Equalizer")] {
            let completionKey = "Airwave.UpgradeTo3.AudioUnitPresets.\(effectName)"
            guard !defaults.bool(forKey: completionKey) else { continue }
            do {
                let entries = try store.load(for: component)
                let importedKey = completionKey + ".ImportedIDs"
                var imported = Set(defaults.stringArray(forKey: importedKey) ?? [])
                let pending = entries.filter { !imported.contains($0.id.uuidString) }
                if !pending.isEmpty {
                    let unit = try await instantiate(component)
                    guard unit.supportsUserPresets else { throw Failure.unavailable(effectName) }
                    var entryError: Error?
                    for entry in pending {
                        try Task.checkCancellation()
                        do {
                            try importPreset(entry, into: unit)
                            imported.insert(entry.id.uuidString)
                            defaults.set(imported.sorted(), forKey: importedKey)
                        } catch {
                            if entryError == nil { entryError = error }
                        }
                    }
                    if let entryError { throw entryError }
                }
                defaults.set(true, forKey: completionKey)
            } catch {
                try Task.checkCancellation()
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        defaults.set(true, forKey: "Airwave.UpgradeTo3.AudioUnitPresetsCompleted")
    }

    private static func importPreset(_ entry: PresetMigrationStore.Entry, into unit: AUAudioUnit) throws {
        guard let state = try PropertyListSerialization.propertyList(from: entry.state, format: nil) as? [String: Any] else {
            throw Failure.invalidState(entry.name)
        }
        let existing = unit.userPresets
        let baseName = entry.name
        var name = baseName
        var suffix = 2
        while let conflict = existing.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            if let saved = try? unit.presetState(for: conflict),
               PresetDocument.matches(state, saved, for: entry.component) { return }
            name = "\(baseName) (\(suffix))"
            suffix += 1
        }
        unit.fullStateForDocument = state
        guard let restored = unit.fullStateForDocument,
              PresetDocument.matches(state, restored, for: entry.component) else { throw Failure.invalidState(entry.name) }
        let preset = AUAudioUnitPreset()
        preset.name = name
        preset.number = -1
        try unit.saveUserPreset(preset)
        guard PresetDocument.matches(state, try unit.presetState(for: preset), for: entry.component) else {
            throw Failure.invalidState(entry.name)
        }
    }

    private enum Failure: LocalizedError {
        case unavailable(String)
        case invalidState(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let name): "The \(name) Audio Unit isn't ready to import saved presets."
            case .invalidState(let name): "The preset “\(name)” could not be restored."
            }
        }
    }
}

enum PresetDocument {
    private static let bundledSpatial = "AirwaveSpatial.bundledPreset"
    private static let spatialName = "AirwaveSpatial.presetName"
    private static let impulseResponse = "AirwaveSpatial.impulseResponse"

    static func emptyState(for component: ComponentID) -> [String: Any] {
        if component == .airwaveSpatial { return ["AirwaveSpatial.noPreset": true] }
        return EqualizerAUState.document(preset: nil, context: nil)
    }

    static func hasSelection(_ state: [String: Any], for component: ComponentID) -> Bool {
        switch component {
        case .airwaveSpatial:
            return state[bundledSpatial] is String || (state[spatialName] is String && state[impulseResponse] is Data)
        case .airwaveEqualizer:
            return (try? EqualizerAUState(state).preset) != nil
        default:
            return false
        }
    }

    static func matches(_ expected: [String: Any], _ actual: [String: Any], for component: ComponentID) -> Bool {
        switch component {
        case .airwaveSpatial:
            return hasSelection(expected, for: component)
                && expected[bundledSpatial] as? String == actual[bundledSpatial] as? String
                && expected[impulseResponse] as? Data == actual[impulseResponse] as? Data
        case .airwaveEqualizer:
            guard let old = try? EqualizerAUState(expected).preset, let new = try? EqualizerAUState(actual).preset else { return false }
            return old.filename == new.filename && old.data == new.data
        default:
            return false
        }
    }
}
