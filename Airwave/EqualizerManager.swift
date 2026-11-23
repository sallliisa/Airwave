import Combine
import CoreServices
import Foundation

nonisolated protocol EqualizerSecurityScopeAccessing {
    func startAccessingSecurityScopedResource(for url: URL) -> Bool
    func stopAccessingSecurityScopedResource(for url: URL)
}

nonisolated struct DefaultEqualizerSecurityScope: EqualizerSecurityScopeAccessing {
    func startAccessingSecurityScopedResource(for url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessingSecurityScopedResource(for url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

nonisolated protocol EqualizerManifestWriting {
    func write(_ data: Data, to url: URL) throws
}

nonisolated struct DefaultEqualizerManifestWriter: EqualizerManifestWriting {
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

nonisolated enum EqualizerImportCollisionPolicy {
    case reject
    case replace
}

nonisolated struct EqualizerImportFailure: Equatable {
    let filename: String
    let reason: String
    var folderToChoose: URL? = nil
}

nonisolated struct EqualizerImportPreflight {
    let acceptable: [URL]
    let conflicts: [URL]
    let rejected: [EqualizerImportFailure]
}

nonisolated struct EqualizerImportResult {
    let imported: [EqualizerPreset]
    let skipped: [String]
    let failures: [EqualizerImportFailure]
}

nonisolated struct EqualizerLibraryError: Equatable, LocalizedError {
    let filename: String
    let reason: String

    var errorDescription: String? {
        "\(filename): \(reason)"
    }
}

@MainActor
final class EqualizerManager: ObservableObject {
    static let shared = EqualizerManager()

    @Published private(set) var presets: [EqualizerPreset] = []
    @Published private(set) var libraryError: EqualizerLibraryError?

    let managedDirectory: URL
    let runtimeEffect: EqualizerRuntimeEffect

    private let fileManager: FileManager
    private let securityScope: any EqualizerSecurityScopeAccessing
    private let manifestWriter: any EqualizerManifestWriting
    private let manifestURL: URL
    private let bundledPresetCatalog: BundledPresetCatalog
    private var eventStream: FSEventStreamRef?
    private var directoryDebounceTask: DispatchWorkItem?

    init(
        managedDirectory: URL? = nil,
        fileManager: FileManager = .default,
        defaults _: UserDefaults = .standard,
        securityScope: any EqualizerSecurityScopeAccessing = DefaultEqualizerSecurityScope(),
        manifestWriter: any EqualizerManifestWriting = DefaultEqualizerManifestWriter(),
        runtimeEffect: EqualizerRuntimeEffect = EqualizerRuntimeEffect(),
        bundledPresetCatalog: BundledPresetCatalog? = nil,
        startWatcher: Bool = true
    ) {
        self.fileManager = fileManager
        self.securityScope = securityScope
        self.manifestWriter = manifestWriter
        self.runtimeEffect = runtimeEffect
        self.bundledPresetCatalog = bundledPresetCatalog ?? BundledPresetCatalog.fromMainBundle()
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.managedDirectory = (managedDirectory ?? applicationSupport
            .appendingPathComponent("Airwave", isDirectory: true)
            .appendingPathComponent("Equalizer Presets", isDirectory: true))
            .standardizedFileURL
        self.manifestURL = self.managedDirectory.appendingPathComponent("manifest.json")

        try? fileManager.createDirectory(at: self.managedDirectory, withIntermediateDirectories: true)
        seedBundledPresets()
        reload()
        if startWatcher { startDirectoryWatcher() }
    }

    deinit {
        directoryDebounceTask?.cancel()
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func seedBundledPresets() {
        BundledPresetSeeder.seed(
            files: bundledPresetCatalog.equalizerFiles,
            into: managedDirectory,
            markerURL: managedDirectory.appendingPathComponent(".bundled-presets.json"),
            fileManager: fileManager
        ) { source in
            let data = try Data(contentsOf: source)
            _ = try EqualizerAPOParser.parse(data: data, filename: source.lastPathComponent)
        }
    }

    func reload() {
        libraryError = nil
        let manifest = loadManifest()
        let metadataByFilename = manifest.reduce(into: [String: EqualizerPresetMetadata]()) { result, metadata in
            result[metadata.filename] = metadata
        }
        var updatedPresets: [EqualizerPreset] = []
        var errors: [EqualizerLibraryError] = []

        let children = (try? fileManager.contentsOfDirectory(
            at: managedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let childFilenames = Set(children.map(\.lastPathComponent))
        for fileURL in children where fileURL.pathExtension.caseInsensitiveCompare("txt") == .orderedSame
            || EqualizerConfigFiles.isArchive(fileURL) {
            do {
                let definition = try EqualizerConfigFiles.readManagedDefinition(at: fileURL)
                let stored = metadataByFilename[fileURL.lastPathComponent]
                updatedPresets.append(EqualizerPreset(
                    id: stored?.id ?? UUID(),
                    displayName: stored?.displayName ?? fileURL.deletingPathExtension().lastPathComponent,
                    fileURL: fileURL.standardizedFileURL,
                    definition: definition
                ))
            } catch {
                if EqualizerConfigFiles.isArchive(fileURL),
                   let previous = presets.first(where: { $0.fileURL == fileURL.standardizedFileURL }) {
                    updatedPresets.append(previous)
                }
                errors.append(.init(filename: fileURL.lastPathComponent, reason: error.localizedDescription))
            }
        }
        for metadata in manifest where !childFilenames.contains(metadata.filename) {
            errors.append(.init(filename: metadata.filename, reason: "the managed file could not be read"))
        }

        presets = sort(updatedPresets)
        let reconciledManifest = presets.map {
            EqualizerPresetMetadata(
                id: $0.id,
                filename: $0.fileURL.lastPathComponent,
                displayName: $0.displayName
            )
        }
        if reconciledManifest != manifest {
            _ = saveManifest(reconciledManifest)
        }

        if let first = errors.first {
            libraryError = first
        }
    }

    private func startDirectoryWatcher() {
        let pathsToWatch = [managedDirectory.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (
            _,
            clientCallBackInfo,
            _,
            _,
            _,
            _
        ) in
            guard let info = clientCallBackInfo else { return }
            let manager = Unmanaged<EqualizerManager>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { [weak manager] in
                manager?.scheduleDirectoryReload()
            }
        }

        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(stream)
            eventStream = stream
        }
    }

    private func scheduleDirectoryReload() {
        directoryDebounceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        directoryDebounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
    }

    func preset(id: UUID?) -> EqualizerPreset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    func preflightImport(_ urls: [URL]) -> EqualizerImportPreflight {
        var acceptable: [URL] = []
        var conflicts: [URL] = []
        var rejected: [EqualizerImportFailure] = []
        for url in urls {
            do {
                let input = try validateInput(url)
                if fileManager.fileExists(atPath: input.destination.path) {
                    conflicts.append(url)
                } else {
                    acceptable.append(url)
                }
            } catch {
                rejected.append(importFailure(for: url, error: error))
            }
        }
        return .init(acceptable: acceptable, conflicts: conflicts, rejected: rejected)
    }

    @discardableResult
    func importPresets(
        _ urls: [URL],
        collisionPolicy: EqualizerImportCollisionPolicy
    ) -> EqualizerImportResult {
        var imported: [EqualizerPreset] = []
        var skipped: [String] = []
        var failures: [EqualizerImportFailure] = []

        for url in urls {
            do {
                let input = try validateInput(url)
                let existing = presets.first { $0.fileURL.lastPathComponent == input.filename }
                if fileManager.fileExists(atPath: input.destination.path), collisionPolicy == .reject {
                    skipped.append(input.filename)
                    continue
                }

                let destinationExisted = fileManager.fileExists(atPath: input.destination.path)
                let originalData = destinationExisted
                    ? try? EqualizerConfigFiles.readFile(at: input.destination, limit: EqualizerConfigFiles.maximumArchiveSize)
                    : nil
                guard !destinationExisted || originalData != nil else {
                    throw InputValidationError(reason: "the existing managed file could not be read")
                }
                let previousPresets = presets

                try input.data.write(to: input.destination, options: .atomic)

                let preset = EqualizerPreset(
                    id: existing?.id ?? UUID(),
                    displayName: existing?.displayName ?? input.destination.deletingPathExtension().lastPathComponent,
                    fileURL: input.destination,
                    definition: input.definition
                )
                if let index = presets.firstIndex(where: { $0.id == preset.id }) {
                    presets[index] = preset
                } else {
                    presets.append(preset)
                }
                presets = sort(presets)
                guard saveManifest(for: presets) else {
                    presets = previousPresets
                    restoreManagedFile(
                        at: input.destination,
                        existed: destinationExisted,
                        data: originalData
                    )
                    failures.append(.init(
                        filename: input.filename,
                        reason: "managed library metadata could not be saved"
                    ))
                    continue
                }
                imported.append(preset)
            } catch {
                failures.append(importFailure(for: url, error: error))
            }
        }
        return .init(imported: imported, skipped: skipped, failures: failures)
    }

    @discardableResult
    func delete(_ preset: EqualizerPreset) -> Bool {
        guard let stored = presets.first(where: { $0.id == preset.id }),
              stored.fileURL.standardizedFileURL == preset.fileURL.standardizedFileURL,
              isDirectChildOfManagedDirectory(stored.fileURL) else {
            return false
        }
        let originalData: Data
        do {
            originalData = try EqualizerConfigFiles.readFile(at: stored.fileURL, limit: EqualizerConfigFiles.maximumArchiveSize)
        } catch {
            libraryError = .init(filename: stored.fileURL.lastPathComponent, reason: "the managed file could not be read")
            return false
        }
        let previousPresets = presets
        do {
            try fileManager.removeItem(at: stored.fileURL)
        } catch {
            libraryError = .init(filename: stored.fileURL.lastPathComponent, reason: reason(for: error))
            return false
        }
        presets.removeAll { $0.id == stored.id }
        guard saveManifest(for: presets) else {
            restoreManagedFile(at: stored.fileURL, existed: true, data: originalData)
            presets = previousPresets
            return false
        }
        return true
    }

    private struct ValidatedInput {
        let filename: String
        let destination: URL
        let data: Data
        let definition: EqualizerDefinition
    }

    private struct InputValidationError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private func validateInput(_ url: URL) throws -> ValidatedInput {
        let accessed = securityScope.startAccessingSecurityScopedResource(for: url)
        defer {
            if accessed { securityScope.stopAccessingSecurityScopedResource(for: url) }
        }

        let input = try EqualizerConfigFiles.prepareImport(url)
        let destination = managedDirectory.appendingPathComponent(input.filename, isDirectory: false).standardizedFileURL
        guard isDirectChildOfManagedDirectory(destination) else {
            throw InputValidationError(reason: "invalid filename")
        }
        return ValidatedInput(filename: input.filename, destination: destination, data: input.data, definition: input.definition)
    }

    private func loadManifest() -> [EqualizerPresetMetadata] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        guard let manifest = try? JSONDecoder().decode(EqualizerPresetManifest.self, from: data) else {
            libraryError = .init(filename: manifestURL.lastPathComponent, reason: "manifest could not be read")
            return []
        }
        return manifest.presets
    }

    @discardableResult
    private func saveManifest(for presets: [EqualizerPreset] = []) -> Bool {
        let source = presets.isEmpty ? self.presets : presets
        return saveManifest(source.map {
            EqualizerPresetMetadata(id: $0.id, filename: $0.fileURL.lastPathComponent, displayName: $0.displayName)
        })
    }

    @discardableResult
    private func saveManifest(_ metadata: [EqualizerPresetMetadata]) -> Bool {
        let manifest = EqualizerPresetManifest(presets: metadata)
        guard let data = try? JSONEncoder().encode(manifest) else {
            libraryError = .init(filename: manifestURL.lastPathComponent, reason: "manifest could not be encoded")
            return false
        }
        do {
            try manifestWriter.write(data, to: manifestURL)
            return true
        } catch {
            libraryError = .init(filename: manifestURL.lastPathComponent, reason: "manifest could not be saved")
            return false
        }
    }

    private func restoreManagedFile(at url: URL, existed: Bool, data: Data?) {
        if existed, let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? fileManager.removeItem(at: url)
        }
    }

    private func sort(_ presets: [EqualizerPreset]) -> [EqualizerPreset] {
        presets.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func isDirectChildOfManagedDirectory(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == managedDirectory.standardizedFileURL
    }

    private func reason(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func importFailure(for url: URL, error: Error) -> EqualizerImportFailure {
        let filename = url.lastPathComponent
        if let access = error as? EqualizerConfigFiles.FolderAccessRequired, access.config.lastPathComponent == "config.txt" {
            return .init(filename: filename, reason: reason(for: access), folderToChoose: access.config.deletingLastPathComponent())
        }
        if let dependency = error as? EqualizerConfigFiles.DependencyError {
            return .init(filename: filename, reason: dependency.description(relativeTo: filename))
        }
        if let parse = error as? EqualizerParseError, parse.filename == filename {
            return .init(filename: filename, reason: parse.issueDescription)
        }
        return .init(filename: filename, reason: reason(for: error))
    }
}

private struct EqualizerPresetManifest: Codable, Equatable {
    let presets: [EqualizerPresetMetadata]
}
