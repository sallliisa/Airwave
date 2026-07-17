import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct EqualizerSettingsLibraryRow: Equatable, Identifiable {
    let id: String
    let name: String
    let preset: EqualizerPreset?
    let isSelected: Bool
}

nonisolated enum EqualizerSettingsLibraryModel {
    static func rows(
        presets: [EqualizerPreset],
        selectedID: UUID?
    ) -> [EqualizerSettingsLibraryRow] {
        guard !presets.isEmpty else { return [] }
        return [EqualizerSettingsLibraryRow(
            id: "none",
            name: "None",
            preset: nil,
            isSelected: selectedID == nil
        )] + presets.map { preset in
            return EqualizerSettingsLibraryRow(
                id: preset.id.uuidString,
                name: preset.displayName,
                preset: preset,
                isSelected: selectedID == preset.id
            )
        }
    }

    static func rows(
        presets: [EqualizerPreset],
        selection: EqualizerSelection
    ) -> [EqualizerSettingsLibraryRow] {
        let selectedID: UUID?
        if case .preset(let id) = selection { selectedID = id } else { selectedID = nil }
        return rows(presets: presets, selectedID: selectedID)
    }
}

nonisolated enum EqualizerConflictResolution {
    case replace
    case keepExisting
    case cancel
}

nonisolated enum EqualizerDeletionDecision {
    case confirm
    case cancel
}

nonisolated struct EqualizerSettingsMessage: Equatable {
    let text: String
}

@MainActor
final class EqualizerSettingsCoordinator: ObservableObject {
    @Published private(set) var conflicts: [URL] = []
    @Published private(set) var message: EqualizerSettingsMessage?

    let manager: EqualizerManager
    private var pendingURLs: [URL] = []
    private var pendingFailures: [EqualizerImportFailure] = []

    init(manager: EqualizerManager) {
        self.manager = manager
    }

    func receive(_ urls: [URL]) {
        message = nil
        conflicts = []
        pendingURLs = []
        pendingFailures = []
        guard !urls.isEmpty else { return }

        let preflight = manager.preflightImport(urls)
        let validURLs = urls.filter { url in
            preflight.acceptable.contains(url) || preflight.conflicts.contains(url)
        }
        pendingFailures = preflight.rejected

        if preflight.conflicts.isEmpty {
            importURLs(validURLs, collisionPolicy: .reject, preflightFailures: pendingFailures)
        } else {
            pendingURLs = validURLs
            conflicts = preflight.conflicts
        }
    }

    func resolveConflicts(_ resolution: EqualizerConflictResolution) {
        guard !conflicts.isEmpty else { return }
        let urls = pendingURLs
        let failures = pendingFailures
        pendingURLs = []
        pendingFailures = []
        conflicts = []

        switch resolution {
        case .replace:
            importURLs(urls, collisionPolicy: .replace, preflightFailures: failures)
        case .keepExisting:
            importURLs(urls, collisionPolicy: .reject, preflightFailures: failures)
        case .cancel:
            message = makeMessage(failures: failures)
        }
    }

    func dismissMessage() {
        message = nil
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [UTType(filenameExtension: "txt") ?? .plainText]
        panel.title = "Import Equalizer Presets"
        panel.message = "Choose one or more EqualizerAPO .txt preset files."
        guard panel.runModal() == .OK else { return }
        receive(panel.urls)
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([manager.managedDirectory])
    }

    @discardableResult
    func delete(
        _ preset: EqualizerPreset,
        decision: EqualizerDeletionDecision
    ) -> Bool {
        guard decision == .confirm else { return false }
        guard manager.delete(preset) else {
            let error = manager.libraryError
            message = EqualizerSettingsMessage(
                text: error.map { "Could not delete \($0.filename): \($0.reason)" } ?? "Could not delete the managed preset."
            )
            return false
        }
        message = nil
        return true
    }

    private func importURLs(
        _ urls: [URL],
        collisionPolicy: EqualizerImportCollisionPolicy,
        preflightFailures: [EqualizerImportFailure] = []
    ) {
        let result = manager.importPresets(urls, collisionPolicy: collisionPolicy)
        message = makeMessage(failures: preflightFailures + result.failures)
    }

    private func makeMessage(failures: [EqualizerImportFailure]) -> EqualizerSettingsMessage? {
        guard !failures.isEmpty else { return nil }
        return EqualizerSettingsMessage(
            text: failures.map { "\($0.filename): \($0.reason)" }.joined(separator: " • ")
        )
    }
}

struct EqualizerSettingsView: View {
    @ObservedObject private var manager: EqualizerManager
    @ObservedObject private var profiles = DeviceProfileManager.shared
    @StateObject private var coordinator: EqualizerSettingsCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var pendingDelete: EqualizerPreset?

    @MainActor
    init(manager: EqualizerManager) {
        _manager = ObservedObject(wrappedValue: manager)
        _coordinator = StateObject(wrappedValue: EqualizerSettingsCoordinator(manager: manager))
    }

    @MainActor
    init() {
        self.init(manager: .shared)
    }

    var body: some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius)
                    .strokeBorder(
                        Color.primary.opacity(isTargeted ? 0.8 : 0),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
            }
            .overlay(alignment: .bottom) {
                if isTargeted {
                    Label("Drop EqualizerAPO .txt presets", systemImage: "square.and.arrow.down")
                        .font(.callout.weight(.medium))
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                        .transition(.opacity)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                coordinator.receive(urls)
                return true
            } isTargeted: { targeted in
                if reduceMotion {
                    isTargeted = targeted
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { isTargeted = targeted }
                }
            }
            .confirmationDialog(
                coordinator.conflicts.count == 1
                    ? "Replace existing preset?"
                    : "Replace \(coordinator.conflicts.count) existing presets?",
                isPresented: Binding(
                    get: { !coordinator.conflicts.isEmpty },
                    set: { isPresented in
                        if !isPresented && !coordinator.conflicts.isEmpty {
                            coordinator.resolveConflicts(.cancel)
                        }
                    }
                )
            ) {
                Button("Replace") { coordinator.resolveConflicts(.replace) }
                Button("Keep Existing", role: .cancel) {
                    coordinator.resolveConflicts(.keepExisting)
                }
            } message: {
                Text("Files with the same name can replace the managed copy. Other valid files will still import.")
            }
            .confirmationDialog(
                "Delete \(pendingDelete?.displayName ?? "preset")?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { preset in
                Button("Delete", role: .destructive) {
                    _ = coordinator.delete(preset, decision: .confirm)
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { preset in
                Text("This deletes the managed copy of \(preset.displayName) from Airwave’s Equalizer Presets folder.")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let message = coordinator.message {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(message.text).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Dismiss") { coordinator.dismissMessage() }
                            .buttonStyle(.plain)
                            .font(.caption)
                    }
                    .padding(8)
                    .background(AirwavePalette.raised)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(message.text)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
    }

    private var content: some View {
        libraryCard
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if manager.presets.isEmpty {
                    AirwaveEmptyLibraryState(
                        systemImage: "slider.horizontal.3",
                        title: "No equalizer presets",
                        description: "Airwave normally ships five EQ presets. Import an EqualizerAPO .txt preset to add another profile."
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(EqualizerSettingsLibraryModel.rows(
                                presets: manager.presets,
                                selectedID: profiles.editingProfile?.equalizerPresetID
                            )) { row in
                                Button {
                                    profiles.setEqualizerPresetID(row.preset?.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(row.name)
                                            .font(.callout)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        if row.isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.semibold))
                                        }
                                    }
                                    .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
                                    .padding(.vertical, AirwaveLayout.rowVerticalPadding)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(
                                    row.isSelected ? AirwavePalette.hover : .clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .accessibilityValue(row.isSelected ? "Selected" : "Not selected")
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Button("Import…") { coordinator.presentImportPanel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Manage…") { coordinator.showInFinder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reveal the managed Equalizer Presets folder")
                Link("Get more equalizer presets…", destination: AirwaveResourceLinks.equalizer)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .font(.system(size: 11, weight: .medium))
                    .help("Open AutoEq")
                Spacer(minLength: 0)
                Button("Delete", role: .destructive) {
                    pendingDelete = selectedPreset
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedPreset == nil)
                .help("Delete the selected managed preset")
            }
            .padding(AirwaveLayout.cardPadding)
        }
        .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var selectedPreset: EqualizerPreset? {
        manager.preset(id: profiles.editingProfile?.equalizerPresetID)
    }
}
