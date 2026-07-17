import Foundation
import Combine
import Sparkle

nonisolated enum UpdateState: Equatable {
    case idle
    case checking
    case current
    case available(version: String)
    case error(message: String)
}

nonisolated struct UpdateStateModel: Equatable {
    private(set) var state: UpdateState = .idle

    mutating func beganChecking() {
        state = .checking
    }

    mutating func found(version: String) {
        state = .available(version: version)
    }

    mutating func foundNoUpdate() {
        state = .current
    }

    mutating func failed(message: String) {
        state = .error(message: message)
    }
}

@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    @Published private(set) var state: UpdateState = .idle

    let installedVersion: String

    private var model = UpdateStateModel() {
        didSet { state = model.state }
    }
    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: !Self.isTestHost,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private override init() {
        installedVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Unknown"
        super.init()

        guard !Self.isTestHost else { return }
        _ = updaterController

        // Sparkle owns the 24-hour schedule. This extra information-only probe
        // guarantees a silent check on launch and never downloads an update.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.checkSilently()
        }
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        model.beganChecking()
        updaterController.checkForUpdates(nil)
    }

    func presentAvailableUpdate() {
        updaterController.checkForUpdates(nil)
    }

    private func checkSilently() {
        guard updaterController.updater.canCheckForUpdates else { return }
        model.beganChecking()
        updaterController.updater.checkForUpdateInformation()
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        model.found(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        model.foundNoUpdate()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard let error else { return }

        // "No update" is delivered through updaterDidNotFindUpdate. Errors
        // reaching this callback represent feed, network, or validation failure.
        model.failed(message: error.localizedDescription)
    }
}
