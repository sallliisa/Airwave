import Foundation

struct HostPresetLibrary {
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
        case unsupportedEffect
        case invalidFile
        case invalidState
        case noPreset
        case invalidName
        case missing

        var errorDescription: String? {
            switch self {
            case .unsupportedEffect: "This Audio Unit does not use the Airwave preset library."
            case .invalidFile: "Choose a valid preset file."
            case .invalidState: "The effect's preset could not be read."
            case .noPreset: "Choose or import a preset in the effect's controls first."
            case .invalidName: "Enter a name for the preset."
            case .missing: "This preset is no longer in the library."
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

    @discardableResult
    func save(name: String, component: ComponentID, state: Data) throws -> Entry {
        let name = try Self.checkedName(name)
        let portable = try Self.portableState(state, component: component)
        let entry = Entry(id: UUID(), component: component, name: name, state: portable)
        try append(entry)
        return entry
    }

    @discardableResult
    func importPreset(from source: URL, component: ComponentID) throws -> Entry {
        let hasAccess = source.startAccessingSecurityScopedResource()
        defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
        let name = try Self.checkedName(source.hasDirectoryPath ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent)
        let state: Data
        switch component {
        case .airwaveSpatial:
            let wav = try Self.readPreset(source, limit: WAVLoader.maximumFileSize)
            try Self.validateWAV(wav)
            state = try Self.spatialState(name: name, wav: wav)
        case .airwaveEqualizer:
            let preset: EqualizerAUState.Preset
            if EqualizerConfigFiles.isArchive(source) {
                let data = try Self.readPreset(source, limit: EqualizerConfigFiles.maximumArchiveSize)
                _ = try EqualizerConfigFiles.parseManagedDefinition(data: data, filename: source.lastPathComponent)
                preset = EqualizerAUState.Preset(name: name, filename: source.lastPathComponent, data: data)
            } else {
                let prepared = try EqualizerConfigFiles.prepareImport(source)
                preset = EqualizerAUState.Preset(name: name, filename: prepared.filename, data: prepared.data)
            }
            state = try Self.encode(EqualizerAUState.document(preset: preset, context: nil))
        default:
            throw Failure.unsupportedEffect
        }
        let entry = Entry(id: UUID(), component: component, name: name, state: state)
        try append(entry)
        return entry
    }

    func rename(_ entry: Entry, to name: String) throws {
        let name = try Self.checkedName(name)
        var document = try read()
        guard let index = document.entries.firstIndex(where: { $0.key == entry.key }) else { throw Failure.missing }
        let current = document.entries[index]
        document.entries[index] = Entry(id: current.id, component: current.component, name: name, state: current.state)
        try write(document)
    }

    func delete(_ entry: Entry) throws {
        var document = try read()
        guard let index = document.entries.firstIndex(where: { $0.key == entry.key }) else { throw Failure.missing }
        document.entries.remove(at: index)
        document.deleted.insert(entry.key)
        try write(document)
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

    private func append(_ entry: Entry) throws {
        var document = try read()
        document.entries.append(entry)
        try write(document)
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

    private static func portableState(_ state: Data, component: ComponentID) throws -> Data {
        guard let document = try PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any] else {
            throw Failure.invalidState
        }
        switch component {
        case .airwaveSpatial:
            if let wav = document["AirwaveSpatial.impulseResponse"] as? Data,
               let name = document["AirwaveSpatial.presetName"] as? String {
                try validateWAV(wav)
                return try spatialState(name: name, wav: wav)
            }
            guard let preset = document["AirwaveSpatial.bundledPreset"] as? String, !preset.isEmpty else {
                throw Failure.noPreset
            }
            return try encode(["AirwaveSpatial.bundledPreset": preset, "AirwaveSpatial.bypass": false])
        case .airwaveEqualizer:
            guard let preset = try EqualizerAUState(document).preset else { throw Failure.noPreset }
            if let text = preset.legacyText {
                // Older AU documents treated # as an inline comment.
                let source = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .map { $0.prefix(while: { $0 != "#" }) }.joined(separator: "\n")
                _ = try EqualizerAPOParser.parse(data: Data(source.utf8), filename: preset.filename, allowDeferred: false)
            } else {
                _ = try EqualizerConfigFiles.parseManagedDefinition(data: preset.data, filename: preset.filename)
            }
            return try encode(EqualizerAUState.document(preset: preset, context: nil))
        default:
            throw Failure.unsupportedEffect
        }
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
