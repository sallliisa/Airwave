import XCTest
@testable import Airwave

@MainActor
final class ProductSurfaceTests: XCTestCase {
    func testSettingsSurfaceIncludesResourceLinksPickerLabelsIconsAndHitTargets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let style = try String(contentsOf: root.appendingPathComponent("Airwave/AirwaveStyle.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("Airwave/SettingsView.swift"), encoding: .utf8)
        let equalizer = try String(contentsOf: root.appendingPathComponent("Airwave/EqualizerSettingsView.swift"), encoding: .utf8)

        XCTAssertTrue(style.contains("Get more HRIRs…"))
        XCTAssertTrue(equalizer.contains("Get more equalizer presets…"))
        XCTAssertTrue(style.contains("https://airtable.com/embed/appac4r1cu9UpBNAN/shrpUAbtyZxhDDMjg/tblopH2GznvFipWjq/viwnouWPGDuYEd8Go"))
        XCTAssertTrue(style.contains("https://autoeq.app/"))
        XCTAssertTrue(style.contains("Button(\"Manage…\")"))
        XCTAssertTrue(equalizer.contains("Button(\"Manage…\")"))
        XCTAssertFalse(style.contains("Button(\"Show in Finder\")"))
        XCTAssertFalse(equalizer.contains("Button(\"Show in Finder\")"))
        XCTAssertTrue(style.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(style.contains(".foregroundStyle(.tint)"))
        XCTAssertTrue(equalizer.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(equalizer.contains(".foregroundStyle(.tint)"))

        let libraryCard = try XCTUnwrap(equalizer.range(of: "private var libraryCard"))
        let libraryCardSource = String(equalizer[libraryCard.lowerBound...])
        XCTAssertFalse(libraryCardSource.contains("title: \"Equalizer Presets\""))

        for icon in ["slider.horizontal.3", "headphones", "sparkles", "gearshape"] {
            XCTAssertTrue(settings.contains("systemImage: \"\(icon)\""))
        }
        XCTAssertTrue(settings.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertTrue(settings.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(settings.contains("isReady: onboarding.runtime.isSetupHealthy"))
    }

    func testSettingsPageUsesOneUnifiedTransition() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Airwave/SettingsView.swift"),
            encoding: .utf8
        )

        let settingsStart = try XCTUnwrap(source.range(of: "struct SettingsView: View"))
        let generalPageStart = try XCTUnwrap(
            source.range(of: "private var generalPage", range: settingsStart.lowerBound..<source.endIndex)
        )
        let pageSwitchingSource = String(source[settingsStart.lowerBound..<generalPageStart.lowerBound])
        XCTAssertTrue(pageSwitchingSource.contains(".id(page.wrappedValue)"))
        XCTAssertEqual(
            pageSwitchingSource.components(separatedBy: ".transition(pageRevealTransition)").count - 1,
            1
        )

        let pageContentStart = try XCTUnwrap(pageSwitchingSource.range(of: "private var settingsPageContent"))
        let pageContentSource = pageSwitchingSource[pageContentStart.lowerBound...]
        XCTAssertFalse(pageContentSource.contains(".transition("))
    }

    func testRegisteredDevicesUsesSelectableRowsAndPickerFooterActions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Airwave/DeviceManagementView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@State private var selectedDeviceUID: String?"))
        XCTAssertTrue(source.contains(".accessibilityAddTraits(selectedDeviceUID == row.id ? .isSelected : [])"))
        XCTAssertTrue(source.contains("private var actionFooter: some View"))
        XCTAssertTrue(source.contains(".disabled(selectedRow?.canReset != true)"))
        XCTAssertTrue(source.contains(".disabled(selectedRow?.canForget != true)"))

        let row = try XCTUnwrap(source.range(of: "private func deviceRow"))
        let footer = try XCTUnwrap(source.range(of: "private var actionFooter"))
        let rowSource = String(source[row.lowerBound..<footer.lowerBound])
        XCTAssertFalse(rowSource.contains("Button(\"Reset Profile\")"))
        XCTAssertFalse(rowSource.contains("Button(\"Forget Device\")"))
        XCTAssertFalse(rowSource.contains("Image(systemName: \"checkmark\")"))
        XCTAssertTrue(source[source.startIndex..<row.lowerBound].contains("Divider()"))
    }

    func testPickerActionsHaveNoSuccessIndicatorsButRetainFailureFeedback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let device = try String(
            contentsOf: root.appendingPathComponent("Airwave/DeviceManagementView.swift"),
            encoding: .utf8
        )
        let hrir = try String(
            contentsOf: root.appendingPathComponent("Airwave/AirwaveStyle.swift"),
            encoding: .utf8
        )
        let equalizer = try String(
            contentsOf: root.appendingPathComponent("Airwave/EqualizerSettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(device.contains("DeviceManagementResult"))
        XCTAssertFalse(device.contains("coordinator.result"))
        XCTAssertFalse(device.contains("checkmark.circle.fill"))
        XCTAssertFalse(hrir.contains("isSuccess"))
        XCTAssertFalse(equalizer.contains("isSuccess"))
        XCTAssertTrue(hrir.contains("exclamationmark.triangle.fill"))
        XCTAssertTrue(equalizer.contains("exclamationmark.triangle.fill"))
        XCTAssertTrue(hrir.contains("confirmationDialog("))
        XCTAssertTrue(equalizer.contains("confirmationDialog("))
    }

    func testOnboardingHasOneCaptureCardAndNoSplitHealthCopy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Airwave/OnboardingView.swift"), encoding: .utf8)

        XCTAssertEqual(source.components(separatedBy: "title: \"System Audio Capture\"").count - 1, 1)
        XCTAssertTrue(source.contains("Test System Audio Capture"))
        XCTAssertFalse(source.contains(["Audio", "Tap Health"].joined(separator: " ")))
        XCTAssertFalse(source.contains(["macOS", "Permission"].joined(separator: " ")))
    }

    func testOnboardingHRIRDescriptionCanWrap() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Airwave/OnboardingView.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(source.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(source.contains(".frame(height: 260, alignment: .top)"))
    }

    func testCaptureControlsGuidanceAndStatusCardOrder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Airwave/OnboardingView.swift"), encoding: .utf8)

        let controls = try XCTUnwrap(source.range(of: "captureTestControls"))
        let guidance = try XCTUnwrap(source.range(of: "captureFailureGuidance(guidance)"))
        let card = try XCTUnwrap(source.range(of: "captureAccessCard"))
        XCTAssertLessThan(card.lowerBound, guidance.lowerBound)
        XCTAssertLessThan(guidance.lowerBound, controls.lowerBound)
        XCTAssertTrue(source.contains("if viewModel.captureFailureGuidance == nil"))
        XCTAssertTrue(source.contains("case .checking, .unverified: return .unknown"))
        XCTAssertTrue(source.contains("case .checking, .unknown: return Color.primary"))
        XCTAssertTrue(source.contains("case .checking:"))
        XCTAssertTrue(source.contains("hasCaptureFailureGuidance"))
        XCTAssertTrue(source.contains("viewModel.canComplete(allowingUnknownCapture: canReturnToSettings)"))
        XCTAssertTrue(source.contains("viewModel.complete(allowingUnknownCapture: canReturnToSettings)"))
        XCTAssertTrue(source.contains("private var isRuntimeReady: Bool"))
        XCTAssertTrue(source.contains("isReady: isRuntimeReady"))
    }

    func testCapturePresentationUsesTruthfulStatesAndActions() {
        XCTAssertEqual(
            OnboardingReadinessPresentation.make(
                captureAccess: .permissionRequired,
                hasPreset: false,
                runtimeStatus: .needsPermission,
                isReady: false
            ).actionStep,
            .systemAudio
        )
        let unknown = OnboardingReadinessPresentation.make(
            captureAccess: .unverified,
            hasPreset: false,
            runtimeStatus: .inactive,
            isReady: false
        )
        XCTAssertFalse(unknown.isAttention)
        XCTAssertEqual(unknown.title, "Capture not confirmed")
        XCTAssertEqual(unknown.actionTitle, "Test System Audio Capture")

        let checking = OnboardingReadinessPresentation.make(
            captureAccess: .checking,
            hasPreset: false,
            runtimeStatus: .starting,
            isReady: false
        )
        XCTAssertFalse(checking.isAttention)
        XCTAssertNil(checking.actionStep)

        let failed = OnboardingReadinessPresentation.make(
            captureAccess: .failed(reason: "Capture test timed out."),
            hasPreset: false,
            runtimeStatus: .nativePassthrough(reason: "Capture test timed out."),
            isReady: false
        )
        XCTAssertTrue(failed.isAttention)
        XCTAssertEqual(failed.actionTitle, "Review Capture")
        XCTAssertNil(
            OnboardingReadinessPresentation.make(
                captureAccess: .verified,
                hasPreset: true,
                runtimeStatus: .processing,
                isReady: true
            ).actionStep
        )
    }

    func testCaptureFailureGuidanceAppearsOnlyForFailedCaptureStates() {
        XCTAssertNil(CaptureFailureGuidance.make(for: .unverified))
        XCTAssertNil(CaptureFailureGuidance.make(for: .checking))
        XCTAssertNil(CaptureFailureGuidance.make(for: .verified))

        let permissionGuidance = CaptureFailureGuidance.make(for: .permissionRequired)
        XCTAssertNotNil(permissionGuidance)
        XCTAssertNil(permissionGuidance?.reason)
        XCTAssertEqual(permissionGuidance?.suggestions.count, 2)

        let failureGuidance = CaptureFailureGuidance.make(for: .failed(reason: "Capture test timed out."))
        XCTAssertEqual(failureGuidance?.reason, "Capture test timed out.")
        XCTAssertEqual(failureGuidance?.suggestions.count, 3)
        XCTAssertTrue(failureGuidance?.suggestions.contains("Enable Airwave under Privacy & Security → System Audio Capture.") == true)
        XCTAssertTrue(failureGuidance?.suggestions.contains("Have another app actively playing audio.") == true)
        XCTAssertTrue(failureGuidance?.suggestions.contains("Use a supported physical stereo output; virtual and aggregate outputs are unsupported.") == true)
    }

    func testCompletedSetupDoesNotRequireFreshCaptureWhenInactiveWithoutEffect() {
        let persistence = PersistenceFake()
        persistence.isComplete = true
        let runtime = AudioRuntimeState(status: .inactive, captureAccess: .unverified)
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.needsSetupAttention)
    }

    func testCompletedSetupUnknownCaptureDoesNotShowAttention() {
        let persistence = PersistenceFake()
        persistence.isComplete = true
        let runtime = AudioRuntimeState(status: .starting, captureAccess: .checking)
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.needsSetupAttention)
    }

    func testVerifiedCaptureCanCompleteWhileRuntimeIsNotYetSteadyState() {
        let persistence = PersistenceFake()
        let runtime = AudioRuntimeState(
            status: .starting,
            currentOutput: output(),
            captureAccess: .verified
        )
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertTrue(viewModel.canComplete(allowingUnknownCapture: false))
    }

    func testInitialSetupUnknownCaptureCannotCompleteButSubsequentSetupCan() {
        let persistence = PersistenceFake()
        let runtime = AudioRuntimeState(
            status: .inactive,
            currentOutput: output(),
            captureAccess: .unverified
        )
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.canComplete(allowingUnknownCapture: false))
        XCTAssertTrue(viewModel.canComplete(allowingUnknownCapture: true))
    }

    func testCompleteUsesSetupEntryContext() {
        let persistence = PersistenceFake()
        let runtime = AudioRuntimeState(
            status: .inactive,
            currentOutput: output(),
            captureAccess: .unverified
        )
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.complete(allowingUnknownCapture: false))
        XCTAssertFalse(persistence.isComplete)
        XCTAssertTrue(viewModel.complete(allowingUnknownCapture: true))
        XCTAssertTrue(persistence.isComplete)
    }

    func testSubsequentSetupCheckingCaptureCannotComplete() {
        let persistence = PersistenceFake()
        let runtime = AudioRuntimeState(
            status: .starting,
            currentOutput: output(),
            captureAccess: .checking
        )
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.canComplete(allowingUnknownCapture: true))
    }

    func testKnownFailuresAndUnsupportedCaptureCannotCompleteInEitherSetupContext() {
        let persistence = PersistenceFake()

        for captureAccess in [
            AudioRuntimeState.CaptureAccess.permissionRequired,
            .failed(reason: "capture failed")
        ] {
            let runtime = AudioRuntimeState(
                status: .processing,
                currentOutput: output(),
                captureAccess: captureAccess
            )
            let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

            XCTAssertFalse(viewModel.canComplete(allowingUnknownCapture: false), "Unexpectedly allowed initial completion for \(captureAccess)")
            XCTAssertFalse(viewModel.canComplete(allowingUnknownCapture: true), "Unexpectedly allowed subsequent completion for \(captureAccess)")
        }

        let unsupportedRuntime = AudioRuntimeState(
            status: .processing,
            currentOutput: output(channels: 1),
            captureAccess: .verified
        )
        let unsupportedViewModel = OnboardingViewModel(
            runtime: unsupportedRuntime,
            actions: ActionsFake(),
            persistence: persistence
        )

        XCTAssertFalse(unsupportedViewModel.canComplete(allowingUnknownCapture: false))
        XCTAssertFalse(unsupportedViewModel.canComplete(allowingUnknownCapture: true))
    }

    func testPersistedWarningBlocksSubsequentUnknownCaptureCompletion() {
        let persistence = PersistenceFake()
        persistence.persistedCaptureFailure = PersistedCaptureFailure(kind: .failed, reason: "previous timeout")
        let runtime = AudioRuntimeState(
            status: .inactive,
            currentOutput: output(),
            captureAccess: .unverified
        )
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.canComplete(allowingUnknownCapture: true))
    }

    func testCaptureRequestDelegatesToRuntimeAndFocusRestores() {
        let actions = ActionsFake()
        let focus = FocusFake()
        let viewModel = OnboardingViewModel(
            runtime: AudioRuntimeState(), actions: actions, persistence: PersistenceFake(), focusRestorer: focus
        )

        viewModel.requestPermission()
        XCTAssertEqual(actions.requestCount, 1)
        XCTAssertEqual(focus.beginCount, 1)
    }

    func testCaptureFailureGuidanceActionsDelegateToExistingActions() {
        let actions = ActionsFake()
        let viewModel = OnboardingViewModel(
            runtime: AudioRuntimeState(captureAccess: .failed(reason: "silent")),
            actions: actions,
            persistence: PersistenceFake()
        )

        viewModel.openPermissionSettings()
        viewModel.requestPermission()

        XCTAssertEqual(actions.settingsCount, 1)
        XCTAssertEqual(actions.requestCount, 1)
    }

    func testCaptureFailureGuidanceStaysUntilVerified() {
        let runtime = AudioRuntimeState(captureAccess: .failed(reason: "first failure"))
        let persistence = PersistenceFake()
        let viewModel = OnboardingViewModel(
            runtime: runtime,
            actions: ActionsFake(),
            persistence: persistence
        )

        XCTAssertEqual(viewModel.captureFailureGuidance?.reason, "first failure")
        XCTAssertEqual(persistence.persistedCaptureFailure?.reason, "first failure")

        runtime.setCaptureAccess(.unverified)
        XCTAssertEqual(viewModel.captureFailureGuidance?.reason, "first failure")
        XCTAssertEqual(viewModel.captureAccessPresentation, .failed(reason: "first failure"))
        runtime.setCaptureAccess(.checking)
        XCTAssertEqual(viewModel.captureFailureGuidance?.reason, "first failure")
        XCTAssertEqual(viewModel.captureAccessPresentation, .checking)

        runtime.setCaptureAccess(.failed(reason: "second failure"))
        XCTAssertEqual(viewModel.captureFailureGuidance?.reason, "second failure")
        XCTAssertEqual(persistence.persistedCaptureFailure?.reason, "second failure")

        runtime.setCaptureAccess(.verified)
        XCTAssertNil(viewModel.captureFailureGuidance)
        XCTAssertNil(persistence.persistedCaptureFailure)
        XCTAssertEqual(viewModel.captureAccessPresentation, .verified)
    }

    func testPersistedCaptureFailureRoundTripsAcrossPersistenceInstances() throws {
        let suite = "Airwave.ProductSetupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let persistence = UserDefaultsOnboardingPersistenceV2(defaults: defaults)
        persistence.persistedCaptureFailure = PersistedCaptureFailure(kind: .failed, reason: "capture timed out")

        let relaunchedPersistence = UserDefaultsOnboardingPersistenceV2(defaults: defaults)

        XCTAssertEqual(
            relaunchedPersistence.persistedCaptureFailure,
            PersistedCaptureFailure(kind: .failed, reason: "capture timed out")
        )
    }

    func testPersistedFailureRestoresGuidanceWithoutChangingUnknownRuntime() {
        let persistence = PersistenceFake()
        persistence.persistedCaptureFailure = PersistedCaptureFailure(kind: .failed, reason: "previous timeout")
        let runtime = AudioRuntimeState(captureAccess: .unverified)
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertEqual(viewModel.captureFailureGuidance?.reason, "previous timeout")
        XCTAssertEqual(viewModel.captureAccessPresentation, .failed(reason: "previous timeout"))
        XCTAssertEqual(runtime.captureAccess, .unverified)
        XCTAssertTrue(viewModel.needsSetupAttention)
    }

    func testPersistedPermissionFailureRestoresPermissionPresentation() {
        let persistence = PersistenceFake()
        persistence.persistedCaptureFailure = PersistedCaptureFailure(kind: .permissionRequired, reason: nil)
        let runtime = AudioRuntimeState(captureAccess: .unverified)
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertEqual(viewModel.captureAccessPresentation, .permissionRequired)
        XCTAssertEqual(runtime.captureAccess, .unverified)
    }

    func testUnknownCaptureWithoutPersistedFailureRemainsUnverifiedPresentation() {
        let runtime = AudioRuntimeState(captureAccess: .unverified)
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: PersistenceFake())

        XCTAssertEqual(viewModel.captureAccessPresentation, .unverified)
    }

    func testPersistedFailureMakesFinalReadinessAttentionState() {
        let presentation = OnboardingReadinessPresentation.make(
            captureAccess: .unverified,
            hasPreset: true,
            runtimeStatus: .inactive,
            isReady: false,
            hasCaptureFailureGuidance: true
        )

        XCTAssertTrue(presentation.isAttention)
        XCTAssertEqual(presentation.actionStep, .systemAudio)
    }

    func testVerifiedRuntimeClearsPersistedFailureDuringViewModelInitialization() {
        let persistence = PersistenceFake()
        persistence.persistedCaptureFailure = PersistedCaptureFailure(kind: .failed, reason: "old failure")
        let runtime = AudioRuntimeState(currentOutput: output(), captureAccess: .verified)

        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertNil(viewModel.captureFailureGuidance)
        XCTAssertNil(persistence.persistedCaptureFailure)
    }

    func testFirstRunDefaultsEnableLaunchAtLoginAndHideMenuBarItem() throws {
        let suite = "Airwave.ProductSetupDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let loginItem = LoginItemAdapterFake()
        let launchAtLogin = LaunchAtLoginManager(adapter: loginItem)
        let migrated = try SettingsSchemaV2Migrator(
            defaults: defaults,
            launchAtLogin: launchAtLogin
        ).migrateIfNeeded()
        let menuVisibility = MenuBarVisibilityManager(defaults: defaults, visibilityDidChange: {})

        XCTAssertTrue(migrated)
        XCTAssertTrue(launchAtLogin.isEnabled)
        XCTAssertEqual(loginItem.registerCount, 1)
        XCTAssertFalse(menuVisibility.isVisible)
    }

    func testExistingMenuBarPreferenceIsPreserved() throws {
        let suite = "Airwave.ProductSetupDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: MenuBarVisibilityManager.defaultsKey)

        let menuVisibility = MenuBarVisibilityManager(defaults: defaults, visibilityDidChange: {})

        XCTAssertTrue(menuVisibility.isVisible)
    }

    private func output(channels: Int = 2) -> OutputDeviceDescriptor {
        OutputDeviceDescriptor(
            id: .init(1), uid: "built-in", name: "Built-in Output", transport: "Built-in",
            outputChannelCount: channels, nominalSampleRate: 48_000, isVirtual: false, isAggregate: false
        )
    }
}

@MainActor
private final class LoginItemAdapterFake: LoginItemAdapting {
    var isEnabled = false
    var registerCount = 0

    func register() throws {
        registerCount += 1
        isEnabled = true
    }

    func unregister() throws {
        isEnabled = false
    }
}

@MainActor
private final class ActionsFake: AudioRuntimeUserActions {
    var requestCount = 0
    var settingsCount = 0
    func requestSystemAudioAccess() { requestCount += 1 }
    func retryNow() {}
    func openSystemAudioRecordingSettings() { settingsCount += 1 }
}

@MainActor
private final class FocusFake: PermissionFocusRestoring {
    var beginCount = 0
    func beginPermissionRequest() { beginCount += 1 }
    func permissionRequestResolved() {}
}

private final class PersistenceFake: OnboardingPersisting {
    var version = 2
    var checkpoint: OnboardingStepV2 = .welcome
    var isComplete = false
    var isDeferred = false
    var persistedCaptureFailure: PersistedCaptureFailure?
}
