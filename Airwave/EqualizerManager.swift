import Combine
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

    init(
        managedDirectory: URL? = nil,
        fileManager: FileManager = .default,
        defaults _: UserDefaults = .standard,
        securityScope: any EqualizerSecurityScopeAccessing = DefaultEqualizerSecurityScope(),
        manifestWriter: any EqualizerManifestWriting = DefaultEqualizerManifestWriter(),
        runtimeEffect: EqualizerRuntimeEffect = EqualizerRuntimeEffect(),
        bundledPresetCatalog: BundledPresetCatalog? = nil
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
        for fileURL in children where fileURL.pathExtension.caseInsensitiveCompare("txt") == .orderedSame {
            do {
                let definition = try EqualizerAPOParser.parse(
                    data: Data(contentsOf: fileURL),
                    filename: fileURL.lastPathComponent
                )
                let stored = metadataByFilename[fileURL.lastPathComponent]
                updatedPresets.append(EqualizerPreset(
                    id: stored?.id ?? UUID(),
                    displayName: stored?.displayName ?? fileURL.deletingPathExtension().lastPathComponent,
                    fileURL: fileURL.standardizedFileURL,
                    definition: definition
                ))
            } catch {
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
                rejected.append(.init(filename: url.lastPathComponent, reason: reason(for: error)))
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
                let originalData = destinationExisted ? try? Data(contentsOf: input.destination) : nil
                guard !destinationExisted || originalData != nil else {
                    throw InputValidationError(reason: "the existing managed file could not be read")
                }
                let previousPresets = presets

                let temporary = managedDirectory.appendingPathComponent(".airwave-\(UUID().uuidString).txt")
                do {
                    try fileManager.copyItem(at: url, to: temporary)
                    if fileManager.fileExists(atPath: input.destination.path) {
                        _ = try fileManager.replaceItemAt(input.destination, withItemAt: temporary)
                    } else {
                        try fileManager.moveItem(at: temporary, to: input.destination)
                    }
                } catch {
                    try? fileManager.removeItem(at: temporary)
                    throw error
                }

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
                failures.append(.init(filename: url.lastPathComponent, reason: reason(for: error)))
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
            originalData = try Data(contentsOf: stored.fileURL)
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

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw InputValidationError(reason: "choose a text file, not a folder")
        }
        guard url.pathExtension.caseInsensitiveCompare("txt") == .orderedSame else {
            throw InputValidationError(reason: "only .txt files can be imported")
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw InputValidationError(reason: "the file could not be read")
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let type = attributes[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            throw InputValidationError(reason: "symbolic links cannot be imported")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw InputValidationError(reason: "the file could not be read")
        }
        guard data.count <= EqualizerAPOParser.maximumDataSize else {
            throw InputValidationError(reason: "file exceeds the 1 MiB limit")
        }
        let filename = url.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            throw InputValidationError(reason: "invalid filename")
        }
        let destination = managedDirectory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard isDirectChildOfManagedDirectory(destination) else {
            throw InputValidationError(reason: "invalid filename")
        }
        do {
            let definition = try EqualizerAPOParser.parse(data: data, filename: filename)
            return ValidatedInput(filename: filename, destination: destination, definition: definition)
        } catch {
            throw InputValidationError(reason: reason(for: error))
        }
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
        try? fileManager.removeItem(at: url)
        guard existed, let data else { return }
        try? data.write(to: url, options: .atomic)
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
}

private struct EqualizerPresetManifest: Codable, Equatable {
    let presets: [EqualizerPresetMetadata]
}
