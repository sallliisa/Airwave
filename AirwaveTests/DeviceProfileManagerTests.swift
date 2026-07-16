import Foundation
import XCTest
@testable import Airwave

@MainActor
final class DeviceProfileManagerTests: XCTestCase {
    func testEmptyStartupDiscardsLegacySelectionAndWritesV1Store() throws {
        let context = try Context()
        context.defaults.set(UUID().uuidString, forKey: DeviceProfileManager.legacyEqualizerSelectionKey)

        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })

        XCTAssertTrue(manager.profiles.isEmpty)
        XCTAssertNil(context.defaults.string(forKey: DeviceProfileManager.legacyEqualizerSelectionKey))
        XCTAssertNotNil(context.defaults.data(forKey: DeviceProfileManager.storageKey))
    }

    func testSupportedDeviceStartsByUIDAsNoneNoneAndPersistsAcrossRelaunch() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        let output = profileDevice(id: 1, uid: "stable", name: "Built-in")

        manager.observe(output)
        let profile = try XCTUnwrap(manager.currentProfile)
        XCTAssertEqual(profile.deviceUID, "stable")
        XCTAssertNil(profile.hrirPresetID)
        XCTAssertNil(profile.equalizerPresetID)

        let hrirID = UUID()
        let eqID = UUID()
        manager.setHRIRPresetID(hrirID)
        manager.setEqualizerPresetID(eqID)

        let relaunched = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        XCTAssertEqual(relaunched.profiles.count, 1)
        XCTAssertEqual(relaunched.profiles[0].hrirPresetID, hrirID)
        XCTAssertEqual(relaunched.profiles[0].equalizerPresetID, eqID)
    }

    func testSameUIDRefreshesMetadataWithoutFollowingTransientObjectID() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })

        manager.observe(profileDevice(id: 1, uid: "stable", name: "Old Name"))
        manager.observe(profileDevice(id: 99, uid: "stable", name: "New Name", transport: "usb"))

        XCTAssertEqual(manager.profiles.count, 1)
        XCTAssertEqual(manager.currentProfile?.deviceName, "New Name")
        XCTAssertEqual(manager.currentProfile?.transport, "usb")
        XCTAssertEqual(manager.currentProfile?.deviceUID, "stable")
    }

    func testUnsupportedOutputsAreNeverStoredAndRememberedEditorFallsBack() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })

        manager.observe(profileDevice(id: 1, uid: "a", name: "Alpha"))
        context.date = context.date.addingTimeInterval(1)
        manager.observe(profileDevice(id: 2, uid: "b", name: "Beta"))
        manager.observe(profileDevice(id: 3, uid: "virtual", name: "Virtual", virtual: true))

        XCTAssertNil(manager.currentDeviceUID)
        XCTAssertEqual(manager.editingDeviceUID, "b")
        XCTAssertEqual(manager.profiles.map(\.deviceUID), ["a", "b"])
        XCTAssertFalse(manager.profiles.contains { $0.deviceUID == "virtual" })
    }

    func testManualRememberedSelectionDoesNotChangeCurrentOutput() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        manager.observe(profileDevice(id: 1, uid: "a", name: "Alpha"))
        manager.observe(profileDevice(id: 2, uid: "b", name: "Beta"))

        manager.selectEditingDevice(uid: "a")

        XCTAssertEqual(manager.currentDeviceUID, "b")
        XCTAssertEqual(manager.editingDeviceUID, "a")
    }

    func testCorruptPayloadFailsSafeUntilNextValidMutation() throws {
        let context = try Context()
        context.defaults.set(Data("not-json".utf8), forKey: DeviceProfileManager.storageKey)
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })

        XCTAssertTrue(manager.profiles.isEmpty)
        XCTAssertEqual(context.defaults.data(forKey: DeviceProfileManager.storageKey), Data("not-json".utf8))

        manager.observe(profileDevice(id: 1, uid: "stable", name: "Output"))

        XCTAssertNotEqual(context.defaults.data(forKey: DeviceProfileManager.storageKey), Data("not-json".utf8))
    }

    func testMissingReferencesClearOnlyTheirOwnEffectAndEmitTypedChanges() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        manager.observe(profileDevice(id: 1, uid: "stable", name: "Output"))
        let hrirID = UUID()
        let eqID = UUID()
        manager.setHRIRPresetID(hrirID)
        manager.setEqualizerPresetID(eqID)
        var changes: [DeviceProfileChange] = []
        let cancellable = manager.changes.sink { changes.append($0) }
        defer { cancellable.cancel() }

        manager.clearMissingHRIRPresetIDs([hrirID])

        XCTAssertNil(manager.currentProfile?.hrirPresetID)
        XCTAssertEqual(manager.currentProfile?.equalizerPresetID, eqID)
        XCTAssertEqual(changes.last?.effect, .hrir)
    }

    func testResetClearsBothEffectsWithOneWriteAndOneBothChange() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        manager.observe(profileDevice(id: 1, uid: "stable", name: "Output"))
        manager.setHRIRPresetID(UUID())
        manager.setEqualizerPresetID(UUID())
        let writesBeforeReset = context.defaults.profileStoreWrites
        var changes: [DeviceProfileChange] = []
        let cancellable = manager.changes.sink { changes.append($0) }
        defer { cancellable.cancel() }

        XCTAssertTrue(manager.resetProfile(deviceUID: "stable"))

        XCTAssertNil(manager.currentProfile?.hrirPresetID)
        XCTAssertNil(manager.currentProfile?.equalizerPresetID)
        XCTAssertEqual(context.defaults.profileStoreWrites, writesBeforeReset + 1)
        XCTAssertEqual(changes, [.init(revision: manager.revision, deviceUID: "stable", effect: .both)])
    }

    func testResetMissingAndAlreadyEmptyAreFalseWithoutWritesOrChanges() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        manager.observe(profileDevice(id: 1, uid: "stable", name: "Output"))
        let writesBeforeReset = context.defaults.profileStoreWrites
        var changeCount = 0
        let cancellable = manager.changes.sink { _ in changeCount += 1 }
        defer { cancellable.cancel() }

        XCTAssertFalse(manager.resetProfile(deviceUID: "missing"))
        XCTAssertFalse(manager.resetProfile(deviceUID: "stable"))

        XCTAssertEqual(context.defaults.profileStoreWrites, writesBeforeReset)
        XCTAssertEqual(changeCount, 0)
    }

    func testResetCurrentEmitsOneRuntimeRelevantBothEffect() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        manager.observe(profileDevice(id: 1, uid: "stable", name: "Output"))
        manager.setHRIRPresetID(UUID())
        manager.setEqualizerPresetID(UUID())
        var changes: [DeviceProfileChange] = []
        let cancellable = manager.changes.sink { changes.append($0) }
        defer { cancellable.cancel() }

        _ = manager.resetProfile(deviceUID: "stable")

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.effect, .both)
        XCTAssertEqual(changes.first?.deviceUID, manager.currentDeviceUID)
    }

    func testForgetNonCurrentRemovesItPersistsOnceAndRepairsEditingFallback() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        manager.observe(profileDevice(id: 1, uid: "older", name: "Older"))
        context.date = context.date.addingTimeInterval(1)
        manager.observe(profileDevice(id: 2, uid: "current", name: "Current"))
        manager.selectEditingDevice(uid: "older")
        let writesBeforeForget = context.defaults.profileStoreWrites
        var changes: [DeviceProfileChange] = []
        let cancellable = manager.changes.sink { changes.append($0) }
        defer { cancellable.cancel() }

        XCTAssertTrue(manager.forgetProfile(deviceUID: "older"))

        XCTAssertEqual(manager.profiles.map(\.deviceUID), ["current"])
        XCTAssertEqual(manager.editingDeviceUID, "current")
        XCTAssertEqual(context.defaults.profileStoreWrites, writesBeforeForget + 1)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.effect, .metadata)
        XCTAssertEqual(changes.first?.deviceUID, "older")
    }

    func testForgetCurrentAndMissingAreFalseNoOps() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        manager.observe(profileDevice(id: 1, uid: "current", name: "Current"))
        let writesBeforeForget = context.defaults.profileStoreWrites
        var changeCount = 0
        let cancellable = manager.changes.sink { _ in changeCount += 1 }
        defer { cancellable.cancel() }

        XCTAssertFalse(manager.forgetProfile(deviceUID: "current"))
        XCTAssertFalse(manager.forgetProfile(deviceUID: "missing"))

        XCTAssertEqual(manager.profiles.count, 1)
        XCTAssertEqual(context.defaults.profileStoreWrites, writesBeforeForget)
        XCTAssertEqual(changeCount, 0)
    }

    func testForgottenUIDIsRecreatedAsNoneNoneWhenObservedAgain() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        manager.observe(profileDevice(id: 1, uid: "forgotten", name: "Output"))
        manager.setHRIRPresetID(UUID())
        manager.setEqualizerPresetID(UUID())
        context.date = context.date.addingTimeInterval(1)
        manager.observe(profileDevice(id: 2, uid: "other", name: "Other"))
        manager.selectEditingDevice(uid: "forgotten")
        XCTAssertTrue(manager.forgetProfile(deviceUID: "forgotten"))

        context.date = context.date.addingTimeInterval(1)
        manager.observe(profileDevice(id: 3, uid: "forgotten", name: "Output"))

        XCTAssertEqual(manager.currentProfile?.deviceUID, "forgotten")
        XCTAssertNil(manager.currentProfile?.hrirPresetID)
        XCTAssertNil(manager.currentProfile?.equalizerPresetID)
    }
}

@MainActor
private final class Context {
    let suite = "DeviceProfileManagerTests.\(UUID().uuidString)"
    let defaults: CountingUserDefaults
    var date = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        defaults = try XCTUnwrap(CountingUserDefaults(suiteName: suite))
    }

    deinit { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class CountingUserDefaults: UserDefaults {
    private(set) var profileStoreWrites = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == DeviceProfileManager.storageKey {
            profileStoreWrites += 1
        }
        super.set(value, forKey: defaultName)
    }
}

private func profileDevice(
    id: UInt64,
    uid: String,
    name: String,
    transport: String = "built",
    virtual: Bool = false,
    aggregate: Bool = false,
    channels: Int = 2
) -> OutputDeviceDescriptor {
    OutputDeviceDescriptor(
        id: .init(id), uid: uid, name: name, transport: transport,
        outputChannelCount: channels, nominalSampleRate: 48_000,
        isVirtual: virtual, isAggregate: aggregate
    )
}
