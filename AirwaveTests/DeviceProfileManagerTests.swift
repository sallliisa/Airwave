import Foundation
import XCTest
@testable import Airwave

@MainActor
final class DeviceProfileManagerTests: XCTestCase {
    func testAvailableUnsavedTargetIsSelectableWithoutPersistence() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        let output = profileDevice(id: 1, uid: "available", name: "Available")
        let writes = context.defaults.profileStoreWrites

        manager.updateAvailableOutputs([output])
        manager.selectEditingDevice(uid: output.uid)

        XCTAssertEqual(manager.targets.map(\.deviceUID), ["available"])
        XCTAssertNil(manager.editingProfile)
        XCTAssertEqual(manager.editingTarget?.savedProfile, nil)
        XCTAssertEqual(context.defaults.profileStoreWrites, writes)
        XCTAssertEqual(manager.revision, 0)
    }

    func testCurrentObservationDoesNotCreateProfileOrChangeRoute() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        let output = profileDevice(id: 1, uid: "current", name: "Current")
        let writes = context.defaults.profileStoreWrites

        manager.observeCurrentOutput(output)

        XCTAssertEqual(manager.currentDeviceUID, "current")
        XCTAssertEqual(manager.editingDeviceUID, "current")
        XCTAssertTrue(manager.editingTarget?.isCurrent == true)
        XCTAssertTrue(manager.profiles.isEmpty)
        XCTAssertEqual(context.defaults.profileStoreWrites, writes)
    }

    func testFirstHRIRSelectionMaterializesOneProfileWriteAndOneTypedChange() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        let output = profileDevice(id: 1, uid: "hrir", name: "HRIR")
        manager.updateAvailableOutputs([output])
        manager.selectEditingDevice(uid: output.uid)
        let writes = context.defaults.profileStoreWrites
        var changes: [DeviceProfileChange] = []
        let cancellable = manager.changes.sink { changes.append($0) }
        defer { cancellable.cancel() }
        let id = UUID()

        manager.setHRIRPresetID(id)

        XCTAssertEqual(manager.profiles.count, 1)
        XCTAssertEqual(manager.editingProfile?.hrirPresetID, id)
        XCTAssertNil(manager.editingProfile?.equalizerPresetID)
        XCTAssertEqual(context.defaults.profileStoreWrites, writes + 1)
        XCTAssertEqual(changes, [.init(revision: 1, deviceUID: "hrir", effect: .hrir)])
    }

    func testFirstEQSelectionMaterializesOneProfileWriteAndOneTypedChange() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        let output = profileDevice(id: 1, uid: "eq", name: "EQ")
        manager.updateAvailableOutputs([output])
        manager.selectEditingDevice(uid: output.uid)
        let writes = context.defaults.profileStoreWrites
        var changes: [DeviceProfileChange] = []
        let cancellable = manager.changes.sink { changes.append($0) }
        defer { cancellable.cancel() }
        let id = UUID()

        manager.setEqualizerPresetID(id)

        XCTAssertEqual(manager.profiles.count, 1)
        XCTAssertEqual(manager.editingProfile?.equalizerPresetID, id)
        XCTAssertNil(manager.editingProfile?.hrirPresetID)
        XCTAssertEqual(context.defaults.profileStoreWrites, writes + 1)
        XCTAssertEqual(changes, [.init(revision: 1, deviceUID: "eq", effect: .equalizer)])
    }

    func testNilSelectionForUnsavedTargetIsZeroWriteNoOp() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        manager.updateAvailableOutputs([profileDevice(id: 1, uid: "available", name: "Available")])
        manager.selectEditingDevice(uid: "available")
        let writes = context.defaults.profileStoreWrites

        manager.setHRIRPresetID(nil)
        manager.setEqualizerPresetID(nil)

        XCTAssertTrue(manager.profiles.isEmpty)
        XCTAssertEqual(context.defaults.profileStoreWrites, writes)
        XCTAssertEqual(manager.revision, 0)
    }

    func testAvailableSavedUIDUsesLiveMetadataAndMergesOnce() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        seedProfile(manager, profileDevice(id: 1, uid: "stable", name: "Old Name", transport: "built"))
        manager.observeCurrentOutput(nil)
        let writes = context.defaults.profileStoreWrites

        manager.updateAvailableOutputs([
            profileDevice(id: 99, uid: "stable", name: "Live Name", transport: "usb")
        ])

        XCTAssertEqual(manager.targets.count, 1)
        XCTAssertEqual(manager.targets.first?.deviceName, "Live Name")
        XCTAssertEqual(manager.targets.first?.transport, "usb")
        XCTAssertTrue(manager.targets.first?.isAvailable == true)
        XCTAssertEqual(manager.profiles.first?.deviceName, "Live Name")
        XCTAssertEqual(context.defaults.profileStoreWrites, writes)
    }

    func testDisconnectedSavedProfileRemainsTarget() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        seedProfile(manager, profileDevice(id: 1, uid: "saved", name: "Saved"))
        manager.observeCurrentOutput(nil)
        manager.updateAvailableOutputs([])

        XCTAssertEqual(manager.targets.map(\.deviceUID), ["saved"])
        XCTAssertFalse(manager.targets[0].isAvailable)
        XCTAssertNotNil(manager.targets[0].savedProfile)
    }

    func testUnsupportedInventoryNeverBecomesTargetOrProfile() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        manager.updateAvailableOutputs([
            profileDevice(id: 1, uid: "virtual", name: "Virtual", virtual: true),
            profileDevice(id: 2, uid: "aggregate", name: "Aggregate", aggregate: true),
            profileDevice(id: 3, uid: "mono", name: "Mono", channels: 1),
            profileDevice(id: 4, uid: "", name: "No UID")
        ])

        XCTAssertTrue(manager.targets.isEmpty)
        manager.setHRIRPresetID(UUID(), for: "virtual")
        XCTAssertTrue(manager.profiles.isEmpty)
    }

    func testDisappearingUnsavedEditorFallsBackToMostRecentSavedProfile() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        seedProfile(manager, profileDevice(id: 1, uid: "saved", name: "Saved"))
        let transient = profileDevice(id: 2, uid: "transient", name: "Transient")
        manager.updateAvailableOutputs([transient])
        manager.selectEditingDevice(uid: transient.uid)

        manager.updateAvailableOutputs([])

        XCTAssertEqual(manager.editingDeviceUID, "saved")
    }

    func testForgetAvailableSavedDeviceLeavesTransientTarget() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        let forgotten = profileDevice(id: 1, uid: "forgotten", name: "Forgotten")
        seedProfile(manager, forgotten)
        seedProfile(manager, profileDevice(id: 2, uid: "current", name: "Current"))
        manager.updateAvailableOutputs([forgotten])
        manager.selectEditingDevice(uid: forgotten.uid)

        XCTAssertTrue(manager.forgetProfile(deviceUID: forgotten.uid))

        XCTAssertNil(manager.profile(for: forgotten.uid))
        XCTAssertEqual(manager.editingTarget?.deviceUID, forgotten.uid)
        XCTAssertTrue(manager.editingTarget?.isAvailable == true)
    }

    func testExistingBlankV1ProfileLoadsUnchanged() throws {
        let context = try Context()
        let profile = DeviceAudioProfile(
            deviceUID: "blank", deviceName: "Blank", transport: "built",
            hrirPresetID: nil, equalizerPresetID: nil, lastSeenAt: context.date
        )
        let data = try JSONEncoder().encode(DeviceProfileEnvelope(schemaVersion: 1, profiles: [profile]))
        context.defaults.set(data, forKey: DeviceProfileManager.storageKey)

        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })

        XCTAssertEqual(manager.profiles, [profile])
        XCTAssertEqual(context.defaults.data(forKey: DeviceProfileManager.storageKey), data)
    }

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

        seedProfile(manager, output)
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

        seedProfile(manager, profileDevice(id: 1, uid: "stable", name: "Old Name"))
        manager.observeCurrentOutput(profileDevice(id: 99, uid: "stable", name: "New Name", transport: "usb"))

        XCTAssertEqual(manager.profiles.count, 1)
        XCTAssertEqual(manager.currentProfile?.deviceName, "New Name")
        XCTAssertEqual(manager.currentProfile?.transport, "usb")
        XCTAssertEqual(manager.currentProfile?.deviceUID, "stable")
    }

    func testUnsupportedOutputsAreNeverStoredAndRememberedEditorFallsBack() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })

        seedProfile(manager, profileDevice(id: 1, uid: "a", name: "Alpha"))
        context.date = context.date.addingTimeInterval(1)
        seedProfile(manager, profileDevice(id: 2, uid: "b", name: "Beta"))
        manager.observeCurrentOutput(profileDevice(id: 3, uid: "virtual", name: "Virtual", virtual: true))

        XCTAssertNil(manager.currentDeviceUID)
        XCTAssertEqual(manager.editingDeviceUID, "b")
        XCTAssertEqual(manager.profiles.map(\.deviceUID), ["a", "b"])
        XCTAssertFalse(manager.profiles.contains { $0.deviceUID == "virtual" })
    }

    func testManualRememberedSelectionDoesNotChangeCurrentOutput() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        seedProfile(manager, profileDevice(id: 1, uid: "a", name: "Alpha"))
        seedProfile(manager, profileDevice(id: 2, uid: "b", name: "Beta"))

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

        seedProfile(manager, profileDevice(id: 1, uid: "stable", name: "Output"))

        XCTAssertNotEqual(context.defaults.data(forKey: DeviceProfileManager.storageKey), Data("not-json".utf8))
    }

    func testMissingReferencesClearOnlyTheirOwnEffectAndEmitTypedChanges() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        seedProfile(manager, profileDevice(id: 1, uid: "stable", name: "Output"))
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
        seedProfile(manager, profileDevice(id: 1, uid: "stable", name: "Output"))
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
        seedProfile(manager, profileDevice(id: 1, uid: "stable", name: "Output"))
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
        seedProfile(manager, profileDevice(id: 1, uid: "stable", name: "Output"))
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
        seedProfile(manager, profileDevice(id: 1, uid: "older", name: "Older"))
        context.date = context.date.addingTimeInterval(1)
        seedProfile(manager, profileDevice(id: 2, uid: "current", name: "Current"))
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
        seedProfile(manager, profileDevice(id: 1, uid: "current", name: "Current"))
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

    func testForgottenAvailableUIDRemainsTransientWhenObservedAgain() throws {
        let context = try Context()
        let manager = DeviceProfileManager(defaults: context.defaults, now: { context.date })
        seedProfile(manager, profileDevice(id: 1, uid: "forgotten", name: "Output"))
        manager.setHRIRPresetID(UUID())
        manager.setEqualizerPresetID(UUID())
        context.date = context.date.addingTimeInterval(1)
        manager.observeCurrentOutput(profileDevice(id: 2, uid: "other", name: "Other"))
        manager.selectEditingDevice(uid: "forgotten")
        XCTAssertTrue(manager.forgetProfile(deviceUID: "forgotten"))

        context.date = context.date.addingTimeInterval(1)
        manager.observeCurrentOutput(profileDevice(id: 3, uid: "forgotten", name: "Output"))

        XCTAssertEqual(manager.currentDeviceUID, "forgotten")
        XCTAssertNil(manager.currentProfile)
        XCTAssertEqual(manager.editingTarget?.deviceUID, "forgotten")
        XCTAssertTrue(manager.editingTarget?.isAvailable == true)
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

@MainActor
private func seedProfile(_ manager: DeviceProfileManager, _ output: OutputDeviceDescriptor) {
    manager.updateAvailableOutputs([output])
    manager.selectEditingDevice(uid: output.uid)
    manager.setHRIRPresetID(UUID(), for: output.uid)
    manager.setHRIRPresetID(nil, for: output.uid)
    manager.observeCurrentOutput(output)
}
