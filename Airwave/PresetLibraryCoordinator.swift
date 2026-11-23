import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

nonisolated struct PresetLibraryFailure: Equatable {
    let filename: String
    let reason: String
    var folderToChoose: URL? = nil
}

nonisolated struct PresetLibraryPreflight {
    let acceptable: [URL]
    let conflicts: [URL]
    let rejected: [PresetLibraryFailure]
}

nonisolated struct PresetLibraryRow<Preset: Identifiable>: Identifiable {
    let id: String
    let name: String
    let preset: Preset?
    let isSelected: Bool
}

nonisolated enum PresetLibraryRowModel {
    /// "None" followed by the library, sorted only where the feature sorts today.
    static func rows<Preset: Identifiable>(
        presets: [Preset],
        selectedID: Preset.ID?,
        name: (Preset) -> String,
        sortedByName: Bool
    ) -> [PresetLibraryRow<Preset>] {
        guard !presets.isEmpty else { return [] }
        let ordered = sortedByName
            ? presets.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
            : presets
        return [PresetLibraryRow(
            id: "none",
            name: "None",
            preset: nil,
            isSelected: selectedID == nil
        )] + ordered.map { preset in
            PresetLibraryRow(
                id: String(describing: preset.id),
                name: name(preset),
                preset: preset,
                isSelected: selectedID == preset.id
            )
        }
    }
}

nonisolated enum PresetLibraryConflictResolution {
    case replace
    case keepExisting
    case cancel
}

nonisolated enum PresetLibraryDeletionDecision {
    case confirm
    case cancel
}

nonisolated struct PresetLibraryMessage: Equatable {
    let title: String
    let text: String
    var folderToChoose: URL? = nil
}

/// What one preset library needs to expose for the shared import/delete flow.
/// Managers keep their own APIs; adapters below map them onto this.
protocol PresetLibraryManaging: AnyObject {
    associatedtype Preset: Identifiable & Equatable

    func preflightLibraryImport(_ urls: [URL]) async -> PresetLibraryPreflight
    func importLibraryPresets(_ urls: [URL], replacingConflicts: Bool) async -> [PresetLibraryFailure]
    func deleteLibraryPreset(_ preset: Preset) -> Bool
    /// "<name>: <reason>" describing the last delete failure, if the manager has one.
    func deletionFailureDetail(for preset: Preset) -> String?
    func revealLibraryDirectory()
}

/// The per-feature strings and file types; everything else is shared.
nonisolated struct PresetLibraryConfiguration {
    let contentType: UTType
    let canChooseDirectories: Bool
    let panelTitle: String
    let panelMessage: String
    let deletionFailureFallback: String

    static let hrir = PresetLibraryConfiguration(
        contentType: UTType(filenameExtension: "wav") ?? .audio,
        canChooseDirectories: false,
        panelTitle: "Import HRIR Presets",
        panelMessage: "Choose one or more compatible HRIR WAV files.",
        deletionFailureFallback: "Could not delete the managed HRIR preset."
    )

    static let equalizer = PresetLibraryConfiguration(
        contentType: UTType(filenameExtension: "txt") ?? .plainText,
        canChooseDirectories: true,
        panelTitle: "Import Equalizer Presets",
        panelMessage: "Choose .txt presets or folders containing config.txt.",
        deletionFailureFallback: "Could not delete the managed preset."
    )
}

/// One preset's deletion, captured so the coordinator itself stays non-generic
/// (a generic ObservableObject class crashes the Swift 6.3.3 SIL optimizer).
nonisolated struct PresetLibraryDeletion {
    let perform: () -> Bool
    /// "<name>: <reason>" for the failure, read after `perform` returns false.
    let failureDetail: () -> String?
}

/// Import, conflict resolution, and deletion for any preset library.
@MainActor
final class PresetLibraryCoordinator: ObservableObject {
    @Published private(set) var conflicts: [URL] = []
    @Published private(set) var message: PresetLibraryMessage?

    let configuration: PresetLibraryConfiguration
    private let preflight: ([URL]) async -> PresetLibraryPreflight
    private let performImport: ([URL], Bool) async -> [PresetLibraryFailure]
    private let reveal: () -> Void
    private var pendingURLs: [URL] = []
    private var pendingFailures: [PresetLibraryFailure] = []
    private var operation: Task<Void, Never>?
    private var generation = 0

    init<Manager: PresetLibraryManaging>(
        manager: Manager,
        configuration: PresetLibraryConfiguration
    ) {
        self.configuration = configuration
        self.preflight = { await manager.preflightLibraryImport($0) }
        self.performImport = { await manager.importLibraryPresets($0, replacingConflicts: $1) }
        self.reveal = { manager.revealLibraryDirectory() }
    }

    func receive(_ urls: [URL]) {
        generation += 1
        let generation = generation
        operation?.cancel()
        message = nil
        conflicts = []
        pendingURLs = []
        pendingFailures = []
        guard !urls.isEmpty else { return }

        operation = Task { [weak self, preflight] in
            let result = await preflight(urls)
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            let validURLs = urls.filter { url in
                result.acceptable.contains(url) || result.conflicts.contains(url)
            }
            self.pendingFailures = result.rejected
            if result.conflicts.isEmpty {
                self.importURLs(validURLs, replacingConflicts: false, preflightFailures: result.rejected)
            } else {
                self.pendingURLs = validURLs
                self.conflicts = result.conflicts
            }
        }
    }

    func resolveConflicts(_ resolution: PresetLibraryConflictResolution) {
        guard !conflicts.isEmpty else { return }
        let urls = pendingURLs
        let failures = pendingFailures
        pendingURLs = []
        pendingFailures = []
        conflicts = []

        switch resolution {
        case .replace:
            importURLs(urls, replacingConflicts: true, preflightFailures: failures)
        case .keepExisting:
            importURLs(urls, replacingConflicts: false, preflightFailures: failures)
        case .cancel:
            message = makeMessage(failures: failures)
        }
    }

    func dismissMessage() {
        message = nil
    }

    func makeImportPanel(folderToChoose: URL? = nil) -> NSOpenPanel {
        let panel = NSOpenPanel()
        if let folderToChoose {
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.folder]
            panel.directoryURL = folderToChoose.deletingLastPathComponent()
            panel.title = "Choose Config Folder"
            panel.message = "Choose the folder containing config.txt and its companion files."
            panel.prompt = "Import"
            return panel
        }
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = configuration.canChooseDirectories
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [configuration.contentType]
        if configuration.canChooseDirectories {
            panel.allowedContentTypes.append(.folder)
        }
        panel.title = configuration.panelTitle
        panel.message = configuration.panelMessage
        return panel
    }

    func presentImportPanel(folderToChoose: URL? = nil) {
        let panel = makeImportPanel(folderToChoose: folderToChoose)
        // Non-modal: the settings window keeps drawing while the panel is up.
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.receive(panel.urls) }
        }
    }

    func showInFinder() {
        reveal()
    }

    @discardableResult
    func delete(
        _ deletion: PresetLibraryDeletion,
        decision: PresetLibraryDeletionDecision
    ) -> Bool {
        guard decision == .confirm else { return false }
        guard deletion.perform() else {
            message = PresetLibraryMessage(
                title: "Couldn’t delete preset",
                text: deletion.failureDetail() ?? configuration.deletionFailureFallback
            )
            return false
        }
        message = nil
        return true
    }

    private func importURLs(
        _ urls: [URL],
        replacingConflicts: Bool,
        preflightFailures: [PresetLibraryFailure] = []
    ) {
        let generation = generation
        operation = Task { [weak self, performImport] in
            let failures = await performImport(urls, replacingConflicts)
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.message = self.makeMessage(failures: preflightFailures + failures)
        }
    }

    func waitForIdle() async {
        // Drain the newest operation chain. importURLs() replaces the handle
        // from inside the preflight task, so loop until no unawaited task
        // remains. Bounded: one receive installs at most a preflight task that
        // installs at most one import task.
        for _ in 0..<8 {
            guard let current = operation else { return }
            await current.value
            guard operation != nil else { return }
        }
    }

    private func makeMessage(failures: [PresetLibraryFailure]) -> PresetLibraryMessage? {
        guard let first = failures.first else { return nil }
        if failures.count == 1, let folder = first.folderToChoose {
            return PresetLibraryMessage(title: "Choose the config folder", text: first.reason, folderToChoose: folder)
        }
        return PresetLibraryMessage(
            title: failures.count == 1 ? "Couldn’t import preset" : "Some presets couldn’t be imported",
            text: failures.map { "\($0.filename)\n\($0.reason)" }.joined(separator: "\n\n"),
            folderToChoose: failures.compactMap(\.folderToChoose).first
        )
    }
}

extension PresetLibraryManaging {
    /// Deletion of one preset, bound to this manager.
    func libraryDeletion(for preset: Preset) -> PresetLibraryDeletion {
        PresetLibraryDeletion(
            perform: { self.deleteLibraryPreset(preset) },
            failureDetail: { self.deletionFailureDetail(for: preset) }
        )
    }
}

// MARK: - Manager adapters

extension HRIRManager: PresetLibraryManaging {
    func preflightLibraryImport(_ urls: [URL]) async -> PresetLibraryPreflight {
        // Bounded header read only; stays on the main actor with the
        // manager. Full decode/copy runs off-main in importPresetsAsync.
        // Never use Task.detached + assumeIsolated here: detached runs
        // off-main and the assertion traps with EXC_BREAKPOINT.
        let preflight = preflightImport(urls)
        return PresetLibraryPreflight(
            acceptable: preflight.acceptable,
            conflicts: preflight.conflicts,
            rejected: preflight.rejected.map { .init(filename: $0.filename, reason: $0.reason) }
        )
    }

    func importLibraryPresets(_ urls: [URL], replacingConflicts: Bool) async -> [PresetLibraryFailure] {
        await importPresetsAsync(urls, collisionPolicy: replacingConflicts ? .replace : .reject)
            .failures
            .map { .init(filename: $0.filename, reason: $0.reason) }
    }

    func deleteLibraryPreset(_ preset: HRIRPreset) -> Bool { deletePreset(preset) }

    func deletionFailureDetail(for preset: HRIRPreset) -> String? {
        errorMessage.map { "\(preset.name): \($0)" }
    }

    func revealLibraryDirectory() { openPresetsDirectory() }
}

extension EqualizerManager: PresetLibraryManaging {
    func preflightLibraryImport(_ urls: [URL]) async -> PresetLibraryPreflight {
        let preflight = preflightImport(urls)
        return PresetLibraryPreflight(
            acceptable: preflight.acceptable,
            conflicts: preflight.conflicts,
            rejected: preflight.rejected.map { .init(filename: $0.filename, reason: $0.reason, folderToChoose: $0.folderToChoose) }
        )
    }

    func importLibraryPresets(_ urls: [URL], replacingConflicts: Bool) async -> [PresetLibraryFailure] {
        importPresets(urls, collisionPolicy: replacingConflicts ? .replace : .reject)
            .failures
            .map { .init(filename: $0.filename, reason: $0.reason, folderToChoose: $0.folderToChoose) }
    }

    func deleteLibraryPreset(_ preset: EqualizerPreset) -> Bool { delete(preset) }

    func deletionFailureDetail(for preset: EqualizerPreset) -> String? {
        libraryError.map { "\($0.filename): \($0.reason)" }
    }

    func revealLibraryDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([managedDirectory])
    }
}
