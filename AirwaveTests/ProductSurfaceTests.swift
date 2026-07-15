import XCTest
@testable import Airwave

@MainActor
final class ProductSurfaceTests: XCTestCase {
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

    func testVirtualOutputWarnsWithoutRepairAndCannotComplete() {
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
        XCTAssertTrue(viewModel.virtualOutputGuidance?.contains("macOS Sound settings") == true)
    }

    func testCompletionRequiresPresetProcessingAndSupportedOutput() {
        let runtime = AudioRuntimeState(status: .processing, currentOutput: output())
        var hasPreset = false
        let persistence = OnboardingPersistenceFake()
        let viewModel = OnboardingViewModel(
            runtime: runtime,
            actions: RuntimeActionsFake(),
            persistence: persistence,
            hasActivePreset: { hasPreset }
        )
        XCTAssertFalse(viewModel.complete())
        hasPreset = true
        XCTAssertTrue(viewModel.complete())
        XCTAssertTrue(persistence.isComplete)
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

        let relaunched = OnboardingViewModel(
            runtime: AudioRuntimeState(), actions: RuntimeActionsFake(),
            persistence: persistence, hasActivePreset: { false }
        )
        XCTAssertFalse(relaunched.shouldPresentAutomatically)
        XCTAssertEqual(relaunched.currentStep, .systemAudio)
        relaunched.resume()
        XCTAssertTrue(relaunched.shouldPresentAutomatically)
    }

    func testMenuPresentationMapsEveryRuntimeStateAndOnlyRetryableStatesExposeRetry() {
        let cases: [(AudioRuntimeState.Status, String, Bool)] = [
            (.unavailable("x"), "waveform.circle", false),
            (.needsSetup, "waveform.circle", false),
            (.needsPermission, "exclamationmark.waveform", true),
            (.nativePassthrough(reason: "x"), "exclamationmark.waveform", false),
            (.starting, "waveform.badge.plus", false),
            (.processing, "waveform.circle.fill", false),
            (.recovering(reason: "x"), "exclamationmark.waveform", true)
        ]
        for (status, icon, retry) in cases {
            let presentation = RuntimeMenuPresentation.make(from: status)
            XCTAssertEqual(presentation.iconName, icon)
            XCTAssertEqual(presentation.canRetry, retry)
            XCTAssertEqual(presentation.healthTitle, status.title)
        }
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
