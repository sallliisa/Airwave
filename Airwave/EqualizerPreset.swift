import Foundation

nonisolated enum EqualizerFilterType: Equatable {
    case peaking
    case lowPass
    case highPass
    case bandPass
    case notch
    case allPass
    case lowShelf
    case highShelf
}

nonisolated enum EqualizerShelfFrequency: Equatable {
    case center
    case corner
}

nonisolated enum EqualizerFilterShape: Equatable {
    case q(Double, frequency: EqualizerShelfFrequency = .center)
    case bandwidthOctaves(Double)
    case shelfSlope(normalized: Double, frequency: EqualizerShelfFrequency)
}

nonisolated struct EqualizerFilter: Equatable {
    let sourceLine: Int
    let sourceNumber: Int?
    let isEnabled: Bool
    let type: EqualizerFilterType
    let frequencyHz: Double
    let gainDB: Double
    let shape: EqualizerFilterShape
}

extension EqualizerFilter {
    init(
        sourceLine: Int,
        sourceNumber: Int?,
        isEnabled: Bool,
        type: EqualizerFilterType,
        frequencyHz: Double,
        gainDB: Double,
        q: Double
    ) {
        self.init(
            sourceLine: sourceLine,
            sourceNumber: sourceNumber,
            isEnabled: isEnabled,
            type: type,
            frequencyHz: frequencyHz,
            gainDB: gainDB,
            shape: .q(q)
        )
    }
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
    case stereo(EqualizerStereoCommand, line: Int)
    case enterInclude
    case leaveInclude
}

nonisolated struct EqualizerDefinition: Equatable {
    let directives: [EqualizerDirective]
    let sourceLocations: [EqualizerConfigFiles.SourceLocation]

    var preampDB: Double {
        var total: Double = 0
        for case let .preamp(gainDB) in directives {
            total += gainDB
        }
        return total
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

    init(directives: [EqualizerDirective], sourceLocations: [EqualizerConfigFiles.SourceLocation] = []) {
        self.directives = directives
        self.sourceLocations = sourceLocations
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
