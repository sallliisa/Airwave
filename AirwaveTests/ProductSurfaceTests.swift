import XCTest
@testable import Airwave

@MainActor
final class ProductSurfaceTests: XCTestCase {
    func testOnboardingHasOneCaptureCardAndNoSplitHealthCopy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Airwave/OnboardingView.swift"), encoding: .utf8)

        XCTAssertEqual(source.components(separatedBy: "title: \"System Audio Capture\"").count - 1, 1)
        XCTAssertTrue(source.contains("Test System Audio Capture"))
        XCTAssertFalse(source.contains(["Audio", "Tap Health"].joined(separator: " ")))
        XCTAssertFalse(source.contains(["macOS", "Permission"].joined(separator: " ")))
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

        XCTAssertTrue(viewModel.canComplete)
    }

    func testKnownFailuresAndUnsupportedOrUnknownCaptureCannotComplete() {
        let persistence = PersistenceFake()

        for captureAccess in [
            AudioRuntimeState.CaptureAccess.unverified,
            .permissionRequired,
            .failed(reason: "capture failed")
        ] {
            let runtime = AudioRuntimeState(
                status: .processing,
                currentOutput: output(),
                captureAccess: captureAccess
            )
            let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

            XCTAssertFalse(viewModel.canComplete, "Unexpectedly allowed completion for \(captureAccess)")
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

        XCTAssertFalse(unsupportedViewModel.canComplete)
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
        runtime.setCaptureAccess(.checking)
        XCTAssertEqual(viewModel.captureFailureGuidance?.reason, "first failure")

        runtime.setCaptureAccess(.failed(reason: "second failure"))
        XCTAssertEqual(viewModel.captureFailureGuidance?.reason, "second failure")
        XCTAssertEqual(persistence.persistedCaptureFailure?.reason, "second failure")

        runtime.setCaptureAccess(.verified)
        XCTAssertNil(viewModel.captureFailureGuidance)
        XCTAssertNil(persistence.persistedCaptureFailure)
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
        persistence.persistedCaptureFailure = PersistedCaptureFailure(kind: .permissionRequired, reason: nil)
        let runtime = AudioRuntimeState(captureAccess: .unverified)
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertEqual(viewModel.captureFailureGuidance?.suggestions.count, 2)
        XCTAssertEqual(runtime.captureAccess, .unverified)
        XCTAssertTrue(viewModel.needsSetupAttention)
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

    private func output(channels: Int = 2) -> OutputDeviceDescriptor {
        OutputDeviceDescriptor(
            id: .init(1), uid: "built-in", name: "Built-in Output", transport: "Built-in",
            outputChannelCount: channels, nominalSampleRate: 48_000, isVirtual: false, isAggregate: false
        )
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
