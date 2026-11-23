import SwiftUI

/// Per-feature chrome copy for `PresetLibraryView`.
nonisolated struct PresetLibraryChrome {
    let dropLabel: String
    let manageHelp: String
    let linkTitle: String
    let linkDestination: URL
    let linkHelp: String
    let deleteHelp: String
    /// Folder named in the delete confirmation, e.g. "HRIR Presets".
    let libraryFolderName: String
    /// Draws the card background; call sites that already provide one pass false.
    var showsCardBackground = false

    static let hrir = PresetLibraryChrome(
        dropLabel: "Drop HRIR WAV files",
        manageHelp: "Reveal the managed HRIR Presets folder",
        linkTitle: "Get more HRIRs…",
        linkDestination: AirwaveResourceLinks.hrir,
        linkHelp: "Open the HeSuVi HRTF Database",
        deleteHelp: "Delete the selected managed HRIR preset",
        libraryFolderName: "HRIR Presets"
    )

    static let equalizer = PresetLibraryChrome(
        dropLabel: "Drop EQ presets or config folders",
        manageHelp: "Reveal the managed Equalizer Presets folder",
        linkTitle: "Get more equalizer presets…",
        linkDestination: AirwaveResourceLinks.equalizer,
        linkHelp: "Open AutoEq",
        deleteHelp: "Delete the selected managed preset",
        libraryFolderName: "Equalizer Presets",
        showsCardBackground: true
    )
}

/// Drop target, import/manage/delete footer, and dialogs shared by every preset
/// library. The row list and the
/// selection semantics stay with the caller.
struct PresetLibraryView<Preset: Identifiable & Equatable, Rows: View>: View {
    @ObservedObject var coordinator: PresetLibraryCoordinator
    let chrome: PresetLibraryChrome
    let selectedPreset: Preset?
    let presetName: (Preset) -> String
    let deletion: (Preset) -> PresetLibraryDeletion
    var onDeleted: (Preset) -> Void = { _ in }
    @ViewBuilder let rows: () -> Rows

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var pendingDelete: Preset?

    var body: some View {
        card
            .overlay {
                RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius)
                    .strokeBorder(
                        Color.primary.opacity(isTargeted ? 0.8 : 0),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
            }
            .overlay(alignment: .bottom) {
                if isTargeted {
                    Label(chrome.dropLabel, systemImage: "square.and.arrow.down")
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
                "Delete \(pendingDelete.map(presetName) ?? "preset")?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { preset in
                Button("Delete", role: .destructive) {
                    if coordinator.delete(deletion(preset), decision: .confirm) {
                        onDeleted(preset)
                    }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { preset in
                Text("This deletes the managed copy of \(presetName(preset)) from Airwave’s \(chrome.libraryFolderName) folder.")
            }
            .confirmationDialog(
                coordinator.message?.title ?? "Preset library",
                isPresented: Binding(
                    get: { coordinator.message != nil },
                    set: { if !$0 { coordinator.dismissMessage() } }
                ),
                titleVisibility: .visible,
                presenting: coordinator.message
            ) { message in
                if let folder = message.folderToChoose {
                    Button("Choose Folder…") { coordinator.presentImportPanel(folderToChoose: folder) }
                }
                Button(message.folderToChoose == nil ? "OK" : "Cancel", role: .cancel) { coordinator.dismissMessage() }
            } message: { message in
                Text(message.text)
            }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            rows()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .modifier(PresetLibraryCardBackground(isVisible: chrome.showsCardBackground))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Import…") { coordinator.presentImportPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Manage…") { coordinator.showInFinder() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(chrome.manageHelp)
            Link(chrome.linkTitle, destination: chrome.linkDestination)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .font(.system(size: 11, weight: .medium))
                .help(chrome.linkHelp)
            Spacer(minLength: 0)
            Button("Delete", role: .destructive) {
                pendingDelete = selectedPreset
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedPreset == nil)
            .help(chrome.deleteHelp)
        }
        .padding(AirwaveLayout.cardPadding)
    }
}

private struct PresetLibraryCardBackground: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        if isVisible {
            content.background(
                AirwavePalette.raised,
                in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius)
            )
        } else {
            content
        }
    }
}
