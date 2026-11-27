import Foundation

struct PresetMigrationStore {
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        let component: ComponentID
        let name: String
        let state: Data

        fileprivate var key: Key { Key(component: component, id: id) }
    }

    fileprivate struct Key: Codable, Hashable {
        let component: ComponentID
        let id: UUID
    }

    private struct Document: Codable {
        var entries: [Entry] = []
        var deleted: Set<Key> = []

        private enum CodingKeys: CodingKey {
            case entries, deleted
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            entries = try values.decode([DecodableEntry<Entry>].self, forKey: .entries).compactMap(\.value)
            deleted = try values.decode(Set<Key>.self, forKey: .deleted)
        }
    }

    private struct LegacySpatial: Decodable {
        let id: UUID
        let name: String
        let fileURL: URL
    }

    private struct LegacyEqualizer: Decodable {
        let id: UUID
        let filename: String
        let displayName: String
    }

    private struct LegacyEqualizerManifest: Decodable {
        let presets: [DecodableEntry<LegacyEqualizer>]
    }

    private struct DecodableEntry<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    enum Failure: LocalizedError {
        case invalidFile
        case invalidName

        var errorDescription: String? {
            switch self {
            case .invalidFile: "Choose a valid preset file."
            case .invalidName: "Enter a name for the preset."
            }
        }
    }

    static let filename = "Effect Presets.plist"
    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Airwave/\(filename)")
    }

    let url: URL

    init(url: URL = Self.defaultURL) { self.url = url }

    static func supports(_ component: ComponentID) -> Bool {
        component == .airwaveSpatial || component == .airwaveEqualizer
    }

    func load(for component: ComponentID) throws -> [Entry] {
        try read().entries.filter { $0.component == component }.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
        }
    }

    func mergeLegacy(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return }
        var document = try read()
        var known = document.deleted.union(document.entries.map(\.key))
        let additions = entries.filter { known.insert($0.key).inserted }
        guard !additions.isEmpty else { return }
        document.entries.append(contentsOf: additions)
        try write(document)
    }

    static func legacyEntries(at library: URL) -> [Entry] {
        guard isDirectory(library) else { return [] }
        let spatialDirectory = library.appending(path: "presets", directoryHint: .isDirectory)
        let equalizerDirectory = library.appending(path: "Equalizer Presets", directoryHint: .isDirectory)
        let spatial: [DecodableEntry<LegacySpatial>] = legacyManifest("presets.json", in: spatialDirectory) ?? []
        let equalizer: LegacyEqualizerManifest? = legacyManifest("manifest.json", in: equalizerDirectory)

        return spatial.compactMap { decoded in
            guard let preset = decoded.value,
                  let file = try? managedFile(preset.fileURL.lastPathComponent, in: spatialDirectory),
                  let wav = try? readPreset(file, limit: WAVLoader.maximumFileSize),
                  let name = try? checkedName(preset.name),
                  (try? validateWAV(wav)) != nil,
                  let state = try? spatialState(name: name, wav: wav) else { return nil }
            return Entry(id: preset.id, component: .airwaveSpatial, name: name, state: state)
        } + (equalizer?.presets ?? []).compactMap { decoded in
            guard let preset = decoded.value,
                  let file = try? managedFile(preset.filename, in: equalizerDirectory),
                  let data = try? readPreset(file, limit: EqualizerConfigFiles.maximumArchiveSize),
                  let name = try? checkedName(preset.displayName) else { return nil }
            let selection = EqualizerAUState.Preset(name: name, filename: preset.filename, data: data)
            guard (try? EqualizerConfigFiles.parseManagedDefinition(data: data, filename: preset.filename)) != nil,
                  let state = try? encode(EqualizerAUState.document(preset: selection, context: nil)) else { return nil }
            return Entry(id: preset.id, component: .airwaveEqualizer, name: name, state: state)
        }
    }

    private func read() throws -> Document {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Document()
        }
        return try PropertyListDecoder().decode(Document.self, from: data)
    }

    private func write(_ document: Document) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func legacyManifest<Value: Decodable>(_ name: String, in folder: URL) -> Value? {
        guard isDirectory(folder), let file = try? managedFile(name, in: folder),
              let bytes = try? readPreset(file, limit: 8 * 1_024 * 1_024) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: bytes)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let metadata = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return metadata?.isDirectory == true && metadata?.isSymbolicLink != true
    }

    private static func managedFile(_ filename: String, in folder: URL) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
              !filename.utf8.contains(0) else { throw Failure.invalidFile }
        return folder.appending(path: filename, directoryHint: .notDirectory)
    }

    private static func readPreset(_ file: URL, limit: Int) throws -> Data {
        let data = try EqualizerConfigFiles.readFile(at: file, limit: limit)
        guard !data.isEmpty else { throw Failure.invalidFile }
        return data
    }

    private static func checkedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.invalidName }
        return trimmed
    }

    private static func encode(_ state: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    private static func spatialState(name: String, wav: Data) throws -> Data {
        try encode([
            "AirwaveSpatial.presetName": name,
            "AirwaveSpatial.impulseResponse": wav,
            "AirwaveSpatial.bypass": false
        ])
    }

    private static func validateWAV(_ wav: Data) throws {
        guard !wav.isEmpty, wav.count <= WAVLoader.maximumFileSize else { throw Failure.invalidFile }
        let file = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + ".wav", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: file) }
        try wav.write(to: file, options: .atomic)
        _ = try WAVLoader.headerInfo(from: file)
        let parsed = try WAVLoader.load(from: file)
        guard parsed.channelCount >= 2 else { throw WAVError.invalidChannelCount(parsed.channelCount) }
    }
}
