import Combine
import Foundation

struct DeviceAudioProfile: Codable, Equatable, Identifiable {
    var id: String { deviceUID }
    let deviceUID: String
    var deviceName: String
    var transport: String
    var hrirPresetID: UUID?
    var equalizerPresetID: UUID?
    var lastSeenAt: Date
}

struct DeviceProfileEnvelope: Codable, Equatable {
    let schemaVersion: Int
    var profiles: [DeviceAudioProfile]
}

enum DeviceProfileEffect: Equatable {
    case hrir
    case equalizer
    case metadata
    case both
}

struct DeviceProfileChange: Equatable {
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
    @Published private(set) var currentDeviceUID: String?
    @Published private(set) var editingDeviceUID: String?
    @Published private(set) var revision: UInt64 = 0
    let changes = PassthroughSubject<DeviceProfileChange, Never>()

    var editingProfile: DeviceAudioProfile? { profile(for: editingDeviceUID) }
    var currentProfile: DeviceAudioProfile? { profile(for: currentDeviceUID) }
    var sortedProfiles: [DeviceAudioProfile] {
        profiles.sorted { lhs, rhs in
            if lhs.deviceUID == currentDeviceUID { return rhs.deviceUID != currentDeviceUID }
            if rhs.deviceUID == currentDeviceUID { return false }
            let comparison = lhs.deviceName.localizedCaseInsensitiveCompare(rhs.deviceName)
            return comparison == .orderedSame ? lhs.deviceUID < rhs.deviceUID : comparison == .orderedAscending
        }
    }

    private let defaults: UserDefaults
    private let now: () -> Date

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
    }

    func profile(for uid: String?) -> DeviceAudioProfile? {
        guard let uid else { return nil }
        return profiles.first { $0.deviceUID == uid }
    }

    @discardableResult
    func observe(_ output: OutputDeviceDescriptor?) -> DeviceAudioProfile? {
        guard let output, output.isSupportedProfileOutput else {
            currentDeviceUID = nil
            editingDeviceUID = profiles.max(by: { $0.lastSeenAt < $1.lastSeenAt })?.deviceUID
            profiles = sortedProfiles
            return nil
        }
        let timestamp = now()
        currentDeviceUID = output.uid
        editingDeviceUID = output.uid
        if let index = profiles.firstIndex(where: { $0.deviceUID == output.uid }) {
            let old = profiles[index]
            profiles[index].deviceName = output.name
            profiles[index].transport = output.transport
            profiles[index].lastSeenAt = timestamp
            if old.deviceName != output.name || old.transport != output.transport {
                mutate(uid: output.uid, effect: .metadata, alreadyChanged: true)
            } else {
                persist()
            }
        } else {
            profiles.append(DeviceAudioProfile(
                deviceUID: output.uid, deviceName: output.name, transport: output.transport,
                hrirPresetID: nil, equalizerPresetID: nil, lastSeenAt: timestamp
            ))
            mutate(uid: output.uid, effect: .metadata, alreadyChanged: true)
        }
        profiles = sortedProfiles
        return profile(for: output.uid)
    }

    func selectEditingDevice(uid: String) {
        guard profile(for: uid) != nil else { return }
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
        guard let index = profiles.firstIndex(where: { $0.deviceUID == uid }), profiles[index].hrirPresetID != id else { return }
        profiles[index].hrirPresetID = id
        mutate(uid: uid, effect: .hrir, alreadyChanged: true)
    }

    func setEqualizerPresetID(_ id: UUID?, for uid: String) {
        guard let index = profiles.firstIndex(where: { $0.deviceUID == uid }), profiles[index].equalizerPresetID != id else { return }
        profiles[index].equalizerPresetID = id
        mutate(uid: uid, effect: .equalizer, alreadyChanged: true)
    }

    @discardableResult
    func resetProfile(deviceUID: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.deviceUID == deviceUID }),
              profiles[index].hrirPresetID != nil || profiles[index].equalizerPresetID != nil else {
            return false
        }

        profiles[index].hrirPresetID = nil
        profiles[index].equalizerPresetID = nil
        profiles = sortedProfiles
        persist()
        emit(uid: deviceUID, effect: .both)
        return true
    }

    @discardableResult
    func forgetProfile(deviceUID: String) -> Bool {
        guard currentDeviceUID != deviceUID,
              let index = profiles.firstIndex(where: { $0.deviceUID == deviceUID }) else {
            return false
        }

        profiles.remove(at: index)
        if editingDeviceUID == deviceUID {
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

    private func batchClear(ids: Set<UUID>, keyPath: WritableKeyPath<DeviceAudioProfile, UUID?>, effect: DeviceProfileEffect) {
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

    private func mutate(uid: String, effect: DeviceProfileEffect, alreadyChanged: Bool) {
        if alreadyChanged { profiles = profiles }
        profiles = sortedProfiles
        persist()
        emit(uid: uid, effect: effect)
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

    private static func deduplicated(_ profiles: [DeviceAudioProfile]) -> [DeviceAudioProfile] {
        Dictionary(grouping: profiles, by: \.deviceUID).compactMap { _, values in
            values.max(by: { $0.lastSeenAt < $1.lastSeenAt })
        }
    }
}
