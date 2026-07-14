import AVFoundation
import XCTest
@testable import Airwave

@MainActor
final class OnboardingModelTests: XCTestCase {
    private func readyDiagnostics() -> DiagnosticsResult {
        var result = DiagnosticsResult()
        result.virtualDriverInstalled = true
        result.detectedVirtualDrivers = ["BlackHole 2ch"]
        result.aggregateDevicesExist = true
        result.validAggregateExists = true
        result.aggregateHealth = [AggregateHealth(
            name: "Airwave Audio",
            deviceUID: "aggregate",
            hasInput: true,
            hasOutput: true,
            inputDeviceCount: 1,
            outputDeviceCount: 1,
            missingDevices: []
        )]
        result.microphonePermissionGranted = true
        result.microphonePermissionDetermined = true
        return result
    }

    func testSnapshotReportsEveryCompleteRequirement() {
        let route = SetupRouteState(
            aggregateSelected: true,
            inputSelected: true,
            outputSelected: true,
            presetSelected: true
        )
        let snapshot = SetupSnapshot(
            diagnostics: readyDiagnostics(),
            presets: [preset()],
            route: route,
            microphoneStatus: .authorized
        )

        XCTAssertEqual(snapshot.driverStatus, .complete)
        XCTAssertEqual(snapshot.aggregateStatus, .complete)
        XCTAssertEqual(snapshot.permissionStatus, .complete)
        XCTAssertEqual(snapshot.hrirStatus, .complete)
        XCTAssertEqual(snapshot.routeStatus, .complete)
        XCTAssertTrue(snapshot.isReadyToRun)
    }

    func testCompletionStepIsFinalChecksAndListsAllRequirements() {
        XCTAssertEqual(SetupStep.completion.title, "Final checks")
        XCTAssertEqual(
            SetupStep.requirementSteps,
            [.virtualDriver, .aggregateDevice, .microphonePermission, .hrirPreset, .audioRoute]
        )
    }

    func testSetupMenuVisibilityTracksLiveSnapshotReadiness() {
        let ready = SetupSnapshot(
            driverStatus: .complete,
            aggregateStatus: .complete,
            permissionStatus: .complete,
            hrirStatus: .complete,
            routeStatus: .complete,
            route: SetupRouteState(
                aggregateSelected: true,
                inputSelected: true,
                outputSelected: true,
                presetSelected: true
            )
        )
        let incomplete = SetupSnapshot(
            driverStatus: .complete,
            aggregateStatus: .complete,
            permissionStatus: .complete,
            hrirStatus: .incomplete,
            routeStatus: .complete
        )

        XCTAssertFalse(OnboardingViewModel.shouldShowSetupMenuItem(for: ready))
        XCTAssertTrue(OnboardingViewModel.shouldShowSetupMenuItem(for: incomplete))
        XCTAssertTrue(OnboardingViewModel.shouldShowSetupMenuItem(for: .checking))
    }

    func testStartUsingAirwaveRequiresAllLiveChecks() {
        XCTAssertTrue(OnboardingViewModel.canStartUsingAirwave(for: readySnapshot()))
        XCTAssertFalse(OnboardingViewModel.canStartUsingAirwave(for: .checking))
    }

    func testSnapshotBlocksInvalidAggregateAndDeniedPermission() {
        var diagnostics = readyDiagnostics()
        diagnostics.validAggregateExists = false
        diagnostics.aggregateHealth = [AggregateHealth(
            name: "Broken Aggregate",
            deviceUID: "aggregate",
            hasInput: true,
            hasOutput: false,
            inputDeviceCount: 1,
            outputDeviceCount: 0,
            missingDevices: []
        )]

        let snapshot = SetupSnapshot(
            diagnostics: diagnostics,
            presets: [],
            route: SetupRouteState(),
            microphoneStatus: .denied
        )

        XCTAssertEqual(snapshot.aggregateStatus, .blocked("Add a connected pair of headphones or speakers to your aggregate in Audio MIDI Setup."))
        XCTAssertEqual(snapshot.permissionStatus, .blocked("Microphone access is off for Airwave. Turn it on in System Settings to continue."))
        XCTAssertEqual(snapshot.hrirStatus, .incomplete)
        XCTAssertFalse(snapshot.isReadyToRun)
    }

    func testSnapshotReportsCheckingAndIncompleteStates() {
        let snapshot = SetupSnapshot(
            diagnostics: DiagnosticsResult(),
            presets: [],
            route: SetupRouteState(),
            isChecking: true
        )
        XCTAssertEqual(snapshot.driverStatus, .checking)
        XCTAssertEqual(snapshot.aggregateStatus, .checking)
        XCTAssertEqual(snapshot.permissionStatus, .checking)
        XCTAssertEqual(snapshot.hrirStatus, .checking)
        XCTAssertEqual(snapshot.routeStatus, .checking)

        let incomplete = SetupSnapshot(
            diagnostics: DiagnosticsResult(),
            presets: [],
            route: SetupRouteState(),
            microphoneStatus: .notDetermined
        )
        XCTAssertEqual(incomplete.driverStatus, .incomplete)
        XCTAssertEqual(incomplete.aggregateStatus, .incomplete)
        XCTAssertEqual(incomplete.permissionStatus, .incomplete)
        XCTAssertEqual(incomplete.hrirStatus, .incomplete)
        XCTAssertEqual(incomplete.routeStatus, .incomplete)
    }

    func testReadinessRequiresPresetAndCompleteRoute() {
        let diagnostics = readyDiagnostics()
        let noPreset = SetupSnapshot(
            diagnostics: diagnostics,
            presets: [],
            route: SetupRouteState(
                aggregateSelected: true,
                inputSelected: true,
                outputSelected: true,
                presetSelected: false
            ),
            microphoneStatus: .authorized
        )
        XCTAssertFalse(noPreset.isReadyToRun)

        let noOutput = SetupSnapshot(
            diagnostics: diagnostics,
            presets: [preset()],
            route: SetupRouteState(
                aggregateSelected: true,
                inputSelected: true,
                outputSelected: false,
                presetSelected: true
            ),
            microphoneStatus: .authorized
        )
        XCTAssertFalse(noOutput.isReadyToRun)
    }

    func testCompletedStepsAreNavigable() {
        let snapshot = SetupSnapshot(
            driverStatus: .complete,
            aggregateStatus: .complete,
            permissionStatus: .complete,
            hrirStatus: .complete,
            routeStatus: .complete,
            route: SetupRouteState(
                aggregateSelected: true,
                inputSelected: true,
                outputSelected: true,
                presetSelected: true
            )
        )

        XCTAssertTrue(OnboardingStepNavigationPolicy.canSelect(step: .virtualDriver, currentStep: .audioRoute, snapshot: snapshot))
        XCTAssertTrue(OnboardingStepNavigationPolicy.canSelect(step: .hrirPreset, currentStep: .audioRoute, snapshot: snapshot))
        XCTAssertTrue(OnboardingStepNavigationPolicy.canSelect(step: .completion, currentStep: .audioRoute, snapshot: snapshot))
    }

    func testIncompleteStepsAreNavigable() {
        let snapshot = SetupSnapshot(
            driverStatus: .complete,
            aggregateStatus: .complete,
            permissionStatus: .complete,
            hrirStatus: .incomplete,
            routeStatus: .incomplete
        )

        XCTAssertTrue(OnboardingStepNavigationPolicy.canSelect(step: .aggregateDevice, currentStep: .virtualDriver, snapshot: snapshot))
        XCTAssertTrue(OnboardingStepNavigationPolicy.canSelect(step: .hrirPreset, currentStep: .virtualDriver, snapshot: snapshot))
        XCTAssertTrue(OnboardingStepNavigationPolicy.canSelect(step: .audioRoute, currentStep: .virtualDriver, snapshot: snapshot))
    }

    func testCompletionStepIsNavigableBeforeReadiness() {
        let incomplete = SetupSnapshot(
            driverStatus: .complete,
            aggregateStatus: .complete,
            permissionStatus: .complete,
            hrirStatus: .complete,
            routeStatus: .incomplete
        )
        let complete = SetupSnapshot(
            driverStatus: .complete,
            aggregateStatus: .complete,
            permissionStatus: .complete,
            hrirStatus: .complete,
            routeStatus: .complete,
            route: SetupRouteState(
                aggregateSelected: true,
                inputSelected: true,
                outputSelected: true,
                presetSelected: true
            )
        )

        XCTAssertTrue(OnboardingStepNavigationPolicy.canSelect(step: .completion, currentStep: .audioRoute, snapshot: incomplete))
        XCTAssertTrue(OnboardingStepNavigationPolicy.canSelect(step: .completion, currentStep: .audioRoute, snapshot: complete))
    }

    @MainActor
    func testResolvedRefreshDoesNotShowCheckingIndicator() {
        XCTAssertTrue(OnboardingViewModel.shouldShowCheckingIndicator(
            hasPublishedResolvedSnapshot: false,
            diagnosticsIsRefreshing: true
        ))
        XCTAssertFalse(OnboardingViewModel.shouldShowCheckingIndicator(
            hasPublishedResolvedSnapshot: true,
            diagnosticsIsRefreshing: true
        ))
        XCTAssertFalse(OnboardingViewModel.shouldShowCheckingIndicator(
            hasPublishedResolvedSnapshot: false,
            diagnosticsIsRefreshing: false
        ))
    }

    @MainActor
    func testFinishLaterPersistsCheckpointAndLaunchDismissal() {
        let persistence = InMemoryOnboardingPersistence()
        let viewModel = OnboardingViewModel(
            persistence: persistence,
            actions: TestSetupActions(),
            routeController: TestRouteController()
        )

        viewModel.beginLaunch()
        viewModel.finishLater()

        XCTAssertTrue(persistence.isDismissedForCurrentLaunch)
        XCTAssertEqual(persistence.checkpoint, viewModel.currentStep)
    }

    private func preset() -> HRIRPreset {
        HRIRPreset(
            id: UUID(),
            name: "Test HRIR",
            fileURL: URL(fileURLWithPath: "/tmp/test.wav"),
            channelCount: 2,
            sampleRate: 48_000
        )
    }

    private func readySnapshot() -> SetupSnapshot {
        SetupSnapshot(
            driverStatus: .complete,
            aggregateStatus: .complete,
            permissionStatus: .complete,
            hrirStatus: .complete,
            routeStatus: .complete,
            route: SetupRouteState(
                aggregateSelected: true,
                inputSelected: true,
                outputSelected: true,
                presetSelected: true
            )
        )
    }
}

@MainActor
private final class TestSetupActions: SetupActionProviding {
    func openBlackHoleDownload() {}
    func openAudioMIDISetup() {}
    func openMicrophoneSettings() {}
    func openHRTFDatabase() {}
    func openHRIRFolder() {}
    func requestMicrophonePermission(completion: ((Bool) -> Void)?) { completion?(false) }
    func startAirwave() {}
    func quitAirwave() {}
}

@MainActor
private final class TestRouteController: OnboardingRouteProviding {
    var aggregateDevices: [AudioDevice] = []
    var selectedAggregate: AudioDevice?
    var availableInputs: [AggregateDeviceInspector.SubDeviceInfo] = []
    var selectedInput: AggregateDeviceInspector.SubDeviceInfo?
    var availableOutputs: [AggregateDeviceInspector.SubDeviceInfo] = []
    var selectedOutput: AggregateDeviceInspector.SubDeviceInfo?
    var presets: [HRIRPreset] = []
    var selectedPreset: HRIRPreset?

    func selectAggregate(_ device: AudioDevice) { selectedAggregate = device }
    func selectInput(_ input: AggregateDeviceInspector.SubDeviceInfo) { selectedInput = input }
    func selectOutput(_ output: AggregateDeviceInspector.SubDeviceInfo) { selectedOutput = output }
    func selectPreset(_ preset: HRIRPreset) { selectedPreset = preset }
}
