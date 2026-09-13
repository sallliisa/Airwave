import Foundation

enum OnboardingStepV2: String, CaseIterable, Codable {
    case welcome
    case systemAudio
    case hrirPreset
    case liveHealth

    /// Position in the setup flow; used for page numbering and slide direction.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var pageNumber: Int { index + 1 }

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
}

final class UserDefaultsOnboardingPersistenceV2: OnboardingPersisting {
    static let currentVersion = 2
    private let defaults: UserDefaults
    private let versionKey = "Airwave.OnboardingV2.Version"
    private let checkpointKey = "Airwave.OnboardingV2.Checkpoint"
    private let completionKey = "Airwave.OnboardingV2.Completed"
    private let deferredKey = "Airwave.OnboardingV2.Deferred"
    private let legacyCaptureFailureKey = "Airwave.OnboardingV2.CaptureFailure"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Runtime failures are live state. Older builds persisted them and could
        // resurrect a warning after the underlying condition had recovered.
        defaults.removeObject(forKey: legacyCaptureFailureKey)
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
