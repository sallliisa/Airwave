import Foundation

nonisolated struct EqualizerAUState {
    struct Preset {
        let name: String
        let filename: String
        let data: Data
        fileprivate let isLegacyText: Bool

        init(name: String, filename: String, data: Data) {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.name = name.isEmpty ? "Preset" : name
            self.filename = filename
            self.data = data
            self.isLegacyText = false
        }

        init(name: String, legacyText: String) {
            self.name = name
            self.filename = "Preset.txt"
            self.data = Data(legacyText.utf8)
            self.isLegacyText = true
        }

        var legacyText: String? { isLegacyText ? String(decoding: data, as: UTF8.self) : nil }
    }

    struct OutputContext: Equatable, Sendable {
        let deviceName: String
        let deviceUID: String
        let inputChannelCount: Int

        fileprivate var dictionary: [String: Any] {
            ["deviceName": deviceName, "deviceUID": deviceUID, "inputChannelCount": inputChannelCount]
        }
    }

    let preset: Preset?
    let context: OutputContext?
    let bypass: Bool

    private enum Key {
        static let version = "Equalizer.version"
        static let name = "Equalizer.presetName"
        static let text = "Equalizer.presetText"
        static let filename = "Equalizer.presetFilename"
        static let data = "Equalizer.presetData"
        static let context = "Equalizer.outputContext"
        static let bypass = "Equalizer.bypass"
    }

    init(_ dictionary: [String: Any]?) throws {
        let state = dictionary ?? [:]
        if let context = state[Key.context] {
            guard let fields = context as? [String: Any],
                  let deviceName = fields["deviceName"] as? String,
                  let deviceUID = fields["deviceUID"] as? String,
                  let inputChannelCount = fields["inputChannelCount"] as? Int,
                  inputChannelCount > 0 else { throw InvalidDocument() }
            self.context = OutputContext(deviceName: deviceName, deviceUID: deviceUID, inputChannelCount: inputChannelCount)
        } else {
            context = nil
        }
        if let bypass = state[Key.bypass] {
            guard let value = bypass as? Bool else { throw InvalidDocument() }
            self.bypass = value
        } else {
            bypass = false
        }

        let version = state[Key.version] as? Int
        let hasPreset = [Key.name, Key.text, Key.filename, Key.data].contains { state[$0] != nil }
        switch (version, hasPreset) {
        case (nil, false) where state[Key.version] == nil && state[Key.bypass] == nil:
            preset = nil
        case (1, false), (2, false):
            preset = nil
        case (1, true):
            guard let name = state[Key.name] as? String, let text = state[Key.text] as? String else {
                throw InvalidDocument()
            }
            preset = Preset(name: name, legacyText: text)
        case (2, true):
            guard let name = state[Key.name] as? String, let filename = state[Key.filename] as? String,
                  let bytes = state[Key.data] as? Data else { throw InvalidDocument() }
            preset = Preset(name: name, filename: filename, data: bytes)
        default:
            throw InvalidDocument()
        }
    }

    static func document(preset: Preset?, context: OutputContext?, bypass: Bool = false,
                         including base: [String: Any] = [:]) -> [String: Any] {
        var state = base
        state[Key.version] = 2
        state[Key.bypass] = bypass
        state[Key.context] = context?.dictionary
        state[Key.name] = preset?.name
        state[Key.text] = nil
        state[Key.filename] = nil
        state[Key.data] = nil
        if let text = preset?.legacyText {
            state[Key.version] = 1
            state[Key.text] = text
        } else if let preset {
            state[Key.filename] = preset.filename
            state[Key.data] = preset.data
        }
        return state
    }

    static func settingOutputContext(_ context: OutputContext, in state: [String: Any]?) -> [String: Any] {
        var result = state ?? [:]
        result[Key.context] = context.dictionary
        return result
    }

    private struct InvalidDocument: LocalizedError {
        var errorDescription: String? { "The saved Equalizer preset has an invalid or unsupported format." }
    }
}
