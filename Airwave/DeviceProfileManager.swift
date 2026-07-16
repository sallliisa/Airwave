import Combine
import Foundation

nonisolated struct DeviceAudioProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String { deviceUID }
    let deviceUID: String
    var deviceName: String
    var transport: String
    var hrirPresetID: UUID?
    var equalizerPresetID: UUID?
    var lastSeenAt: Date
}

nonisolated struct DeviceProfileEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var profiles: [DeviceAudioProfile]
}

nonisolated struct DeviceProfileTarget: Equatable, Identifiable, Sendable {
    var id: String { deviceUID }
    let deviceUID: String
    let deviceName: String
    let transport: String
    let isAvailable: Bool
    let isCurrent: Bool
    let savedProfile: DeviceAudioProfile?
}

nonisolated enum DeviceProfileEffect: Equatable, Sendable {
    case hrir
    case equalizer
    case metadata
    case both
}

nonisolated struct DeviceProfileChange: Equatable, Sendable {
    let revision: UInt64
    let deviceUID: String
    let effect: DeviceProfileEffect
}

@MainActor
final class DeviceProfileManager: ObservableObject {
    static let shared = DeviceProfileManager()
    static let storageKey = "Airwave.DeviceProfiles.v1"
    static let legacyEqualizerSelectionKey = "Airwave.Equalizer.SelectedPresetID"

    @Published private(set) var profiles: [DeviceAudioProfile] = []
    @Published private(set) var availableOutputs: [OutputDeviceDescriptor] = []
    @Published private(set) var currentDeviceUID: String?
    @Published private(set) var editingDeviceUID: String?
    @Published private(set) var revision: UInt64 = 0
    let changes = PassthroughSubject<DeviceProfileChange, Never>()

    private let defaults: UserDefaults
    private let now: () -> Date
    private var inventoryOutputs: [OutputDeviceDescriptor] = []
    private var currentOutput: OutputDeviceDescriptor?

    var editingProfile: DeviceAudioProfile? { profile(for: editingDeviceUID) }
    var currentProfile: DeviceAudioProfile? { profile(for: currentDeviceUID) }
    var editingTarget: DeviceProfileTarget? { target(for: editingDeviceUID) }

    var sortedProfiles: [DeviceAudioProfile] {
        profiles.sorted(by: profileSort)
    }

    var targets: [DeviceProfileTarget] {
        var merged: [String: DeviceProfileTarget] = [:]
        for output in availableOutputs {
            merged[output.uid] = DeviceProfileTarget(
                deviceUID: output.uid,
                deviceName: output.name,
                transport: output.transport,
                isAvailable: true,
                isCurrent: output.uid == currentDeviceUID,
                savedProfile: profile(for: output.uid)
            )
        }
        for profile in profiles where merged[profile.deviceUID] == nil {
            merged[profile.deviceUID] = DeviceProfileTarget(
                deviceUID: profile.deviceUID,
                deviceName: profile.deviceName,
                transport: profile.transport,
                isAvailable: false,
                isCurrent: profile.deviceUID == currentDeviceUID,
                savedProfile: profile
            )
        }
        return merged.values.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            let comparison = lhs.deviceName.localizedCaseInsensitiveCompare(rhs.deviceName)
            return comparison == .orderedSame
                ? lhs.deviceUID < rhs.deviceUID
                : comparison == .orderedAscending
        }
    }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                let envelope = try JSONDecoder().decode(DeviceProfileEnvelope.self, from: data)
                guard envelope.schemaVersion == 1 else { throw CocoaError(.coderInvalidValue) }
                profiles = Self.deduplicated(envelope.profiles)
            } catch {
                Logger.log("[DeviceProfiles] Unable to decode v1 profile store; using empty state")
                profiles = []
            }
        } else {
            defaults.removeObject(forKey: Self.legacyEqualizerSelectionKey)
            persist()
        }
        profiles = sortedProfiles
    }

    func profile(for uid: String?) -> DeviceAudioProfile? {
        guard let uid else { return nil }
        return profiles.first { $0.deviceUID == uid }
    }

    func observeCurrentOutput(_ output: OutputDeviceDescriptor?) {
        guard let output, output.isSupportedProfileOutput else {
            currentDeviceUID = nil
            currentOutput = nil
            repairEditingTarget()
            rebuildAvailableOutputs()
            return
        }

        currentDeviceUID = output.uid
        currentOutput = output
        editingDeviceUID = output.uid
        mergeCurrentOutputIntoInventory(output)
        refreshSavedMetadata(using: [output], updateLastSeen: true)
    }

    func updateAvailableOutputs(_ outputs: [OutputDeviceDescriptor]) {
        inventoryOutputs = Self.deduplicatedSupportedDescriptors(outputs)
        rebuildAvailableOutputs()
        refreshSavedMetadata(using: inventoryOutputs)
        repairEditingTarget()
    }

    func selectEditingDevice(uid: String) {
        guard target(for: uid) != nil else { return }
        editingDeviceUID = uid
    }

    func setHRIRPresetID(_ id: UUID?) {
        guard let uid = editingDeviceUID else { return }
        setHRIRPresetID(id, for: uid)
    }

    func setEqualizerPresetID(_ id: UUID?) {
        guard let uid = editingDeviceUID else { return }
        setEqualizerPresetID(id, for: uid)
    }

    func setCurrentHRIRPresetID(_ id: UUID?) {
        guard let uid = currentDeviceUID else { return }
        setHRIRPresetID(id, for: uid)
    }

    func setHRIRPresetID(_ id: UUID?, for uid: String) {
        guard let index = index(of: uid) else {
            guard id != nil, let target = target(for: uid), target.isAvailable else { return }
            createProfile(for: target, hrirPresetID: id, equalizerPresetID: nil, effect: .hrir)
            return
        }
        guard profiles[index].hrirPresetID != id else { return }
        profiles[index].hrirPresetID = id
        mutate(uid: uid, effect: .hrir)
    }

    func setEqualizerPresetID(_ id: UUID?, for uid: String) {
        guard let index = index(of: uid) else {
            guard id != nil, let target = target(for: uid), target.isAvailable else { return }
            createProfile(for: target, hrirPresetID: nil, equalizerPresetID: id, effect: .equalizer)
            return
        }
        guard profiles[index].equalizerPresetID != id else { return }
        profiles[index].equalizerPresetID = id
        mutate(uid: uid, effect: .equalizer)
    }

    @discardableResult
    func resetProfile(deviceUID: String) -> Bool {
        guard let index = index(of: deviceUID),
              profiles[index].hrirPresetID != nil || profiles[index].equalizerPresetID != nil else {
            return false
        }

        profiles[index].hrirPresetID = nil
        profiles[index].equalizerPresetID = nil
        mutate(uid: deviceUID, effect: .both)
        return true
    }

    @discardableResult
    func forgetProfile(deviceUID: String) -> Bool {
        guard currentDeviceUID != deviceUID, let index = index(of: deviceUID) else { return false }

        profiles.remove(at: index)
        if editingDeviceUID == deviceUID, target(for: deviceUID) == nil {
            editingDeviceUID = currentDeviceUID ?? mostRecentlySeenProfileUID()
        }
        profiles = sortedProfiles
        persist()
        emit(uid: deviceUID, effect: .metadata)
        return true
    }

    func clearMissingHRIRPresetIDs(_ ids: Set<UUID>) {
        batchClear(ids: ids, keyPath: \.hrirPresetID, effect: .hrir)
    }

    func clearMissingHRIRIDs(_ ids: Set<UUID>) {
        clearMissingHRIRPresetIDs(ids)
    }

    func clearMissingEqualizerPresetIDs(_ ids: Set<UUID>) {
        batchClear(ids: ids, keyPath: \.equalizerPresetID, effect: .equalizer)
    }

    func clearMissingEqualizerIDs(_ ids: Set<UUID>) {
        clearMissingEqualizerPresetIDs(ids)
    }

    private func target(for uid: String?) -> DeviceProfileTarget? {
        guard let uid else { return nil }
        return targets.first { $0.deviceUID == uid }
    }

    private func index(of uid: String) -> Int? {
        profiles.firstIndex { $0.deviceUID == uid }
    }

    private func createProfile(
        for target: DeviceProfileTarget,
        hrirPresetID: UUID?,
        equalizerPresetID: UUID?,
        effect: DeviceProfileEffect
    ) {
        guard target.isAvailable, target.savedProfile == nil else { return }
        profiles.append(DeviceAudioProfile(
            deviceUID: target.deviceUID,
            deviceName: target.deviceName,
            transport: target.transport,
            hrirPresetID: hrirPresetID,
            equalizerPresetID: equalizerPresetID,
            lastSeenAt: now()
        ))
        mutate(uid: target.deviceUID, effect: effect)
    }

    private func mergeCurrentOutputIntoInventory(_ output: OutputDeviceDescriptor) {
        inventoryOutputs = Self.deduplicatedSupportedDescriptors(inventoryOutputs + [output])
        rebuildAvailableOutputs()
    }

    private func rebuildAvailableOutputs() {
        availableOutputs = Self.deduplicatedSupportedDescriptors(inventoryOutputs + (currentOutput.map { [$0] } ?? []))
    }

    private func refreshSavedMetadata(
        using outputs: [OutputDeviceDescriptor],
        updateLastSeen: Bool = false
    ) {
        var changed = false
        for output in outputs {
            guard let index = index(of: output.uid) else { continue }
            let materiallyChanged = profiles[index].deviceName != output.name || profiles[index].transport != output.transport
            guard materiallyChanged else { continue }
            profiles[index].deviceName = output.name
            profiles[index].transport = output.transport
            if updateLastSeen { profiles[index].lastSeenAt = now() }
            changed = true
        }
        guard changed else { return }
        profiles = sortedProfiles
    }

    private func repairEditingTarget() {
        guard let editingDeviceUID, target(for: editingDeviceUID) == nil else { return }
        self.editingDeviceUID = currentDeviceUID ?? mostRecentlySeenProfileUID()
    }

    private func mutate(uid: String, effect: DeviceProfileEffect) {
        profiles = sortedProfiles
        persist()
        emit(uid: uid, effect: effect)
    }

    private func batchClear(
        ids: Set<UUID>,
        keyPath: WritableKeyPath<DeviceAudioProfile, UUID?>,
        effect: DeviceProfileEffect
    ) {
        guard !ids.isEmpty else { return }
        var affected: [String] = []
        for index in profiles.indices where profiles[index][keyPath: keyPath].map(ids.contains) == true {
            profiles[index][keyPath: keyPath] = nil
            affected.append(profiles[index].deviceUID)
        }
        guard !affected.isEmpty else { return }
        persist()
        for uid in affected { emit(uid: uid, effect: effect) }
    }

    private func emit(uid: String, effect: DeviceProfileEffect) {
        revision &+= 1
        changes.send(.init(revision: revision, deviceUID: uid, effect: effect))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(DeviceProfileEnvelope(schemaVersion: 1, profiles: profiles)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func mostRecentlySeenProfileUID() -> String? {
        profiles.max {
            if $0.lastSeenAt == $1.lastSeenAt { return $0.deviceUID < $1.deviceUID }
            return $0.lastSeenAt < $1.lastSeenAt
        }?.deviceUID
    }

    private func profileSort(_ lhs: DeviceAudioProfile, _ rhs: DeviceAudioProfile) -> Bool {
        if lhs.deviceUID == currentDeviceUID { return rhs.deviceUID != currentDeviceUID }
        if rhs.deviceUID == currentDeviceUID { return false }
        let comparison = lhs.deviceName.localizedCaseInsensitiveCompare(rhs.deviceName)
        return comparison == .orderedSame ? lhs.deviceUID < rhs.deviceUID : comparison == .orderedAscending
    }

    private static func deduplicated(_ profiles: [DeviceAudioProfile]) -> [DeviceAudioProfile] {
        Dictionary(grouping: profiles, by: \.deviceUID).compactMap { _, values in
            values.max(by: { $0.lastSeenAt < $1.lastSeenAt })
        }
    }

    private static func deduplicatedSupportedDescriptors(_ outputs: [OutputDeviceDescriptor]) -> [OutputDeviceDescriptor] {
        var result: [String: OutputDeviceDescriptor] = [:]
        for output in outputs where output.isSupportedProfileOutput {
            if let existing = result[output.uid] {
                let comparison = output.name.localizedCaseInsensitiveCompare(existing.name)
                if comparison == .orderedAscending || (comparison == .orderedSame && output.id.value < existing.id.value) {
                    result[output.uid] = output
                }
            } else {
                result[output.uid] = output
            }
        }
        return result.values.sorted { lhs, rhs in
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return comparison == .orderedSame ? lhs.uid < rhs.uid : comparison == .orderedAscending
        }
    }
}
