import AppKit
import AudioToolbox
import CoreAudioKit
import UniformTypeIdentifiers
import os

final class AirwaveSpatialViewController: AUViewController, AUAudioUnitFactory {
    private typealias BundledPreset = AirwaveSpatialAudioUnit.BundledPreset
    private static let importWAVTitle = "Import WAV…"
    private static let importWAVTag = 1

    private nonisolated let unit = OSAllocatedUnfairLock<AirwaveSpatialAudioUnit?>(uncheckedState: nil)
    private let presetMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var bypassButton = NSButton(checkboxWithTitle: "Bypass", target: self, action: #selector(setBypass))
    private var bypassObservation: NSKeyValueObservation?

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
        }
        refreshEditor()
    }

    private func refreshEditor() {
        refreshPresetMenu()
        refreshBypass()
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    private func refreshPresetMenu() {
        let selection = unit.withLockUnchecked { $0?.presetSelection }
        presetMenu.removeAllItems()
        for preset in BundledPreset.allCases {
            presetMenu.addItem(withTitle: preset.title)
            presetMenu.lastItem?.representedObject = preset.rawValue
        }
        let title: String
        switch selection {
        case .bundled(let preset):
            title = preset.title
        case .imported(let name):
            let reservedTitles = BundledPreset.allCases.map(\.title) + [Self.importWAVTitle]
            title = reservedTitles.contains(name) ? "\(name) (Imported)" : name
            presetMenu.addItem(withTitle: title)
        case nil:
            title = BundledPreset.neutral.title
        }
        presetMenu.menu?.addItem(.separator())
        presetMenu.addItem(withTitle: Self.importWAVTitle)
        presetMenu.lastItem?.tag = Self.importWAVTag
        presetMenu.selectItem(withTitle: title)
        presetMenu.isEnabled = selection != nil
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
        guard let item = presetMenu.selectedItem,
              let audioUnit = unit.withLockUnchecked({ $0 }) else { return }
        refreshPresetMenu()
        if item.tag == Self.importWAVTag {
            importPreset()
        } else if let id = item.representedObject as? String, let preset = BundledPreset(rawValue: id),
                  audioUnit.presetSelection != .bundled(preset) {
            updatePreset { try audioUnit.useBundledPreset(preset) }
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
