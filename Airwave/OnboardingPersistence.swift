import Foundation

protocol OnboardingPersistence {
    var onboardingVersion: Int { get set }
    var checkpoint: SetupStep { get set }
    var isComplete: Bool { get set }
    var isDismissedForCurrentLaunch: Bool { get }

    func beginLaunch()
    func dismissForCurrentLaunch()
}

final class UserDefaultsOnboardingPersistence: OnboardingPersistence {
    static let currentVersion = 1

    private let defaults: UserDefaults
    private let launchID = UUID().uuidString
    private let versionKey = "Airwave.Onboarding.Version"
    private let checkpointKey = "Airwave.Onboarding.Checkpoint"
    private let completionKey = "Airwave.Onboarding.Completed"
    private let dismissedLaunchKey = "Airwave.Onboarding.DismissedLaunch"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var onboardingVersion: Int {
        get { defaults.integer(forKey: versionKey) == 0 ? Self.currentVersion : defaults.integer(forKey: versionKey) }
        set { defaults.set(newValue, forKey: versionKey) }
    }

    var checkpoint: SetupStep {
        get {
            guard let rawValue = defaults.string(forKey: checkpointKey),
                  let step = SetupStep(rawValue: rawValue) else { return .introduction }
            return step
        }
        set { defaults.set(newValue.rawValue, forKey: checkpointKey) }
    }

    var isComplete: Bool {
        get { defaults.bool(forKey: completionKey) }
        set { defaults.set(newValue, forKey: completionKey) }
    }

    var isDismissedForCurrentLaunch: Bool {
        defaults.string(forKey: dismissedLaunchKey) == launchID
    }

    func beginLaunch() {
        defaults.set(launchID, forKey: "Airwave.Onboarding.CurrentLaunch")
        defaults.removeObject(forKey: dismissedLaunchKey)
        if defaults.object(forKey: versionKey) == nil {
            defaults.set(Self.currentVersion, forKey: versionKey)
        }
    }

    func dismissForCurrentLaunch() {
        defaults.set(launchID, forKey: dismissedLaunchKey)
    }
}

final class InMemoryOnboardingPersistence: OnboardingPersistence {
    var onboardingVersion = UserDefaultsOnboardingPersistence.currentVersion
    var checkpoint: SetupStep = .introduction
    var isComplete = false
    private(set) var isDismissedForCurrentLaunch = false

    func beginLaunch() { isDismissedForCurrentLaunch = false }
    func dismissForCurrentLaunch() { isDismissedForCurrentLaunch = true }
}
