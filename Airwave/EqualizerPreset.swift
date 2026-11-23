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

nonisolated struct EqualizerGraphicPoint: Equatable {
    let frequencyHz: Double
    let gainDB: Double
}

nonisolated struct EqualizerGraphicCurve: Equatable {
    let sourceLine: Int
    let points: [EqualizerGraphicPoint]
}

nonisolated enum EqualizerDirective: Equatable {
    case preamp(Double)
    case parametric(EqualizerFilter)
    case graphic(EqualizerGraphicCurve)
}

nonisolated struct EqualizerDefinition: Equatable {
    let directives: [EqualizerDirective]

    var preampDB: Double {
        for case let .preamp(gainDB) in directives {
            return gainDB
        }
        return 0
    }

    var filters: [EqualizerFilter] {
        directives.compactMap { directive in
            guard case let .parametric(filter) = directive else { return nil }
            return filter
        }
    }

    init(preampDB: Double = 0, filters: [EqualizerFilter] = []) {
        var directives: [EqualizerDirective] = preampDB == 0 ? [] : [.preamp(preampDB)]
        directives.append(contentsOf: filters.map(EqualizerDirective.parametric))
        self.init(directives: directives)
    }

    init(directives: [EqualizerDirective]) {
        self.directives = directives
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
