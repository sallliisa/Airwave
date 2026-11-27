import Combine
import Foundation
import Sparkle

struct HostUpdateConfiguration {
    let feed: URL

    init?(bundle: Bundle = .main) {
        self.init(
            feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
    }

    init?(feed: String?, publicKey: String?) {
        guard let feed, let url = URL(string: feed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              let publicKey, let key = Data(base64Encoded: publicKey), key.count == 32 else { return nil }
        self.feed = url
    }
}

@MainActor
final class HostUpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    private enum Status {
        case idle
        case checking
        case current
        case available(String)
        case failed(String)
    }

    let installedVersion: String
    @Published private var status: Status = .idle
    @Published private(set) var canCheck = false

    private let bundle: Bundle
    private let onRelaunch: () -> Void
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    init(bundle: Bundle = .main, onRelaunch: @escaping () -> Void) {
        self.bundle = bundle
        self.onRelaunch = onRelaunch
        installedVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var isAvailable: Bool { controller != nil }

    var statusLabel: String? {
        switch status {
        case .idle, .checking: return nil
        case .current: return "Up to date"
        case .available(let version): return "Version \(version) is available."
        case .failed(let reason): return "Update check failed. \(reason)"
        }
    }

    var actionTitle: String {
        if case .available = status { return "Update…" }
        return "Check for Updates…"
    }

    var isChecking: Bool {
        if case .checking = status { return true }
        return false
    }

    func start() {
        let environment = ProcessInfo.processInfo.environment
        guard controller == nil, environment["XCTestConfigurationFilePath"] == nil,
              environment["SYSTEM_AUDIO_HOST_TEST_PROFILE"] == nil,
              HostUpdateConfiguration(bundle: bundle) != nil else { return }

        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = updater
        observation = updater.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            guard let canCheck = change.newValue else { return }
            Task { @MainActor in self?.canCheck = canCheck }
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, updater.updater.canCheckForUpdates else { return }
            self.status = .checking
            updater.updater.checkForUpdateInformation()
        }
    }

    func checkForUpdates() {
        guard let controller, controller.updater.canCheckForUpdates else { return }
        status = .checking
        controller.checkForUpdates(nil)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        onRelaunch()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .available(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        status = .current
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        if let error {
            let failure = error as NSError
            if failure.domain == SUSparkleErrorDomain, failure.code == 1001 {
                status = .current
            } else {
                status = .failed(error.localizedDescription)
            }
        } else if case .checking = status {
            status = .idle
        }
    }
}
