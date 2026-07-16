import Combine
import Foundation

/// Resolves a device profile into one complete effect pair. Core Audio resource
/// ownership deliberately remains in AudioRuntimeController.
@MainActor
final class DeviceProfileRuntimeCoordinator: OutputEffectProfilePreparing {
    static let shared = DeviceProfileRuntimeCoordinator(
        profiles: .shared,
        hrir: .shared,
        equalizer: .shared,
        controller: .shared
    )

    private let profiles: DeviceProfileManager
    private let hrir: HRIRManager
    private let equalizer: EqualizerManager
    private let controller: AudioRuntimeController
    private var cancellables: Set<AnyCancellable> = []
    private var generation = 0
    private var launched = false
    private var isSanitizing = false
    private var pendingPreparation: (output: OutputDeviceDescriptor, completion: (AudioRuntimeEffectReadiness) -> Void)?

    init(
        profiles: DeviceProfileManager,
        hrir: HRIRManager,
        equalizer: EqualizerManager,
        controller: AudioRuntimeController
    ) {
        self.profiles = profiles
        self.hrir = hrir
        self.equalizer = equalizer
        self.controller = controller
    }

    func launch() {
        guard !launched else { return }
        launched = true
        controller.setProfilePreparer(self)

        profiles.changes.sink { [weak self] change in
            self?.profileChanged(change)
        }.store(in: &cancellables)

        hrir.$presets.combineLatest(hrir.$initialLibrarySyncReady)
            .sink { [weak self] _, ready in
                guard ready else { return }
                self?.reconcileLibraries()
                self?.resumePendingPreparation()
            }.store(in: &cancellables)
        equalizer.$presets.sink { [weak self] _ in
            guard self?.hrir.initialLibrarySyncReady == true else { return }
            self?.reconcileLibraries()
        }.store(in: &cancellables)

        controller.launch(
            effectReadiness: .init(spatialReady: false, equalizerDefinition: nil)
        )
    }

    func prepare(
        output: OutputDeviceDescriptor,
        completion: @escaping (AudioRuntimeEffectReadiness) -> Void
    ) {
        generation += 1
        let requestedGeneration = generation
        hrir.deactivatePreset()
        guard output.isSupportedProfileOutput, let profile = profiles.observe(output) else {
            completion(.init(spatialReady: false, equalizerDefinition: nil))
            return
        }

        var resolvedProfile = profile
        if let id = resolvedProfile.equalizerPresetID, equalizer.preset(id: id) == nil {
            isSanitizing = true
            profiles.clearMissingEqualizerPresetIDs([id])
            isSanitizing = false
            resolvedProfile.equalizerPresetID = nil
        }
        if hrir.initialLibrarySyncReady,
           let id = resolvedProfile.hrirPresetID,
           !hrir.presets.contains(where: { $0.id == id }) {
            isSanitizing = true
            profiles.clearMissingHRIRPresetIDs([id])
            isSanitizing = false
            resolvedProfile.hrirPresetID = nil
        }

        let definition = equalizer.preset(id: resolvedProfile.equalizerPresetID)?.definition
        if resolvedProfile.hrirPresetID != nil && !hrir.initialLibrarySyncReady {
            pendingPreparation = (output, completion)
            return
        }
        guard let hrirID = resolvedProfile.hrirPresetID,
              let preset = hrir.presets.first(where: { $0.id == hrirID }) else {
            completion(.init(spatialReady: false, equalizerDefinition: definition))
            return
        }

        hrir.activatePreset(
            preset,
            targetSampleRate: output.nominalSampleRate,
            inputLayout: .stereo
        ) { [weak self] result in
            guard let self, requestedGeneration == self.generation else { return }
            switch result {
            case .success:
                completion(.init(spatialReady: true, equalizerDefinition: definition))
            case .failure(let message):
                completion(.init(
                    spatialReady: false,
                    equalizerDefinition: definition,
                    spatialError: message
                ))
            }
        }
    }

    func cancelPreparation() {
        generation += 1
        pendingPreparation = nil
        hrir.deactivatePreset()
    }

    func outputBecameUnsupportedOrUnavailable() {
        cancelPreparation()
        _ = profiles.observe(nil)
    }

    private func profileChanged(_ change: DeviceProfileChange) {
        guard !isSanitizing, change.deviceUID == profiles.currentDeviceUID else { return }
        switch change.effect {
        case .metadata:
            break
        case .equalizer:
            let definition = equalizer.preset(id: profiles.currentProfile?.equalizerPresetID)?.definition
            controller.updateCurrentEqualizer(definition)
        case .hrir, .both:
            controller.reprepareCurrentOutput()
        }
    }

    private func reconcileLibraries() {
        guard hrir.initialLibrarySyncReady else { return }
        let hrirIDs = Set(hrir.presets.map(\.id))
        let eqIDs = Set(equalizer.presets.map(\.id))
        let missingHRIR = Set(profiles.profiles.compactMap(\.hrirPresetID)).subtracting(hrirIDs)
        let missingEQ = Set(profiles.profiles.compactMap(\.equalizerPresetID)).subtracting(eqIDs)
        let currentHRIRMissing = profiles.currentProfile?.hrirPresetID.map(missingHRIR.contains) == true
        let currentEQMissing = profiles.currentProfile?.equalizerPresetID.map(missingEQ.contains) == true
        isSanitizing = true
        profiles.clearMissingHRIRPresetIDs(missingHRIR)
        profiles.clearMissingEqualizerPresetIDs(missingEQ)
        isSanitizing = false
        if currentHRIRMissing {
            controller.reprepareCurrentOutput()
        } else if currentEQMissing {
            controller.updateCurrentEqualizer(nil)
        }
    }

    private func resumePendingPreparation() {
        guard let pending = pendingPreparation else { return }
        pendingPreparation = nil
        prepare(output: pending.output, completion: pending.completion)
    }
}
