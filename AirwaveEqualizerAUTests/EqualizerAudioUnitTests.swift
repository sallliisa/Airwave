import AudioToolbox
import AVFoundation
import XCTest

final class EqualizerAudioUnitTests: XCTestCase {
    private static let component = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x45714150,
        componentManufacturer: 0x536e6866,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    func testPortableFolderAndOutputContextRenderLikeAirwave2() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let filters = source.appendingPathComponent("filters")
        try FileManager.default.createDirectory(at: filters, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("""
        Device: Studio
        If: inputChannelCount == 6
        Include: filters/Room.txt
        EndIf:
        """.utf8).write(to: source.appendingPathComponent("config.txt"))
        try Data("""
        Channel: L
        Preamp: -6.020599913 dB
        Channel: all
        Copy: L=R R=L
        Delay: 1 samples
        Convolution: "Room IR.wav"
        """.utf8).write(to: filters.appendingPathComponent("Room.txt"))
        try impulseWAV().write(to: filters.appendingPathComponent("Room IR.wav"))

        let first = try EqualizerAudioUnit(componentDescription: Self.component)
        try first.importPreset(from: source)
        let context = EqualizerAUState.OutputContext(deviceName: "Studio", deviceUID: "interface", inputChannelCount: 6)
        let state = EqualizerAUState.settingOutputContext(context, in: first.fullStateForDocument)
        let savedState = try roundtrip(state)
        try FileManager.default.removeItem(at: source)

        let restored = try EqualizerAudioUnit(componentDescription: Self.component)
        restored.fullStateForDocument = savedState
        try configure(restored)
        defer { restored.deallocateRenderResources() }
        let inputLeft: [Float] = [0.75, 0, 0, 0]
        let inputRight: [Float] = [0.25, 0, 0, 0]
        let output = try render(restored, left: inputLeft, right: inputRight)
        XCTAssertEqual(output.left, [0, 0, 0.125, 0])
        XCTAssertEqual(output.right, [0, 0.09375, 0, 0])

        let otherOutput = try EqualizerAudioUnit(componentDescription: Self.component)
        let otherContext = EqualizerAUState.OutputContext(deviceName: "Speakers", deviceUID: "speakers", inputChannelCount: 6)
        otherOutput.fullStateForDocument = EqualizerAUState.settingOutputContext(otherContext, in: savedState)
        try configure(otherOutput)
        defer { otherOutput.deallocateRenderResources() }
        let unaffected = try render(otherOutput, left: inputLeft, right: inputRight)
        XCTAssertEqual(unaffected.left, inputLeft)
        XCTAssertEqual(unaffected.right, inputRight)
        XCTAssertEqual(try render(restored, left: inputLeft, right: inputRight, timestamp: 4).left, output.left)
    }

    func testRestoresStandaloneVersionOneTextWithInlineComments() throws {
        let text = "Preamp: -6.020599913 dB # Existing standalone Equalizer preset"
        let restored = try EqualizerAudioUnit(componentDescription: Self.component)
        restored.fullStateForDocument = try roundtrip([
            "Equalizer.version": 1,
            "Equalizer.presetName": "Earlier preset",
            "Equalizer.presetText": text,
            "Equalizer.bypass": true
        ])
        XCTAssertEqual(restored.preset?.name, "Earlier preset")
        let state = try XCTUnwrap(restored.fullStateForDocument)
        XCTAssertEqual(state["Equalizer.presetText"] as? String, text)
        try configure(restored)
        defer { restored.deallocateRenderResources() }
        let samples = [Float](repeating: 1, count: 1_024)
        XCTAssertEqual(try render(restored, left: samples, right: samples).left.last, 1)
        restored.shouldBypassEffect = false
        XCTAssertEqual(try render(restored, left: samples, right: samples, timestamp: 1_024).left.last, 0.5)

        let fresh = try EqualizerAudioUnit(componentDescription: Self.component)
        try fresh.applyPreset(name: "Pasted", text: text)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("Preamp: 0 dB # Unity is a usable preset".utf8).write(to: file)
        try fresh.importPreset(from: file)
        XCTAssertEqual(fresh.preset?.name, file.deletingPathExtension().lastPathComponent)
    }

    func testCustomIIRAndTimedChannelDelayFollowTheHostRate() throws {
        let config = """
        Channel: R
        Filter: ON IIR Order 1 Coefficients 0.25 0 0.5 -0.25
        Delay: 0.03125 ms
        """
        for (rate, delay) in [(48_000.0, 2), (96_000.0, 3)] {
            let unit = try EqualizerAudioUnit(componentDescription: Self.component)
            try unit.applyPreset(name: "Right channel", text: config)
            try configure(unit, sampleRate: rate)
            defer { unit.deallocateRenderResources() }
            let start = try render(unit, left: [0.25, 0], right: [1, 0])
            let remainder = try render(unit, left: [0, 0, 0, 0, 0], right: [0, 0, 0, 0, 0], timestamp: 2)
            XCTAssertEqual(start.left + remainder.left, [0.25, 0, 0, 0, 0, 0, 0])
            let right = start.right + remainder.right
            XCTAssertEqual(Array(right.prefix(delay)), Array(repeating: 0, count: delay))
            XCTAssertEqual(Array(right[delay..<(delay + 4)]), [0.5, 0.25, 0.125, 0.0625])
        }
    }

    func testInvalidReplacementKeepsWorkingPresetAndResponse() throws {
        let unit = try EqualizerAudioUnit(componentDescription: Self.component)
        try unit.applyPreset(name: "Good", text: "Preamp: -6 dB\nFilter 1: ON PK Fc 1000 Hz Gain 6 dB Q 1")
        try configure(unit)
        defer { unit.deallocateRenderResources() }

        XCTAssertThrowsError(try unit.applyPreset(name: "Bad", text: "Convolution: missing.wav"))
        XCTAssertEqual(unit.preset?.name, "Good")
        let response = try unit.responseDB(frequencies: [20, 1_000, 20_000])
        XCTAssertEqual(response[0], -6, accuracy: 0.1)
        XCTAssertEqual(response[1], 0, accuracy: 0.1)
        XCTAssertEqual(response[2], -6, accuracy: 0.1)
    }

    func testFactoryPresetsUseAirwave2CurvesAndRestoreFromDocument() throws {
        let original = try EqualizerAudioUnit(componentDescription: Self.component)
        let presets = try XCTUnwrap(original.factoryPresets)
        XCTAssertEqual(presets.map(\.name), ["Bass Booster", "Bass Reducer", "Treble Booster", "Treble Reducer", "Vocal Booster"])
        XCTAssertEqual(Set(presets.map(\.number)).count, presets.count)
        for preset in presets {
            original.currentPreset = preset
            XCTAssertEqual(original.currentPreset?.number, preset.number)
            XCTAssertEqual(original.preset?.name, preset.name)
        }

        original.currentPreset = try XCTUnwrap(presets.first { $0.name == "Bass Reducer" })
        let state = try roundtrip(XCTUnwrap(original.fullStateForDocument))
        let restored = try EqualizerAudioUnit(componentDescription: Self.component)
        restored.fullStateForDocument = state
        XCTAssertEqual(restored.currentPreset?.name, "Bass Reducer")
        try configure(restored)
        defer { restored.deallocateRenderResources() }
        let response = try restored.responseDB(frequencies: [50, 10_000])
        XCTAssertLessThan(response[0], -5)
        XCTAssertEqual(response[1], 0, accuracy: 0.1)

        // An older project must keep the bytes it saved even when a later build changes a factory curve.
        var previousRevision = state
        previousRevision["Equalizer.presetData"] = Data("Preamp: -6.020599913 dB".utf8)
        let oldInstance = try EqualizerAudioUnit(componentDescription: Self.component)
        oldInstance.fullStateForDocument = previousRevision
        try configure(oldInstance)
        defer { oldInstance.deallocateRenderResources() }
        let output = try render(oldInstance, left: [1, 0], right: [0, 1])
        XCTAssertEqual(output.left, [0.5, 0])
        XCTAssertEqual(output.right, [0, 0.5])
    }

    private func configure(_ unit: AUAudioUnit, sampleRate: Double = 48_000) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = 1_024
        try unit.allocateRenderResources()
    }

    private func roundtrip(_ state: [String: Any]) throws -> [String: Any] {
        let bytes = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
    }

    private func render(_ unit: AUAudioUnit, left: [Float], right: [Float],
                        timestamp: Double = 0) throws -> (left: [Float], right: [Float]) {
        let frames = AVAudioFrameCount(left.count)
        let format = unit.outputBusses[0].format
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        input.frameLength = frames
        output.frameLength = frames
        let inputData = try XCTUnwrap(input.floatChannelData)
        inputData[0].update(from: left, count: left.count)
        inputData[1].update(from: right, count: right.count)

        var flags: AudioUnitRenderActionFlags = []
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        time.mSampleTime = timestamp
        let status = unit.renderBlock(&flags, &time, frames, 0, output.mutableAudioBufferList) { _, _, _, _, list in
            let target = UnsafeMutableAudioBufferListPointer(list)
            let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            for index in target.indices {
                target[index] = source[index]
            }
            return noErr
        }
        XCTAssertEqual(status, noErr)
        let result = try XCTUnwrap(output.floatChannelData)
        return (Array(UnsafeBufferPointer(start: result[0], count: left.count)),
                Array(UnsafeBufferPointer(start: result[1], count: right.count)))
    }

    private func impulseWAV() -> Data {
        let samples: [Int16] = [0, 8_192, 16_384, 0, 0, 0, 0, 0]
        var data = Data("RIFF".utf8)
        func append(_ value: some FixedWidthInteger) {
            Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(2))
        append(UInt32(48_000))
        append(UInt32(192_000))
        append(UInt16(4))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(samples.count * 2))
        samples.forEach { append($0) }
        return data
    }
}
