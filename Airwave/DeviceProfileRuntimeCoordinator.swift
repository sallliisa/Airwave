import Combine
import Foundation

/// Resolves a device profile into one complete effect pair. Core Audio resource
/// ownership deliberately remains in AudioRuntimeController.
/// Liveness surface the coordinator needs from the runtime controller.
/// Production `AudioRuntimeController` conforms; tests wrap it with a
/// counting spy. Exists so plan 037 tests observe live-update counts
/// without subclassing (controller state is private).
@MainActor
protocol AudioRuntimeControlling: AnyObject {
    var canUpdateSpatialLive: Bool { get }
    var isDeferredTeardownPendingForTesting: Bool { get }
    @discardableResult
    func updateSpatialLive(isReady: Bool) -> Bool
    func updateCurrentEqualizer(_ definition: EqualizerDefinition?)
    func presetActivationFailed(_ message: String)
    func reprepareCurrentOutput()
}

extension AudioRuntimeController: AudioRuntimeControlling {}

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
    private let controller: any AudioRuntimeControlling
    /// Owned preparer registration. The protocol hides `setProfilePreparer`,
    /// so the coordinator keeps the concrete controller only for launch.
    private let preparerHost: AudioRuntimeController?
    private var cancellables: Set<AnyCancellable> = []
    private var generation = 0
    private var launched = false
    private var isSanitizing = false
    private var pendingPreparation: (routing: ResolvedOutputRouting, completion: (AudioRuntimeEffectReadiness) -> Void)?
    /// Route the live pipeline was prepared for; HRIR swaps reuse its source layout and rate.
    private var preparedRouting: ResolvedOutputRouting?
    /// Latest arrays emitted by the `$presets` subscriptions. `@Published`
    /// sends during willSet, so a read of the backing property inside the
    /// sink can still hold the old value; reconciliation below uses these.
    private var latestHRIRSnapshot: [HRIRPreset] = []
    private var latestEqualizerSnapshot: [EqualizerPreset] = []
    /// Last applied selected content: HRIR revision and EQ definition.
    /// A snapshot that changes neither must not restart audio.
    private var lastAppliedHRIRRevision: HRIRContentIdentity?
    private var lastAppliedEqualizerDefinition: EqualizerDefinition?

    init(
        profiles: DeviceProfileManager,
        hrir: HRIRManager,
        equalizer: EqualizerManager,
        controller: any AudioRuntimeControlling,
        preparerHost: AudioRuntimeController? = nil
    ) {
        self.profiles = profiles
        self.hrir = hrir
        self.equalizer = equalizer
        self.controller = controller
        self.preparerHost = preparerHost ?? (controller as? AudioRuntimeController)
    }

    /// Production convenience: the controller is its own preparer host.
    convenience init(
        profiles: DeviceProfileManager,
        hrir: HRIRManager,
        equalizer: EqualizerManager,
        controller: AudioRuntimeController
    ) {
        self.init(profiles: profiles, hrir: hrir, equalizer: equalizer, controller: controller as any AudioRuntimeControlling, preparerHost: controller)
    }

    func launch() {
        guard !launched else { return }
        launched = true
        preparerHost?.setProfilePreparer(self)

        profiles.changes.sink { [weak self] change in
            self?.profileChanged(change)
        }.store(in: &cancellables)

        hrir.$presets.combineLatest(hrir.$initialLibrarySyncReady)
            .sink { [weak self] presets, ready in
                guard ready else { return }
                self?.latestHRIRSnapshot = presets
                self?.reconcileLibraries(hrirSnapshot: presets)
                self?.reloadSelectedHRIRIfChanged()
                self?.resumePendingPreparation()
            }.store(in: &cancellables)
        equalizer.$presets.sink { [weak self] presets in
            guard self?.hrir.initialLibrarySyncReady == true else { return }
            self?.latestEqualizerSnapshot = presets
            self?.reconcileLibraries(equalizerSnapshot: presets)
            self?.reloadSelectedEqualizerIfChanged()
        }.store(in: &cancellables)

        preparerHost?.launch(
            effectReadiness: .init(spatialReady: false, equalizerDefinition: nil)
        )
    }

    func savedOutputChannels(for output: OutputDeviceDescriptor) -> StereoOutputChannels? {
        // Keep the active UID visible even when a saved pair no longer matches
        // the device geometry, so the configuration editor can repair it.
        profiles.observeCurrentOutput(output)
        return profiles.profile(for: output.uid)?.outputChannels
    }

    func prepare(
        routing: ResolvedOutputRouting,
        completion: @escaping (AudioRuntimeEffectReadiness) -> Void
    ) {
        generation += 1
        let requestedGeneration = generation
        let output = routing.device
        // Full preparation always follows a pipeline teardown; drop render state
        // instead of fading, so a rebuilt pipeline never resumes a stale preset.
        hrir.deactivatePreset(immediate: true)
        preparedRouting = routing
        profiles.observeCurrentOutput(output)

        var hrirPresetID = profiles.currentProfile?.hrirPresetID
        var equalizerPresetID = profiles.currentProfile?.equalizerPresetID
        if let id = equalizerPresetID, equalizer.preset(id: id) == nil {
            isSanitizing = true
            profiles.clearMissingEqualizerPresetIDs([id])
            isSanitizing = false
            equalizerPresetID = nil
        }
        if hrir.initialLibrarySyncReady,
           let id = hrirPresetID,
           !hrir.presets.contains(where: { $0.id == id }) {
            isSanitizing = true
            profiles.clearMissingHRIRPresetIDs([id])
            isSanitizing = false
            hrirPresetID = nil
        }

        let definition = equalizer.preset(id: equalizerPresetID)?.definition
        if hrirPresetID != nil && !hrir.initialLibrarySyncReady {
            pendingPreparation = (routing, completion)
            return
        }
        guard let hrirID = hrirPresetID,
              let preset = hrir.presets.first(where: { $0.id == hrirID }) else {
            lastAppliedEqualizerDefinition = definition
            completion(.init(spatialReady: false, equalizerDefinition: definition))
            return
        }

        hrir.activatePreset(
            preset,
            targetSampleRate: routing.sampleRate,
            inputLayout: routing.inputLayout
        ) { [weak self] result in
            guard let self, requestedGeneration == self.generation else { return }
            switch result {
            case .success:
                self.lastAppliedHRIRRevision = self.hrir.contentRevisionForTesting(filename: preset.fileURL.lastPathComponent)
                self.lastAppliedEqualizerDefinition = definition
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
        preparedRouting = nil
        hrir.deactivatePreset(immediate: true)
    }

    func outputBecameUnsupportedOrUnavailable() {
        cancelPreparation()
        profiles.observeCurrentOutput(nil)
    }

    private func profileChanged(_ change: DeviceProfileChange) {
        guard !isSanitizing, change.deviceUID == profiles.currentDeviceUID else { return }
        switch change.effect {
        case .metadata:
            break
        case .routing, .reset:
            // Resolve and rebuild once for the active UID. Inactive profile
            // edits return above and leave the live route untouched.
            controller.reprepareCurrentOutput()
        case .equalizer:
            let definition = equalizer.preset(id: profiles.currentProfile?.equalizerPresetID)?.definition
            lastAppliedEqualizerDefinition = definition
            controller.updateCurrentEqualizer(definition)
        case .hrir, .both:
            spatialProfileChanged(includesEqualizer: change.effect == .both)
        }
    }

    /// Swaps the HRIR preset on the live pipeline; the render thread crossfades
    /// between renderer states. Restarts only when no live pipeline can take it.
    private func spatialProfileChanged(includesEqualizer: Bool) {
        let definition = equalizer.preset(id: profiles.currentProfile?.equalizerPresetID)?.definition
        // HRIR→None (plan 021 Step 2): publish the empty-renderer state first so
        // the renderer crossfades to passthrough, then let the controller hold
        // the tap past the fade before teardown. Checked BEFORE liveness so the
        // wedged-pipeline variant of the incident takes this path too.
        guard let hrirID = profiles.currentProfile?.hrirPresetID,
              let preset = hrir.presets.first(where: { $0.id == hrirID }) else {
            generation += 1
            hrir.deactivatePreset()
            guard definition == nil else {
                // An equalizer remains: existing behavior — keep the pipeline
                // alive, push the EQ live, and fade the renderer out.
                guard controller.canUpdateSpatialLive, preparedRouting != nil,
                      !controller.isDeferredTeardownPendingForTesting else {
                    controller.reprepareCurrentOutput()
                    return
                }
                if includesEqualizer { controller.updateCurrentEqualizer(definition) }
                _ = controller.updateSpatialLive(isReady: false)
                return
            }
            // Nothing left to run: publish passthrough (the renderer fades)
            // and let the controller defer the tap teardown past the fade, so
            // destroying the tap cannot unmute native audio into program audio.
            if includesEqualizer { controller.updateCurrentEqualizer(nil) }
            _ = controller.updateSpatialLive(isReady: false)
            return
        }
        guard controller.canUpdateSpatialLive, let routing = preparedRouting else {
            controller.reprepareCurrentOutput()
            return
        }
        // A preset was re-selected while a previous None-switch teardown is
        // still inside its hold window: never live-update into a dying chain.
        if controller.isDeferredTeardownPendingForTesting {
            controller.reprepareCurrentOutput()
            return
        }

        generation += 1
        let requestedGeneration = generation
        hrir.activatePreset(
            preset,
            targetSampleRate: routing.sampleRate,
            inputLayout: routing.inputLayout
        ) { [weak self] result in
            guard let self, requestedGeneration == self.generation else { return }
            switch result {
            case .success:
                self.lastAppliedHRIRRevision = self.hrir.contentRevisionForTesting(filename: preset.fileURL.lastPathComponent)
                if includesEqualizer {
                    let definition = self.equalizer.preset(id: self.profiles.currentProfile?.equalizerPresetID)?.definition
                    self.lastAppliedEqualizerDefinition = definition
                    self.controller.updateCurrentEqualizer(definition)
                }
                self.controller.updateSpatialLive(isReady: true)
            case .failure(let message):
                self.hrir.deactivatePreset(immediate: true)
                self.lastAppliedHRIRRevision = nil
                self.controller.presetActivationFailed(message)
            }
        }
    }

    private func reconcileLibraries(
        hrirSnapshot: [HRIRPreset]? = nil,
        equalizerSnapshot: [EqualizerPreset]? = nil
    ) {
        guard hrir.initialLibrarySyncReady else { return }
        // Use the emitted snapshot on this event, not the backing property:
        // willSet timing can leave the property one event behind.
        let hrirPresets = hrirSnapshot ?? (latestHRIRSnapshot.isEmpty ? hrir.presets : latestHRIRSnapshot)
        let eqPresets = equalizerSnapshot ?? (latestEqualizerSnapshot.isEmpty ? equalizer.presets : latestEqualizerSnapshot)
        let hrirIDs = Set(hrirPresets.map(\.id))
        let eqIDs = Set(eqPresets.map(\.id))
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
        prepare(routing: pending.routing, completion: pending.completion)
    }

    /// 037 step 2/3: the selected HRIR file changed content. Route through
    /// the existing live-update path; keep pipeline identity and the
    /// prepared output rate. A removal snapshot clears through
    /// reconciliation above; this handles the still-selected replacement.
    private func reloadSelectedHRIRIfChanged() {
        guard let routing = preparedRouting,
              controller.canUpdateSpatialLive,
              !controller.isDeferredTeardownPendingForTesting else { return }
        let selectedID = profiles.currentProfile?.hrirPresetID
        // Coordinator-side duplicate gate: this exact revision already
        // applied through an earlier snapshot or the prepare path.
        if let selectedID,
           let row = latestHRIRSnapshot.first(where: { $0.id == selectedID }),
           let stored = hrir.contentRevisionForTesting(filename: row.fileURL.lastPathComponent),
           stored == lastAppliedHRIRRevision { return }
        let started = hrir.reloadSelectedPreset(
            latestHRIRSnapshot,
            selectedID: selectedID,
            targetSampleRate: routing.sampleRate,
            inputLayout: routing.inputLayout
        ) { [weak self] preset in
            self?.activateLiveHRIR(preset: preset, routing: routing)
        }
        if started, let selectedID,
           let row = latestHRIRSnapshot.first(where: { $0.id == selectedID }) {
            lastAppliedHRIRRevision = hrir.contentRevisionForTesting(filename: row.fileURL.lastPathComponent)
        }
    }

    /// 037 step 2/3: the selected EQ definition changed content. Route
    /// through the existing live-update path. A duplicate snapshot keeps
    /// the definition and must not touch audio. Falls back to the backing
    /// property when the sink has not stored this event yet (direct
    /// `reload()` calls in tests publish synchronously through willSet).
    private func reloadSelectedEqualizerIfChanged() {
        guard controller.canUpdateSpatialLive,
              preparedRouting != nil,
              !controller.isDeferredTeardownPendingForTesting else { return }
        guard let selectedID = profiles.currentProfile?.equalizerPresetID else { return }
        let definition = latestEqualizerSnapshot.first(where: { $0.id == selectedID })?.definition
            ?? equalizer.preset(id: selectedID)?.definition
        guard let definition else { return }
        guard definition != lastAppliedEqualizerDefinition else { return }
        lastAppliedEqualizerDefinition = definition
        controller.updateCurrentEqualizer(definition)
    }

    /// Live HRIR activation shared with the profile-change path. Bumps the
    /// generation so a stale activation cannot publish, then applies the
    /// ready state without rebuilding the pipeline.
    private func activateLiveHRIR(preset: HRIRPreset, routing: ResolvedOutputRouting) {
        generation += 1
        let requestedGeneration = generation
        hrir.activatePreset(
            preset,
            targetSampleRate: routing.sampleRate,
            inputLayout: routing.inputLayout
        ) { [weak self] result in
            guard let self, requestedGeneration == self.generation else { return }
            switch result {
            case .success:
                self.controller.updateSpatialLive(isReady: true)
            case .failure(let message):
                self.hrir.deactivatePreset(immediate: true)
                self.lastAppliedHRIRRevision = nil
                self.controller.presetActivationFailed(message)
            }
        }
    }
}
