import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct HostPresetLibraryView: View {
    struct Target: Identifiable {
        let slot: EffectSlot
        let device: HostDeviceTarget

        var id: UUID { slot.id }
    }

    private enum Edit {
        case save(Data)
        case rename(HostPresetLibrary.Entry)
        case delete(HostPresetLibrary.Entry)

        var actionTitle: String {
            switch self {
            case .save: "Save"
            case .rename: "Rename"
            case .delete: "Delete"
            }
        }

        var title: String {
            switch self {
            case .save: "Save Current Preset"
            case .rename: "Rename Preset"
            case .delete: "Delete Preset?"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: HostController
    let target: Target

    @State private var entries: [HostPresetLibrary.Entry] = []
    @State private var selection: UUID?
    @State private var editing: Edit?
    @State private var name = ""
    @State private var error: String?
    @State private var applying = false

    private var selected: HostPresetLibrary.Entry? {
        entries.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(target.slot.name) Presets")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(target.device.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            catalog

            HStack(spacing: 8) {
                Button("Import…", action: importPreset)
                Button("Save Current…") {
                    perform {
                        let state = try host.presetState(for: target.slot.id, deviceUID: target.device.id)
                        name = ""
                        editing = .save(state)
                    }
                }
                .disabled(target.slot.migrationIssue != nil)
                if let selected {
                    Menu {
                        Button("Rename…") {
                            name = selected.name
                            editing = .rename(selected)
                        }
                        Button("Delete…", role: .destructive) { editing = .delete(selected) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Manage selected preset")
                }

                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard let selected else { return }
                    apply(selected)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(applying)
        .interactiveDismissDisabled(applying)
        .padding(20)
        .frame(width: 480, height: 366)
        .background(HostAppearance.canvas)
        .onAppear { perform { try reload() } }
        .alert(editing?.title ?? "", isPresented: Binding(
            get: { editing != nil }, set: { if !$0 { editing = nil } }
        ), presenting: editing) { edit in
            switch edit {
            case .delete(let entry):
                Button(edit.actionTitle, role: .destructive) {
                    perform {
                        try host.presetLibrary.delete(entry)
                        try reload()
                    }
                }
            case .save, .rename:
                TextField("Preset name", text: $name)
                Button(edit.actionTitle) { save(edit) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("Cancel", role: .cancel) {}
        } message: { edit in
            if case .delete(let entry) = edit {
                Text("Delete “\(entry.name)” from the library? Devices already using it will keep their settings.")
            }
        }
        .alert("Preset Library", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        ), presenting: error) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var catalog: some View {
        Group {
            if entries.isEmpty {
                Text("No saved presets")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            Button {
                                selection = entry.id
                            } label: {
                                HStack(spacing: 8) {
                                    Text(entry.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Spacer()
                                    if selection == entry.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(selection == entry.id ? HostAppearance.hover : .clear)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == entry.id ? .isSelected : [])
                            .accessibilityIdentifier("preset.\(entry.id.uuidString)")
                            if entries.last?.id != entry.id { Divider().padding(.leading, 12) }
                        }
                    }
                }
            }
        }
        .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))
        .clipShape(.rect(cornerRadius: HostAppearance.cornerRadius))
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { self.error = error.localizedDescription }
    }

    private func reload(select selectedID: UUID? = nil) throws {
        entries = try host.presetLibrary.load(for: target.slot.component)
        selection = entries.first { $0.id == (selectedID ?? selection) }?.id
    }

    private func save(_ edit: Edit) {
        perform {
            switch edit {
            case .save(let state):
                let entry = try host.presetLibrary.save(name: name, component: target.slot.component, state: state)
                try reload(select: entry.id)
            case .rename(let entry):
                try host.presetLibrary.rename(entry, to: name)
                try reload(select: entry.id)
            case .delete:
                break
            }
        }
    }

    private func apply(_ entry: HostPresetLibrary.Entry) {
        applying = true
        Task {
            defer { applying = false }
            do {
                try await host.applyPreset(entry, to: target.slot.id, deviceUID: target.device.id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.title = "Import \(target.slot.name) Preset"
        panel.prompt = "Import"
        if target.slot.component == .airwaveSpatial {
            panel.allowedContentTypes = [.wav]
        } else {
            panel.canChooseDirectories = true
            panel.allowedContentTypes = [.plainText, .folder]
            if let archive = UTType(filenameExtension: EqualizerConfigFiles.archiveExtension) {
                panel.allowedContentTypes.append(archive)
            }
        }
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            perform {
                let entry = try host.presetLibrary.importPreset(from: url, component: target.slot.component)
                try reload(select: entry.id)
            }
        }
    }
}
