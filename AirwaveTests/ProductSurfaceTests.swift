import AppKit
import XCTest
@testable import Airwave

@MainActor
final class ProductSurfaceTests: XCTestCase {
    func testSettingsWindowContentStateSwitchesModesAndLimitsSetupExit() {
        let state = SettingsWindowContentState()
        XCTAssertEqual(state.mode, .settings)
        XCTAssertFalse(state.canReturnToSettings)

        state.show(.setup)
        XCTAssertEqual(state.mode, .setup)
        XCTAssertFalse(state.canReturnToSettings)

        state.show(.setup, canReturnToSettings: true)
        XCTAssertTrue(state.canReturnToSettings)

        state.show(.settings, canReturnToSettings: true)
        XCTAssertEqual(state.mode, .settings)
        XCTAssertFalse(state.canReturnToSettings)
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

    func testLifecyclePolicyUsesDockOnlyForHiddenMenuWithVisibleWindow() {
        XCTAssertEqual(
            ApplicationLifecycleCoordinator.activationPolicy(menuBarVisible: true, hasVisibleUserWindow: false),
            .accessory
        )
        XCTAssertEqual(
            ApplicationLifecycleCoordinator.activationPolicy(menuBarVisible: true, hasVisibleUserWindow: true),
            .accessory
        )
        XCTAssertEqual(
            ApplicationLifecycleCoordinator.activationPolicy(menuBarVisible: false, hasVisibleUserWindow: false),
            .accessory
        )
        XCTAssertEqual(
            ApplicationLifecycleCoordinator.activationPolicy(menuBarVisible: false, hasVisibleUserWindow: true),
            .regular
        )
    }

    func testOrdinaryQuitCancelsTerminationWhileExplicitAndSystemQuitProceed() {
        let ordinaryApplication = LifecycleApplicationFake()
        let ordinary = ApplicationLifecycleCoordinator(
            application: ordinaryApplication,
            isMenuBarVisible: { false },
            observeWindows: false
        )
        XCTAssertEqual(ordinary.terminationReply(), .terminateCancel)
        XCTAssertEqual(ordinaryApplication.policies.last, .accessory)

        let explicitApplication = LifecycleApplicationFake()
        let explicit = ApplicationLifecycleCoordinator(
            application: explicitApplication,
            isMenuBarVisible: { false },
            observeWindows: false
        )
        explicit.requestExplicitQuit()
        XCTAssertEqual(explicitApplication.terminateCount, 1)
        XCTAssertEqual(explicit.terminationReply(), .terminateNow)

        let system = ApplicationLifecycleCoordinator(
            application: LifecycleApplicationFake(),
            isMenuBarVisible: { false },
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
        let runtime = AudioRuntimeState(status: .needsSetup)
        let actions = RuntimeActionsFake()
        let persistence = OnboardingPersistenceFake()
        let viewModel = OnboardingViewModel(
            runtime: runtime, actions: actions, persistence: persistence, hasActivePreset: { false }
        )
        XCTAssertEqual(viewModel.permissionPresentation, .unknown)

        viewModel.requestPermission()
        XCTAssertEqual(actions.requestCount, 1)
        XCTAssertEqual(viewModel.permissionPresentation, .unknown)
        runtime.publish(.starting, output: output())
        XCTAssertEqual(viewModel.permissionPresentation, .requesting)
        runtime.publish(.needsSetup, output: output())
        XCTAssertEqual(viewModel.permissionPresentation, .granted)
        runtime.publish(.needsPermission, output: output())
        XCTAssertEqual(viewModel.permissionPresentation, .denied)

        viewModel.openPermissionSettings()
        viewModel.retry()
        XCTAssertEqual(actions.settingsCount, 1)
        XCTAssertEqual(actions.retryCount, 1)
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
            persistence: OnboardingPersistenceFake(),
            hasActivePreset: { true }
        )
        XCTAssertFalse(viewModel.canComplete)
    }

    func testCompletionAllowsNoneWithGrantedPermissionAndSupportedOutput() {
        let runtime = AudioRuntimeState(status: .processing, currentOutput: output())
        let persistence = OnboardingPersistenceFake()
        let viewModel = OnboardingViewModel(
            runtime: runtime,
            actions: RuntimeActionsFake(),
            persistence: persistence,
            hasActivePreset: { false }
        )
        XCTAssertTrue(viewModel.complete())
        XCTAssertTrue(persistence.isComplete)

        let probedRuntime = AudioRuntimeState(status: .needsSetup, currentOutput: output())
        let probed = OnboardingViewModel(
            runtime: probedRuntime,
            actions: RuntimeActionsFake(),
            persistence: OnboardingPersistenceFake(),
            hasActivePreset: { false }
        )
        probed.requestPermission()
        probedRuntime.publish(.starting, output: output())
        probedRuntime.publish(.needsSetup, output: output())
        XCTAssertTrue(probed.canComplete)
    }

    func testFinishLaterSuppressesRelaunchPromptUntilExplicitResume() {
        let persistence = OnboardingPersistenceFake()
        let first = OnboardingViewModel(
            runtime: AudioRuntimeState(), actions: RuntimeActionsFake(),
            persistence: persistence, hasActivePreset: { false }
        )
        XCTAssertTrue(first.shouldPresentAutomatically)
        first.advance()
        first.finishLater()
        XCTAssertTrue(first.shouldShowSetupMenuItem)

        let relaunched = OnboardingViewModel(
            runtime: AudioRuntimeState(), actions: RuntimeActionsFake(),
            persistence: persistence, hasActivePreset: { false }
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
            persistence: persistence, hasActivePreset: { false }
        )

        viewModel.selectStep(.liveHealth)
        XCTAssertEqual(viewModel.currentStep, .liveHealth)
        XCTAssertEqual(persistence.checkpoint, .liveHealth)
        viewModel.selectStep(.systemAudio)
        XCTAssertEqual(viewModel.currentStep, .systemAudio)
        XCTAssertEqual(persistence.checkpoint, .systemAudio)
    }

    func testMenuPresentationMapsEveryRuntimeStateAndOnlyRetryableStatesExposeRetry() {
        let cases: [(AudioRuntimeState.Status, String, Bool)] = [
            (.unavailable("private reason"), "exclamationmark.waveform", false),
            (.needsSetup, "exclamationmark.waveform", false),
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
            runtimeStatus: .needsSetup, isReady: true
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
