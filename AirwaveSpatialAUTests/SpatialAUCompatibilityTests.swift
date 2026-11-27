import AudioToolbox
import AVFoundation
import XCTest

final class SpatialAUCompatibilityTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testReleasedWAVStatePreservesSurroundWithoutBlockLatency() throws {
        let cases: [(layout: AudioChannelLayoutTag, firstLeftSample: Float)] = [
            (kAudioChannelLayoutTag_MPEG_5_1_A, 0.3125),
            (kAudioChannelLayoutTag_DiscreteInOrder | 6, 0.40625)
        ]
        for (tag, firstLeftSample) in cases {
            let unit = try makeUnit()
            let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: tag))
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
            let wav = impulseResponse()
            unit.fullStateForDocument = [
                "AirwaveSpatial.presetName": "Legacy imported surround",
                "AirwaveSpatial.impulseResponse": wav,
                "AirwaveSpatial.bypass": false
            ]
            try configure(unit, inputFormat: format)
            defer { unit.deallocateRenderResources() }

            let result = try render(unit, impulses: [0, 0, 0, 0, 0.5, 0.25])
            XCTAssertEqual(unit.latency, 0)
            XCTAssertEqual(result.left[0], firstLeftSample, accuracy: 0.00001)
            XCTAssertEqual(result.right[0], 0.25, accuracy: 0.00001)
            XCTAssertEqual(unit.fullStateForDocument?["AirwaveSpatial.impulseResponse"] as? Data, wav)
            XCTAssertEqual(unit.fullStateForDocument?["AirwaveSpatial.presetName"] as? String, "Legacy imported surround")

            unit.reset()
            unit.shouldBypassEffect = true
            let bypass = try render(unit, impulses: [0, 0, 0, 0, 0.5, 0.25])
            XCTAssertEqual(bypass.left[0], 0.25, accuracy: 0.00001)
            XCTAssertEqual(bypass.right[0], 0.125, accuracy: 0.00001)
        }
    }

    func testBundledRoomAndStageRenderAndRestoreByName() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        var signatures: [[Float]] = []
        for name in ["neutral", "room", "stage"] {
            let first = try makeUnit()
            first.fullStateForDocument = ["AirwaveSpatial.bundledPreset": name]
            let state = try XCTUnwrap(first.fullStateForDocument)
            XCTAssertEqual(state["AirwaveSpatial.bundledPreset"] as? String, name)

            let restored = try makeUnit()
            restored.fullStateForDocument = state
            try configure(restored, inputFormat: format)
            defer { restored.deallocateRenderResources() }

            let response = try render(restored, impulses: [0.5, 0], frames: 2048)
            let stereo = response.left + response.right
            XCTAssertTrue(stereo.allSatisfy(\.isFinite))
            XCTAssertTrue(stereo.contains { abs($0) > 0.00001 })
            for previous in signatures {
                XCTAssertTrue(zip(stereo, previous).contains { abs($0 - $1) > 0.00001 },
                              "\(name) should render its own response")
            }
            signatures.append(stereo)
        }
    }

    private func makeUnit() throws -> AUAudioUnit {
        try AirwaveSpatialAudioUnit(componentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: 0x4177_7370,
            componentManufacturer: 0x4177_7665, componentFlags: 0, componentFlagsMask: 0
        ))
    }

    private func configure(_ unit: AUAudioUnit, inputFormat: AVAudioFormat) throws {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        try unit.inputBusses[0].setFormat(inputFormat)
        try unit.outputBusses[0].setFormat(stereo)
        unit.inputBusses[0].isEnabled = true
        unit.maximumFramesToRender = 2048
        try unit.allocateRenderResources()
    }

    private func render(_ unit: AUAudioUnit, impulses: [Float], frames: Int = 17) throws -> (left: [Float], right: [Float]) {
        let format = unit.outputBusses[0].format
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        var stamp = AudioTimeStamp()
        stamp.mFlags = .sampleTimeValid
        var flags: AudioUnitRenderActionFlags = []
        let renderStatus = unit.renderBlock(&flags, &stamp, AVAudioFrameCount(frames), 0, buffer.mutableAudioBufferList) {
            _, _, frameCount, _, buffers in
            let input = UnsafeMutableAudioBufferListPointer(buffers)
            guard input.count == impulses.count else { return kAudioUnitErr_InvalidPropertyValue }
            for index in input.indices {
                guard let data = input[index].mData?.assumingMemoryBound(to: Float.self) else {
                    return kAudioUnitErr_InvalidPropertyValue
                }
                data.update(repeating: 0, count: Int(frameCount))
                data[0] = impulses[index]
            }
            return noErr
        }
        XCTAssertEqual(renderStatus, noErr)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        return (Array(UnsafeBufferPointer(start: channels[0], count: frames)),
                Array(UnsafeBufferPointer(start: channels[1], count: frames)))
    }

    /// HeSuVi seven-channel impulse. Distinct side and back gains distinguish
    /// labelled 5.1 surround from the legacy count-only fallback.
    private func impulseResponse() -> Data {
        let gains: [Float] = [0.125, 0.0625, 0.5, 0.25, 0.75, 0.125, 0.5]
        let bytesPerFrame = UInt16(gains.count * MemoryLayout<Int16>.stride)
        let dataSize = UInt32(bytesPerFrame) * 2
        var bytes = Data()
        func append<T: FixedWidthInteger>(_ number: T) {
            var littleEndian = number.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
        }
        bytes.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + dataSize)
        bytes.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(gains.count))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * UInt32(bytesPerFrame))
        append(bytesPerFrame)
        append(UInt16(16))
        bytes.append(contentsOf: "data".utf8)
        append(dataSize)
        for gain in gains { append(Int16(gain * 32_768)) }
        for _ in gains { append(Int16(0)) }
        return bytes
    }
}
