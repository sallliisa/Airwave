import Foundation
import Combine

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
        case .welcome: "Welcome & Safety"
        case .systemAudio: "System Audio Recording"
        case .hrirPreset: "HRIR Preset"
        case .liveHealth: "Live Health"
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

enum SystemAudioPermissionPresentation: Equatable {
    case unknown
    case requesting
    case granted
    case denied
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    static let shared = OnboardingViewModel(
        runtime: .shared,
        actions: AudioRuntimeController.shared,
        persistence: UserDefaultsOnboardingPersistenceV2(),
        hasActivePreset: { HRIRManager.shared.activePreset != nil }
    )

    @Published private(set) var currentStep: OnboardingStepV2
    @Published private(set) var didRequestPermission = false
    @Published private(set) var observedPermissionRequest = false

    let runtime: AudioRuntimeState
    private let actions: AudioRuntimeUserActions
    private let persistence: OnboardingPersisting
    private let hasActivePreset: () -> Bool
    private var cancellables: Set<AnyCancellable> = []

    init(
        runtime: AudioRuntimeState,
        actions: AudioRuntimeUserActions,
        persistence: OnboardingPersisting,
        hasActivePreset: @escaping () -> Bool
    ) {
        self.runtime = runtime
        self.actions = actions
        self.persistence = persistence
        self.hasActivePreset = hasActivePreset
        currentStep = persistence.checkpoint
        runtime.$status
            .sink { [weak self] status in
                guard let self, self.didRequestPermission else { return }
                if case .starting = status { self.observedPermissionRequest = true }
                if case .recovering = status { self.observedPermissionRequest = true }
            }
            .store(in: &cancellables)
    }

    var shouldPresentAutomatically: Bool { !persistence.isComplete && !persistence.isDeferred }
    var isComplete: Bool { persistence.isComplete }

    var permissionPresentation: SystemAudioPermissionPresentation {
        switch runtime.status {
        case .needsPermission: .denied
        case .starting, .recovering: .requesting
        case .processing: .granted
        case .needsSetup where observedPermissionRequest: .granted
        default: .unknown
        }
    }

    var virtualOutputGuidance: String? {
        guard let output = runtime.currentOutput, output.isVirtual || output.isAggregate else { return nil }
        return "Airwave needs a physical stereo output. Choose one in macOS Sound settings; BlackHole and aggregate devices are unsupported."
    }

    var canComplete: Bool {
        guard hasActivePreset(), runtime.status == .processing,
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

    func requestPermission() {
        didRequestPermission = true
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
    let iconName: String
    let healthTitle: String
    let healthDetail: String
    let canRetry: Bool

    static func make(from status: AudioRuntimeState.Status) -> Self {
        let icon: String
        switch status {
        case .processing: icon = "waveform.circle.fill"
        case .recovering, .needsPermission, .nativePassthrough: icon = "exclamationmark.waveform"
        case .starting: icon = "waveform.badge.plus"
        case .unavailable, .needsSetup: icon = "waveform.circle"
        }
        let retryable: Bool
        switch status {
        case .needsPermission, .recovering: retryable = true
        default: retryable = false
        }
        return Self(iconName: icon, healthTitle: status.title, healthDetail: status.detail, canRetry: retryable)
    }
}
