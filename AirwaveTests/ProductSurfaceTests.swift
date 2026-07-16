import AppKit
import XCTest
@testable import Airwave

@MainActor
final class ProductSurfaceTests: XCTestCase {
    func testSettingsWindowContentStateSwitchesModesAndLimitsSetupExit() {
        let state = SettingsWindowContentState()
        XCTAssertEqual(state.mode, .settings)
        XCTAssertFalse(state.canReturnToSettings)
        XCTAssertEqual(state.settingsPage, .general)

        state.selectSettingsPage(.equalizer)
        XCTAssertEqual(state.settingsPage, .equalizer)

        state.show(.setup)
        XCTAssertEqual(state.mode, .setup)
        XCTAssertFalse(state.canReturnToSettings)

        state.show(.setup, canReturnToSettings: true)
        XCTAssertTrue(state.canReturnToSettings)

        state.show(.settings, canReturnToSettings: true)
        XCTAssertEqual(state.mode, .settings)
        XCTAssertFalse(state.canReturnToSettings)
        XCTAssertEqual(state.settingsPage, .general)
    }

    func testSettingsSurfaceUsesOneWindowAndOneSharedMenuBarViewModelPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegate = try String(
            contentsOf: root.appendingPathComponent("Airwave/AppDelegate.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appendingPathComponent("Airwave/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(appDelegate.components(separatedBy: "let content = SettingsWindowContent(state: contentState)").count - 1, 1)
        XCTAssertEqual(appDelegate.components(separatedBy: ".environmentObject(MenuBarViewModel.shared)").count - 1, 1)
        XCTAssertTrue(settings.contains("SettingsPage.allCases"))
        XCTAssertTrue(settings.contains("transition(.opacity)"))
        XCTAssertTrue(settings.contains("accessibilityReduceMotion"))
    }

    func testEqualizerSettingsLibraryRowsKeepNoneFirstAndPreserveManagerOrder() throws {
        let context = try EqualizerSettingsTestContext()
        let zulu = try context.writePreset(named: "Zulu.txt", preamp: 2)
        let alpha = try context.writePreset(named: "Alpha.txt", preamp: 1)
        let imported = context.manager.importPresets([zulu, alpha], collisionPolicy: .reject).imported

        let rows = EqualizerSettingsLibraryModel.rows(
            presets: context.manager.presets,
            selection: .none
        )
        XCTAssertEqual(rows.map(\.name), ["None", "Alpha", "Zulu"])
        XCTAssertTrue(rows.first?.isSelected == true)
        XCTAssertFalse(rows.dropFirst().contains(where: { $0.isSelected }))
        XCTAssertEqual(imported.map(\.displayName), ["Zulu", "Alpha"])
    }

    func testEqualizerSettingsDetailShowsNoneAndReferencePresetIncludingMutedRows() throws {
        let context = try EqualizerSettingsTestContext()
        let source = try context.writePreset(named: "Reference.txt", contents: """
            Preamp: -2.56 dB
            Filter 1: ON LSC Fc 105.0 Hz Gain -2.8 dB Q 0.70
            Filter 2: OFF PK Fc 440.0 Hz Gain 1.0 dB Q 1.00
            Filter 3: ON HSC Fc 10000.0 Hz Gain -5.2 dB Q 0.70
            """)
        let preset = try XCTUnwrap(
            context.manager.importPresets([source], collisionPolicy: .reject).imported.first
        )

        let none = EqualizerSettingsDetailModel(preset: nil)
        XCTAssertTrue(none.isBypassed)
        XCTAssertEqual(none.title, "Equalizer bypassed")

        let detail = EqualizerSettingsDetailModel(preset: preset)
        XCTAssertFalse(detail.isBypassed)
        XCTAssertEqual(detail.title, "Reference")
        XCTAssertEqual(detail.filename, "Reference.txt")
        XCTAssertEqual(detail.preamp, "-2.56 dB")
        XCTAssertEqual(detail.filters.map(\.state), ["ON", "OFF", "ON"])
        XCTAssertEqual(detail.filters.map(\.type), ["LSC", "PK", "HSC"])
        XCTAssertEqual(detail.filters[1].frequency, "440.0 Hz")
        XCTAssertTrue(detail.filters[1].isMuted)
    }

    func testEqualizerSettingsCoordinatorImportsInInputOrderAndReportsLineErrors() throws {
        let context = try EqualizerSettingsTestContext()
        let first = try context.writePreset(named: "First.txt", preamp: 1)
        let invalid = try context.writePreset(named: "Broken.txt", contents: "Filter 1: ???\n")
        let second = try context.writePreset(named: "Second.txt", preamp: 2)
        let coordinator = EqualizerSettingsCoordinator(manager: context.manager)

        coordinator.receive([first, invalid, second])

        XCTAssertEqual(context.manager.selectedPreset?.displayName, "First")
        XCTAssertEqual(context.manager.presets.map(\.displayName), ["First", "Second"])
        XCTAssertTrue(coordinator.message?.text.contains("Broken.txt") == true)
        XCTAssertTrue(coordinator.message?.text.contains("line 1") == true)
    }

    func testEqualizerSettingsCoordinatorConflictChoicesPartialSuccessAndZeroSuccessPreserveSelection() throws {
        let context = try EqualizerSettingsTestContext()
        let existingSource = try context.writePreset(named: "Existing.txt", preamp: 1)
        let existing = try XCTUnwrap(
            context.manager.importPresets([existingSource], collisionPolicy: .reject).imported.first
        )
        context.manager.select(.preset(existing.id))
        let replacement = try context.writePreset(named: "Existing.txt", preamp: 2)
        let added = try context.writePreset(named: "Added.txt", preamp: 3)
        let invalid = try context.writePreset(named: "Broken.txt", contents: "not supported\n")
        let coordinator = EqualizerSettingsCoordinator(manager: context.manager)

        coordinator.receive([replacement, added])
        XCTAssertEqual(coordinator.conflicts.map(\.lastPathComponent), ["Existing.txt"])
        coordinator.resolveConflicts(.keepExisting)
        XCTAssertEqual(context.manager.selectedPreset?.displayName, "Added")
        XCTAssertEqual(context.manager.selectedDefinition?.preampDB, 3)

        context.manager.select(.preset(existing.id))
        coordinator.receive([replacement])
        coordinator.resolveConflicts(.replace)
        XCTAssertEqual(context.manager.selection, .preset(existing.id))
        XCTAssertEqual(context.manager.selectedDefinition?.preampDB, 2)

        coordinator.receive([invalid])
        XCTAssertEqual(context.manager.selection, .preset(existing.id))
        coordinator.dismissMessage()
        XCTAssertNil(coordinator.message)
    }

    func testEqualizerSettingsCoordinatorDeletionRequiresConfirmationAndActiveDeletionSelectsNone() throws {
        let context = try EqualizerSettingsTestContext()
        let source = try context.writePreset(named: "Curve.txt", preamp: 1)
        let preset = try XCTUnwrap(
            context.manager.importPresets([source], collisionPolicy: .reject).imported.first
        )
        context.manager.select(.preset(preset.id))
        let coordinator = EqualizerSettingsCoordinator(manager: context.manager)

        XCTAssertFalse(coordinator.delete(preset, decision: .cancel))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preset.fileURL.path))
        XCTAssertTrue(coordinator.delete(preset, decision: .confirm))
        XCTAssertEqual(context.manager.selection, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preset.fileURL.path))
    }

    func testEqualizerSettingsCoordinatorPreservesSelectionWhenDeletionFailsAndDeletesInactivePreset() throws {
        let context = try EqualizerSettingsTestContext()
        let activeSource = try context.writePreset(named: "Active.txt", preamp: 1)
        let inactiveSource = try context.writePreset(named: "Inactive.txt", preamp: 2)
        let imported = context.manager.importPresets([activeSource, inactiveSource], collisionPolicy: .reject).imported
        let active = try XCTUnwrap(imported.first(where: { $0.displayName == "Active" }))
        let inactive = try XCTUnwrap(imported.first(where: { $0.displayName == "Inactive" }))
        context.manager.select(.preset(active.id))
        let coordinator = EqualizerSettingsCoordinator(manager: context.manager)

        let invalidCopy = EqualizerPreset(
            id: active.id,
            displayName: active.displayName,
            fileURL: URL(fileURLWithPath: "/tmp/not-managed.txt"),
            definition: active.definition
        )
        XCTAssertFalse(coordinator.delete(invalidCopy, decision: .confirm))
        XCTAssertEqual(context.manager.selection, .preset(active.id))
        XCTAssertTrue(context.manager.presets.contains(active))

        XCTAssertTrue(coordinator.delete(inactive, decision: .confirm))
        XCTAssertEqual(context.manager.selection, .preset(active.id))
        XCTAssertFalse(context.manager.presets.contains(inactive))
    }

    func testEqualizerSettingsUsesManagedFinderTargetAndDoesNotExposeExternalPaths() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Airwave/EqualizerSettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("activateFileViewerSelecting([manager.managedDirectory])"))
        XCTAssertTrue(source.contains("Drop EqualizerAPO .txt presets"))
        XCTAssertTrue(source.contains("UTType(filenameExtension: \"txt\")"))
        XCTAssertTrue(source.contains("coordinator.conflicts.count"))
        XCTAssertTrue(source.contains("resolveConflicts(.replace)"))
        XCTAssertTrue(source.contains("resolveConflicts(.keepExisting)"))
    }

    func testMenuBarVisibilityDefaultsOffAndPersists() throws {
        let suite = "MenuVisibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var visibilityChanges = 0
        let first = MenuBarVisibilityManager(defaults: defaults) { visibilityChanges += 1 }
        XCTAssertFalse(first.isVisible)
        first.isVisible = true
        XCTAssertEqual(visibilityChanges, 1)
        XCTAssertTrue(MenuBarVisibilityManager(defaults: defaults, visibilityDidChange: {}).isVisible)
        first.isVisible = false
        XCTAssertEqual(visibilityChanges, 2)
        XCTAssertFalse(MenuBarVisibilityManager(defaults: defaults, visibilityDidChange: {}).isVisible)
    }

    func testLifecyclePolicyUsesDockWheneverUserWindowIsVisible() {
        XCTAssertEqual(
            ApplicationLifecycleCoordinator.activationPolicy(hasVisibleUserWindow: false),
            .accessory
        )
        XCTAssertEqual(
            ApplicationLifecycleCoordinator.activationPolicy(hasVisibleUserWindow: true),
            .regular
        )
    }

    func testLifecycleDoesNotReapplyUnchangedPolicy() {
        let application = LifecycleApplicationFake()
        let lifecycle = ApplicationLifecycleCoordinator(application: application, observeWindows: false)

        lifecycle.updateActivationPolicy(hasVisibleUserWindow: true)
        lifecycle.updateActivationPolicy(hasVisibleUserWindow: true)
        lifecycle.prepareToPresentUserWindow()
        XCTAssertEqual(application.policies, [.regular])

        lifecycle.updateActivationPolicy(hasVisibleUserWindow: false)
        lifecycle.updateActivationPolicy(hasVisibleUserWindow: false)
        XCTAssertEqual(application.policies, [.regular, .accessory])
    }

    func testMiniaturizedSettingsWindowRemainsUserFacing() {
        let window = MiniaturizedWindowFake()
        window.identifier = SettingsWindowPresenter.windowIdentifier

        XCTAssertTrue(window.isMiniaturized)
        XCTAssertTrue(ApplicationLifecycleCoordinator.isUserFacingWindow(window))
    }

    func testOrdinaryQuitCancelsTerminationWhileExplicitAndSystemQuitProceed() {
        let ordinaryApplication = LifecycleApplicationFake()
        let ordinary = ApplicationLifecycleCoordinator(
            application: ordinaryApplication,
            observeWindows: false
        )
        XCTAssertEqual(ordinary.terminationReply(), .terminateCancel)
        XCTAssertEqual(ordinaryApplication.policies.last, .accessory)

        let explicitApplication = LifecycleApplicationFake()
        let explicit = ApplicationLifecycleCoordinator(
            application: explicitApplication,
            observeWindows: false
        )
        explicit.requestExplicitQuit()
        XCTAssertEqual(explicitApplication.terminateCount, 1)
        XCTAssertEqual(explicit.terminationReply(), .terminateNow)

        let system = ApplicationLifecycleCoordinator(
            application: LifecycleApplicationFake(),
            observeWindows: false
        )
        system.beginSystemTermination()
        XCTAssertEqual(system.terminationReply(), .terminateNow)
    }

    func testHRIRImportCopiesSourceAndPreservesIdentityOnReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = source.appendingPathComponent("Room.WAV")
        let firstBytes = wavFixture(frames: 8)
        try firstBytes.write(to: input)
        let manager = HRIRManager(presetsDirectory: managed, startWatcher: false)

        let first = manager.importPresets([input], collisionPolicy: .reject)
        XCTAssertEqual(first.imported.count, 1)
        XCTAssertEqual(try Data(contentsOf: input), firstBytes)
        let originalID = try XCTUnwrap(first.imported.first?.id)

        let replacementBytes = wavFixture(frames: 12)
        try replacementBytes.write(to: input)
        let replacement = manager.importPresets([input], collisionPolicy: .replace)
        XCTAssertEqual(replacement.imported.first?.id, originalID)
        XCTAssertEqual(try Data(contentsOf: input), replacementBytes)
        XCTAssertEqual(try Data(contentsOf: managed.appendingPathComponent("Room.WAV")), replacementBytes)
    }

    func testHRIRImportPreflightAndPartialSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid.wav")
        let invalid = root.appendingPathComponent("notes.txt")
        try wavFixture(frames: 8).write(to: valid)
        try Data("nope".utf8).write(to: invalid)
        let manager = HRIRManager(presetsDirectory: managed, startWatcher: false)
        let preflight = manager.preflightImport([invalid, valid])
        XCTAssertEqual(preflight.acceptable, [valid])
        XCTAssertEqual(preflight.rejected.count, 1)
        let result = manager.importPresets([invalid, valid], collisionPolicy: .reject)
        XCTAssertEqual(result.imported.map(\.name), ["valid"])
        XCTAssertEqual(result.failures.count, 1)
    }
    func testSchemaV2ResetRemovesLegacyDefaultsDisablesLoginOnceAndPreservesHRIRFixture() throws {
        let suite = "ProductSurfaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsSchemaV2Migrator.legacyKeys.forEach { defaults.set(Data([1, 2, 3]), forKey: $0) }
        let login = LoginResetFake()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hrir = directory.appendingPathComponent("fixture.wav")
        let fixture = Data([82, 73, 70, 70, 9, 8, 7])
        try fixture.write(to: hrir)

        let migrator = SettingsSchemaV2Migrator(defaults: defaults, launchAtLogin: login)
        XCTAssertTrue(try migrator.migrateIfNeeded())
        XCTAssertEqual(login.disableCount, 1)
        XCTAssertTrue(SettingsSchemaV2Migrator.legacyKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        XCTAssertEqual(try Data(contentsOf: hrir), fixture)

        XCTAssertFalse(try migrator.migrateIfNeeded())
        XCTAssertEqual(login.disableCount, 1)
        XCTAssertEqual(try Data(contentsOf: hrir), fixture)
    }

    func testLaunchAtLoginResetUsesInjectedAdapterAndDefaultsOff() throws {
        let adapter = LoginAdapterFake(enabled: true)
        let manager = LaunchAtLoginManager(adapter: adapter)
        try manager.disableForSchemaReset()
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(adapter.unregisterCount, 1)
        try manager.disableForSchemaReset()
        XCTAssertEqual(adapter.unregisterCount, 1)
    }

    func testPermissionPresentationCoversUnknownRequestingSuccessDeniedSettingsRetryAndRevocation() {
        let runtime = AudioRuntimeState(status: .inactive)
        let actions = RuntimeActionsFake()
        let persistence = OnboardingPersistenceFake()
        let viewModel = OnboardingViewModel(
            runtime: runtime, actions: actions, persistence: persistence
        )
        XCTAssertEqual(viewModel.permissionPresentation, .unknown)

        viewModel.requestPermission()
        XCTAssertEqual(actions.requestCount, 1)
        XCTAssertEqual(viewModel.permissionPresentation, .unknown)
        runtime.publish(.starting, output: output())
        XCTAssertEqual(viewModel.permissionPresentation, .requesting)
        runtime.publish(.inactive, output: output())
        XCTAssertEqual(viewModel.permissionPresentation, .granted)
        runtime.publish(.needsPermission, output: output())
        XCTAssertEqual(viewModel.permissionPresentation, .denied)

        viewModel.openPermissionSettings()
        viewModel.retry()
        XCTAssertEqual(actions.settingsCount, 1)
        XCTAssertEqual(actions.retryCount, 1)
    }

    func testPermissionPresentationDoesNotTreatEffectStartupAsPermissionRequest() {
        let runtime = AudioRuntimeState(status: .starting)
        let viewModel = OnboardingViewModel(
            runtime: runtime,
            actions: RuntimeActionsFake(),
            persistence: OnboardingPersistenceFake()
        )

        XCTAssertEqual(viewModel.permissionPresentation, .unknown)

        runtime.publish(.recovering(reason: "Audio processing stopped safely."))

        XCTAssertEqual(viewModel.permissionPresentation, .unknown)
    }

    func testPermissionFocusRestoresOnceAfterSuccessAndDenial() {
        for resolvedStatus in [AudioRuntimeState.Status.processing, .needsPermission] {
            let runtime = AudioRuntimeState(status: .inactive)
            let focus = PermissionFocusRestorerFake()
            let viewModel = OnboardingViewModel(
                runtime: runtime,
                actions: RuntimeActionsFake(),
                persistence: OnboardingPersistenceFake(),
                focusRestorer: focus
            )

            viewModel.requestPermission()
            XCTAssertEqual(focus.beginCount, 1)
            runtime.publish(.starting, output: output())
            runtime.publish(resolvedStatus, output: output())
            runtime.publish(resolvedStatus, output: output())
            XCTAssertEqual(focus.resolveCount, 1)
        }
    }

    func testNewPermissionRequestSupersedesPendingFocusRestoration() {
        let runtime = AudioRuntimeState(status: .inactive)
        let focus = PermissionFocusRestorerFake()
        let viewModel = OnboardingViewModel(
            runtime: runtime,
            actions: RuntimeActionsFake(),
            persistence: OnboardingPersistenceFake(),
            focusRestorer: focus
        )

        viewModel.requestPermission()
        viewModel.requestPermission()
        runtime.publish(.starting, output: output())
        runtime.publish(.needsPermission, output: output())
        XCTAssertEqual(focus.beginCount, 2)
        XCTAssertEqual(focus.resolveCount, 1)
    }

    func testPermissionFocusRestorerIgnoresClosedWindow() {
        let window = NSWindow()
        var restoreCount = 0
        let restorer = PermissionWindowFocusRestorer(
            captureWindow: { window },
            restoreWindow: { _ in restoreCount += 1 }
        )

        restorer.beginPermissionRequest()
        restorer.permissionRequestResolved()
        restorer.permissionRequestResolved()
        XCTAssertEqual(restoreCount, 0)
    }

    func testFreshAndV1UpgradeBothStartAtUnskippableWelcomeCheckpoint() throws {
        for isUpgrade in [false, true] {
            let suite = "OnboardingUpgrade.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if isUpgrade {
                defaults.set(1, forKey: "Airwave.Onboarding.Version")
                defaults.set("completion", forKey: "Airwave.Onboarding.Checkpoint")
                defaults.set(true, forKey: "Airwave.Onboarding.Completed")
                _ = try SettingsSchemaV2Migrator(defaults: defaults, launchAtLogin: LoginResetFake()).migrateIfNeeded()
            }
            let persistence = UserDefaultsOnboardingPersistenceV2(defaults: defaults)
            XCTAssertEqual(persistence.version, 2)
            XCTAssertEqual(persistence.checkpoint, .welcome)
            XCTAssertFalse(persistence.isComplete)
        }
    }

    func testUnsupportedOutputStillCannotCompleteWithoutPublicGuidance() {
        let virtual = output(name: "BlackHole", virtual: true)
        let runtime = AudioRuntimeState(
            status: .nativePassthrough(reason: "Change output in macOS Settings."),
            currentOutput: virtual
        )
        let viewModel = OnboardingViewModel(
            runtime: runtime,
            actions: RuntimeActionsFake(),
            persistence: OnboardingPersistenceFake()
        )
        XCTAssertFalse(viewModel.canComplete)
    }

    func testCompletionAllowsNoneWithGrantedPermissionAndSupportedOutput() {
        let runtime = AudioRuntimeState(status: .processing, currentOutput: output())
        let persistence = OnboardingPersistenceFake()
        let viewModel = OnboardingViewModel(
            runtime: runtime,
            actions: RuntimeActionsFake(),
            persistence: persistence
        )
        XCTAssertTrue(viewModel.complete())
        XCTAssertTrue(persistence.isComplete)

        let probedRuntime = AudioRuntimeState(status: .inactive, currentOutput: output())
        let probed = OnboardingViewModel(
            runtime: probedRuntime,
            actions: RuntimeActionsFake(),
            persistence: OnboardingPersistenceFake()
        )
        probed.requestPermission()
        probedRuntime.publish(.starting, output: output())
        probedRuntime.publish(.inactive, output: output())
        XCTAssertTrue(probed.canComplete)
        XCTAssertTrue(probed.isConfigurationHealthy)
        XCTAssertFalse(probed.needsSetupAttention)
    }

    func testFinishLaterSuppressesRelaunchPromptUntilExplicitResume() {
        let persistence = OnboardingPersistenceFake()
        let first = OnboardingViewModel(
            runtime: AudioRuntimeState(), actions: RuntimeActionsFake(),
            persistence: persistence
        )
        XCTAssertTrue(first.shouldPresentAutomatically)
        first.advance()
        first.finishLater()
        XCTAssertTrue(first.shouldShowSetupMenuItem)

        let relaunched = OnboardingViewModel(
            runtime: AudioRuntimeState(), actions: RuntimeActionsFake(),
            persistence: persistence
        )
        XCTAssertFalse(relaunched.shouldPresentAutomatically)
        XCTAssertEqual(relaunched.currentStep, .systemAudio)
        relaunched.resume()
        XCTAssertTrue(relaunched.shouldPresentAutomatically)
    }

    func testOnboardingProgressAllowsDirectStepSelectionAndPersistsCheckpoint() {
        let persistence = OnboardingPersistenceFake()
        let viewModel = OnboardingViewModel(
            runtime: AudioRuntimeState(), actions: RuntimeActionsFake(),
            persistence: persistence
        )

        viewModel.selectStep(.liveHealth)
        XCTAssertEqual(viewModel.currentStep, .liveHealth)
        XCTAssertEqual(persistence.checkpoint, .liveHealth)
        viewModel.selectStep(.systemAudio)
        XCTAssertEqual(viewModel.currentStep, .systemAudio)
        XCTAssertEqual(persistence.checkpoint, .systemAudio)
    }

    func testAutomaticPresentationAlwaysStartsAtWelcome() {
        let persistence = OnboardingPersistenceFake()
        persistence.checkpoint = .liveHealth
        let viewModel = OnboardingViewModel(
            runtime: AudioRuntimeState(status: .processing, currentOutput: output()),
            actions: RuntimeActionsFake(), persistence: persistence
        )

        viewModel.prepareForPresentation(.automaticFirstSetup)

        XCTAssertEqual(viewModel.currentStep, .welcome)
        XCTAssertEqual(persistence.checkpoint, .welcome)
    }

    func testVoluntaryPresentationRoutesToFirstRelevantHealthStep() {
        let completedPersistence = OnboardingPersistenceFake()
        completedPersistence.checkpoint = .liveHealth
        completedPersistence.isComplete = true
        let healthy = OnboardingViewModel(
            runtime: AudioRuntimeState(status: .processing, currentOutput: output()),
            actions: RuntimeActionsFake(), persistence: completedPersistence
        )
        healthy.prepareForPresentation(.voluntary)
        XCTAssertEqual(healthy.currentStep, .welcome)
        XCTAssertFalse(healthy.needsSetupAttention)

        let missingPermission = OnboardingViewModel(
            runtime: AudioRuntimeState(status: .needsPermission, currentOutput: output()),
            actions: RuntimeActionsFake(), persistence: OnboardingPersistenceFake()
        )
        missingPermission.prepareForPresentation(.voluntary)
        XCTAssertEqual(missingPermission.currentStep, .systemAudio)
        XCTAssertTrue(missingPermission.needsSetupAttention)

        let inactiveAtBoot = OnboardingViewModel(
            runtime: AudioRuntimeState(status: .inactive),
            actions: RuntimeActionsFake(), persistence: OnboardingPersistenceFake()
        )
        inactiveAtBoot.prepareForPresentation(.voluntary)
        XCTAssertEqual(inactiveAtBoot.currentStep, .systemAudio)
        XCTAssertFalse(inactiveAtBoot.isConfigurationHealthy)
        XCTAssertTrue(inactiveAtBoot.needsSetupAttention)

        let unsupportedOutput = OnboardingViewModel(
            runtime: AudioRuntimeState(
                status: .nativePassthrough(reason: "Unsupported output"),
                currentOutput: output(virtual: true)
            ),
            actions: RuntimeActionsFake(), persistence: OnboardingPersistenceFake()
        )
        unsupportedOutput.prepareForPresentation(.voluntary)
        XCTAssertEqual(unsupportedOutput.currentStep, .liveHealth)
        XCTAssertTrue(unsupportedOutput.needsSetupAttention)
    }

    func testInactiveWithoutLiveProbeNeedsSetupRegardlessOfPersistedCompletion() {
        let freshViewModel = OnboardingViewModel(
            runtime: AudioRuntimeState(status: .inactive),
            actions: RuntimeActionsFake(), persistence: OnboardingPersistenceFake()
        )

        XCTAssertFalse(freshViewModel.canComplete)
        XCTAssertFalse(freshViewModel.isConfigurationHealthy)
        XCTAssertTrue(freshViewModel.needsSetupAttention)
        XCTAssertEqual(freshViewModel.recommendedVoluntaryEntryStep, .systemAudio)

        let completedPersistence = OnboardingPersistenceFake()
        completedPersistence.isComplete = true
        let completedViewModel = OnboardingViewModel(
            runtime: AudioRuntimeState(status: .inactive),
            actions: RuntimeActionsFake(), persistence: completedPersistence
        )

        XCTAssertEqual(completedViewModel.permissionPresentation, .unknown)
        XCTAssertFalse(completedViewModel.canComplete)
        XCTAssertTrue(completedViewModel.needsSetupAttention)
    }

    func testMenuPresentationMapsEveryRuntimeStateAndOnlyRetryableStatesExposeRetry() {
        let cases: [(AudioRuntimeState.Status, String, Bool)] = [
            (.unavailable("private reason"), "exclamationmark.waveform", false),
            (.inactive, "waveform.circle", false),
            (.needsPermission, "exclamationmark.waveform", true),
            (.nativePassthrough(reason: "private reason"), "exclamationmark.waveform", false),
            (.starting, "waveform.badge.plus", false),
            (.processing, "waveform.circle.fill", false),
            (.recovering(reason: "private reason"), "exclamationmark.waveform", true)
        ]
        for (status, statusIcon, retry) in cases {
            let presentation = RuntimeMenuPresentation.make(from: status)
            XCTAssertEqual(presentation.statusIconName, statusIcon)
            XCTAssertEqual(presentation.canRetry, retry)
            XCTAssertEqual(presentation.healthTitle, status.title)
            XCTAssertFalse(presentation.healthDetail.contains("private reason"))
        }
    }

    func testOnboardingTitlesKeepPersistedCasesWhileUsingNewCopy() {
        XCTAssertEqual(OnboardingStepV2.welcome.rawValue, "welcome")
        XCTAssertEqual(OnboardingStepV2.liveHealth.rawValue, "liveHealth")
        XCTAssertEqual(OnboardingStepV2.welcome.title, "Welcome")
        XCTAssertEqual(OnboardingStepV2.liveHealth.title, "Finish")
    }

    func testReadinessPresentationPrioritizesPermissionPresetAndGenericRuntimeCopy() {
        let permission = OnboardingReadinessPresentation.make(
            permission: .denied, hasPreset: false,
            runtimeStatus: .nativePassthrough(reason: "unsupported output"), isReady: false
        )
        XCTAssertEqual(permission.actionStep, .systemAudio)
        XCTAssertFalse(permission.detail.localizedCaseInsensitiveContains("output"))

        let preset = OnboardingReadinessPresentation.make(
            permission: .granted, hasPreset: false,
            runtimeStatus: .inactive, isReady: true
        )
        XCTAssertNil(preset.actionStep)
        XCTAssertTrue(preset.detail.contains("Choose an HRIR preset whenever"))

        let runtime = OnboardingReadinessPresentation.make(
            permission: .granted, hasPreset: true,
            runtimeStatus: .recovering(reason: "unsupported output"), isReady: false
        )
        XCTAssertNil(runtime.actionStep)
        XCTAssertTrue(runtime.canRetry)
        XCTAssertFalse(runtime.detail.localizedCaseInsensitiveContains("output"))

        let ready = OnboardingReadinessPresentation.make(
            permission: .granted, hasPreset: true,
            runtimeStatus: .processing, isReady: true
        )
        XCTAssertEqual(ready.title, "You’re ready to go")
        XCTAssertFalse(ready.canRetry)
    }

    func testMenuPresetsSortCaseInsensitively() {
        let presets = ["Zulu", "alpha", "Beta"].map {
            HRIRPreset(
                id: UUID(), name: $0,
                fileURL: URL(fileURLWithPath: "/tmp/\($0).wav"),
                channelCount: 14, sampleRate: 48_000
            )
        }
        XCTAssertEqual(MenuBarViewModel.sortedPresets(presets).map(\.name), ["alpha", "Beta", "Zulu"])
    }

    func testMenuPresetTargetRateUsesCurrentOutputWithSafeFallback() {
        let highRateOutput = OutputDeviceDescriptor(
            id: .init(7), uid: "studio", name: "Studio DAC", transport: "usb",
            outputChannelCount: 2, nominalSampleRate: 96_000,
            isVirtual: false, isAggregate: false
        )
        XCTAssertEqual(MenuBarViewModel.presetTargetSampleRate(for: highRateOutput), 96_000)
        XCTAssertEqual(MenuBarViewModel.presetTargetSampleRate(for: nil), 48_000)
    }
}

private func wavFixture(frames: Int) -> Data {
    let channels: UInt16 = 2
    let bits: UInt16 = 16
    let sampleRate: UInt32 = 48_000
    let dataSize = UInt32(frames) * UInt32(channels) * UInt32(bits / 8)
    var data = Data()
    func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
    func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    ascii("RIFF"); u32(36 + dataSize); ascii("WAVE")
    ascii("fmt "); u32(16); u16(1); u16(channels); u32(sampleRate)
    u32(sampleRate * UInt32(channels) * UInt32(bits / 8)); u16(channels * bits / 8); u16(bits)
    ascii("data"); u32(dataSize); data.append(Data(repeating: 0, count: Int(dataSize)))
    return data
}

@MainActor
private final class LifecycleApplicationFake: ApplicationLifecycleApplication {
    var policies: [NSApplication.ActivationPolicy] = []
    var windows: [NSWindow] = []
    var terminateCount = 0

    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        policies.append(activationPolicy)
        return true
    }

    func terminate(_ sender: Any?) {
        terminateCount += 1
    }
}

@MainActor
private final class MiniaturizedWindowFake: NSWindow {
    override var isMiniaturized: Bool { true }
}

@MainActor
private final class PermissionFocusRestorerFake: PermissionFocusRestoring {
    var beginCount = 0
    var resolveCount = 0
    func beginPermissionRequest() { beginCount += 1 }
    func permissionRequestResolved() { resolveCount += 1 }
}

@MainActor
private final class LoginResetFake: LaunchAtLoginResetting {
    var disableCount = 0
    func disableForSchemaReset() throws { disableCount += 1 }
}

@MainActor
private final class LoginAdapterFake: LoginItemAdapting {
    var isEnabled: Bool
    var registerCount = 0
    var unregisterCount = 0
    init(enabled: Bool) { isEnabled = enabled }
    func register() throws { registerCount += 1; isEnabled = true }
    func unregister() throws { unregisterCount += 1; isEnabled = false }
}

@MainActor
private final class RuntimeActionsFake: AudioRuntimeUserActions {
    var requestCount = 0
    var retryCount = 0
    var settingsCount = 0
    func requestSystemAudioAccess() { requestCount += 1 }
    func retryNow() { retryCount += 1 }
    func openSystemAudioRecordingSettings() { settingsCount += 1 }
}

private final class OnboardingPersistenceFake: OnboardingPersisting {
    var version = 2
    var checkpoint: OnboardingStepV2 = .welcome
    var isComplete = false
    var isDeferred = false
}

private func output(
    name: String = "Built-in Output",
    virtual: Bool = false,
    aggregate: Bool = false,
    channels: Int = 2
) -> OutputDeviceDescriptor {
    OutputDeviceDescriptor(
        id: .init(42), uid: "output", name: name, transport: virtual ? "virt" : "built",
        outputChannelCount: channels, nominalSampleRate: 48_000,
        isVirtual: virtual, isAggregate: aggregate
    )
}

@MainActor
private final class EqualizerSettingsTestContext {
    let root: URL
    let managed: URL
    let sourceDirectory: URL
    let defaults: UserDefaults
    let manager: EqualizerManager
    private let suiteName: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        managed = root.appendingPathComponent("Equalizer Presets", isDirectory: true)
        sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        suiteName = "EqualizerSettingsTestContext.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        manager = EqualizerManager(
            managedDirectory: managed,
            fileManager: .default,
            defaults: defaults
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func writePreset(named name: String, preamp: Double) throws -> URL {
        try writePreset(named: name, contents: "Preamp: \(preamp) dB\n")
    }

    func writePreset(named name: String, contents: String) throws -> URL {
        let url = sourceDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
