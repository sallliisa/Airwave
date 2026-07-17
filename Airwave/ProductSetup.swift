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
    func enableForFirstRun() throws
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
        try launchAtLogin.enableForFirstRun()
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
        case .systemAudio: "System Audio Capture"
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
    var persistedCaptureFailure: PersistedCaptureFailure? { get set }
}

final class UserDefaultsOnboardingPersistenceV2: OnboardingPersisting {
    static let currentVersion = 2
    private let defaults: UserDefaults
    private let versionKey = "Airwave.OnboardingV2.Version"
    private let checkpointKey = "Airwave.OnboardingV2.Checkpoint"
    private let completionKey = "Airwave.OnboardingV2.Completed"
    private let deferredKey = "Airwave.OnboardingV2.Deferred"
    private let captureFailureKey = "Airwave.OnboardingV2.CaptureFailure"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.integer(forKey: versionKey) != Self.currentVersion {
            defaults.set(Self.currentVersion, forKey: versionKey)
            defaults.set(OnboardingStepV2.welcome.rawValue, forKey: checkpointKey)
            defaults.set(false, forKey: completionKey)
            defaults.set(false, forKey: deferredKey)
            defaults.removeObject(forKey: captureFailureKey)
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

    var persistedCaptureFailure: PersistedCaptureFailure? {
        get {
            guard let data = defaults.data(forKey: captureFailureKey) else { return nil }
            return try? JSONDecoder().decode(PersistedCaptureFailure.self, from: data)
        }
        set {
            guard let newValue,
                  let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: captureFailureKey)
                return
            }
            defaults.set(data, forKey: captureFailureKey)
        }
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
                    "Enable Airwave under Privacy & Security → System Audio Capture.",
                    "Have another app actively playing audio."
                ]
            )
        case .failed(let reason):
            return Self(
                reason: reason,
                suggestions: [
                    "Enable Airwave under Privacy & Security → System Audio Capture.",
                    "Have another app actively playing audio.",
                    "Use a supported physical stereo output; virtual and aggregate outputs are unsupported."
                ]
            )
        case .unverified, .checking, .verified:
            return nil
        }
    }
}

struct PersistedCaptureFailure: Codable, Equatable {
    enum Kind: String, Codable {
        case permissionRequired
        case failed
    }

    let kind: Kind
    let reason: String?

    var presentation: CaptureAccessPresentation {
        switch kind {
        case .permissionRequired:
            return .permissionRequired
        case .failed:
            return .failed(reason: reason ?? "Audio capture test failed safely.")
        }
    }

    var guidance: CaptureFailureGuidance {
        switch kind {
        case .permissionRequired:
            return CaptureFailureGuidance.make(for: .permissionRequired)!
        case .failed:
            return CaptureFailureGuidance.make(for: .failed(reason: reason ?? "Audio capture test failed safely."))!
        }
    }

    static func make(for captureAccess: AudioRuntimeState.CaptureAccess) -> Self? {
        switch captureAccess {
        case .permissionRequired:
            return Self(kind: .permissionRequired, reason: nil)
        case .failed(let reason):
            return Self(kind: .failed, reason: reason)
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
        if runtime.captureAccess == .verified {
            persistence.persistedCaptureFailure = nil
            captureFailureGuidance = nil
        } else if let currentFailure = PersistedCaptureFailure.make(for: runtime.captureAccess) {
            persistence.persistedCaptureFailure = currentFailure
            captureFailureGuidance = currentFailure.guidance
        } else {
            captureFailureGuidance = persistence.persistedCaptureFailure?.guidance
        }
        runtime.$captureAccess
            .sink { [weak self] captureAccess in
                guard let self else { return }
                switch captureAccess {
                case .permissionRequired:
                    let failure = PersistedCaptureFailure(kind: .permissionRequired, reason: nil)
                    self.persistence.persistedCaptureFailure = failure
                    self.captureFailureGuidance = failure.guidance
                case .failed(let reason):
                    let failure = PersistedCaptureFailure(kind: .failed, reason: reason)
                    self.persistence.persistedCaptureFailure = failure
                    self.captureFailureGuidance = failure.guidance
                case .verified:
                    self.persistence.persistedCaptureFailure = nil
                    self.captureFailureGuidance = nil
                case .unverified, .checking:
                    break
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
        if captureFailureGuidance != nil { return true }
        switch runtime.captureAccess {
        case .permissionRequired, .failed: return true
        case .unverified, .checking: return false
        case .verified: break
        }
        return false
    }

    var recommendedVoluntaryEntryStep: OnboardingStepV2 {
        if persistence.isComplete && !needsSetupAttention { return .welcome }
        if runtime.status == .needsPermission { return .systemAudio }
        if case .failed = runtime.captureAccess { return .systemAudio }
        if let output = runtime.currentOutput,
           output.outputChannelCount != 2 || output.isVirtual || output.isAggregate {
            return .liveHealth
        }
        if captureAccessPresentation != .verified { return .systemAudio }
        return .liveHealth
    }

    var captureAccessPresentation: CaptureAccessPresentation {
        switch runtime.captureAccess {
        case .unverified:
            return persistence.persistedCaptureFailure?.presentation ?? .unverified
        case .checking: return .checking
        case .verified: return .verified
        case .permissionRequired: return .permissionRequired
        case .failed(let reason): return .failed(reason: reason)
        }
    }

    // SettingsView keeps its existing call-site label; value still comes from one capture state.
    var permissionPresentation: CaptureAccessPresentation { captureAccessPresentation }

    func canComplete(allowingUnknownCapture: Bool) -> Bool {
        guard runtime.currentOutput?.isSupportedProfileOutput == true else { return false }

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
            detail = "System Audio Capture permission is required."
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
    let actionTitle: String?
    let canRetry: Bool
    let isAttention: Bool

    static func make(
        captureAccess: CaptureAccessPresentation,
        hasPreset: Bool,
        runtimeStatus: AudioRuntimeState.Status,
        isReady: Bool,
        hasCaptureFailureGuidance: Bool = false
    ) -> Self {
        if isReady {
            return Self(
                title: "You’re ready to go",
                detail: hasPreset
                    ? "Airwave is set up and ready to apply your spatial profile."
                    : "Airwave setup is complete. Choose an HRIR preset whenever you’re ready to enable spatial processing.",
                actionStep: nil,
                actionTitle: nil,
                canRetry: false,
                isAttention: false
            )
        }

        if hasCaptureFailureGuidance {
            return Self(
                title: "A little more setup is needed",
                detail: "System Audio Capture still needs your attention.",
                actionStep: .systemAudio,
                actionTitle: "Review Capture",
                canRetry: false,
                isAttention: true
            )
        }

        switch captureAccess {
        case .permissionRequired:
            return Self(
                title: "A little more setup is needed",
                detail: "System Audio Capture still needs your attention.",
                actionStep: .systemAudio,
                actionTitle: "Review Permission",
                canRetry: false,
                isAttention: true
            )
        case .failed:
            return Self(
                title: "A little more setup is needed",
                detail: "System Audio Capture failed. Review the capture step and try again.",
                actionStep: .systemAudio,
                actionTitle: "Review Capture",
                canRetry: false,
                isAttention: true
            )
        case .unverified:
            return Self(
                title: "Capture not confirmed",
                detail: "Run the System Audio Capture test to confirm Airwave can process system audio.",
                actionStep: .systemAudio,
                actionTitle: "Test System Audio Capture",
                canRetry: false,
                isAttention: false
            )
        case .checking:
            return Self(
                title: "Checking system audio capture",
                detail: "Airwave is running the capture test.",
                actionStep: nil,
                actionTitle: nil,
                canRetry: false,
                isAttention: false
            )
        case .verified:
            break
        }

        let menuPresentation = RuntimeMenuPresentation.make(from: runtimeStatus)
        return Self(
            title: "A little more setup is needed",
            detail: runtimeStatus == .starting
                ? "Airwave is getting everything ready. This should only take a moment."
                : "Airwave isn’t ready yet. Review the earlier steps or try again.",
            actionStep: nil,
            actionTitle: nil,
            canRetry: menuPresentation.canRetry,
            isAttention: menuPresentation.canRetry
        )
    }
}
