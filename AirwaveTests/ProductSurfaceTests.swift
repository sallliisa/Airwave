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
        XCTAssertNil(
            OnboardingReadinessPresentation.make(
                captureAccess: .verified,
                hasPreset: true,
                runtimeStatus: .processing,
                isReady: true
            ).actionStep
        )
    }

    func testCompletedSetupDoesNotRequireFreshCaptureWhenInactiveWithoutEffect() {
        let persistence = PersistenceFake()
        persistence.isComplete = true
        let runtime = AudioRuntimeState(status: .inactive, captureAccess: .unverified)
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.needsSetupAttention)
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
}

@MainActor
private final class ActionsFake: AudioRuntimeUserActions {
    var requestCount = 0
    func requestSystemAudioAccess() { requestCount += 1 }
    func retryNow() {}
    func openSystemAudioRecordingSettings() {}
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
}
