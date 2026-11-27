import AudioToolbox
import XCTest
@testable import Airwave3

final class AudioUnitPresetUpgradeTests: XCTestCase {
    @MainActor
    func testRetryResumesWithoutOverwritingOrDuplicatingNativePresets() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "AudioUnitPresetUpgradeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = PresetMigrationStore(url: folder.appending(path: "staged.plist"))
        let unit = try PresetUnit(componentDescription: ComponentID.airwaveEqualizer.description)
        unit.records["Desk"] = document(name: "Desk", preamp: -2)
        unit.rejectedName = "Later"
        try store.mergeLegacy([try entry("Desk", -4), try entry("Later", -6), try entry("Speakers", -9)])

        do {
            try await AudioUnitPresetUpgrade.migrate(from: store, defaults: defaults) { _ in unit }
            XCTFail("Expected the Later preset's save to fail.")
        } catch {
            XCTAssertEqual(Set(unit.records.keys), ["Desk", "Desk (2)", "Speakers"])
        }
        unit.rejectedName = nil
        unit.records["Speakers"] = nil
        try await AudioUnitPresetUpgrade.migrate(from: store, defaults: defaults) { _ in unit }
        XCTAssertEqual(Set(unit.records.keys), ["Desk", "Desk (2)", "Later"])
        XCTAssertEqual(unit.savedNames, ["Desk (2)", "Speakers", "Later"])
        let original = try EqualizerAUState(unit.records["Desk"]).preset
        XCTAssertEqual(original?.data, Data("Preamp: -2 dB".utf8))

        unit.records["Later"] = nil
        try await AudioUnitPresetUpgrade.migrate(from: store, defaults: defaults) { _ in unit }
        XCTAssertNil(unit.records["Later"])
    }

    private func entry(_ name: String, _ preamp: Int) throws -> PresetMigrationStore.Entry {
        let state = try PropertyListSerialization.data(fromPropertyList: document(name: name, preamp: preamp),
                                                       format: .binary, options: 0)
        return PresetMigrationStore.Entry(id: UUID(), component: .airwaveEqualizer, name: name, state: state)
    }

    private func document(name: String, preamp: Int) -> [String: Any] {
        let preset = EqualizerAUState.Preset(name: name, filename: "\(name).txt", data: Data("Preamp: \(preamp) dB".utf8))
        return EqualizerAUState.document(preset: preset, context: nil)
    }
}

private final class PresetUnit: AUAudioUnit {
    var records: [String: [String: Any]] = [:]
    var savedNames: [String] = []
    var rejectedName: String?
    private var document: [String: Any]?

    override var supportsUserPresets: Bool { true }
    override var fullStateForDocument: [String: Any]? {
        get { document }
        set { document = newValue }
    }
    override var userPresets: [AUAudioUnitPreset] {
        records.keys.map { name in
            let preset = AUAudioUnitPreset()
            preset.name = name
            preset.number = -1
            return preset
        }
    }

    override func saveUserPreset(_ preset: AUAudioUnitPreset) throws {
        guard preset.name != rejectedName else { throw CocoaError(.fileWriteNoPermission) }
        savedNames.append(preset.name)
        records[preset.name] = fullStateForDocument
    }

    override func presetState(for preset: AUAudioUnitPreset) throws -> [String: Any] {
        guard let state = records[preset.name] else { throw CocoaError(.fileNoSuchFile) }
        return state
    }
}
