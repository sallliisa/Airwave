import AppKit
import AudioToolbox
import CoreAudioKit
import UniformTypeIdentifiers
import os

final class AirwaveSpatialViewController: AUViewController, AUAudioUnitFactory {
    private typealias BundledPreset = AirwaveSpatialAudioUnit.BundledPreset

    private enum PresetAction {
        case factory(BundledPreset)
        case personal(AUAudioUnitPreset)
        case importWAV
        case rename(AUAudioUnitPreset)
        case delete(AUAudioUnitPreset)
    }

    private nonisolated let unit = OSAllocatedUnfairLock<AirwaveSpatialAudioUnit?>(uncheckedState: nil)
    private let presetMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var bypassButton = NSButton(checkboxWithTitle: "Bypass", target: self, action: #selector(setBypass))
    private var bypassObservation: NSKeyValueObservation?
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
        preferredContentSize = NSSize(width: 340, height: 112)
        let content = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))

        let label = NSTextField(labelWithString: "HRIR preset")
        label.textColor = .secondaryLabelColor
        presetMenu.target = self
        presetMenu.action = #selector(selectPreset)
        presetMenu.setAccessibilityLabel("HRIR preset")
        presetMenu.cell?.lineBreakMode = .byTruncatingMiddle
        presetMenu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshPresetMenu),
                                               name: NSPopUpButton.willPopUpNotification, object: presetMenu)

        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        errorLabel.isHidden = true

        let actions = NSStackView(views: [presetMenu, bypassButton])
        actions.orientation = .horizontal
        actions.spacing = 12

        let stack = NSStackView(views: [label, actions, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            presetMenu.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            presetMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 220)
        ])
        view = content
        connectEditor()
    }

    private func connectEditor() {
        NotificationCenter.default.removeObserver(self, name: AirwaveSpatialAudioUnit.presetDidChange, object: nil)
        bypassObservation = nil
        presetsObservation = nil
        if let audioUnit = unit.withLockUnchecked({ $0 }) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(presetDidChange), name: AirwaveSpatialAudioUnit.presetDidChange,
                object: audioUnit
            )
            bypassObservation = audioUnit.observe(\.shouldBypassEffect) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.refreshBypass()
                }
            }
            presetsObservation = audioUnit.observe(\.userPresets) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.refreshPresetMenu() }
            }
        }
        refreshEditor()
    }

    private func refreshEditor() {
        refreshPresetMenu()
        refreshBypass()
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    @objc private func refreshPresetMenu() {
        let audioUnit = unit.withLockUnchecked { $0 }
        let selection = audioUnit?.presetSelection
        let savedPresets = audioUnit?.userPresets ?? []
        let selectedPersonal = audioUnit?.selectedUserPreset(in: savedPresets)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, action: PresetAction? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = action
            menu.addItem(item)
            return item
        }
        var selectedItem: NSMenuItem?
        for preset in BundledPreset.allCases {
            let item = add(preset.title, action: .factory(preset))
            if selection == .bundled(preset), selectedPersonal == nil { selectedItem = item }
        }
        if !savedPresets.isEmpty {
            menu.addItem(.separator())
            for preset in savedPresets {
                let item = add(preset.name, action: .personal(preset))
                if selectedPersonal?.name == preset.name { selectedItem = item }
            }
        }
        if selectedItem == nil {
            let title: String
            if case .imported(let name) = selection {
                title = name
            } else {
                title = "Choose Preset"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: 0)
            selectedItem = item
        }
        menu.addItem(.separator())
        _ = add("Import WAV…", action: .importWAV)
        if let selectedPersonal {
            _ = add("Rename Current Preset…", action: .rename(selectedPersonal))
            _ = add("Delete Current Preset…", action: .delete(selectedPersonal))
        }
        presetMenu.menu = menu
        presetMenu.select(selectedItem)
        presetMenu.isEnabled = audioUnit != nil
    }

    private func refreshBypass() {
        let audioUnit = unit.withLockUnchecked { $0 }
        bypassButton.isEnabled = audioUnit != nil
        bypassButton.state = audioUnit?.shouldBypassEffect == true ? .on : .off
    }

    @objc private func setBypass() {
        let audioUnit = unit.withLockUnchecked { $0 }
        audioUnit?.shouldBypassEffect = bypassButton.state == .on
    }

    @objc private nonisolated func presetDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshEditor()
        }
    }

    @objc private func selectPreset() {
        guard let action = presetMenu.selectedItem?.representedObject as? PresetAction,
              let audioUnit = unit.withLockUnchecked({ $0 }) else { return }
        refreshPresetMenu()
        switch action {
        case .factory(let preset):
            updatePreset { try audioUnit.useBundledPreset(preset) }
        case .personal(let preset):
            updatePreset { try audioUnit.useUserPreset(preset) }
        case .importWAV:
            importPreset()
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
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak audioUnit] response in
            guard response == .alertFirstButtonReturn, let audioUnit else { return }
            self?.updatePreset { try audioUnit.deleteUserPreset(preset) }
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self,
                  let audioUnit = self.unit.withLockUnchecked({ $0 }) else { return }
            self.updatePreset { try audioUnit.importPreset(from: url) }
        }
    }

    private func updatePreset(_ apply: () throws -> Void) {
        do {
            try apply()
            refreshEditor()
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
        }
    }
}
