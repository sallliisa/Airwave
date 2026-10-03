import AppKit
import Combine

@MainActor
protocol AudioRuntimeUserActions: AnyObject {
    func requestSystemAudioAccess()
    func retryNow()
    func openSystemAudioRecordingSettings()
}

@MainActor
protocol PermissionFocusRestoring: AnyObject {
    func beginPermissionRequest()
    func permissionRequestResolved()
}

@MainActor
final class PermissionWindowFocusRestorer: PermissionFocusRestoring {
    static let shared = PermissionWindowFocusRestorer()

    private let captureWindow: @MainActor () -> NSWindow?
    private let restoreWindow: @MainActor (NSWindow) -> Void
    private weak var requestingWindow: NSWindow?

    init(
        captureWindow: @escaping @MainActor () -> NSWindow? = {
            NSApp.keyWindow ?? NSApp.windows.first {
                $0.identifier == SettingsWindowPresenter.windowIdentifier && $0.isVisible
            }
        },
        restoreWindow: @escaping @MainActor (NSWindow) -> Void = { window in
            ApplicationLifecycleCoordinator.shared.prepareToPresentUserWindow()
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    ) {
        self.captureWindow = captureWindow
        self.restoreWindow = restoreWindow
    }

    func beginPermissionRequest() {
        requestingWindow = captureWindow()
    }

    func permissionRequestResolved() {
        guard let window = requestingWindow else { return }
        requestingWindow = nil
        guard window.isVisible else { return }
        restoreWindow(window)
    }
}

enum CaptureAccessPresentation: Equatable {
    case unverified
    case checking
    case verified
    case permissionRequired
    case failed(reason: String)
}

struct CaptureFailureGuidance: Equatable {
    let reason: String?
    let suggestions: [String]

    static func make(for captureAccess: CaptureAccessPresentation) -> Self? {
        switch captureAccess {
        case .permissionRequired:
            return Self(
                reason: nil,
                suggestions: [
                    "Enable Airwave under Privacy & Security → System Audio Capture."
                ]
            )
        case .failed(let reason):
            return Self(
                reason: reason,
                suggestions: [
                    "Enable Airwave under Privacy & Security → System Audio Capture.",
                    "Use a physical output with a resolvable source feed; virtual and aggregate outputs are unsupported."
                ]
            )
        case .unverified, .checking, .verified:
            return nil
        }
    }
}

enum OnboardingPresentationContext {
    case automaticFirstSetup
    case voluntary
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    static let shared = OnboardingViewModel(
        runtime: .shared,
        actions: AudioRuntimeController.shared,
        persistence: UserDefaultsOnboardingPersistenceV2(),
        focusRestorer: PermissionWindowFocusRestorer.shared
    )

    @Published private(set) var currentStep: OnboardingStepV2
    @Published private(set) var captureFailureGuidance: CaptureFailureGuidance?

    let runtime: AudioRuntimeState
    private let actions: AudioRuntimeUserActions
    private let persistence: OnboardingPersisting
    private let focusRestorer: PermissionFocusRestoring
    private var captureFocusRestorationPending = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        runtime: AudioRuntimeState,
        actions: AudioRuntimeUserActions,
        persistence: OnboardingPersisting,
        focusRestorer: PermissionFocusRestoring? = nil
    ) {
        self.runtime = runtime
        self.actions = actions
        self.persistence = persistence
        self.focusRestorer = focusRestorer ?? PermissionWindowFocusRestorer.shared
        currentStep = persistence.checkpoint
        captureFailureGuidance = Self.failureGuidance(for: runtime.captureAccess)
        runtime.$captureAccess
            .sink { [weak self] captureAccess in
                guard let self else { return }
                switch captureAccess {
                case .permissionRequired:
                    self.captureFailureGuidance = CaptureFailureGuidance.make(for: .permissionRequired)
                case .failed(let reason):
                    self.captureFailureGuidance = CaptureFailureGuidance.make(for: .failed(reason: reason))
                case .unverified, .checking, .verified:
                    self.captureFailureGuidance = nil
                }
                guard self.captureFocusRestorationPending,
                      captureAccess != .checking else { return }
                self.captureFocusRestorationPending = false
                self.focusRestorer.permissionRequestResolved()
            }
            .store(in: &cancellables)
        runtime.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var shouldPresentAutomatically: Bool { !persistence.isComplete && !persistence.isDeferred }
    var shouldShowSetupMenuItem: Bool { needsSetupAttention }
    var isComplete: Bool { persistence.isComplete }

    /// First-run completion remains gated by live runtime readiness.
    var isConfigurationHealthy: Bool { runtime.isSetupHealthy }
    var needsSetupAttention: Bool {
        if !persistence.isComplete { return true }
        return runtime.hasBlockingHealthIssue
    }

    var recommendedVoluntaryEntryStep: OnboardingStepV2 {
        if persistence.isComplete && runtime.hasBlockingHealthIssue { return .liveHealth }
        if persistence.isComplete { return .welcome }
        if runtime.status == .needsPermission { return .systemAudio }
        if case .failed = runtime.captureAccess { return .systemAudio }
        if runtime.currentOutput != nil, !runtime.isCurrentOutputRoutable {
            return .liveHealth
        }
        if captureAccessPresentation != .verified { return .systemAudio }
        return .liveHealth
    }

    var captureAccessPresentation: CaptureAccessPresentation {
        switch runtime.captureAccess {
        case .unverified: return .unverified
        case .checking: return .checking
        case .verified: return .verified
        case .permissionRequired: return .permissionRequired
        case .failed(let reason): return .failed(reason: reason)
        }
    }

    private static func failureGuidance(
        for captureAccess: AudioRuntimeState.CaptureAccess
    ) -> CaptureFailureGuidance? {
        switch captureAccess {
        case .permissionRequired:
            CaptureFailureGuidance.make(for: .permissionRequired)
        case .failed(let reason):
            CaptureFailureGuidance.make(for: .failed(reason: reason))
        case .unverified, .checking, .verified:
            nil
        }
    }

    // SettingsView keeps its existing call-site label; value still comes from one capture state.
    var permissionPresentation: CaptureAccessPresentation { captureAccessPresentation }

    func canComplete(allowingUnknownCapture: Bool) -> Bool {
        guard runtime.isCurrentOutputRoutable else { return false }
        guard !runtime.hasBlockingHealthIssue else { return false }

        switch runtime.captureAccess {
        case .verified:
            return true
        case .unverified:
            return allowingUnknownCapture && captureFailureGuidance == nil
        case .checking, .permissionRequired, .failed:
            return false
        }
    }

    func advance() {
        guard let index = OnboardingStepV2.allCases.firstIndex(of: currentStep),
              index + 1 < OnboardingStepV2.allCases.count else { return }
        currentStep = OnboardingStepV2.allCases[index + 1]
        persistence.checkpoint = currentStep
    }

    func goBack() {
        guard let index = OnboardingStepV2.allCases.firstIndex(of: currentStep), index > 0 else { return }
        currentStep = OnboardingStepV2.allCases[index - 1]
        persistence.checkpoint = currentStep
    }

    func selectStep(_ step: OnboardingStepV2) {
        guard step != currentStep, OnboardingStepV2.allCases.contains(step) else { return }
        currentStep = step
        persistence.checkpoint = step
    }

    func requestPermission() {
        captureFocusRestorationPending = true
        focusRestorer.beginPermissionRequest()
        actions.requestSystemAudioAccess()
    }

    func openPermissionSettings() { actions.openSystemAudioRecordingSettings() }
    func retry() { actions.retryNow() }

    func finishLater() {
        persistence.checkpoint = currentStep
        persistence.isDeferred = true
    }

    func resume() {
        persistence.isDeferred = false
        currentStep = persistence.checkpoint
    }


    func prepareForPresentation(_ context: OnboardingPresentationContext) {
        persistence.isDeferred = false
        switch context {
        case .automaticFirstSetup:
            currentStep = .welcome
        case .voluntary:
            currentStep = recommendedVoluntaryEntryStep
        }
        persistence.checkpoint = currentStep
    }

    @discardableResult
    func complete(allowingUnknownCapture: Bool) -> Bool {
        guard canComplete(allowingUnknownCapture: allowingUnknownCapture) else { return false }
        persistence.isComplete = true
        persistence.isDeferred = false
        persistence.checkpoint = .liveHealth
        return true
    }
}
