import Foundation

nonisolated enum EqualizerFilterType: Equatable {
    case peaking
    case lowShelf
    case highShelf
}

nonisolated struct EqualizerFilter: Equatable {
    let sourceLine: Int
    let sourceNumber: Int?
    let isEnabled: Bool
    let type: EqualizerFilterType
    let frequencyHz: Double
    let gainDB: Double
    let q: Double
}

nonisolated struct EqualizerDefinition: Equatable {
    let preampDB: Double
    let filters: [EqualizerFilter]

    init(preampDB: Double = 0, filters: [EqualizerFilter] = []) {
        self.preampDB = preampDB
        self.filters = filters
    }
}

nonisolated struct EqualizerPreset: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let fileURL: URL
    let definition: EqualizerDefinition
}

nonisolated enum EqualizerSelection: Equatable {
    case none
    case preset(UUID)
}

struct EqualizerPresetMetadata: Codable, Equatable {
    let id: UUID
    let filename: String
    let displayName: String
}
