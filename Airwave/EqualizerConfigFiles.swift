import Darwin
import Foundation

nonisolated enum EqualizerConfigFiles {
    static let archiveExtension = "apo"
    static let maximumArchiveSize = 3 * EqualizerAPOParser.maximumDataSize

    static func isArchive(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare(archiveExtension) == .orderedSame
    }

    nonisolated struct SourceLocation: Equatable {
        let filename: String
        let lineNumber: Int
    }

    nonisolated enum ScopeBoundary: Equatable {
        case enter(beforeLine: Int)
        case leave(beforeLine: Int)
    }

    nonisolated struct Expanded {
        let data: Data
        let rootFilename: String
        let locations: [SourceLocation]
        let scopeBoundaries: [ScopeBoundary]

        func parse() throws -> EqualizerDefinition {
            do {
                let definition = try EqualizerAPOParser.parse(data: data, filename: rootFilename)
                return EqualizerDefinition(directives: definition.directives, sourceLocations: locations)
            } catch let error as EqualizerParseError {
                let issues = error.issues.map { issue in
                    guard let line = issue.lineNumber, locations.indices.contains(line - 1) else {
                        return issue
                    }
                    let location = locations[line - 1]
                    if location.filename == rootFilename {
                        return EqualizerParseIssue(lineNumber: location.lineNumber, reason: issue.reason)
                    }
                    return EqualizerParseIssue(
                        lineNumber: nil,
                        reason: "\(location.filename), line \(location.lineNumber): \(issue.reason)"
                    )
                }
                throw EqualizerParseError(filename: error.filename, issues: issues)
            }
        }
    }

    nonisolated struct Import {
        let filename: String
        let data: Data
        let definition: EqualizerDefinition
    }

    nonisolated private struct Snapshot: Codable {
        let rootFilename: String
        let files: [String: Data]

        var expanded: Expanded {
            get throws {
                let expander = Expander(rootFilename: rootFilename) { path in
                    guard let data = files[path] else {
                        throw FileError(reason: "\(path) is missing from the managed config")
                    }
                    return data
                }
                return try expander.run()
            }
        }
    }

    nonisolated private struct FileError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func prepareImport(_ source: URL) throws -> Import {
        let metadata = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard metadata.isSymbolicLink != true else {
            throw FileError(reason: "symbolic links cannot be imported")
        }
        let isFolder = metadata.isDirectory == true
        let rootFilename = isFolder ? "config.txt" : source.lastPathComponent
        let folder = isFolder ? source : source.deletingLastPathComponent()
        guard URL(fileURLWithPath: rootFilename).pathExtension.caseInsensitiveCompare("txt") == .orderedSame else {
            throw FileError(reason: "choose a .txt preset or a folder containing config.txt")
        }

        let expander = Expander(rootFilename: rootFilename) { path in
            if !isFolder && path == rootFilename {
                return try readFile(at: source, limit: EqualizerAPOParser.maximumDataSize)
            }
            do {
                return try readFile(path, inside: folder)
            } catch {
                let detail = error.localizedDescription
                if isFolder { throw error }
                throw FileError(reason: "\(detail). Choose the config folder to grant access to its files")
            }
        }
        let expanded = try expander.run()
        if !isFolder && !expander.hasIncludes {
            guard let original = expander.files[rootFilename] else {
                throw FileError(reason: "the preset could not be read")
            }
            let definition = try EqualizerAPOParser.parse(data: original, filename: rootFilename)
            return Import(filename: rootFilename, data: original, definition: definition)
        }

        let snapshot = Snapshot(rootFilename: rootFilename, files: expander.files)
        let title = isFolder ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumArchiveSize else {
            throw FileError(reason: "the managed config exceeds the archive size limit")
        }
        return Import(
            filename: "\(title).\(archiveExtension)",
            data: data,
            definition: try expanded.parse()
        )
    }

    static func readManagedDefinition(at url: URL) throws -> EqualizerDefinition {
        if isArchive(url) {
            let data = try readFile(at: url, limit: maximumArchiveSize)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            return try snapshot.expanded.parse()
        }
        let data = try readFile(at: url, limit: EqualizerAPOParser.maximumDataSize)
        return try EqualizerAPOParser.parse(data: data, filename: url.lastPathComponent)
    }

    static func readFile(at url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FileError(reason: "\(url.lastPathComponent) could not be opened")
        }
        return try readFile(descriptor, named: url.lastPathComponent, limit: limit)
    }

    private static func readFile(_ path: String, inside folder: URL) throws -> Data {
        var directory = open(folder.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {
            throw FileError(reason: "the config directory could not be opened")
        }
        defer { _ = close(directory) }

        let parts = path.split(separator: "/")
        guard let filename = parts.last else {
            throw FileError(reason: "empty config file path")
        }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            guard next >= 0 else {
                throw FileError(reason: "\(path) could not be opened")
            }
            _ = close(directory)
            directory = next
        }
        let descriptor = openat(directory, String(filename), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FileError(reason: "\(path) could not be opened")
        }
        return try readFile(descriptor, named: path, limit: EqualizerAPOParser.maximumDataSize)
    }

    private static func readFile(_ descriptor: Int32, named name: String, limit: Int) throws -> Data {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw FileError(reason: "\(name) is not a regular file")
        }
        guard attributes.st_size <= off_t(limit) else {
            throw FileError(reason: "\(name) exceeds the file size limit")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw FileError(reason: "\(name) exceeds the file size limit")
        }
        return data
    }

    private static func resolve(_ argument: String, relativeTo parent: String) throws -> String {
        let path = argument.replacingOccurrences(of: "\\", with: "/")
        let parts = path.split(separator: "/")
        guard !parts.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
              !path.contains(":"), !path.utf8.contains(0) else {
            throw FileError(reason: "expected a relative Include path inside the config folder")
        }
        var resolved = parent.split(separator: "/").dropLast().map(String.init)
        for part in parts {
            switch part {
            case ".":
                continue
            case "..":
                guard !resolved.isEmpty else {
                    throw FileError(reason: "Include path is outside the config folder")
                }
                resolved.removeLast()
            default:
                resolved.append(String(part))
            }
        }
        guard !resolved.isEmpty else {
            throw FileError(reason: "Include path does not name a file")
        }
        return resolved.joined(separator: "/")
    }

    nonisolated private final class Expander {
        private let rootFilename: String
        private let load: (String) throws -> Data
        private var output = [String]()
        private var locations = [SourceLocation]()
        private var scopeBoundaries = [ScopeBoundary]()
        private var active = Set<String>()
        private var expandedBytes = 0
        private var visits = 0

        private(set) var files = [String: Data]()
        private(set) var hasIncludes = false

        init(rootFilename: String, load: @escaping (String) throws -> Data) {
            self.rootFilename = rootFilename
            self.load = load
        }

        func run() throws -> Expanded {
            let rootPath = try resolve(rootFilename, relativeTo: "")
            guard rootPath == rootFilename, !rootPath.contains("/") else {
                throw FileError(reason: "invalid config root filename")
            }
            try expand(rootPath)
            return Expanded(
                data: Data(output.joined(separator: "\n").utf8),
                rootFilename: rootPath,
                locations: locations,
                scopeBoundaries: scopeBoundaries
            )
        }

        private func contents(of path: String) throws -> Data {
            if let cached = files[path] { return cached }
            guard files.count < 64 else {
                throw FileError(reason: "a config can reference at most 64 text files")
            }
            let data = try load(path)
            files[path] = data
            return data
        }

        private func expand(_ path: String) throws {
            guard !active.contains(path) else {
                throw FileError(reason: "Include cycle references \(path)")
            }
            guard active.count < 32, visits < 256 else {
                throw FileError(reason: "Include nesting or expansion limit exceeded")
            }
            visits += 1
            active.insert(path)
            defer { active.remove(path) }

            let bytes = try contents(of: path)
            expandedBytes += bytes.count
            guard expandedBytes <= EqualizerAPOParser.maximumDataSize else {
                throw FileError(reason: "expanded config exceeds the 1 MiB limit")
            }
            guard var source = String(data: bytes, encoding: .utf8) else {
                throw FileError(reason: "\(path) is not valid UTF-8")
            }
            if source.first == "\u{FEFF}" { source.removeFirst() }

            let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            for (index, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                let location = SourceLocation(filename: path, lineNumber: index + 1)
                let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2,
                      fields[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Include") == .orderedSame else {
                    output.append(line)
                    locations.append(location)
                    continue
                }

                hasIncludes = true
                var argument = fields[1].trimmingCharacters(in: .whitespaces)
                if argument.count >= 2, argument.first == "\"",
                   argument.last == "\"" {
                    argument = String(argument.dropFirst().dropLast())
                }
                do {
                    let relativePath = try resolve(argument, relativeTo: path)
                    scopeBoundaries.append(.enter(beforeLine: output.count + 1))
                    try expand(relativePath)
                    scopeBoundaries.append(.leave(beforeLine: output.count + 1))
                } catch {
                    throw FileError(reason: "\(location.filename), line \(location.lineNumber): \(error.localizedDescription)")
                }
            }
        }
    }
}
