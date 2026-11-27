import Darwin
import Foundation

nonisolated enum EqualizerConfigFiles {
    static let archiveExtension = "apo"
    static let maximumArchiveSize = 3 * EqualizerAPOParser.maximumDataSize + 2 * EqualizerConvolutionAsset.maximumTotalFileSize

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

        var line: Int {
            switch self {
            case .enter(let line), .leave(let line): line
            }
        }

        var directive: EqualizerDirective {
            switch self {
            case .enter: .enterInclude
            case .leave: .leaveInclude
            }
        }
    }

    nonisolated struct Expanded {
        let data: Data
        let rootFilename: String
        let locations: [SourceLocation]
        let scopeBoundaries: [ScopeBoundary]
        let assets: [Int: EqualizerConvolutionAsset]

        func parse() throws -> EqualizerDefinition {
            do {
                let definition = try EqualizerAPOParser.parse(
                    data: data, filename: rootFilename, fileBoundaries: scopeBoundaries, assets: assets
                )
                return EqualizerDefinition(directives: definition.directives, sourceLocations: locations, program: definition.program)
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
                let expander = Expander(rootFilename: rootFilename) { path, limit in
                    guard let data = files[path] else { throw FileError(reason: "\(path) is missing from the managed config") }
                    guard data.count <= limit else { throw FileError(reason: "\(path) exceeds the file size limit") }
                    return data
                }
                return try expander.run()
            }
        }
    }

    nonisolated private struct FileError: LocalizedError {
        let reason: String
        var accessDenied = false
        var errorDescription: String? { reason }

        static func opening(_ name: String, code: Int32) -> Self {
            Self(reason: code == ENOENT ? "\(name) was not found" : "\(name) could not be opened",
                 accessDenied: code == EACCES || code == EPERM)
        }
    }

    nonisolated struct FolderAccessRequired: LocalizedError {
        let config: URL

        var errorDescription: String? {
            if config.lastPathComponent == "config.txt" {
                return "Choose the folder containing config.txt so Airwave can read its companion files."
            }
            return "Put this config and its companion files in one folder with config.txt as the entry file, then import the folder."
        }
    }

    nonisolated struct DependencyError: LocalizedError {
        let location: SourceLocation
        let reason: String

        var errorDescription: String? { description(relativeTo: nil) }

        func description(relativeTo filename: String?) -> String {
            let file = location.filename == filename ? "" : "\(location.filename), "
            return "\(file)line \(location.lineNumber): \(reason)"
        }
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

        let expander = Expander(rootFilename: rootFilename) { path, limit in
            if !isFolder && path == rootFilename {
                return try readFile(at: source, limit: limit)
            }
            do {
                return try readFile(path, inside: folder, limit: limit)
            } catch let error as FileError where !isFolder && error.accessDenied {
                throw FolderAccessRequired(config: source)
            }
        }
        let expanded = try expander.run()
        if !isFolder && !expander.hasIncludes && expanded.assets.isEmpty {
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
        let data = try readFile(at: url, limit: isArchive(url) ? maximumArchiveSize : EqualizerAPOParser.maximumDataSize)
        return try parseManagedDefinition(data: data, filename: url.lastPathComponent)
    }

    static func parseManagedDefinition(data: Data, filename: String) throws -> EqualizerDefinition {
        if (filename as NSString).pathExtension.caseInsensitiveCompare(archiveExtension) == .orderedSame {
            guard data.count <= maximumArchiveSize else {
                throw FileError(reason: "the managed config exceeds the archive size limit")
            }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            return try snapshot.expanded.parse()
        }
        return try EqualizerAPOParser.parse(data: data, filename: filename)
    }

    static func readFile(at url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FileError(reason: "\(url.lastPathComponent) could not be opened")
        }
        return try readFile(descriptor, named: url.lastPathComponent, limit: limit)
    }

    private static func readFile(_ path: String, inside folder: URL, limit: Int) throws -> Data {
        var directory = open(folder.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {
            throw FileError.opening("The config folder", code: errno)
        }
        defer { _ = close(directory) }

        let parts = path.split(separator: "/")
        guard let filename = parts.last else {
            throw FileError(reason: "empty config file path")
        }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            guard next >= 0 else {
                throw FileError.opening(path, code: errno)
            }
            _ = close(directory)
            directory = next
        }
        let descriptor = openat(directory, String(filename), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FileError.opening(path, code: errno)
        }
        return try readFile(descriptor, named: path, limit: limit)
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
            throw FileError(reason: "expected a relative path inside the config folder")
        }
        var resolved = parent.split(separator: "/").dropLast().map(String.init)
        for part in parts {
            switch part {
            case ".":
                continue
            case "..":
                guard !resolved.isEmpty else {
                    throw FileError(reason: "path is outside the config folder")
                }
                resolved.removeLast()
            default:
                resolved.append(String(part))
            }
        }
        guard !resolved.isEmpty else {
            throw FileError(reason: "path does not name a file")
        }
        return resolved.joined(separator: "/")
    }

    nonisolated private final class Expander {
        private let rootFilename: String
        private let load: (String, Int) throws -> Data
        private var output = [String]()
        private var locations = [SourceLocation]()
        private var scopeBoundaries = [ScopeBoundary]()
        private var active = Set<String>()
        private var expandedBytes = 0
        private var visits = 0
        private var assetBytes = 0
        private var assets: [Int: EqualizerConvolutionAsset] = [:]

        private(set) var files = [String: Data]()
        private(set) var hasIncludes = false

        init(rootFilename: String, load: @escaping (String, Int) throws -> Data) {
            self.rootFilename = rootFilename
            self.load = load
        }

        func run() throws -> Expanded {
            guard !rootFilename.isEmpty, !rootFilename.contains("/"), !rootFilename.utf8.contains(0),
                  rootFilename != ".", rootFilename != ".." else {
                throw FileError(reason: "invalid config root filename")
            }
            try expand(rootFilename)
            return Expanded(
                data: Data(output.joined(separator: "\n").utf8),
                rootFilename: rootFilename,
                locations: locations,
                scopeBoundaries: scopeBoundaries,
                assets: assets
            )
        }

        private func contents(of path: String, limit: Int) throws -> Data {
            if let cached = files[path] {
                guard cached.count <= limit else { throw FileError(reason: "\(path) exceeds the file size limit") }
                return cached
            }
            guard files.count < 64 else { throw FileError(reason: "a config can reference at most 64 files") }
            let data = try load(path, limit)
            files[path] = data
            return data
        }

        private func addAsset(_ path: String) throws {
            guard EqualizerConvolutionAsset.supports(filename: path) else {
                throw FileError(reason: "Convolution requires a WAV impulse response")
            }
            guard assets.count < 4 else { throw FileError(reason: "a config can contain at most four Convolution commands") }
            let bytes = try contents(of: path, limit: EqualizerConvolutionAsset.maximumFileSize)
            assetBytes += bytes.count
            guard assetBytes <= EqualizerConvolutionAsset.maximumTotalFileSize else {
                throw FileError(reason: "config impulse responses exceed 16 MiB")
            }
            let lineNumber = output.count + 1
            assets[lineNumber] = try EqualizerConvolutionAsset.decode(data: bytes, filename: path, sourceLine: lineNumber)
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

            let bytes = try contents(of: path, limit: EqualizerAPOParser.maximumDataSize)
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
                let command = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
                guard fields.count == 2, command == "include" || command == "convolution" else {
                    output.append(line)
                    locations.append(location)
                    continue
                }

                var argument = fields[1].trimmingCharacters(in: .whitespaces)
                if argument.count >= 2, argument.first == "\"",
                   argument.last == "\"" {
                    argument = String(argument.dropFirst().dropLast())
                }
                do {
                    let relativePath = try resolve(argument, relativeTo: path)
                    if command == "include" {
                        hasIncludes = true
                        scopeBoundaries.append(.enter(beforeLine: output.count + 1))
                        try expand(relativePath)
                        scopeBoundaries.append(.leave(beforeLine: output.count + 1))
                    } else {
                        try addAsset(relativePath)
                        output.append(line)
                        locations.append(location)
                    }
                } catch let error as FolderAccessRequired {
                    throw error
                } catch let error as DependencyError {
                    throw error
                } catch {
                    throw DependencyError(location: location, reason: error.localizedDescription)
                }
            }
        }
    }
}
