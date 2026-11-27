import AppKit
import AudioToolbox
import Combine
import CoreAudioKit
import SwiftUI
import UniformTypeIdentifiers
import os

final class EqualizerViewController: AUViewController, AUAudioUnitFactory {
    private nonisolated let unit = OSAllocatedUnfairLock<EqualizerAudioUnit?>(uncheckedState: nil)
    private let editor = EQEditorModel()

    nonisolated func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let audioUnit = try EqualizerAudioUnit(componentDescription: componentDescription)
        unit.withLockUnchecked { $0 = audioUnit }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.connectEditor()
        }
        return audioUnit
    }

    override func loadView() {
        preferredContentSize = NSSize(width: 540, height: 325)
        view = NSHostingView(rootView: EQEditor(model: editor))
        connectEditor()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        editor.refresh()
    }

    private func connectEditor() {
        let audioUnit = unit.withLockUnchecked { $0 }
        let notifications = NotificationCenter.default
        notifications.removeObserver(self, name: EqualizerAudioUnit.presetDidChange, object: nil)
        if let audioUnit {
            notifications.addObserver(self, selector: #selector(presetDidChange),
                                      name: EqualizerAudioUnit.presetDidChange, object: audioUnit)
        }
        editor.connect(audioUnit)
    }

    @objc private nonisolated func presetDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.editor.refresh() }
    }
}

@MainActor
private final class EQEditorModel: ObservableObject {
    static let frequencies = (0...150).map { 20 * pow(1_000, Double($0) / 150) }
    @Published private(set) var isConnected = false
    @Published private(set) var preset: EqualizerPresetSummary?
    @Published private(set) var response: [Double] = []
    @Published private(set) var error: String?
    private weak var unit: EqualizerAudioUnit?

    var factoryPresets: [AUAudioUnitPreset] { unit?.factoryPresets ?? [] }
    var userPresets: [AUAudioUnitPreset] { unit?.userPresets ?? [] }
    var currentPresetNumber: Int? { unit?.currentPreset?.number }
    var currentUserPreset: AUAudioUnitPreset? {
        guard let current = unit?.currentPreset, current.number < 0 else { return nil }
        return userPresets.first { $0.number == current.number && $0.name == current.name }
    }

    func connect(_ unit: EqualizerAudioUnit?) {
        self.unit = unit
        isConnected = unit != nil
        refresh()
    }

    func refresh() {
        preset = unit?.preset
        guard let unit else {
            response = []
            return
        }
        do {
            let nyquist = unit.outputBusses[0].format.sampleRate / 2
            let frequencies = Array(Self.frequencies.prefix { $0 <= nyquist })
            let values = try unit.responseDB(frequencies: frequencies)
            response = values.isEmpty ? [] : values + Array(repeating: .nan, count: Self.frequencies.count - values.count)
        } catch {
            response = []
            self.error = error.localizedDescription
        }
    }

    func importPreset() {
        let panel = NSOpenPanel()
        panel.title = "Import Equalizer APO Preset"
        panel.prompt = "Import"
        var types: [UTType] = [.plainText, .folder]
        if let archive = UTType(filenameExtension: EqualizerConfigFiles.archiveExtension) {
            types.append(archive)
        }
        panel.allowedContentTypes = types
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.importPreset(from: url)
        }
    }

    private func importPreset(from url: URL) {
        guard let unit else { return }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try unit.importPreset(from: url, remember: true)
            error = nil
            refresh()
        } catch let accessError as EqualizerConfigFiles.FolderAccessRequired {
            error = accessError.localizedDescription
            if accessError.config.lastPathComponent == "config.txt" {
                chooseConfigFolder(startingAt: accessError.config.deletingLastPathComponent())
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func chooseConfigFolder(startingAt folder: URL) {
        let panel = NSOpenPanel()
        panel.title = "Choose the Folder Containing config.txt"
        panel.prompt = "Choose Folder"
        panel.directoryURL = folder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.importPreset(from: url)
        }
    }

    func pastePreset() {
        apply { unit in
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { throw ImportError.emptyClipboard }
            try unit.applyPreset(name: "Pasted Preset", text: text, remember: true)
        }
    }

    func clearPreset() {
        apply { try $0.clearPreset() }
    }

    func selectPreset(_ preset: AUAudioUnitPreset) {
        apply { try $0.selectPreset(preset) }
    }

    func deleteCurrentUserPreset() {
        guard let preset = currentUserPreset else { return }
        apply { try $0.deleteUserPreset(preset) }
    }

    func renameUserPreset(_ preset: AUAudioUnitPreset, to name: String) {
        apply { try $0.renameUserPreset(preset, to: name) }
    }

    private func apply(_ change: (EqualizerAudioUnit) throws -> Void) {
        guard let unit else { return }
        do {
            try change(unit)
            error = nil
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private enum ImportError: LocalizedError {
        case emptyClipboard

        var errorDescription: String? {
            switch self {
            case .emptyClipboard: "Copy an Equalizer APO preset before pasting."
            }
        }
    }
}

private struct EQEditor: View {
    @ObservedObject var model: EQEditorModel
    @State private var presetToRename: AUAudioUnitPreset?
    @State private var presetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                Section("Factory Presets") {
                    presetRows(model.factoryPresets)
                }
                if !model.userPresets.isEmpty {
                    Section("Personal Presets") {
                        presetRows(model.userPresets)
                    }
                }
                Divider()
                Button("Import…", action: model.importPreset)
                    .accessibilityIdentifier("eq-import")
                Button("Paste Preset", action: model.pastePreset)
                    .accessibilityIdentifier("eq-paste")
                Button("Clear Preset", action: model.clearPreset)
                    .disabled(model.preset == nil)
                    .accessibilityIdentifier("eq-clear")
                if let preset = model.currentUserPreset {
                    Button("Rename Preset…") {
                        presetName = preset.name
                        presetToRename = preset
                    }
                    Button("Remove from Personal Presets", role: .destructive, action: model.deleteCurrentUserPreset)
                }
            } label: {
                Text(model.preset?.name ?? "Choose Preset")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 240, alignment: .leading)
            .disabled(!model.isConnected)
            .accessibilityLabel("Equalizer preset")
            .accessibilityValue(model.preset?.name ?? "No Preset")
            .accessibilityIdentifier("eq-presets")

            EQResponseChart(values: model.response)
                .frame(minHeight: 154)
                .overlay {
                    if model.preset != nil && model.response.isEmpty {
                        Text("Response preview unavailable for this preset.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

            if let preset = model.preset {
                HStack(spacing: 16) {
                    Text("Preamp \(preset.preampDB.formatted(.number.precision(.fractionLength(1)))) dB")
                    Text("\(preset.filterCount) \(preset.filterCount == 1 ? "filter" : "filters")")
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("Import or paste an Equalizer APO preset.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = model.error {
                ScrollView {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 46)
                .accessibilityIdentifier("eq-error")
            }
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 260)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Rename Personal Preset", isPresented: Binding(
            get: { presetToRename != nil }, set: { if !$0 { presetToRename = nil } }
        ), presenting: presetToRename) { preset in
            TextField("Preset name", text: $presetName)
            Button("Rename") { model.renameUserPreset(preset, to: presetName) }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func presetRows(_ presets: [AUAudioUnitPreset]) -> some View {
        ForEach(presets, id: \.number) { preset in
            Button {
                model.selectPreset(preset)
            } label: {
                if preset.number == model.currentPresetNumber {
                    Label(preset.name, systemImage: "checkmark")
                } else {
                    Text(preset.name)
                }
            }
        }
    }
}

private struct EQResponseChart: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 43, y: 12, width: max(1, size.width - 62), height: max(1, size.height - 34))
            let finite = values.filter(\.isFinite)
            let low = min(-12, floor((finite.min() ?? 0) / 6) * 6)
            let high = max(12, ceil((finite.max() ?? 0) / 6) * 6)
            func x(_ position: Double) -> Double { plot.minX + plot.width * position }
            func y(_ gain: Double) -> Double { plot.maxY - plot.height * (gain - low) / (high - low) }

            for db in [low, 0, high] {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(db)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
                context.stroke(line, with: .color(.secondary.opacity(db == 0 ? 0.35 : 0.18)))
                context.draw(Text("\(Int(db)) dB").font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary),
                             at: CGPoint(x: plot.minX - 5, y: y(db)), anchor: .trailing)
            }

            let ticks: [(Double, String)] = [(20, "20 Hz"), (100, "100"), (1_000, "1 k"), (10_000, "10 k"), (20_000, "20 k")]
            for (frequency, label) in ticks {
                let gridX = x(log10(frequency / 20) / 3)
                var line = Path()
                line.move(to: CGPoint(x: gridX, y: plot.minY))
                line.addLine(to: CGPoint(x: gridX, y: plot.maxY))
                context.stroke(line, with: .color(.secondary.opacity(0.18)))
                context.draw(Text(label).font(.system(size: 10)).foregroundColor(.secondary),
                             at: CGPoint(x: gridX, y: plot.maxY + 8), anchor: .top)
            }

            var response = Path()
            var hasPoint = false
            for (index, db) in values.enumerated() {
                guard db.isFinite else {
                    hasPoint = false
                    continue
                }
                let point = CGPoint(x: x(Double(index) / Double(max(1, values.count - 1))), y: y(db))
                if hasPoint { response.addLine(to: point) } else { response.move(to: point) }
                hasPoint = true
            }
            context.stroke(response, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Stereo frequency response")
    }
}
