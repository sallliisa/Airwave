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

        XCTAssertTrue(try LegacyAirwaveUpgrade.migrate(defaults: fixture.defaults, store: fixture.store) { source })
        let saved = try fixture.store.load()
        let speakers = try XCTUnwrap(saved["speakers"])
        XCTAssertEqual(speakers.outputChannels, StereoOutputChannels(left: 4, right: 3))
        XCTAssertEqual(speakers.slots.map(\.component), [.airwaveSpatial, .airwaveEqualizer])
        let spatial = try document(speakers.slots[0])
        XCTAssertEqual(spatial["AirwaveSpatial.presetName"] as? String, "Personal HRIR")
        XCTAssertEqual(spatial["AirwaveSpatial.impulseResponse"] as? Data, fixture.wav)
        let eq = try EqualizerAUState(document(speakers.slots[1]))
        XCTAssertEqual(eq.preset?.name, "Desk")
        XCTAssertEqual(eq.preset?.data, fixture.eq)
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
        XCTAssertFalse(try LegacyAirwaveUpgrade.migrate(defaults: fixture.defaults, store: fixture.store) {
            XCTFail("Migration reopened the old preferences after completion.")
            return source
        })
        XCTAssertEqual(try fixture.store.load(), edited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.preferencesURL.path))
    }

    @MainActor
    func testMissingPresetLeavesExistingChainsAndOldPreferencesIntact() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let existing = ["existing": DeviceProfile(name: "Existing", slots: [])]
        try fixture.store.save(existing)
        try FileManager.default.removeItem(at: fixture.eqURL)
        let source = try LegacyAirwaveUpgrade.installedSource(
            defaults: fixture.defaults, home: fixture.home, applicationSupport: fixture.home
        )

        XCTAssertThrowsError(try LegacyAirwaveUpgrade.migrate(defaults: fixture.defaults, store: fixture.store) { source })
        XCTAssertFalse(fixture.defaults.bool(forKey: LegacyAirwaveUpgrade.migrationKey))
        XCTAssertEqual(try fixture.store.load(), existing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.preferencesURL.path))

        try fixture.eq.write(to: fixture.eqURL)
        XCTAssertTrue(try LegacyAirwaveUpgrade.migrate(defaults: fixture.defaults, store: fixture.store) { source })
        XCTAssertEqual(try fixture.store.load()["existing"], existing["existing"])
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
        let wav = Data([0x52, 0x49, 0x46, 0x46])
        let eq = Data("Preamp: -4 dB".utf8)
        let defaults: UserDefaults

        init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: name)) }

        var preferencesURL: URL { home.appending(path: "\(sandbox)/Preferences/com.southneuhof.Airwave.plist") }
        var library: URL { home.appending(path: "\(sandbox)/Application Support/Airwave") }
        var eqURL: URL { library.appending(path: "Equalizer Presets/Desk.txt") }
        var store: ProfileStore { ProfileStore(url: home.appending(path: "upgraded.plist")) }

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
            try write(wav, to: library.appending(path: "presets/Personal.wav"))
            let manifest = try JSONSerialization.data(withJSONObject: [
                "presets": [["id": equalizerID.uuidString, "displayName": "Desk", "filename": "Desk.txt"]]
            ])
            try write(manifest, to: library.appending(path: "Equalizer Presets/manifest.json"))
            try write(eq, to: eqURL)
        }

        func remove() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: home)
        }

        private func write(_ data: Data, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
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
