import Foundation

nonisolated struct BundledPresetCatalog: Equatable {
    let equalizerFiles: [URL]
    let hrirFiles: [URL]

    init(equalizerFiles: [URL] = [], hrirFiles: [URL] = []) {
        self.equalizerFiles = equalizerFiles.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        self.hrirFiles = hrirFiles.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func fromMainBundle(_ bundle: Bundle = .main) -> BundledPresetCatalog {
        // XCTest launches the host app before loading test cases. Avoid doing
        // synchronous AVFoundation work during that host launch; tests inject
        // their own catalog when they need to exercise seeding.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return BundledPresetCatalog()
        }

        return BundledPresetCatalog(
            equalizerFiles: bundle.urls(forResourcesWithExtension: "txt", subdirectory: "assets/eq") ?? [],
            hrirFiles: bundle.urls(forResourcesWithExtension: "wav", subdirectory: "assets/hrtf") ?? []
        )
    }
}

nonisolated enum BundledPresetSeeder {
    private struct InstallationState: Codable {
        var acknowledgedFilenames: [String]
    }

    static func seed(
        files: [URL],
        into directory: URL,
        markerURL: URL,
        fileManager: FileManager = .default,
        validate: (URL) throws -> Void
    ) {
        var acknowledged = loadState(from: markerURL, fileManager: fileManager)

        for source in files {
            let filename = source.lastPathComponent
            guard !filename.isEmpty, filename != ".", filename != ".." else { continue }
            guard !acknowledged.contains(filename) else { continue }

            do {
                try validate(source)

                let destination = directory.appendingPathComponent(filename).standardizedFileURL
                guard destination.deletingLastPathComponent() == directory.standardizedFileURL else {
                    throw SeedingError.invalidFilename
                }

                if !fileManager.fileExists(atPath: destination.path) {
                    let temporary = directory.appendingPathComponent(
                        ".airwave-bundled-(UUID().uuidString)-(filename)",
                        isDirectory: false
                    )
                    do {
                        try fileManager.copyItem(at: source, to: temporary)
                        try fileManager.moveItem(at: temporary, to: destination)
                    } catch {
                        try? fileManager.removeItem(at: temporary)
                        throw error
                    }
                }

                acknowledged.insert(filename)
            } catch {
                Logger.log("[BundledPresetSeeder] Could not install \(filename): \(error.localizedDescription)")
            }
        }

        saveState(acknowledged, to: markerURL, fileManager: fileManager)
    }

    private static func loadState(from url: URL, fileManager: FileManager) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(InstallationState.self, from: data) else {
            return []
        }
        return Set(state.acknowledgedFilenames)
    }

    private static func saveState(_ filenames: Set<String>, to url: URL, fileManager: FileManager) {
        let state = InstallationState(acknowledgedFilenames: filenames.sorted())
        guard let data = try? JSONEncoder().encode(state) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.log("[BundledPresetSeeder] Could not save installation state: \(error.localizedDescription)")
        }
    }

    private enum SeedingError: LocalizedError {
        case invalidFilename

        var errorDescription: String? {
            "the bundled preset filename is invalid"
        }
    }
}
