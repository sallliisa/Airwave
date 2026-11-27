import AppKit
import AudioToolbox
import Combine
import CoreAudioKit
import SwiftUI
import UniformTypeIdentifiers
import os

final class AirwaveSpatialViewController: AUViewController, AUAudioUnitFactory {
    private nonisolated let unit = OSAllocatedUnfairLock<AirwaveSpatialAudioUnit?>(uncheckedState: nil)
    private let picker = SpatialPresetPickerModel()
    private var presetsObservation: NSKeyValueObservation?

    nonisolated func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let audioUnit = try AirwaveSpatialAudioUnit(componentDescription: componentDescription)
        unit.withLockUnchecked { $0 = audioUnit }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.connectEditor()
        }
        return audioUnit
    }

    override func loadView() {
        preferredContentSize = NSSize(width: 360, height: 270)
        let content = NSHostingView(rootView: SpatialPresetPicker(model: picker) { [weak self] action in
            self?.perform(action)
        })
        content.frame.size = preferredContentSize
        view = content
        connectEditor()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshPicker()
    }

    private func connectEditor() {
        NotificationCenter.default.removeObserver(self, name: AirwaveSpatialAudioUnit.presetDidChange, object: nil)
        presetsObservation = nil
        if let audioUnit = unit.withLockUnchecked({ $0 }) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(presetDidChange), name: AirwaveSpatialAudioUnit.presetDidChange,
                object: audioUnit
            )
            presetsObservation = audioUnit.observe(\.userPresets) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.refreshPicker() }
            }
        }
        refreshPicker()
    }

    private func refreshPicker() {
        guard let audioUnit = unit.withLockUnchecked({ $0 }) else { return }
        let presets = audioUnit.userPresets
        let selected = audioUnit.selectedUserPreset(in: presets)
        let detachedName: String?
        if selected != nil {
            detachedName = nil
        } else {
            switch audioUnit.presetSelection {
            case .none: detachedName = nil
            case .imported(let name): detachedName = name
            case .bundled(let preset): detachedName = preset.libraryName
            }
        }
        picker.library = .init(presets: presets, selection: selected?.number, detachedName: detachedName)
    }

    @objc private nonisolated func presetDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.refreshPicker() }
    }

    private func perform(_ action: SpatialPresetPicker.Action) {
        guard let audioUnit = unit.withLockUnchecked({ $0 }) else { return }
        switch action {
        case .select(let preset):
            updatePreset { try audioUnit.useUserPreset(preset) }
        case .importWAV:
            importPreset(in: audioUnit)
        case .rename(let preset):
            renamePreset(preset, in: audioUnit)
        case .delete(let preset):
            deletePreset(preset, from: audioUnit)
        }
    }

    private func renamePreset(_ preset: AUAudioUnitPreset, in audioUnit: AirwaveSpatialAudioUnit) {
        guard let window = view.window else { return }
        let name = NSTextField(string: preset.name)
        name.frame.size.width = 220
        name.setAccessibilityLabel("Preset name")
        let alert = NSAlert()
        alert.messageText = "Rename Preset"
        alert.accessoryView = name
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self, weak audioUnit] response in
            guard response == .alertFirstButtonReturn, let audioUnit else { return }
            self?.updatePreset { try audioUnit.renameUserPreset(preset, to: name.stringValue) }
        }
    }

    private func deletePreset(_ preset: AUAudioUnitPreset, from audioUnit: AirwaveSpatialAudioUnit) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(preset.name)”?"
        alert.informativeText = "Effects using this preset will keep their current settings."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak audioUnit] response in
            guard response == .alertFirstButtonReturn, let audioUnit else { return }
            self?.updatePreset { try audioUnit.deleteUserPreset(preset) }
        }
    }

    private func importPreset(in audioUnit: AirwaveSpatialAudioUnit) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.begin { [weak self, weak audioUnit] result in
            guard result == .OK, let url = panel.url, let audioUnit else { return }
            self?.updatePreset { try audioUnit.importPreset(from: url) }
        }
    }

    private func updatePreset(_ apply: () throws -> Void) {
        do {
            try apply()
            picker.error = nil
            refreshPicker()
        } catch {
            picker.error = error.localizedDescription
        }
    }
}

@MainActor
private final class SpatialPresetPickerModel: ObservableObject {
    struct Library {
        let presets: [AUAudioUnitPreset]
        let selection: Int?
        let detachedName: String?
    }

    @Published var library: Library?
    @Published var error: String?
}

private struct SpatialPresetPicker: View {
    enum Action {
        case select(AUAudioUnitPreset)
        case importWAV
        case rename(AUAudioUnitPreset)
        case delete(AUAudioUnitPreset)
    }

    @ObservedObject var model: SpatialPresetPickerModel
    let perform: (Action) -> Void
    @State private var hoveringPresetActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HRIR Presets")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                rows
                Divider()
                footer
            }
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 8))

            if let name = model.library?.detachedName {
                Text("Current preset · \(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(minWidth: 320, minHeight: 220)
        .disabled(model.library == nil)
    }

    private var rows: some View {
        let presets = model.library?.presets ?? []
        return Group {
            if presets.isEmpty {
                Text("No presets")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(presets, id: \.number) { preset in
                            let selected = preset.number == model.library?.selection
                            Button { perform(.select(preset)) } label: {
                                HStack {
                                    Text(preset.name).font(.callout).lineLimit(1)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.semibold))
                                            .accessibilityHidden(true)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .background(selected ? Color.primary.opacity(0.08) : .clear,
                                        in: .rect(cornerRadius: 6))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("spatial-preset.\(preset.number)")
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(minHeight: 88, maxHeight: .infinity)
        .accessibilityIdentifier("spatial-preset-list")
    }

    private var footer: some View {
        let selected = model.library?.presets.first { $0.number == model.library?.selection }
        return HStack(spacing: 8) {
            Button("Import…") { perform(.importWAV) }
                .buttonStyle(.borderedProminent)
            Spacer()
            SpatialPresetActionsButton(selected: selected, perform: perform)
                .frame(width: 28, height: 28)
                .background(hoveringPresetActions && selected != nil ? Color.primary.opacity(0.08) : .clear,
                            in: .rect(cornerRadius: 6))
                .onHover { hoveringPresetActions = $0 }
        }
        .controlSize(.small)
        .padding(10)
    }
}

private struct SpatialPresetActionsButton: NSViewRepresentable {
    let selected: AUAudioUnitPreset?
    let perform: (SpatialPresetPicker.Action) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        button.setAccessibilityLabel("Manage selected preset")
        button.setAccessibilityIdentifier("spatial-preset-actions")
        button.toolTip = "Manage selected preset"
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.selected = selected
        context.coordinator.perform = perform
        button.isEnabled = selected != nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var selected: AUAudioUnitPreset?
        var perform: ((SpatialPresetPicker.Action) -> Void)?

        @objc func openMenu(_ button: NSButton) {
            let menu = NSMenu()
            menu.addItem(withTitle: "Rename…", action: #selector(rename), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Delete…", action: #selector(delete), keyEquivalent: "").target = self
            menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX - menu.size.width, y: 0), in: button)
        }

        @objc private func rename() {
            if let selected { perform?(.rename(selected)) }
        }

        @objc private func delete() {
            if let selected { perform?(.delete(selected)) }
        }
    }
}
