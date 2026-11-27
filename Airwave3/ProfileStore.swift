import AudioToolbox
import Foundation

struct ComponentID: Codable, Hashable {
    let type: OSType
    let subtype: OSType
    let manufacturer: OSType

    init(_ description: AudioComponentDescription) {
        type = description.componentType
        subtype = description.componentSubType
        manufacturer = description.componentManufacturer
    }

    static let airwaveSpatial = effect(subtype: 0x41777370, manufacturer: 0x41777665) // Awsp/Awve
    static let airwaveEqualizer = effect(subtype: 0x45714150, manufacturer: 0x536E6866) // EqAP/Snhf

    private static func effect(subtype: OSType, manufacturer: OSType) -> Self {
        Self(AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: subtype, componentManufacturer: manufacturer,
            componentFlags: 0, componentFlagsMask: 0
        ))
    }

    var description: AudioComponentDescription {
        AudioComponentDescription(
            componentType: type,
            componentSubType: subtype,
            componentManufacturer: manufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

struct EffectComponent: Identifiable, Equatable {
    let id: ComponentID
    let name: String
    let manufacturer: String
}

struct EffectSlot: Identifiable, Codable, Equatable {
    let id: UUID
    let component: ComponentID
    let name: String
    let manufacturer: String
    var isBypassed: Bool
    var state: Data?

    init(_ effect: EffectComponent) {
        id = UUID()
        component = effect.id
        name = effect.name
        manufacturer = effect.manufacturer
        isBypassed = false
    }
}

struct DeviceProfile: Codable, Equatable {
    var name: String
    var sampleRate: Double?
    var slots: [EffectSlot]
    var outputChannels: StereoOutputChannels? = nil
}

struct ProfileStore {
    private let url: URL
    private let upgradeFailure: LegacyAirwaveUpgrade.Failure?

    init(url: URL = URL.applicationSupportDirectory.appending(path: "Airwave/Effect Chains.plist"),
         upgradeFailure: LegacyAirwaveUpgrade.Failure? = nil) {
        self.url = url
        self.upgradeFailure = upgradeFailure
    }

    func load() throws -> [String: DeviceProfile] {
        if let upgradeFailure { throw upgradeFailure }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }

        let decoder = PropertyListDecoder()
        if let profiles = try? decoder.decode([String: DeviceProfile].self, from: data) {
            return profiles
        }
        return try decoder.decode([String: [EffectSlot]].self, from: data).reduce(into: [:]) {
            $0[$1.key] = DeviceProfile(name: $1.key, slots: $1.value)
        }
    }

    func save(_ profiles: [String: DeviceProfile]) throws {
        if let upgradeFailure { throw upgradeFailure }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(profiles)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
