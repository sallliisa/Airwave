import AppKit
import Combine
import Foundation

@MainActor
protocol ApplicationActivationPolicyApplying: AnyObject {
    @discardableResult
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
}

extension NSApplication: ApplicationActivationPolicyApplying {}

@MainActor
final class MenuBarVisibilityManager: ObservableObject {
    static let shared = MenuBarVisibilityManager()
    static let defaultsKey = "Airwave.Application.ShowInMenuBar"

    @Published var isVisible: Bool {
        didSet {
            defaults.set(isVisible, forKey: Self.defaultsKey)
            visibilityDidChange()
        }
    }

    private let defaults: UserDefaults
    private let visibilityDidChange: () -> Void

    init(
        defaults: UserDefaults = .standard,
        visibilityDidChange: (() -> Void)? = nil
    ) {
        self.defaults = defaults
        self.visibilityDidChange = visibilityDidChange ?? {
            ApplicationLifecycleCoordinator.shared.updateActivationPolicy()
        }
        isVisible = defaults.object(forKey: Self.defaultsKey) == nil ? false : defaults.bool(forKey: Self.defaultsKey)
    }

    func setVisible(_ value: Bool) {
        guard value != isVisible else { return }
        isVisible = value
    }

    func applyActivationPolicy() {
        ApplicationLifecycleCoordinator.shared.updateActivationPolicy()
    }
}

protocol LaunchAtLoginResetting: AnyObject {
    func disableForSchemaReset() throws
}

struct SettingsSchemaV2Migrator {
    static let markerKey = "Airwave.SchemaV2.ResetCompleted"
    static let legacyKeys = [
        "Airwave.AppSettings",
        "Airwave.Onboarding.Version",
        "Airwave.Onboarding.Checkpoint",
        "Airwave.Onboarding.Completed",
        "Airwave.Onboarding.DismissedLaunch",
        "Airwave.Onboarding.CurrentLaunch",
        "SavedSystemOutputDeviceUID"
    ]

    let defaults: UserDefaults
    let launchAtLogin: LaunchAtLoginResetting

    @discardableResult
    func migrateIfNeeded() throws -> Bool {
        guard !defaults.bool(forKey: Self.markerKey) else { return false }
        try launchAtLogin.disableForSchemaReset()
        Self.legacyKeys.forEach(defaults.removeObject(forKey:))
        defaults.set(true, forKey: Self.markerKey)
        return true
    }
}

enum OnboardingStepV2: String, CaseIterable, Codable {
    case welcome
    case systemAudio
    case hrirPreset
    case liveHealth

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .systemAudio: "System Audio Recording"
        case .hrirPreset: "HRIR Preset"
        case .liveHealth: "Finish"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "sparkles"
        case .systemAudio: "waveform.badge.mic"
        case .hrirPreset: "waveform.circle"
        case .liveHealth: "checkmark.seal"
        }
    }
}

protocol OnboardingPersisting: AnyObject {
    var version: Int { get set }
    var checkpoint: OnboardingStepV2 { get set }
    var isComplete: Bool { get set }
    var isDeferred: Bool { get set }
}

final class UserDefaultsOnboardingPersistenceV2: OnboardingPersisting {
    static let currentVersion = 2
    private let defaults: UserDefaults
    private let versionKey = "Airwave.OnboardingV2.Version"
    private let checkpointKey = "Airwave.OnboardingV2.Checkpoint"
    private let completionKey = "Airwave.OnboardingV2.Completed"
    private let deferredKey = "Airwave.OnboardingV2.Deferred"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.integer(forKey: versionKey) != Self.currentVersion {
            defaults.set(Self.currentVersion, forKey: versionKey)
            defaults.set(OnboardingStepV2.welcome.rawValue, forKey: checkpointKey)
            defaults.set(false, forKey: completionKey)
            defaults.set(false, forKey: deferredKey)
        }
    }

    var version: Int {
        get { defaults.integer(forKey: versionKey) }
        set { defaults.set(newValue, forKey: versionKey) }
    }

    var checkpoint: OnboardingStepV2 {
        get { OnboardingStepV2(rawValue: defaults.string(forKey: checkpointKey) ?? "") ?? .welcome }
        set { defaults.set(newValue.rawValue, forKey: checkpointKey) }
    }

    var isComplete: Bool {
        get { defaults.bool(forKey: completionKey) }
        set { defaults.set(newValue, forKey: completionKey) }
    }

    var isDeferred: Bool {
        get { defaults.bool(forKey: deferredKey) }
        set { defaults.set(newValue, forKey: deferredKey) }
    }
}

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
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
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

enum SystemAudioPermissionPresentation: Equatable {
    case unknown
    case requesting
    case granted
    case denied
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
    @Published private(set) var didRequestPermission = false
    @Published private(set) var observedPermissionRequest = false

    let runtime: AudioRuntimeState
    private let actions: AudioRuntimeUserActions
    private let persistence: OnboardingPersisting
    private let focusRestorer: PermissionFocusRestoring
    private var permissionFocusRestorationPending = false
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
        runtime.$status
            .sink { [weak self] status in
                guard let self, self.didRequestPermission else { return }
                if case .starting = status { self.observedPermissionRequest = true }
                if case .recovering = status { self.observedPermissionRequest = true }
                if self.observedPermissionRequest && self.permissionFocusRestorationPending {
                    switch status {
                    case .processing, .needsPermission, .inactive:
                        self.permissionFocusRestorationPending = false
                        self.focusRestorer.permissionRequestResolved()
                    default:
                        break
                    }
                }
            }
            .store(in: &cancellables)
    }

    var shouldPresentAutomatically: Bool { !persistence.isComplete && !persistence.isDeferred }
    var shouldShowSetupMenuItem: Bool { !persistence.isComplete }
    var isComplete: Bool { persistence.isComplete }

    /// Configuration health is distinct from first-time onboarding completion.
    /// An intentionally inactive runtime is healthy because HRIR "None" leaves
    /// native audio unchanged, even when this launch has not probed permission.
    var isConfigurationHealthy: Bool { runtime.status == .inactive || canComplete }
    var needsSetupAttention: Bool { !isConfigurationHealthy }

    var recommendedVoluntaryEntryStep: OnboardingStepV2 {
        if isConfigurationHealthy { return .welcome }
        if runtime.status == .needsPermission { return .systemAudio }
        if let output = runtime.currentOutput,
           output.outputChannelCount != 2 || output.isVirtual || output.isAggregate {
            return .liveHealth
        }
        if permissionPresentation != .granted { return .systemAudio }
        return .liveHealth
    }

    var permissionPresentation: SystemAudioPermissionPresentation {
        switch runtime.status {
        case .needsPermission: .denied
        case .starting, .recovering: .requesting
        case .processing: .granted
        case .inactive where observedPermissionRequest || persistence.isComplete: .granted
        default: .unknown
        }
    }

    var canComplete: Bool {
        if runtime.status == .inactive && persistence.isComplete { return true }
        guard permissionPresentation == .granted,
              runtime.status == .processing || runtime.status == .inactive,
              let output = runtime.currentOutput else { return false }
        return output.outputChannelCount == 2 && !output.isVirtual && !output.isAggregate
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
        didRequestPermission = true
        observedPermissionRequest = false
        permissionFocusRestorationPending = true
        focusRestorer.beginPermissionRequest()
        actions.requestSystemAudioAccess()
        objectWillChange.send()
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
    func complete() -> Bool {
        guard canComplete else { return false }
        persistence.isComplete = true
        persistence.isDeferred = false
        persistence.checkpoint = .liveHealth
        return true
    }
}

struct RuntimeMenuPresentation: Equatable {
    let statusIconName: String
    let healthTitle: String
    let healthDetail: String
    let canRetry: Bool

    static func make(from status: AudioRuntimeState.Status) -> Self {
        let statusIcon: String
        let detail: String
        switch status {
        case .processing:
            statusIcon = "waveform.circle.fill"
            detail = "Airwave is active."
        case .starting:
            statusIcon = "waveform.badge.plus"
            detail = "Airwave is getting ready."
        case .needsPermission:
            statusIcon = "exclamationmark.waveform"
            detail = "System Audio Recording permission is required."
        case .inactive:
            statusIcon = "waveform.circle"
            detail = "No HRIR preset selected; native audio remains unchanged."
        case .nativePassthrough:
            statusIcon = "exclamationmark.waveform"
            detail = "Airwave is waiting until it can resume processing."
        case .recovering:
            statusIcon = "exclamationmark.waveform"
            detail = "Airwave is getting ready again."
        case .unavailable:
            statusIcon = "exclamationmark.waveform"
            detail = "Airwave isn’t available right now."
        }
        let retryable: Bool
        switch status {
        case .needsPermission, .recovering: retryable = true
        default: retryable = false
        }
        return Self(
            statusIconName: statusIcon,
            healthTitle: status.title,
            healthDetail: detail,
            canRetry: retryable
        )
    }
}

struct OnboardingReadinessPresentation: Equatable {
    let title: String
    let detail: String
    let actionStep: OnboardingStepV2?
    let canRetry: Bool

    static func make(
        permission: SystemAudioPermissionPresentation,
        hasPreset: Bool,
        runtimeStatus: AudioRuntimeState.Status,
        isReady: Bool
    ) -> Self {
        if isReady {
            return Self(
                title: "You’re ready to go",
                detail: hasPreset
                    ? "Airwave is set up and ready to apply your spatial profile."
                    : "Airwave setup is complete. Choose an HRIR preset whenever you’re ready to enable spatial processing.",
                actionStep: nil,
                canRetry: false
            )
        }
        if permission != .granted {
            return Self(
                title: "A little more setup is needed",
                detail: "System Audio Recording still needs your attention.",
                actionStep: .systemAudio,
                canRetry: false
            )
        }
        let menuPresentation = RuntimeMenuPresentation.make(from: runtimeStatus)
        return Self(
            title: "A little more setup is needed",
            detail: runtimeStatus == .starting
                ? "Airwave is getting everything ready. This should only take a moment."
                : "Airwave isn’t ready yet. Review the earlier steps or try again.",
            actionStep: nil,
            canRetry: menuPresentation.canRetry
        )
    }
}
