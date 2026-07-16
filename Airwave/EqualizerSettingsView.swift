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

nonisolated struct EqualizerSettingsFilterRow: Equatable {
    let state: String
    let type: String
    let frequency: String
    let gain: String
    let q: String
    let isMuted: Bool
}

nonisolated struct EqualizerSettingsDetailModel: Equatable {
    let title: String
    let filename: String
    let preamp: String
    let explanation: String?
    let filters: [EqualizerSettingsFilterRow]
    let isBypassed: Bool

    init(preset: EqualizerPreset?) {
        guard let preset else {
            title = "Equalizer bypassed"
            filename = "No managed file"
            preamp = "0.00 dB"
            explanation = "None is the default. Select an imported preset to opt into Equalizer processing."
            filters = []
            isBypassed = true
            return
        }

        title = preset.displayName
        filename = preset.fileURL.lastPathComponent
        preamp = Self.format(preset.definition.preampDB, decimals: 2, suffix: " dB")
        explanation = nil
        filters = preset.definition.filters.map { filter in
            EqualizerSettingsFilterRow(
                state: filter.isEnabled ? "ON" : "OFF",
                type: Self.typeName(filter.type),
                frequency: Self.format(filter.frequencyHz, decimals: 1, suffix: " Hz"),
                gain: Self.format(filter.gainDB, decimals: 1, suffix: " dB"),
                q: Self.format(filter.q, decimals: 2, suffix: ""),
                isMuted: !filter.isEnabled
            )
        }
        isBypassed = false
    }

    private static func typeName(_ type: EqualizerFilterType) -> String {
        switch type {
        case .peaking: "PK"
        case .lowShelf: "LSC"
        case .highShelf: "HSC"
        }
    }

    private static func format(_ value: Double, decimals: Int, suffix: String) -> String {
        String(
            format: "%@%@",
            locale: Locale(identifier: "en_US_POSIX"),
            String(format: "%.*f", decimals, value),
            suffix
        )
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
    let isSuccess: Bool
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
            message = makeMessage(imported: [], skipped: [], failures: failures)
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
                text: error.map { "Could not delete \($0.filename): \($0.reason)" } ?? "Could not delete the managed preset.",
                isSuccess: false
            )
            return false
        }
        message = EqualizerSettingsMessage(
            text: "Deleted \(preset.displayName) from the managed Equalizer Presets folder.",
            isSuccess: true
        )
        return true
    }

    private func importURLs(
        _ urls: [URL],
        collisionPolicy: EqualizerImportCollisionPolicy,
        preflightFailures: [EqualizerImportFailure] = []
    ) {
        let result = manager.importPresets(urls, collisionPolicy: collisionPolicy)
        message = makeMessage(
            imported: result.imported,
            skipped: result.skipped,
            failures: preflightFailures + result.failures
        )
    }

    private func makeMessage(
        imported: [EqualizerPreset],
        skipped: [String],
        failures: [EqualizerImportFailure]
    ) -> EqualizerSettingsMessage {
        var parts: [String] = []
        if !imported.isEmpty {
            parts.append("Imported \(imported.count) preset\(imported.count == 1 ? "" : "s").")
        }
        if !skipped.isEmpty {
            parts.append("Kept existing: \(skipped.joined(separator: ", ")).")
        }
        if !failures.isEmpty {
            let details = failures.map { "\($0.filename): \($0.reason)" }.joined(separator: " • ")
            parts.append(details)
        }
        if parts.isEmpty {
            parts.append("No presets were imported.")
        }
        return EqualizerSettingsMessage(
            text: parts.joined(separator: " "),
            isSuccess: !imported.isEmpty && failures.isEmpty
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
    init(manager: EqualizerManager = .shared) {
        _manager = ObservedObject(wrappedValue: manager)
        _coordinator = StateObject(wrappedValue: EqualizerSettingsCoordinator(manager: manager))
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
                        Image(systemName: message.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
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
        HStack(alignment: .top, spacing: AirwaveLayout.cardSpacing) {
            libraryCard
                .frame(width: 292, alignment: .top)
            detailCard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            AirwaveSectionHeader(
                title: "Equalizer Presets",
                subtitle: "None is selected by default."
            )
            .padding(AirwaveLayout.cardPadding)

            Divider()

            ZStack {
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
            .frame(maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Button("Import…") { coordinator.presentImportPanel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Show in Finder") { coordinator.showInFinder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reveal the managed Equalizer Presets folder")
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

    private var detailCard: some View {
        let detail = EqualizerSettingsDetailModel(preset: selectedPreset)
        return VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            AirwaveSectionHeader(
                title: "Equalizer Details",
                subtitle: detail.isBypassed
                    ? "Select a preset to opt into equalizer processing."
                    : "Read-only settings from the managed copy."
            )

            VStack(alignment: .leading, spacing: 12) {
                Text(detail.title).font(.title3.weight(.semibold))
                if !detail.isBypassed {
                    Text("Managed file: \(detail.filename)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Preamp").font(.callout.weight(.medium))
                        Spacer()
                        Text(detail.preamp).font(.callout.monospacedDigit())
                    }
                    Divider()
                    Text("Filters").font(.callout.weight(.medium))
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            filterHeader
                            ForEach(Array(detail.filters.enumerated()), id: \.offset) { _, filter in
                                filterRow(filter)
                            }
                        }
                    }
                } else if let explanation = detail.explanation {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(AirwaveLayout.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        }
    }

    private var filterHeader: some View {
        HStack(spacing: 8) {
            Text("State").frame(width: 38, alignment: .leading)
            Text("Type").frame(width: 38, alignment: .leading)
            Text("Frequency").frame(maxWidth: .infinity, alignment: .trailing)
            Text("Gain").frame(width: 72, alignment: .trailing)
            Text("Q").frame(width: 46, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private func filterRow(_ filter: EqualizerSettingsFilterRow) -> some View {
        HStack(spacing: 8) {
            Text(filter.state).frame(width: 38, alignment: .leading)
            Text(filter.type).frame(width: 38, alignment: .leading)
            Text(filter.frequency).frame(maxWidth: .infinity, alignment: .trailing)
            Text(filter.gain).frame(width: 72, alignment: .trailing)
            Text(filter.q).frame(width: 46, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(filter.isMuted ? .secondary : .primary)
        .opacity(filter.isMuted ? 0.55 : 1)
        .padding(.vertical, 5)
        .accessibilityLabel("\(filter.state) \(filter.type), \(filter.frequency), \(filter.gain), Q \(filter.q)")
    }

    private var selectedPreset: EqualizerPreset? {
        manager.preset(id: profiles.editingProfile?.equalizerPresetID)
    }
}
