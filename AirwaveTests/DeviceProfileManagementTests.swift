import AVFoundation
import Foundation
import XCTest
@testable import Airwave

@MainActor
final class DeviceProfileManagementTests: XCTestCase {
    func testBundledHRTFsSeedAndRemainAvailableOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFiles = try ["NeutralSH1.0", "RoomSH1.0", "StageSH1.0"].map { name in
            let url = sourceDirectory.appendingPathComponent("\(name).wav")
            try writeTestWAV(to: url)
            return url
        }

        let catalog = BundledPresetCatalog(hrirFiles: sourceFiles)
        let manager = HRIRManager(
            presetsDirectory: managed,
            startWatcher: false,
            bundledPresetCatalog: catalog
        )
        await waitForInitialHRIRSync(manager)

        XCTAssertEqual(Set(manager.presets.map(\.name)), ["NeutralSH1.0", "RoomSH1.0", "StageSH1.0"])
        XCTAssertTrue(manager.presets.allSatisfy { $0.channelCount == 2 && $0.sampleRate == 48_000 })

        let deleted = try XCTUnwrap(manager.presets.first { $0.name == "RoomSH1.0" })
        manager.deletePreset(deleted)
        let relaunched = HRIRManager(
            presetsDirectory: managed,
            startWatcher: false,
            bundledPresetCatalog: catalog
        )
        await waitForInitialHRIRSync(relaunched)

        XCTAssertNil(relaunched.presets.first { $0.name == "RoomSH1.0" })
        XCTAssertEqual(Set(relaunched.presets.map(\.name)), ["NeutralSH1.0", "StageSH1.0"])
    }

    func testRowsResolveNamesAndKeepCurrentFirstOrdering() throws {
        let context = try ManagementContext()
        let hrirID = UUID()
        context.hrir.presets = [HRIRPreset(
            id: hrirID,
            name: "Concert Hall",
            fileURL: URL(fileURLWithPath: "/tmp/concert.wav"),
            channelCount: 2,
            sampleRate: 48_000
        )]
        let equalizerFile = context.root.appendingPathComponent("Warm.txt")
        try Data("Preamp: 1 dB\n".utf8).write(to: equalizerFile)
        let imported = context.equalizer.importPresets([equalizerFile], collisionPolicy: .reject).imported
        let importedPreset = try XCTUnwrap(imported.first)
        XCTAssertEqual(importedPreset.displayName, "Warm")

        seedProfile(context.profiles, profileDevice(id: 1, uid: "remembered", name: "Remembered"))
        context.profiles.setHRIRPresetID(hrirID, for: "remembered")
        context.profiles.setEqualizerPresetID(importedPreset.id, for: "remembered")
        context.date = context.date.addingTimeInterval(1)
        seedProfile(context.profiles, profileDevice(id: 2, uid: "current", name: "Current", transport: "USB"))

        let coordinator = context.coordinator()
        XCTAssertEqual(coordinator.rows.map(\.deviceName), ["Current", "Remembered"])
        XCTAssertEqual(coordinator.rows[0].status, "Current")
        XCTAssertEqual(coordinator.rows[0].transport, "USB")
        XCTAssertEqual(coordinator.rows[0].hrirName, "None")
        XCTAssertEqual(coordinator.rows[0].equalizerName, "None")
        XCTAssertEqual(coordinator.rows[1].hrirName, "Concert Hall")
        XCTAssertEqual(coordinator.rows[1].equalizerName, "Warm")
        XCTAssertEqual(coordinator.rows[1].transport, "Built-in")
        XCTAssertEqual(coordinator.rows[1].status, "Not Connected")
    }

    func testRowsIncludeConnectedUnregisteredFourChannelOutputWithoutSavingOnOpen() throws {
        let context = try ManagementContext()
        let current = profileDevice(id: 1, uid: "current", name: "Current")
        let interface = profileDevice(
            id: 2,
            uid: "interface",
            name: "Dual Stereo Interface",
            channels: 4,
            channelLabels: [1, 2, 1, 2],
            preferredStereoChannels: .init(left: 3, right: 4)
        )
        context.profiles.updateAvailableOutputs([current, interface])
        context.profiles.observeCurrentOutput(current)
        let persistedData = context.defaults.data(forKey: DeviceProfileManager.storageKey)
        let coordinator = context.coordinator()

        XCTAssertEqual(coordinator.rows.map(\.id), ["current", "interface"])
        let row = try XCTUnwrap(coordinator.rows.first { $0.id == interface.uid })
        XCTAssertEqual(row.status, "Connected")
        XCTAssertTrue(row.canConfigureOutput)
        XCTAssertFalse(row.canReset)
        XCTAssertFalse(row.canForget)
        XCTAssertNil(context.profiles.profile(for: interface.uid))

        let editor = ConfigureOutputCoordinator(
            deviceUID: interface.uid,
            deviceName: interface.name,
            profiles: context.profiles
        )
        XCTAssertEqual(editor.leftChannel, 3)
        XCTAssertEqual(editor.rightChannel, 4)
        XCTAssertEqual(context.defaults.data(forKey: DeviceProfileManager.storageKey), persistedData)
        XCTAssertEqual(context.profiles.revision, 0)
        editor.cancel()
        XCTAssertEqual(context.defaults.data(forKey: DeviceProfileManager.storageKey), persistedData)
        XCTAssertNil(context.profiles.profile(for: interface.uid))
    }

    func testOfflineSavedOutputRemainsVisibleAndCannotBeConfigured() throws {
        let context = try ManagementContext()
        let interface = profileDevice(id: 1, uid: "offline", name: "Offline Interface", channels: 4)
        let pair = StereoOutputChannels(left: 4, right: 2)
        context.profiles.updateAvailableOutputs([interface])
        XCTAssertTrue(context.profiles.setOutputChannels(pair, for: interface.uid))
        context.profiles.observeCurrentOutput(nil)
        context.profiles.updateAvailableOutputs([])

        let row = try XCTUnwrap(context.coordinator().rows.first)
        XCTAssertEqual(row.id, interface.uid)
        XCTAssertEqual(row.status, "Not Connected")
        XCTAssertFalse(row.canConfigureOutput)
        XCTAssertTrue(row.canReset)
        XCTAssertTrue(row.canForget)
        XCTAssertEqual(context.profiles.profile(for: interface.uid)?.outputChannels, pair)
    }

    func testResetProfileIncludesOutputAssignmentOnlyAndClearsIt() throws {
        let context = try ManagementContext()
        let current = profileDevice(id: 1, uid: "current", name: "Current")
        let interface = profileDevice(id: 2, uid: "interface", name: "Interface", channels: 4)
        context.profiles.updateAvailableOutputs([current, interface])
        context.profiles.observeCurrentOutput(current)
        let pair = StereoOutputChannels(left: 3, right: 1)
        XCTAssertTrue(context.profiles.setOutputChannels(pair, for: interface.uid))
        let coordinator = context.coordinator()

        XCTAssertTrue(try XCTUnwrap(coordinator.rows.first { $0.id == interface.uid }).canReset)
        coordinator.requestReset(deviceUID: interface.uid)
        XCTAssertEqual(
            coordinator.pendingConfirmation?.message,
            "HRIR, EQ, and the saved output channel assignment will be cleared."
        )
        XCTAssertTrue(coordinator.confirmPendingAction())
        XCTAssertNil(context.profiles.profile(for: interface.uid)?.outputChannels)
        XCTAssertNil(context.profiles.profile(for: interface.uid)?.hrirPresetID)
        XCTAssertNil(context.profiles.profile(for: interface.uid)?.equalizerPresetID)
    }

    func testOutputEditorPinsUIDAcrossCurrentOutputChangeAndSavesOneReversedPair() throws {
        let context = try ManagementContext()
        let originalCurrent = profileDevice(id: 1, uid: "original-current", name: "Original Current")
        let target = profileDevice(id: 2, uid: "target", name: "Target Interface", channels: 4)
        let nextCurrent = profileDevice(id: 3, uid: "next-current", name: "Next Current")
        context.profiles.updateAvailableOutputs([originalCurrent, target, nextCurrent])
        context.profiles.observeCurrentOutput(originalCurrent)
        context.profiles.selectEditingDevice(uid: originalCurrent.uid)
        let editor = ConfigureOutputCoordinator(
            deviceUID: target.uid,
            deviceName: target.name,
            profiles: context.profiles
        )
        var changes: [DeviceProfileChange] = []
        let cancellable = context.profiles.changes.sink { changes.append($0) }
        defer { cancellable.cancel() }

        editor.selectLeftChannel(4)
        editor.selectRightChannel(2)
        context.profiles.observeCurrentOutput(nextCurrent)

        XCTAssertEqual(editor.deviceUID, target.uid)
        XCTAssertEqual(editor.deviceName, target.name)
        XCTAssertTrue(editor.canSave)
        XCTAssertTrue(editor.save())
        XCTAssertFalse(editor.save())
        XCTAssertEqual(context.profiles.currentDeviceUID, nextCurrent.uid)
        XCTAssertEqual(context.profiles.profile(for: target.uid)?.outputChannels, .init(left: 4, right: 2))
        XCTAssertEqual(context.profiles.editingDeviceUID, nextCurrent.uid)
        XCTAssertEqual(changes, [.init(revision: 1, deviceUID: target.uid, effect: .routing)])
    }

    func testConfigureOutputPopoverReopenSameUIDResumesDraftAfterTransientDismissal() throws {
        let context = try ManagementContext()
        let target = profileDevice(id: 1, uid: "target", name: "Target", channels: 4)
        context.profiles.updateAvailableOutputs([target])
        let makeEditor: ConfigureOutputPopoverCoordinator.EditorFactory = { uid, name in
            ConfigureOutputCoordinator(deviceUID: uid, deviceName: name, profiles: context.profiles)
        }
        let presentation = ConfigureOutputPopoverCoordinator(
            profiles: context.profiles,
            makeEditor: makeEditor
        )

        presentation.present(deviceUID: target.uid, deviceName: target.name)
        let editor = try XCTUnwrap(presentation.presentedEditor)
        editor.selectLeftChannel(4)
        editor.selectRightChannel(2)
        presentation.dismissTransiently()

        XCTAssertNil(presentation.presentedDeviceUID)
        XCTAssertTrue(editor.canSave)
        XCTAssertNil(context.profiles.profile(for: target.uid))

        presentation.present(deviceUID: target.uid, deviceName: "Updated device name")

        XCTAssertTrue(try XCTUnwrap(presentation.presentedEditor) === editor)
        XCTAssertEqual(presentation.presentedEditor?.deviceName, target.name)
        XCTAssertEqual(presentation.presentedEditor?.leftChannel, 4)
        XCTAssertEqual(presentation.presentedEditor?.rightChannel, 2)
        XCTAssertNil(context.profiles.profile(for: target.uid))

        presentation.cancelPresentedDraft(for: target.uid)
    }

    func testConfigureOutputPopoverSwitchingTargetsKeepsSeparateUIDDraftsWithoutWriting() throws {
        let context = try ManagementContext()
        let first = profileDevice(id: 1, uid: "first", name: "First", channels: 4)
        let second = profileDevice(id: 2, uid: "second", name: "Second", channels: 4)
        context.profiles.updateAvailableOutputs([first, second])
        let savedPair = StereoOutputChannels(left: 1, right: 2)
        XCTAssertTrue(context.profiles.setOutputChannels(savedPair, for: first.uid))
        let baselineRevision = context.profiles.revision
        let makeEditor: ConfigureOutputPopoverCoordinator.EditorFactory = { uid, name in
            ConfigureOutputCoordinator(deviceUID: uid, deviceName: name, profiles: context.profiles)
        }
        let presentation = ConfigureOutputPopoverCoordinator(
            profiles: context.profiles,
            makeEditor: makeEditor
        )
        presentation.present(deviceUID: first.uid, deviceName: first.name)
        let firstEditor = try XCTUnwrap(presentation.presentedEditor)
        firstEditor.selectLeftChannel(4)
        firstEditor.selectRightChannel(2)
        presentation.dismissTransiently()

        presentation.present(deviceUID: second.uid, deviceName: second.name)
        let secondEditor = try XCTUnwrap(presentation.presentedEditor)

        XCTAssertEqual(presentation.presentedDeviceUID, second.uid)
        XCTAssertEqual(secondEditor.deviceUID, second.uid)
        XCTAssertEqual(secondEditor.leftChannel, 1)
        XCTAssertEqual(secondEditor.rightChannel, 2)
        XCTAssertTrue(firstEditor.canSave)
        XCTAssertEqual(firstEditor.deviceUID, first.uid)
        XCTAssertEqual(firstEditor.leftChannel, 4)
        XCTAssertEqual(firstEditor.rightChannel, 2)
        XCTAssertEqual(context.profiles.revision, baselineRevision)
        XCTAssertEqual(context.profiles.profile(for: first.uid)?.outputChannels, savedPair)
        XCTAssertNil(context.profiles.profile(for: second.uid))

        presentation.dismissTransiently()
        presentation.present(deviceUID: first.uid, deviceName: first.name)
        XCTAssertTrue(try XCTUnwrap(presentation.presentedEditor) === firstEditor)
        presentation.cancelPresentedDraft(for: first.uid)
        presentation.present(deviceUID: second.uid, deviceName: second.name)
        XCTAssertTrue(try XCTUnwrap(presentation.presentedEditor) === secondEditor)
        presentation.cancelPresentedDraft(for: second.uid)
        XCTAssertEqual(context.profiles.revision, baselineRevision)
        XCTAssertEqual(context.profiles.profile(for: first.uid)?.outputChannels, savedPair)
        XCTAssertNil(context.profiles.profile(for: second.uid))
    }

    func testConfigureOutputPopoverCancelDiscardsDraftWithoutPreferenceMutation() throws {
        let context = try ManagementContext()
        let target = profileDevice(id: 1, uid: "target", name: "Target", channels: 4)
        context.profiles.updateAvailableOutputs([target])
        let storedData = context.defaults.data(forKey: DeviceProfileManager.storageKey)
        let baselineRevision = context.profiles.revision
        var changes: [DeviceProfileChange] = []
        let cancellable = context.profiles.changes.sink { changes.append($0) }
        defer { cancellable.cancel() }
        let presentation = ConfigureOutputPopoverCoordinator(
            profiles: context.profiles,
            makeEditor: { uid, name in
                ConfigureOutputCoordinator(deviceUID: uid, deviceName: name, profiles: context.profiles)
            }
        )
        presentation.present(deviceUID: target.uid, deviceName: target.name)
        let editor = try XCTUnwrap(presentation.presentedEditor)
        editor.selectLeftChannel(4)
        editor.selectRightChannel(2)

        presentation.cancelPresentedDraft(for: target.uid)

        XCTAssertNil(presentation.presentedDeviceUID)
        XCTAssertNil(presentation.presentedEditor)
        XCTAssertFalse(editor.canSave)
        XCTAssertEqual(context.profiles.revision, baselineRevision)
        XCTAssertEqual(context.defaults.data(forKey: DeviceProfileManager.storageKey), storedData)
        XCTAssertNil(context.profiles.profile(for: target.uid))
        XCTAssertTrue(changes.isEmpty)

        presentation.present(deviceUID: target.uid, deviceName: target.name)
        let reopenedEditor = try XCTUnwrap(presentation.presentedEditor)
        XCTAssertFalse(reopenedEditor === editor)
        XCTAssertEqual(reopenedEditor.leftChannel, 1)
        XCTAssertEqual(reopenedEditor.rightChannel, 2)
        presentation.cancelPresentedDraft(for: target.uid)
    }

    func testConfigureOutputPopoverSaveClosesOnlyAfterSuccessAndKeepsPinnedUID() throws {
        let context = try ManagementContext()
        let current = profileDevice(id: 1, uid: "current", name: "Current")
        let target = profileDevice(id: 2, uid: "target", name: "Target", channels: 4)
        let nextCurrent = profileDevice(id: 3, uid: "next", name: "Next")
        context.profiles.updateAvailableOutputs([current, target, nextCurrent])
        context.profiles.observeCurrentOutput(current)
        var saveAllowed = false
        let presentation = ConfigureOutputPopoverCoordinator(
            profiles: context.profiles,
            makeEditor: { uid, name in
                ConfigureOutputCoordinator(
                    deviceUID: uid,
                    deviceName: name,
                    profiles: context.profiles,
                    saveOperation: { channels, targetUID in
                        guard saveAllowed else { return false }
                        return context.profiles.setOutputChannels(channels, for: targetUID)
                    }
                )
            }
        )
        presentation.present(deviceUID: target.uid, deviceName: target.name)
        let editor = try XCTUnwrap(presentation.presentedEditor)
        editor.selectLeftChannel(4)
        editor.selectRightChannel(2)
        var changes: [DeviceProfileChange] = []
        let cancellable = context.profiles.changes.sink { changes.append($0) }
        defer { cancellable.cancel() }
        context.profiles.observeCurrentOutput(nextCurrent)

        XCTAssertFalse(presentation.savePresentedDraft(for: target.uid))
        XCTAssertEqual(presentation.presentedDeviceUID, target.uid)
        XCTAssertTrue(presentation.presentedEditor === editor)
        XCTAssertTrue(editor.validationMessage?.contains("could not save") == true)
        XCTAssertNil(context.profiles.profile(for: target.uid))
        XCTAssertEqual(context.profiles.currentDeviceUID, nextCurrent.uid)

        saveAllowed = true
        XCTAssertTrue(presentation.savePresentedDraft(for: target.uid))

        XCTAssertNil(presentation.presentedDeviceUID)
        XCTAssertNil(presentation.presentedEditor)
        XCTAssertEqual(context.profiles.currentDeviceUID, nextCurrent.uid)
        XCTAssertEqual(context.profiles.profile(for: target.uid)?.outputChannels, .init(left: 4, right: 2))
        XCTAssertEqual(changes, [.init(revision: 1, deviceUID: target.uid, effect: .routing)])

        presentation.present(deviceUID: target.uid, deviceName: target.name)
        let reopenedEditor = try XCTUnwrap(presentation.presentedEditor)
        XCTAssertFalse(reopenedEditor === editor)
        XCTAssertEqual(reopenedEditor.leftChannel, 4)
        XCTAssertEqual(reopenedEditor.rightChannel, 2)
        presentation.cancelPresentedDraft(for: target.uid)
    }

    func testOutputEditorRetainsInvalidSavedPairAfterChannelShrinkAndAllowsRepair() throws {
        let context = try ManagementContext()
        let original = profileDevice(id: 1, uid: "interface", name: "Interface", channels: 4)
        context.profiles.updateAvailableOutputs([original])
        let savedPair = StereoOutputChannels(left: 3, right: 4)
        XCTAssertTrue(context.profiles.setOutputChannels(savedPair, for: original.uid))
        let editor = ConfigureOutputCoordinator(
            deviceUID: original.uid,
            deviceName: original.name,
            profiles: context.profiles
        )
        XCTAssertEqual(editor.leftChannel, 3)
        XCTAssertEqual(editor.rightChannel, 4)

        context.profiles.updateAvailableOutputs([
            profileDevice(id: 2, uid: original.uid, name: original.name, channels: 2)
        ])
        pumpMainRunLoop()

        XCTAssertTrue(editor.isAvailable)
        XCTAssertFalse(editor.canSave)
        XCTAssertTrue(editor.validationMessage?.contains("saved channel assignment is unavailable") == true)
        XCTAssertEqual(editor.leftChannel, 3)
        XCTAssertEqual(editor.rightChannel, 4)
        XCTAssertEqual(editor.leftChannelOptions, [1, 2, 3])
        XCTAssertEqual(editor.channelOptionLabel(3), "Unavailable (channel 3)")

        editor.selectLeftChannel(1)
        editor.selectRightChannel(2)
        XCTAssertTrue(editor.canSave)
        XCTAssertTrue(editor.save())
        XCTAssertEqual(context.profiles.profile(for: original.uid)?.outputChannels, .init(left: 1, right: 2))
    }

    func testOutputEditorDisconnectInvalidatesDraftWithoutSavingIt() throws {
        let context = try ManagementContext()
        let interface = profileDevice(id: 1, uid: "interface", name: "Interface", channels: 4)
        context.profiles.updateAvailableOutputs([interface])
        let editor = ConfigureOutputCoordinator(
            deviceUID: interface.uid,
            deviceName: interface.name,
            profiles: context.profiles
        )
        editor.selectLeftChannel(4)
        editor.selectRightChannel(2)
        context.profiles.updateAvailableOutputs([])
        pumpMainRunLoop()

        XCTAssertFalse(editor.isAvailable)
        XCTAssertFalse(editor.canSave)
        XCTAssertEqual(editor.leftChannel, 4)
        XCTAssertEqual(editor.rightChannel, 2)
        XCTAssertTrue(editor.validationMessage?.contains("Device unavailable") == true)
        XCTAssertNil(context.profiles.profile(for: interface.uid))
        editor.cancel()
        XCTAssertTrue(context.profiles.profiles.isEmpty)
    }

    func testOutputEditorRejectsDuplicateChannelsAndUsesFallbackWhenPreferenceIsInvalid() throws {
        let context = try ManagementContext()
        let interface = profileDevice(
            id: 1,
            uid: "interface",
            name: "Interface",
            channels: 4,
            preferredStereoChannels: .init(left: 3, right: 3)
        )
        context.profiles.updateAvailableOutputs([interface])
        let editor = ConfigureOutputCoordinator(
            deviceUID: interface.uid,
            deviceName: interface.name,
            profiles: context.profiles
        )

        XCTAssertEqual(editor.leftChannel, 1)
        XCTAssertEqual(editor.rightChannel, 2)
        editor.selectRightChannel(1)
        XCTAssertFalse(editor.canSave)
        XCTAssertTrue(editor.validationMessage?.contains("different channel numbers") == true)
        editor.selectRightChannel(4)
        XCTAssertTrue(editor.canSave)
        editor.cancel()
        XCTAssertNil(context.profiles.profile(for: interface.uid))
    }

    func testActionEnabledStatesMatchProfileAndCurrentStatus() throws {
        let context = try ManagementContext()
        seedProfile(context.profiles, profileDevice(id: 1, uid: "blank", name: "Blank"))
        context.date = context.date.addingTimeInterval(1)
        seedProfile(context.profiles, profileDevice(id: 2, uid: "current", name: "Current"))

        let rows = context.coordinator().rows
        let current = try XCTUnwrap(rows.first { $0.id == "current" })
        let blank = try XCTUnwrap(rows.first { $0.id == "blank" })
        XCTAssertFalse(current.canReset)
        XCTAssertFalse(current.canForget)
        XCTAssertFalse(blank.canReset)
        XCTAssertTrue(blank.canForget)
    }

    func testResetConfirmationCancelAndConfirmUseExpectedCopyAndOneManagerCall() throws {
        let context = try ManagementContext()
        seedProfile(context.profiles, profileDevice(id: 1, uid: "remembered", name: "Studio DAC"))
        context.profiles.setHRIRPresetID(UUID())
        context.date = context.date.addingTimeInterval(1)
        seedProfile(context.profiles, profileDevice(id: 2, uid: "current", name: "Current"))
        var resetCalls: [String] = []
        let coordinator = context.coordinator(resetOperation: { uid in
            resetCalls.append(uid)
            return true
        })

        coordinator.requestReset(deviceUID: "remembered")
        XCTAssertEqual(coordinator.pendingConfirmation, .init(
            action: .reset,
            deviceUID: "remembered",
            deviceName: "Studio DAC",
            title: "Reset Studio DAC profile?",
            message: "HRIR, EQ, and the saved output channel assignment will be cleared.",
            destructiveButtonTitle: "Reset Profile"
        ))
        coordinator.cancelConfirmation()
        XCTAssertNil(coordinator.pendingConfirmation)
        XCTAssertTrue(resetCalls.isEmpty)

        coordinator.requestReset(deviceUID: "remembered")
        XCTAssertTrue(coordinator.confirmPendingAction())
        XCTAssertEqual(resetCalls, ["remembered"])
        XCTAssertNil(coordinator.pendingConfirmation)
    }

    func testForgetConfirmationUsesExpectedCopyAndManagerCallWithoutResultFeedback() throws {
        let context = try ManagementContext()
        seedProfile(context.profiles, profileDevice(id: 1, uid: "remembered", name: "Studio DAC"))
        context.date = context.date.addingTimeInterval(1)
        seedProfile(context.profiles, profileDevice(id: 2, uid: "current", name: "Current"))
        var forgetCalls: [String] = []
        let coordinator = context.coordinator(forgetOperation: { uid in
            forgetCalls.append(uid)
            return true
        })

        coordinator.requestForget(deviceUID: "remembered")
        XCTAssertEqual(coordinator.pendingConfirmation, .init(
            action: .forget,
            deviceUID: "remembered",
            deviceName: "Studio DAC",
            title: "Forget Studio DAC?",
            message: "A connected device stays listed. A profile is created when you save an output assignment or choose a preset.",
            destructiveButtonTitle: "Forget Device"
        ))
        XCTAssertTrue(coordinator.confirmPendingAction())
        XCTAssertEqual(forgetCalls, ["remembered"])
        XCTAssertNil(coordinator.pendingConfirmation)
    }

    func testHRIRSettingsCoordinatorSuppressesSuccessfulActionsAndSkippedImports() async throws {
        let context = try ManagementContext()
        let source = context.root.appendingPathComponent("Room.wav")
        try writeTestWAV(to: source)
        await context.hrir.waitForLibrarySync()
        let coordinator = PresetLibraryCoordinator(manager: context.hrir, configuration: .hrir)

        coordinator.receive([source])
        await coordinator.waitForIdle()
        let imported = try XCTUnwrap(context.hrir.presets.first)
        XCTAssertNil(coordinator.message)

        coordinator.receive([source])
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.conflicts, [source])
        coordinator.resolveConflicts(.keepExisting)
        await coordinator.waitForIdle()
        XCTAssertNil(coordinator.message)

        XCTAssertTrue(coordinator.delete(context.hrir.libraryDeletion(for: imported), decision: .confirm))
        XCTAssertNil(coordinator.message)
    }

    func testHRIRSettingsCoordinatorRetainsImportFailures() async throws {
        let context = try ManagementContext()
        let invalid = context.root.appendingPathComponent("broken.txt")
        try Data("not a WAV\n".utf8).write(to: invalid)
        await context.hrir.waitForLibrarySync()
        let coordinator = PresetLibraryCoordinator(manager: context.hrir, configuration: .hrir)

        coordinator.receive([invalid])
        await coordinator.waitForIdle()

        XCTAssertTrue(coordinator.message?.text.contains("broken.txt") == true)
        XCTAssertTrue(coordinator.message?.text.contains("WAV") == true)
    }

    func testCurrentForgetIsDisabledAndCannotCreateConfirmation() throws {
        let context = try ManagementContext()
        seedProfile(context.profiles, profileDevice(id: 1, uid: "current", name: "Current"))
        let coordinator = context.coordinator()

        XCTAssertFalse(try XCTUnwrap(coordinator.rows.first).canForget)
        coordinator.requestForget(deviceUID: "current")

        XCTAssertNil(coordinator.pendingConfirmation)
    }

    func testEmptyStateHasNoRowsAndUsefulGuidanceModelInput() throws {
        let context = try ManagementContext()
        XCTAssertTrue(context.coordinator().rows.isEmpty)
    }
}

@MainActor
private func waitForInitialHRIRSync(_ manager: HRIRManager) async {
    await manager.waitForLibrarySync()
}

@MainActor
private final class ManagementContext {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let profiles: DeviceProfileManager
    let hrir: HRIRManager
    let equalizer: EqualizerManager
    private let clock: ManagementClock

    var date: Date {
        get { clock.value }
        set { clock.value = newValue }
    }

    init() throws {
        let clock = ManagementClock()
        self.clock = clock
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "DeviceProfileManagementTests.\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        profiles = DeviceProfileManager(defaults: defaults, now: { clock.value })
        hrir = HRIRManager(presetsDirectory: root.appendingPathComponent("hrir"), startWatcher: false)
        equalizer = EqualizerManager(managedDirectory: root.appendingPathComponent("eq"))
    }

    func coordinator(
        resetOperation: ((String) -> Bool)? = nil,
        forgetOperation: ((String) -> Bool)? = nil
    ) -> DeviceManagementCoordinator {
        DeviceManagementCoordinator(
            profileManager: profiles,
            hrirManager: hrir,
            equalizerManager: equalizer,
            resetOperation: resetOperation,
            forgetOperation: forgetOperation
        )
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ManagementClock {
    var value = Date(timeIntervalSince1970: 1_700_000_000)
}

extension DeviceProfileManagementTests {
    func testRowsCacheRebuildsWhenProfilesChange() throws {
        let context = try ManagementContext()
        seedProfile(context.profiles, profileDevice(id: 1, uid: "current", name: "Current"))
        let coordinator = context.coordinator()
        XCTAssertEqual(coordinator.rows.map(\.id), ["current"])

        seedProfile(context.profiles, profileDevice(id: 2, uid: "usb", name: "USB"))
        context.profiles.updateAvailableOutputs([
            profileDevice(id: 1, uid: "current", name: "Current"),
            profileDevice(id: 2, uid: "usb", name: "USB")
        ])
        pumpMainRunLoop()

        XCTAssertEqual(Set(coordinator.rows.map(\.id)), ["current", "usb"])
    }

    func testForgettingAvailableDeviceKeepsItsLiveTargetRow() throws {
        let context = try ManagementContext()
        seedProfile(context.profiles, profileDevice(id: 1, uid: "current", name: "Current"))
        seedProfile(context.profiles, profileDevice(id: 2, uid: "usb", name: "USB"))
        context.profiles.observeCurrentOutput(profileDevice(id: 1, uid: "current", name: "Current"))
        let coordinator = context.coordinator()
        pumpMainRunLoop()
        XCTAssertTrue(coordinator.rows.contains { $0.id == "usb" })

        coordinator.requestForget(deviceUID: "usb")
        XCTAssertTrue(coordinator.confirmPendingAction())

        let row = try XCTUnwrap(coordinator.rows.first { $0.id == "usb" })
        XCTAssertTrue(row.canConfigureOutput)
        XCTAssertFalse(row.canForget)
        XCTAssertNil(context.profiles.profile(for: "usb"))
    }
}

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testShowingSetupKeepsReturnAffordanceOnlyWhenAllowed() {
        let state = SettingsWindowContentState()
        XCTAssertEqual(state.mode, .settings)

        state.show(.setup, canReturnToSettings: true)
        XCTAssertEqual(state.mode, .setup)
        XCTAssertTrue(state.canReturnToSettings)

        state.show(.setup, canReturnToSettings: false)
        XCTAssertFalse(state.canReturnToSettings)
    }

    func testReturningToSettingsResetsThePageAndClearsTheReturnAffordance() {
        let state = SettingsWindowContentState()
        state.selectSettingsPage(.devices)
        state.show(.setup, canReturnToSettings: true)

        state.show(.settings)

        XCTAssertEqual(state.mode, .settings)
        XCTAssertEqual(state.settingsPage, .general)
        XCTAssertFalse(state.canReturnToSettings)
    }

    func testSelectingAPageLeavesTheModeAlone() {
        let state = SettingsWindowContentState()
        state.selectSettingsPage(.equalizer)

        XCTAssertEqual(state.settingsPage, .equalizer)
        XCTAssertEqual(state.mode, .settings)
    }
}

/// The rows cache rebuilds on the next run-loop turn (objectWillChange fires
/// before the change lands), so tests drain the main run loop.
@MainActor
private func pumpMainRunLoop() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

private func profileDevice(
    id: UInt64,
    uid: String,
    name: String,
    transport: String = "built",
    virtual: Bool = false,
    aggregate: Bool = false,
    channels: Int = 2,
    channelLabels: [UInt32]? = nil,
    preferredStereoChannels: StereoOutputChannels? = nil
) -> OutputDeviceDescriptor {
    OutputDeviceDescriptor(
        id: .init(id), uid: uid, name: name, transport: transport,
        channelLabels: channelLabels, outputChannelCount: channels, nominalSampleRate: 48_000,
        isVirtual: virtual, isAggregate: aggregate,
        preferredStereoChannels: preferredStereoChannels
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

private func writeTestWAV(to url: URL) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
    buffer.frameLength = 1
    buffer.floatChannelData?[0][0] = 0
    buffer.floatChannelData?[1][0] = 0
    try file.write(from: buffer)
}
