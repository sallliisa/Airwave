import Foundation

@MainActor
final class OutputDeviceDiscoveryCoordinator {
    static let shared = OutputDeviceDiscoveryCoordinator(
        profiles: .shared,
        client: CoreAudioPlatformClient()
    )

    private let profiles: DeviceProfileManager
    private let client: any OutputDeviceDiscovering
    private var launched = false

    init(profiles: DeviceProfileManager, client: any OutputDeviceDiscovering) {
        self.profiles = profiles
        self.client = client
    }

    deinit {
        client.stopObservingAvailableOutputs()
    }

    func launch() {
        guard !launched else { return }
        launched = true

        do {
            profiles.updateAvailableOutputs(try client.availableOutputDevices())
        } catch {
            Logger.log("[OutputDiscovery] Initial inventory failed: \(error)")
        }

        do {
            try client.observeAvailableOutputs { [weak self] outputs in
                Task { @MainActor [weak self] in
                    self?.profiles.updateAvailableOutputs(outputs)
                }
            }
        } catch {
            Logger.log("[OutputDiscovery] Unable to observe inventory: \(error)")
        }
    }
}
