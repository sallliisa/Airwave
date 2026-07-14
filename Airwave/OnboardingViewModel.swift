import AppKit
import Combine
import SwiftUI

@MainActor
final class OnboardingViewModel: ObservableObject {
    static let shared = OnboardingViewModel()

    @Published private(set) var currentStep: SetupStep = .introduction
    @Published private(set) var snapshot: SetupSnapshot = .checking
    @Published private(set) var hasStartedLaunch = false
    private var autoPresentationRequested = false

    private let diagnosticsManager: SystemDiagnosticsManager
    private let hrirManager: HRIRManager
    private let deviceManager: AudioDeviceManager
    private let audioManager: AudioGraphManager
    private var persistence: OnboardingPersistence
    private let actions: SetupActionProviding
    private let routeController: OnboardingRouteProviding
    private var cancellables = Set<AnyCancellable>()
    private let snapshotRefreshSubject = PassthroughSubject<Void, Never>()
    private var hasPublishedResolvedSnapshot = false

    init(
        diagnosticsManager: SystemDiagnosticsManager = .shared,
        hrirManager: HRIRManager = .shared,
        deviceManager: AudioDeviceManager = .shared,
        audioManager: AudioGraphManager = .shared,
        persistence: OnboardingPersistence = UserDefaultsOnboardingPersistence(),
        actions: SetupActionProviding = SystemSetupActions.shared,
        routeController: OnboardingRouteProviding? = nil
    ) {
        self.diagnosticsManager = diagnosticsManager
        self.hrirManager = hrirManager
        self.deviceManager = deviceManager
        self.audioManager = audioManager
        self.persistence = persistence
        self.actions = actions
        self.routeController = routeController ?? LiveOnboardingRouteController(
            menuViewModel: .shared,
            audioManager: audioManager,
            deviceManager: deviceManager,
            hrirManager: hrirManager
        )
        self.persistence.onboardingVersion = UserDefaultsOnboardingPersistence.currentVersion
        observeLiveState()
    }

    var isCompleted: Bool { persistence.isComplete }
    var isIncomplete: Bool { !persistence.isComplete }
    var shouldShowSetupMenuItem: Bool {
        Self.shouldShowSetupMenuItem(for: snapshot)
    }
    var shouldAutoPresent: Bool {
        isIncomplete && !persistence.isDismissedForCurrentLaunch
    }
    var menuTitle: String {
        isCompleted ? "Set up Airwave again" : "Continue setting up Airwave"
    }

    func requestAutomaticPresentationIfNeeded() -> Bool {
        beginLaunch()
        guard shouldAutoPresent, !autoPresentationRequested else { return false }
        autoPresentationRequested = true
        resume()
        return true
    }
    var canContinue: Bool {
        switch currentStep {
        case .introduction: return true
        case .completion: return false
        default: return snapshot.status(for: currentStep)?.isComplete == true
        }
    }

    func canSelectStep(_ step: SetupStep) -> Bool {
        OnboardingStepNavigationPolicy.canSelect(
            step: step,
            currentStep: currentStep,
            snapshot: snapshot
        )
    }

    var aggregateDevices: [AudioDevice] { routeController.aggregateDevices }
    var selectedAggregate: AudioDevice? { routeController.selectedAggregate }
    var availableInputs: [AggregateDeviceInspector.SubDeviceInfo] { routeController.availableInputs }
    var selectedInput: AggregateDeviceInspector.SubDeviceInfo? { routeController.selectedInput }
    var availableOutputs: [AggregateDeviceInspector.SubDeviceInfo] { routeController.availableOutputs }
    var selectedOutput: AggregateDeviceInspector.SubDeviceInfo? { routeController.selectedOutput }
    var presets: [HRIRPreset] { routeController.presets }
    var selectedPreset: HRIRPreset? { routeController.selectedPreset }

    func beginLaunch() {
        guard !hasStartedLaunch else { return }
        hasStartedLaunch = true
        persistence.beginLaunch()
        snapshot = .checking
        hasPublishedResolvedSnapshot = false
        refresh()
        if shouldAutoPresent {
            resume()
        }
    }

    func resume() {
        currentStep = firstUnmetStep ?? .completion
        persistence.checkpoint = currentStep
        refreshSnapshot()
    }

    func refresh() {
        deviceManager.refreshDevices()
        diagnosticsManager.refresh()
        scheduleSnapshotRefresh()
    }

    func selectStep(_ step: SetupStep) {
        guard canSelectStep(step) else { return }
        currentStep = step
        persistence.checkpoint = step
    }

    func advance() {
        guard canContinue else { return }
        guard let index = SetupStep.allCases.firstIndex(of: currentStep),
              index + 1 < SetupStep.allCases.count else { return }
        currentStep = SetupStep.allCases[index + 1]
        persistence.checkpoint = currentStep
        refreshSnapshot()
    }

    func goBack() {
        guard let index = SetupStep.allCases.firstIndex(of: currentStep), index > 0 else { return }
        currentStep = SetupStep.allCases[index - 1]
        persistence.checkpoint = currentStep
    }

    func finishLater() {
        persistence.checkpoint = currentStep
        persistence.dismissForCurrentLaunch()
    }

    @discardableResult
    func startUsingAirwave() -> Bool {
        guard Self.canStartUsingAirwave(for: snapshot) else { return false }
        persistence.isComplete = true
        persistence.checkpoint = .completion
        currentStep = .completion
        actions.startAirwave()
        return true
    }

    func selectAggregate(_ device: AudioDevice) {
        routeController.selectAggregate(device)
        scheduleSnapshotRefresh()
    }

    func selectInput(_ input: AggregateDeviceInspector.SubDeviceInfo) {
        routeController.selectInput(input)
        scheduleSnapshotRefresh()
    }

    func selectOutput(_ output: AggregateDeviceInspector.SubDeviceInfo) {
        routeController.selectOutput(output)
        scheduleSnapshotRefresh()
    }

    func selectPreset(_ preset: HRIRPreset) {
        routeController.selectPreset(preset)
        scheduleSnapshotRefresh()
    }

    func openBlackHoleDownload() { actions.openBlackHoleDownload() }
    func openAudioMIDISetup() { actions.openAudioMIDISetup() }
    func openMicrophoneSettings() { actions.openMicrophoneSettings() }
    func openHRTFDatabase() { actions.openHRTFDatabase() }
    func openHRIRFolder() { actions.openHRIRFolder() }

    func requestMicrophonePermission() {
        actions.requestMicrophonePermission { [weak self] _ in
            self?.diagnosticsManager.refresh()
            self?.scheduleSnapshotRefresh()
        }
    }

    func quitAirwave() { actions.quitAirwave() }

    private var firstUnmetStep: SetupStep? {
        SetupStep.requirementSteps.first { step in
            guard let status = snapshot.status(for: step) else { return false }
            return !status.isComplete
        }
    }

    private func refreshSnapshot() {
        let isChecking = Self.shouldShowCheckingIndicator(
            hasPublishedResolvedSnapshot: hasPublishedResolvedSnapshot,
            diagnosticsIsRefreshing: diagnosticsManager.isRefreshing
        )
        let route = makeRouteState()
        snapshot = SetupSnapshot(
            diagnostics: diagnosticsManager.diagnostics,
            presets: hrirManager.presets,
            route: route,
            isChecking: isChecking
        )
        if !isChecking {
            hasPublishedResolvedSnapshot = true
        }
    }

    private func scheduleSnapshotRefresh() {
        snapshotRefreshSubject.send(())
    }

    private func makeRouteState() -> SetupRouteState {
        let aggregate = routeController.selectedAggregate
        let aggregateExists = aggregate.map { selected in
            routeController.aggregateDevices.contains { $0.id == selected.id }
        } == true

        let input = routeController.selectedInput
        let inputExists = input.map { selected in
            routeController.availableInputs.contains { $0.uid == selected.uid }
        } == true

        let output = routeController.selectedOutput
        let outputExists = output.map { selected in
            routeController.availableOutputs.contains { $0.uid == selected.uid }
        } == true

        let preset = routeController.selectedPreset
        let presetExists = preset.map { selected in
            routeController.presets.contains { $0.id == selected.id }
        } == true

        return SetupRouteState(
            aggregateSelected: aggregateExists,
            inputSelected: inputExists,
            outputSelected: outputExists,
            presetSelected: presetExists,
            aggregateName: aggregate?.name,
            inputName: input?.name,
            outputName: output?.name,
            presetName: preset?.name
        )
    }

    private func observeLiveState() {
        snapshotRefreshSubject
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSnapshot() }
            .store(in: &cancellables)

        diagnosticsManager.$diagnostics
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
            .store(in: &cancellables)

        hrirManager.$presets
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
            .store(in: &cancellables)

        hrirManager.$activePreset
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
            .store(in: &cancellables)

        deviceManager.$aggregateDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
            .store(in: &cancellables)

        deviceManager.$aggregateSubDeviceChangeCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
            .store(in: &cancellables)

        audioManager.$aggregateDevice
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
            .store(in: &cancellables)

        audioManager.$availableInputs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
            .store(in: &cancellables)

        audioManager.$availableOutputs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
            .store(in: &cancellables)

        audioManager.$selectedInputDevice
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
            .store(in: &cancellables)

        audioManager.$selectedOutputDevice
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: PermissionManager.microphonePermissionDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.deviceManager.refreshDevices()
                self?.diagnosticsManager.refresh()
                self?.scheduleSnapshotRefresh()
            }
            .store(in: &cancellables)
    }

    static func shouldShowCheckingIndicator(
        hasPublishedResolvedSnapshot: Bool,
        diagnosticsIsRefreshing: Bool
    ) -> Bool {
        !hasPublishedResolvedSnapshot && diagnosticsIsRefreshing
    }

    static func shouldShowSetupMenuItem(for snapshot: SetupSnapshot) -> Bool {
        !snapshot.isReadyToRun
    }

    static func canStartUsingAirwave(for snapshot: SetupSnapshot) -> Bool {
        snapshot.isReadyToRun
    }
}
