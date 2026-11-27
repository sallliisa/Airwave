import AudioToolbox
import Darwin
import Foundation

nonisolated struct NativeUserPresetStore {
    private struct Record: Codable {
        let name: String
        let number: Int
        let state: Data
    }

    private struct Descriptor: Decodable {
        let name: String
        let number: Int

        var preset: AUAudioUnitPreset {
            let preset = AUAudioUnitPreset()
            preset.name = name
            preset.number = number
            return preset
        }
    }

    private struct LocatedPreset {
        let file: URL
        let descriptor: Descriptor
    }

    private let folder: URL

    init(effect: String, root: URL = .applicationSupportDirectory) {
        folder = root.appending(path: "Airwave Audio Units", directoryHint: .isDirectory)
            .appending(path: effect, directoryHint: .isDirectory)
    }

    var presets: [AUAudioUnitPreset] {
        entries.map { $0.descriptor.preset }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var entries: [LocatedPreset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)) ?? []
        return files.filter { $0.pathExtension == "plist" }.compactMap { file in
            guard let descriptor = try? decode(Descriptor.self, at: file) else { return nil }
            return LocatedPreset(file: file, descriptor: descriptor)
        }
    }

    func save(_ preset: AUAudioUnitPreset, state: [String: Any]) throws {
        let name = try checkedName(preset.name)
        let state = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        let number = try withWriteLock {
            let entries = self.entries
            let saved = entries.first { equalNames($0.descriptor.name, name) }
            let file = saved?.file ?? folder.appending(path: UUID().uuidString + ".plist", directoryHint: .notDirectory)
            let number = saved?.descriptor.number ?? numberForNewPreset(preset.number, among: entries)
            try write(Record(name: name, number: number, state: state), to: file)
            return number
        }
        preset.name = name
        preset.number = number
    }

    func state(for preset: AUAudioUnitPreset) throws -> [String: Any] {
        let record = try decode(Record.self, at: locate(preset).file)
        guard let state = try PropertyListSerialization.propertyList(from: record.state, format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return state
    }

    func delete(_ preset: AUAudioUnitPreset) throws {
        try withWriteLock { try FileManager.default.removeItem(at: locate(preset).file) }
    }

    func rename(_ preset: AUAudioUnitPreset, to name: String) throws {
        let name = try checkedName(name)
        try withWriteLock {
            let entries = self.entries
            let existing = try locate(preset, among: entries)
            guard !entries.contains(where: { $0.file != existing.file && equalNames($0.descriptor.name, name) }) else {
                throw CocoaError(.fileWriteFileExists)
            }
            let record = try decode(Record.self, at: existing.file)
            try write(Record(name: name, number: record.number, state: record.state), to: existing.file)
        }
        preset.name = name
    }

    private func locate(_ preset: AUAudioUnitPreset, among entries: [LocatedPreset]? = nil) throws -> LocatedPreset {
        let name = try checkedName(preset.name)
        guard let entry = (entries ?? self.entries).first(where: { equalNames($0.descriptor.name, name) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return entry
    }

    private func checkedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        return name
    }

    private func equalNames(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func write(_ record: Record, to file: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(record).write(to: file, options: .atomic)
    }

    private func withWriteLock<Value>(_ operation: () throws -> Value) throws -> Value {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = folder.appending(path: ".lock").path
        let descriptor = open(lock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try operation()
    }

    private func decode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
        try PropertyListDecoder().decode(type, from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func numberForNewPreset(_ suggested: Int, among entries: [LocatedPreset]) -> Int {
        let used = Set(entries.map(\.descriptor.number))
        let requested = suggested > 0 ? -suggested : min(suggested, -1)
        if !used.contains(requested) { return requested }
        return (1...used.count + 1).lazy.map { -$0 }.first { !used.contains($0) } ?? requested
    }
}
