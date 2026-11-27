import AVFoundation
import Foundation
import ServiceManagement
import XCTest
@testable import Airwave3

final class LegacyAirwaveUpgradeTests: XCTestCase {
    @MainActor
    func testMigratesTheOldContainerIntoEditableChainsOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let source = try LegacyAirwaveUpgrade.installedSource(
            defaults: fixture.defaults, home: fixture.home, applicationSupport: fixture.home
        )

        XCTAssertTrue(try fixture.migrate { source })
        let saved = try fixture.store.load()
        let speakers = try XCTUnwrap(saved["speakers"])
        XCTAssertEqual(speakers.outputChannels, StereoOutputChannels(left: 4, right: 3))
        XCTAssertEqual(speakers.slots.map(\.component), [.airwaveSpatial, .airwaveEqualizer])
        XCTAssertEqual(speakers.slots.map(\.manufacturer), ["Airwave", "Airwave"])
        let spatial = try document(speakers.slots[0])
        XCTAssertEqual(spatial["AirwaveSpatial.presetName"] as? String, "Personal HRIR")
        XCTAssertEqual(spatial["AirwaveSpatial.impulseResponse"] as? Data, try Data(contentsOf: fixture.wavURL))
        let eq = try EqualizerAUState(document(speakers.slots[1]))
        XCTAssertEqual(eq.preset?.name, "Desk")
        XCTAssertEqual(eq.preset?.data, fixture.eq)
        XCTAssertEqual(Set(try fixture.presetLibrary.load(for: .airwaveEqualizer).map(\.name)), ["Desk", "Headphones"])
        XCTAssertEqual(saved["offline"]?.slots.count, 0)
        XCTAssertEqual(saved["offline"]?.outputChannels, StereoOutputChannels(left: 1, right: 2))
        let login = UpgradeLoginItem()
        let shell = ShellModel(defaults: fixture.defaults, loginItem: login)
        shell.applyInitialLoginPreference()
        XCTAssertTrue(shell.setupCompleted)
        XCTAssertTrue(shell.showsMenuBar)
        XCTAssertFalse(login.registered)

        var edited = saved
        edited["speakers"]?.slots.removeFirst()
        try fixture.store.save(edited)
        XCTAssertFalse(try fixture.migrate {
            XCTFail("Migration reopened the old preferences after completion.")
            return source
        })
        XCTAssertEqual(try fixture.store.load(), edited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.preferencesURL.path))
    }

    @MainActor
    func testMissingPresetKeepsOtherEffectsBypassedUntilReplaced() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let existing = ["existing": DeviceProfile(name: "Existing", slots: [])]
        try fixture.store.save(existing)
        try FileManager.default.removeItem(at: fixture.eqURL)
        let source = try LegacyAirwaveUpgrade.installedSource(
            defaults: fixture.defaults, home: fixture.home, applicationSupport: fixture.home
        )

        XCTAssertTrue(try fixture.migrate { source })
        XCTAssertTrue(fixture.defaults.bool(forKey: LegacyAirwaveUpgrade.migrationKey))
        let migrated = try fixture.store.load()
        XCTAssertEqual(migrated["existing"], existing["existing"])
        let speakers = try XCTUnwrap(migrated["speakers"])
        XCTAssertEqual(speakers.slots.map(\.component), [.airwaveSpatial, .airwaveEqualizer])
        XCTAssertNotNil(speakers.slots[0].state)
        let missing = speakers.slots[1]
        XCTAssertNil(missing.state)
        XCTAssertTrue(missing.isBypassed)
        XCTAssertNotNil(missing.migrationIssue)
        XCTAssertNotNil(migrated["offline"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.preferencesURL.path))

        let host = HostController(store: fixture.store, defaults: fixture.defaults, presetLibrary: fixture.presetLibrary,
                                  currentOutput: { throw CocoaError(.fileNoSuchFile) }, availableOutputs: { [] })
        defer { host.shutdown() }
        host.selectEditingDevice("speakers")
        host.setEditingBypass(missing.id, false)
        XCTAssertEqual(host.editingSlotIssues[missing.id], missing.migrationIssue)
        XCTAssertTrue(host.editingSlots[1].isBypassed)
    }

    @MainActor
    func testRehearsalMigrationBackfillsLibraryWithoutChangingExistingProfile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        fixture.defaults.set(true, forKey: LegacyAirwaveUpgrade.migrationKey)
        let existing = ["speakers": DeviceProfile(name: "Customized", slots: [])]
        try fixture.store.save(existing)
        XCTAssertTrue(try fixture.migrate {
            try LegacyAirwaveUpgrade.installedSource(defaults: fixture.defaults, home: fixture.home)
        })
        XCTAssertEqual(try fixture.store.load(), existing)
        XCTAssertEqual(Set(try fixture.presetLibrary.load(for: .airwaveEqualizer).map(\.name)), ["Desk", "Headphones"])
    }

    @MainActor
    func testUnreadableLegacyProfilesStillImportPresetsAndCanRetry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let corrupt = LegacyAirwaveUpgrade.Source(
            preferences: [LegacyAirwaveUpgrade.profilesKey: Data("corrupt".utf8)], library: fixture.library
        )
        XCTAssertThrowsError(try fixture.migrate { corrupt })
        XCTAssertFalse(fixture.defaults.bool(forKey: LegacyAirwaveUpgrade.migrationKey))
        XCTAssertEqual(Set(try fixture.presetLibrary.load(for: .airwaveEqualizer).map(\.name)), ["Desk", "Headphones"])

        let existing = DeviceProfile(name: "Customized", slots: [])
        try fixture.store.save(["speakers": existing])
        XCTAssertTrue(try fixture.migrate {
            try LegacyAirwaveUpgrade.installedSource(defaults: fixture.defaults, home: fixture.home)
        })
        let saved = try fixture.store.load()
        XCTAssertEqual(saved["speakers"], existing)
        XCTAssertNotNil(saved["offline"])
    }

    private func document(_ slot: EffectSlot) throws -> [String: Any] {
        let data = try XCTUnwrap(slot.state)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private struct Fixture {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sandbox = "Library/Containers/com.southneuhof.Airwave/Data/Library"
        let name = "Airwave3Tests.\(UUID())"
        let hrirID = UUID()
        let equalizerID = UUID()
        let eq = Data("Preamp: -4 dB".utf8)
        let defaults: UserDefaults

        init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: name)) }

        var preferencesURL: URL { home.appending(path: "\(sandbox)/Preferences/com.southneuhof.Airwave.plist") }
        var library: URL { home.appending(path: "\(sandbox)/Application Support/Airwave") }
        var eqURL: URL { library.appending(path: "Equalizer Presets/Desk.txt") }
        var wavURL: URL { library.appending(path: "presets/Personal.wav") }
        var store: ProfileStore { ProfileStore(url: home.appending(path: "upgraded.plist")) }
        var presetLibrary: PresetMigrationStore { PresetMigrationStore(url: home.appending(path: "presets.plist")) }

        @MainActor
        func migrate(_ source: () throws -> LegacyAirwaveUpgrade.Source) throws -> Bool {
            try LegacyAirwaveUpgrade.migrate(defaults: defaults, store: store, presetLibrary: presetLibrary, source: source)
        }

        func populate() throws {
            let profiles: [[String: Any]] = [
                ["deviceUID": "speakers", "deviceName": "Speakers", "hrirPresetID": hrirID.uuidString,
                 "equalizerPresetID": equalizerID.uuidString, "outputChannels": ["left": 4, "right": 3]],
                ["deviceUID": "offline", "deviceName": "Offline Device", "outputChannels": ["left": 1, "right": 2]]
            ]
            let saved = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "profiles": profiles])
            let preferences = try PropertyListSerialization.data(fromPropertyList: [
                LegacyAirwaveUpgrade.profilesKey: saved,
                LegacyAirwaveUpgrade.completedKey: true,
                LegacyAirwaveUpgrade.menuBarKey: true
            ], format: .binary, options: 0)
            try write(preferences, to: preferencesURL)
            let metadata = try JSONSerialization.data(withJSONObject: [
                ["id": hrirID.uuidString, "name": "Personal HRIR", "fileURL": "file:///old/location/Personal.wav"]
            ])
            try write(metadata, to: library.appending(path: "presets/presets.json"))
            try writeImpulse()
            let manifest = try JSONSerialization.data(withJSONObject: [
                "presets": [
                    ["id": equalizerID.uuidString, "displayName": "Desk", "filename": "Desk.txt"],
                    ["id": UUID().uuidString, "displayName": "Headphones", "filename": "Headphones.txt"]
                ]
            ])
            try write(manifest, to: library.appending(path: "Equalizer Presets/manifest.json"))
            try write(eq, to: eqURL)
            try write(Data("Preamp: -2 dB".utf8), to: library.appending(path: "Equalizer Presets/Headphones.txt"))
        }

        func remove() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: home)
        }

        private func write(_ data: Data, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        private func writeImpulse() throws {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
            buffer.frameLength = 8
            for channel in 0..<2 {
                for frame in 0..<8 { buffer.floatChannelData?[channel][frame] = frame == 0 ? 1 : 0 }
            }
            try AVAudioFile(forWriting: wavURL, settings: format.settings).write(from: buffer)
        }
    }
}

@MainActor
private final class UpgradeLoginItem: HostLoginItem {
    var registered = false
    var status: SMAppService.Status { registered ? .enabled : .notRegistered }

    func register() throws { registered = true }
    func unregister() throws { registered = false }
}
