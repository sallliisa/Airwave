import AVFoundation
import Foundation
import XCTest
@testable import Airwave

final class ConvolutionEngineTests: XCTestCase {
    private let blockSize = 8

    private func makeEngine() -> StereoConvolutionEngine {
        let impulse = [Float](arrayLiteral: 1, 0, 0, 0, 0, 0, 0, 0)
        return try! XCTUnwrap(StereoConvolutionEngine(
            leftEarHRIR: impulse,
            rightEarHRIR: impulse,
            blockSize: blockSize
        ))
    }

    /// Drives both ears and returns the left-ear output.
    private func process(_ engine: StereoConvolutionEngine, input: [Float]) -> [Float] {
        var left = [Float](repeating: 0, count: blockSize)
        var right = [Float](repeating: 0, count: blockSize)
        input.withUnsafeBufferPointer { inputPtr in
            left.withUnsafeMutableBufferPointer { leftPtr in
                right.withUnsafeMutableBufferPointer { rightPtr in
                    engine.process(
                        input: inputPtr.baseAddress!,
                        outputLeft: leftPtr.baseAddress!,
                        outputRight: rightPtr.baseAddress!
                    )
                }
            }
        }
        XCTAssertEqual(left, right, "both ears share one impulse response")
        return left
    }

    func testImpulsePreservesSampleOrder() {
        let engine = makeEngine()
        let input: [Float] = [0.25, -0.5, 1, 0.75, -1, 0.125, 0.5, -0.25]

        let output = process(engine, input: input)

        XCTAssertTrue(zip(output, input).allSatisfy { abs($0.0 - $0.1) < 0.0001 })
    }

    func testResetClearsOverlapAndFrequencyHistory() {
        let engine = makeEngine()
        var input = [Float](repeating: 0, count: blockSize)
        input[blockSize - 1] = 1
        _ = process(engine, input: input)

        engine.reset()
        input = [Float](repeating: 0, count: blockSize)
        let output = process(engine, input: input)

        XCTAssertTrue(output.allSatisfy { abs($0) < 0.0001 })
    }

    func testMultipleBlocksRemainFinite() {
        let engine = makeEngine()
        var input = (0..<blockSize).map { Float($0) / 7 }

        for _ in 0..<64 {
            let output = process(engine, input: input)
            XCTAssertTrue(output.allSatisfy { $0.isFinite })
            input = input.map { -$0 * 0.97 + 0.01 }
        }
    }

    func testIdenticalInputAfterResetProducesIdenticalOutput() {
        let engine = makeEngine()
        let input = Array([Float](stride(from: -0.75, through: 0.75, by: 0.2)).prefix(blockSize))

        let first = process(engine, input: input)
        engine.reset()
        let second = process(engine, input: input)

        XCTAssertTrue(zip(first, second).allSatisfy { abs($0.0 - $0.1) < 0.0001 })
    }
}

final class ResamplerTests: XCTestCase {
    func testEqualRateEmptyAndInvalidRates() throws {
        XCTAssertEqual(try Resampler.resampleHighQuality(input: [1, 2], fromRate: 48_000, toRate: 48_000), [1, 2])
        XCTAssertEqual(try Resampler.resampleHighQuality(input: [], fromRate: 48_000, toRate: 44_100), [])
        XCTAssertThrowsError(try Resampler.resampleHighQuality(input: [1], fromRate: .nan, toRate: 48_000))
    }

    func testRateConversionProducesFiniteBoundedOutput() throws {
        let input = (0..<4_800).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        let output = try Resampler.resampleHighQuality(input: input, fromRate: 48_000, toRate: 44_100)
        XCTAssertTrue((4_300...4_500).contains(output.count))
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    func testImpulsePreservesGainAndDelayAtSupportedRates() throws {
        for (fromRate, toRate) in [(44_100.0, 48_000.0), (48_000.0, 44_100.0), (88_200.0, 96_000.0), (96_000.0, 88_200.0)] {
            var input = [Float](repeating: 0, count: 4_096)
            input[1_024] = 1

            let output = try Resampler.resampleHighQuality(input: input, fromRate: fromRate, toRate: toRate)
            let expectedCount = Int(ceil(Double(input.count) * toRate / fromRate))
            let expectedPeak = Int((1_024 * toRate / fromRate).rounded())
            let peak = try XCTUnwrap(output.indices.max { abs(output[$0]) < abs(output[$1]) })

            XCTAssertEqual(output.count, expectedCount, accuracy: 1)
            XCTAssertEqual(peak, expectedPeak, accuracy: 1)
            XCTAssertEqual(output.reduce(0, +), 1, accuracy: 0.01)
        }
    }

    func testDownsamplingRejectsOutOfBandTone() throws {
        func convertedRMS(frequency: Double) throws -> Double {
            let input = (0..<24_000).map { Float(sin(2 * .pi * frequency * Double($0) / 96_000)) }
            let output = try Resampler.resampleHighQuality(input: input, fromRate: 96_000, toRate: 48_000)
            let settled = output.dropFirst(512).dropLast(512)
            return sqrt(settled.reduce(0) { $0 + Double($1 * $1) } / Double(settled.count))
        }

        let attenuation = 20 * log10(try convertedRMS(frequency: 30_000) / convertedRMS(frequency: 1_000))
        XCTAssertLessThan(attenuation, -40)
    }

    func testInterEarDelayIsPreserved() throws {
        var left = [Float](repeating: 0, count: 4_096)
        var right = left
        left[1_000] = 1
        right[1_037] = 1

        for (fromRate, toRate) in [(44_100.0, 96_000.0), (96_000.0, 44_100.0)] {
            let convertedLeft = try Resampler.resampleHighQuality(input: left, fromRate: fromRate, toRate: toRate)
            let convertedRight = try Resampler.resampleHighQuality(input: right, fromRate: fromRate, toRate: toRate)
            let leftPeak = try XCTUnwrap(convertedLeft.indices.max { abs(convertedLeft[$0]) < abs(convertedLeft[$1]) })
            let rightPeak = try XCTUnwrap(convertedRight.indices.max { abs(convertedRight[$0]) < abs(convertedRight[$1]) })
            let expectedDelay = Int((37 * toRate / fromRate).rounded())
            XCTAssertEqual(rightPeak - leftPeak, expectedDelay, accuracy: 1)
        }
    }

    func testSingleSampleAndBounds() throws {
        let output = try Resampler.resampleHighQuality(input: [1], fromRate: 44_100, toRate: 48_000)
        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertThrowsError(try Resampler.resampleHighQuality(
            input: [Float](repeating: 0, count: Resampler.maximumOutputFrames),
            fromRate: 44_100,
            toRate: 96_000
        ))
        for rate in [0.0, -1, .infinity] {
            XCTAssertThrowsError(try Resampler.resampleHighQuality(input: [1], fromRate: rate, toRate: 48_000))
            XCTAssertThrowsError(try Resampler.resampleHighQuality(input: [1], fromRate: 48_000, toRate: rate))
        }
    }

    func testExact96000FrameOutputIsAccepted() throws {
        // 24,000 frames at 48 kHz need 96,000 frames at 192 kHz.
        // The limit applies to returned frames, not converter scratch.
        let input = [Float](repeating: 0.1, count: 24_000)
        let output = try Resampler.resampleHighQuality(input: input, fromRate: 48_000, toRate: 192_000)
        XCTAssertLessThanOrEqual(output.count, Resampler.maximumOutputFrames)
        XCTAssertEqual(output.count, 96_000, accuracy: 2)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    func testAbove96000FrameOutputIsRejected() {
        // 24,001 frames at 48 kHz need 96,004 frames at 192 kHz.
        let input = [Float](repeating: 0.1, count: 24_001)
        XCTAssertThrowsError(try Resampler.resampleHighQuality(
            input: input,
            fromRate: 48_000,
            toRate: 192_000
        )) { error in
            guard case ResamplerError.outputTooLarge = error else {
                return XCTFail("expected outputTooLarge, got \(error)")
            }
        }
    }

    func testEqualRateRespectsOutputLimit() throws {
        let exact = [Float](repeating: 0.25, count: Resampler.maximumOutputFrames)
        XCTAssertEqual(
            try Resampler.resampleHighQuality(input: exact, fromRate: 48_000, toRate: 48_000),
            exact
        )
        let over = [Float](repeating: 0.25, count: Resampler.maximumOutputFrames + 1)
        XCTAssertThrowsError(try Resampler.resampleHighQuality(
            input: over,
            fromRate: 48_000,
            toRate: 48_000
        )) { error in
            guard case ResamplerError.outputTooLarge = error else {
                return XCTFail("expected outputTooLarge, got \(error)")
            }
        }
    }
}

@MainActor
final class HRIRResamplingActivationTests: XCTestCase {
    private func makeManager() -> (HRIRManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = HRIRManager(
            presetsDirectory: root.appendingPathComponent("hrir"),
            startWatcher: false,
            bundledPresetCatalog: BundledPresetCatalog(hrirFiles: [])
        )
        return (manager, root)
    }

    private func bundledURL(named name: String) -> URL {
        // Tests run in the host app process, so the HRIR assets live in
        // the main bundle. Copy to temp so AVAudioFile opens a
        // sandbox-readable regular file path.
        guard let url = Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: "assets/hrtf")?.first(where: { $0.lastPathComponent == name }) else {
            fatalError("missing bundled resource \(name)")
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try! FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    private func activate(
        manager: HRIRManager,
        preset: HRIRPreset,
        rate: Double,
        layout: InputLayout = .stereo
    ) async -> HRIRActivationResult {
        await withCheckedContinuation { continuation in
            manager.activatePreset(preset, targetSampleRate: rate, inputLayout: layout) { result in
                continuation.resume(returning: result)
            }
        }
    }

    func testBundledPresetActivatesAt48kHz() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.waitForLibrarySync()
        let url = bundledURL(named: "NeutralSH1.0.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let preset = HRIRPreset(
            id: UUID(), name: "NeutralSH1.0",
            fileURL: url, channelCount: 14, sampleRate: 48_000
        )

        let result = await activate(manager: manager, preset: preset, rate: 48_000)

        XCTAssertEqual(result, .success)
        XCTAssertTrue(manager.isConvolutionActive)
        XCTAssertNil(manager.errorMessage)
    }

    func testBundledPresetActivatesAt44_1kHz() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.waitForLibrarySync()
        let url = bundledURL(named: "NeutralSH1.0.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let preset = HRIRPreset(
            id: UUID(), name: "NeutralSH1.0",
            fileURL: url, channelCount: 14, sampleRate: 48_000
        )

        let result = await activate(manager: manager, preset: preset, rate: 44_100)

        XCTAssertEqual(result, .success)
        XCTAssertTrue(manager.isConvolutionActive)
        XCTAssertNil(manager.errorMessage)
    }

    func testFailedConversionKeepsPriorRenderer() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.waitForLibrarySync()
        let url = bundledURL(named: "NeutralSH1.0.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let working = HRIRPreset(
            id: UUID(), name: "NeutralSH1.0",
            fileURL: url, channelCount: 14, sampleRate: 48_000
        )

        let first = await activate(manager: manager, preset: working, rate: 48_000)
        XCTAssertEqual(first, .success)
        XCTAssertTrue(manager.isConvolutionActive)
        let activeID = try XCTUnwrap(manager.activePreset?.id)

        // 4,320 frames at 48 kHz need 180,000 frames at 2 MHz.
        // The resampler must reject the request and the manager
        // must keep the working renderer.
        let failed = await activate(manager: manager, preset: working, rate: 2_000_000)

        guard case .failure = failed else {
            return XCTFail("expected failure, got \(failed)")
        }
        XCTAssertEqual(manager.activePreset?.id, activeID)
        XCTAssertTrue(manager.isConvolutionActive)
        XCTAssertNotNil(manager.errorMessage)
    }
}

@MainActor
final class WAVLoaderBoundsTests: XCTestCase {
    func testHeaderMatchesFullDecodeFor16BitStereoWithOddFrameCount() throws {
        // 16-bit PCM file with an odd frame count (1001): data bytes = 4004.
        // A width-blind reader that assumes 32-bit samples divides by
        // channelCount * 4 = 8 and rejects the file (remainder 4) or reports
        // 500 frames. The header reader must use the format block alignment
        // (4 bytes/frame) and report 1001, matching full decode. Written by
        // hand so the test does not depend on AVAudioFile integer layouts.
        let url = try writeRawPCM16Stereo(frames: 1_001)
        defer { try? FileManager.default.removeItem(at: url) }

        let header = try WAVLoader.headerInfo(from: url)
        XCTAssertEqual(header.channelCount, 2)
        XCTAssertEqual(header.frameCount, 1_001)

        let full = try WAVLoader.load(from: url)
        XCTAssertEqual(full.frameCount, header.frameCount)
        XCTAssertEqual(full.channelCount, header.channelCount)
    }

    func testHeaderMatchesFullDecodeFor24BitStereo() throws {
        // 24-bit PCM file: block alignment is 6 bytes/frame. A reader that
        // assumes 32-bit samples divides by 8 and mis-reports 750 frames for
        // 1000 real frames (6000 bytes). Written by hand; AVAudioFile has no
        // 24-bit common format, and its integer layouts hang the test host.
        let url = try writeRawPCM24Stereo(frames: 1_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let header = try WAVLoader.headerInfo(from: url)
        let full = try WAVLoader.load(from: url)
        XCTAssertEqual(header.frameCount, 1_000)
        XCTAssertEqual(full.frameCount, header.frameCount)
        XCTAssertEqual(full.channelCount, header.channelCount)
    }

    func testHeaderFindsDataAfterLargeMetadataChunk() throws {
        let url = try writeWAV(channels: 2, frames: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        try insertChunk(id: "bext", size: 8 * 1_024, into: url)

        let header = try WAVLoader.headerInfo(from: url)
        XCTAssertEqual(header.channelCount, 2)
        XCTAssertEqual(header.frameCount, 64)

        let full = try WAVLoader.load(from: url)
        XCTAssertEqual(full.frameCount, header.frameCount)
    }

    func testHeaderRejectsMissingDataChunk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = Data("RIFF".utf8)
        var size = UInt32(36).littleEndian
        bytes.append(Data(bytes: &size, count: 4))
        bytes.append(Data("WAVE".utf8))
        bytes.append(Data("fmt ".utf8))
        var fmtSize = UInt32(16).littleEndian
        bytes.append(Data(bytes: &fmtSize, count: 4))
        var fmt = Data(count: 16)
        fmt[0] = 3; fmt[2] = 2; fmt[4] = 0x80; fmt[5] = 0xBB; fmt[6] = 0; fmt[7] = 0
        fmt[12] = 8; fmt[14] = 32
        bytes.append(fmt)
        try bytes.write(to: url)

        XCTAssertThrowsError(try WAVLoader.headerInfo(from: url)) { error in
            guard case WAVError.fileReadError = error else {
                return XCTFail("expected fileReadError for missing data chunk, got \(error)")
            }
        }
    }

    func testFullDecodeRejectsNonFiniteWAVFixture() throws {
        // int16/int32 paths convert to finite Float and pass; only a float
        // file can carry a NaN through AVAudioFile for the finite check.
        let url = try writeWAV(channels: 2, frames: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        try overwriteFloatSample(url: url, channel: 0, frame: 3, value: .nan)

        XCTAssertThrowsError(try WAVLoader.load(from: url)) { error in
            guard case WAVError.nonFiniteSample = error else {
                return XCTFail("expected nonFiniteSample, got \(error)")
            }
        }
    }

    func testSparseOversizedFileFailsWithoutAllocation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // Sparse 64 MiB + 1 byte file: header claims 2 Float32 channels at
        // 48 kHz; only the header is written, so the test allocates nothing
        // near the advertised frame count.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var riff = Data("RIFF".utf8)
        var riffSize = UInt32(WAVLoader.maximumFileSize + 1 - 8).littleEndian
        riff.append(Data(bytes: &riffSize, count: 4))
        riff.append(Data("WAVE".utf8))
        riff.append(Data("fmt ".utf8))
        var fmtSize = UInt32(16).littleEndian
        riff.append(Data(bytes: &fmtSize, count: 4))
        var fmt = Data(count: 16)
        fmt[0] = 3; fmt[2] = 2
        fmt[4] = 0x80; fmt[5] = 0xBB; fmt[6] = 0; fmt[7] = 0
        fmt[12] = 8; fmt[14] = 32
        riff.append(fmt)
        riff.append(Data("data".utf8))
        var dataSize = UInt32(WAVLoader.maximumFileSize + 1 - 44).littleEndian
        riff.append(Data(bytes: &dataSize, count: 4))
        try handle.write(contentsOf: riff)
        try handle.truncate(atOffset: UInt64(WAVLoader.maximumFileSize + 1))
        try handle.close()

        XCTAssertThrowsError(try WAVLoader.load(from: url)) { error in
            guard case WAVError.fileTooLarge = error else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
        }
    }

    private func writeWAV(
        channels: Int,
        frames: Int,
        sampleRate: Double = 48_000,
        format commonFormat: AVAudioCommonFormat = .pcmFormatFloat32
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let layout = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        ))
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if let floatData = buffer.floatChannelData {
            for channel in 0..<channels {
                let samples = floatData[channel]
                for frame in 0..<frames { samples[frame] = frame == 0 ? 0.5 : 0 }
            }
        } else if let int16Data = buffer.int16ChannelData {
            for channel in 0..<channels {
                let samples = int16Data[channel]
                for frame in 0..<frames { samples[frame] = frame == 0 ? 16_000 : 0 }
            }
        } else if let int32Data = buffer.int32ChannelData {
            for channel in 0..<channels {
                let samples = int32Data[channel]
                for frame in 0..<frames { samples[frame] = frame == 0 ? 1_000_000_000 : 0 }
            }
        } else {
            throw XCTSkip("unsupported test buffer layout")
        }
        try file.write(from: buffer)
        return url
    }

    /// Inserts a metadata chunk after the fmt chunk, so the data chunk moves
    /// past small-prefix readers. The file stays valid for full decoding.
    private func insertChunk(id: String, size: Int, into url: URL) throws {
        var bytes = try Data(contentsOf: url)
        let raw = [UInt8](bytes.prefix(64))
        var cursor = 12
        var fmtEnd: Int?
        while cursor + 8 <= raw.count {
            let chunkID = String(bytes: raw[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            let chunkSize = Int(raw[cursor + 4]) | (Int(raw[cursor + 5]) << 8)
                | (Int(raw[cursor + 6]) << 16) | (Int(raw[cursor + 7]) << 24)
            let advance = 8 + chunkSize + (chunkSize % 2)
            if chunkID == "fmt " { fmtEnd = cursor + advance; break }
            guard advance > 0 else { break }
            cursor += advance
        }
        let insertAt = try XCTUnwrap(fmtEnd)
        var chunk = Data(id.utf8)
        var chunkSize = UInt32(size).littleEndian
        chunk.append(Data(bytes: &chunkSize, count: 4))
        chunk.append(Data(repeating: 0, count: size))
        bytes.insert(contentsOf: chunk, at: insertAt)
        // Fix the RIFF size field.
        var riffSize = UInt32(bytes.count - 8).littleEndian
        bytes.replaceSubrange(4..<8, with: Data(bytes: &riffSize, count: 4))
        try bytes.write(to: url)
    }

    /// Writes one Float32 sample in place through AVAudioFile's layout.
    /// The first frame of channel 0 sits at the data-chunk start for the
    /// non-interleaved Float32 files this helper writes.
    private func overwriteFloatSample(url: URL, channel: Int, frame: Int, value: Float) throws {
        let bytes = try Data(contentsOf: url)
        let raw = [UInt8](bytes)
        var cursor = 12
        var dataStart: Int?
        while cursor + 8 <= raw.count {
            let chunkID = String(bytes: raw[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            let chunkSize = Int(raw[cursor + 4]) | (Int(raw[cursor + 5]) << 8)
                | (Int(raw[cursor + 6]) << 16) | (Int(raw[cursor + 7]) << 24)
            if chunkID == "data" { dataStart = cursor + 8; break }
            let advance = 8 + chunkSize + (chunkSize % 2)
            guard advance > 0 else { break }
            cursor += advance
        }
        let start = try XCTUnwrap(dataStart)
        let header = try WAVLoader.headerInfo(from: url)
        // AVAudioFile writes non-interleaved Float32 files channel by channel.
        let offset = start + channel * header.frameCount * 4 + frame * 4
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var bits = value.bitPattern.littleEndian
        try handle.write(contentsOf: Data(bytes: &bits, count: 4))
    }

    /// Writes a hand-built 16-bit PCM stereo WAV (interleaved, block
    /// alignment 4). Avoids AVAudioFile integer layouts, which hang the
    /// test host (non-interleaved flag ignored, then watchdog kills it).
    private func writeRawPCM16Stereo(frames: Int, sampleRate: UInt32 = 48_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        var bytes = Data("RIFF".utf8)
        let dataBytes = frames * 2 * 2
        var riffSize = UInt32(36 + dataBytes).littleEndian
        bytes.append(Data(bytes: &riffSize, count: 4))
        bytes.append(Data("WAVE".utf8))
        bytes.append(Data("fmt ".utf8))
        var fmtSize = UInt32(16).littleEndian
        bytes.append(Data(bytes: &fmtSize, count: 4))
        var fmt = Data(count: 16)
        fmt[0] = 1 // PCM
        fmt[2] = 2 // channels
        fmt[4] = UInt8(sampleRate & 0xFF); fmt[5] = UInt8((sampleRate >> 8) & 0xFF)
        fmt[6] = UInt8((sampleRate >> 16) & 0xFF); fmt[7] = UInt8((sampleRate >> 24) & 0xFF)
        let byteRate = sampleRate * 4
        fmt[8] = UInt8(byteRate & 0xFF); fmt[9] = UInt8((byteRate >> 8) & 0xFF)
        fmt[10] = UInt8((byteRate >> 16) & 0xFF); fmt[11] = UInt8((byteRate >> 24) & 0xFF)
        fmt[12] = 4; fmt[13] = 0 // block alignment
        fmt[14] = 16; fmt[15] = 0 // bits per sample
        bytes.append(fmt)
        bytes.append(Data("data".utf8))
        var dataSize = UInt32(dataBytes).littleEndian
        bytes.append(Data(bytes: &dataSize, count: 4))
        var samples = Data(count: dataBytes)
        samples.withUnsafeMutableBytes { pointer in
            let words = pointer.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                words[frame * 2] = frame == 0 ? 16_000 : 0
                words[frame * 2 + 1] = 0
            }
        }
        bytes.append(samples)
        try bytes.write(to: url)
        return url
    }

    /// Writes a hand-built 24-bit PCM stereo WAV (interleaved, block
    /// alignment 6).
    private func writeRawPCM24Stereo(frames: Int, sampleRate: UInt32 = 48_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        var bytes = Data("RIFF".utf8)
        let dataBytes = frames * 2 * 3
        var riffSize = UInt32(36 + dataBytes).littleEndian
        bytes.append(Data(bytes: &riffSize, count: 4))
        bytes.append(Data("WAVE".utf8))
        bytes.append(Data("fmt ".utf8))
        var fmtSize = UInt32(16).littleEndian
        bytes.append(Data(bytes: &fmtSize, count: 4))
        var fmt = Data(count: 16)
        fmt[0] = 1 // PCM
        fmt[2] = 2 // channels
        fmt[4] = UInt8(sampleRate & 0xFF); fmt[5] = UInt8((sampleRate >> 8) & 0xFF)
        fmt[6] = UInt8((sampleRate >> 16) & 0xFF); fmt[7] = UInt8((sampleRate >> 24) & 0xFF)
        let byteRate = sampleRate * 6
        fmt[8] = UInt8(byteRate & 0xFF); fmt[9] = UInt8((byteRate >> 8) & 0xFF)
        fmt[10] = UInt8((byteRate >> 16) & 0xFF); fmt[11] = UInt8((byteRate >> 24) & 0xFF)
        fmt[12] = 6; fmt[13] = 0 // block alignment
        fmt[14] = 24; fmt[15] = 0 // bits per sample
        bytes.append(fmt)
        bytes.append(Data("data".utf8))
        var dataSize = UInt32(dataBytes).littleEndian
        bytes.append(Data(bytes: &dataSize, count: 4))
        var samples = Data(count: dataBytes)
        samples.withUnsafeMutableBytes { pointer in
            let raw = pointer.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                // First left sample = 0x400000 (positive quarter scale).
                let value: UInt32 = frame == 0 ? 0x400000 : 0
                raw[frame * 6] = UInt8(value & 0xFF)
                raw[frame * 6 + 1] = UInt8((value >> 8) & 0xFF)
                raw[frame * 6 + 2] = UInt8((value >> 16) & 0xFF)
            }
        }
        bytes.append(samples)
        try bytes.write(to: url)
        return url
    }

    func testHeaderReadReportsChannelsRateAndLengthWithoutFullDecode() throws {
        let url = try writeWAV(channels: 14, frames: 4_320)
        defer { try? FileManager.default.removeItem(at: url) }

        let header = try WAVLoader.headerInfo(from: url)
        XCTAssertEqual(header.channelCount, 14)
        XCTAssertEqual(header.sampleRate, 48_000)
        XCTAssertEqual(header.frameCount, 4_320)

        let full = try WAVLoader.load(from: url)
        XCTAssertEqual(full.channelCount, header.channelCount)
        XCTAssertEqual(full.frameCount, header.frameCount)
    }

    func testHeaderReadRejectsLongRenderAboveHalfSecond() throws {
        let url = try writeWAV(channels: 2, frames: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try WAVLoader.headerInfo(from: url)) { error in
            guard case WAVError.tooManyFrames(48_000) = error else {
                return XCTFail("expected tooManyFrames, got \(error)")
            }
        }
        XCTAssertThrowsError(try WAVLoader.load(from: url))
    }

    func testHeaderReadRejectsExcessChannelsBeforeAllocation() throws {
        let url = try writeWAV(channels: 14, frames: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        // AVAudioFile writes its own header layout, so corrupt the channel
        // count field in place and check the bounded reader rejects it. The
        // field sits at byte 22 in the files this helper writes; find it by
        // scanning the bounded prefix for the fmt chunk instead of trusting
        // a fixed offset for foreign files.
        let prefix = try Data(contentsOf: url).prefix(4 * 1_024)
        let bytes = [UInt8](prefix)
        var cursor = 12
        var fmtOffset: Int?
        while cursor + 8 <= bytes.count {
            let id = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            let size = Int(bytes[cursor + 4]) | (Int(bytes[cursor + 5]) << 8)
                | (Int(bytes[cursor + 6]) << 16) | (Int(bytes[cursor + 7]) << 24)
            if id == "fmt " { fmtOffset = cursor; break }
            if id == "data" { break }
            let advance = 8 + size + (size % 2)
            guard advance > 0, cursor + advance <= bytes.count else { break }
            cursor += advance
        }
        let fmt = try XCTUnwrap(fmtOffset)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(fmt + 10))
        var channels: UInt16 = 40
        try handle.write(contentsOf: Data(bytes: &channels, count: 2))

        XCTAssertThrowsError(try WAVLoader.headerInfo(from: url)) { error in
            guard case WAVError.invalidChannelCount(40) = error else {
                return XCTFail("expected invalidChannelCount, got \(error)")
            }
        }
    }

    func testHeaderReadCapKeepsBundledPresetsValid() throws {
        // The bundled presets ship in assets/hrtf. Derive the source-tree root
        // from this file's path so the check works under xcodebuild.
        let thisFile = URL(fileURLWithPath: #filePath).standardizedFileURL
        let root = thisFile
            .deletingLastPathComponent() // ConvolutionEngineTests.swift
            .deletingLastPathComponent() // AirwaveTests
        for name in ["NeutralSH1.0", "RoomSH1.0", "StageSH1.0"] {
            let url = root.appendingPathComponent("assets/hrtf/\(name).wav")
            let header = try WAVLoader.headerInfo(from: url)
            XCTAssertEqual(header.channelCount, 14)
            XCTAssertEqual(header.sampleRate, 48_000)
            XCTAssertLessThanOrEqual(Double(header.frameCount), header.sampleRate * WAVLoader.maximumDuration)
        }
    }
}

@MainActor
final class HRIRLibraryImportTests: XCTestCase {
    private func makeManager() -> (HRIRManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = HRIRManager(
            presetsDirectory: root.appendingPathComponent("hrir"),
            startWatcher: false,
            bundledPresetCatalog: BundledPresetCatalog(hrirFiles: [])
        )
        return (manager, root)
    }

    private func writeWAV(to url: URL, channels: Int = 2, frames: Int = 8, gain: Float = 0.5) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let layout = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        ))
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            let samples = try XCTUnwrap(buffer.floatChannelData)[channel]
            for frame in 0..<frames { samples[frame] = frame == 0 ? gain : 0 }
        }
        try file.write(from: buffer)
    }

    func testAsyncImportPublishesValidPresetAndKeepsArraysOnMain() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.waitForLibrarySync()
        let source = root.appendingPathComponent("sources/Valid.wav")
        try writeWAV(to: source)

        let output = await manager.importPresetsAsync([source], collisionPolicy: .reject)
        XCTAssertEqual(output.failures, [])
        XCTAssertEqual(output.imported.count, 1)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(manager.presets.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.presets[0].fileURL.path))
    }

    func testStaleImportRequestDoesNotPublishOverNewerRequest() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.waitForLibrarySync()
        let first = root.appendingPathComponent("sources/First.wav")
        let second = root.appendingPathComponent("sources/Second.wav")
        try writeWAV(to: first, gain: 0.25)
        try writeWAV(to: second, gain: 0.75)

        // A superseded coordinator generation publishes nothing: take the
        // older ticket first, then the newer ticket, and run the older
        // request after the newer completes. The stale request must skip
        // validation and commit nothing.
        let oldTicket = await manager.takeImportTicketForTesting()
        let newTicket = await manager.takeImportTicketForTesting()
        let newResult = await manager.importPresetsStagedForTesting(
            [second],
            collisionPolicy: .replace,
            ticketTaker: { newTicket }
        )
        XCTAssertEqual(newResult.imported.count, 1)
        let oldResult = await manager.importPresetsStagedForTesting(
            [first],
            collisionPolicy: .replace,
            ticketTaker: { oldTicket }
        )

        XCTAssertTrue(oldResult.imported.isEmpty)
        XCTAssertEqual(manager.presets.count, 1)
        XCTAssertEqual(manager.presets.first?.fileURL.lastPathComponent, "Second.wav")
    }

    func testOverlappingCoordinatorRequestsKeepNewestPreflight() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.waitForLibrarySync()
        let first = root.appendingPathComponent("sources/First.wav")
        let second = root.appendingPathComponent("sources/Second.wav")
        try writeWAV(to: first, gain: 0.25)
        try writeWAV(to: second, gain: 0.75)

        // Each receive runs its own preflight+import; the second request must
        // still commit after the first completes.
        let firstOutput = await manager.importPresetsAsync([first], collisionPolicy: .replace)
        XCTAssertEqual(firstOutput.imported.count, 1)
        let secondOutput = await manager.importPresetsAsync([second], collisionPolicy: .replace)
        XCTAssertEqual(secondOutput.imported.count, 1)

        XCTAssertEqual(manager.presets.count, 2)
        XCTAssertEqual(
            Set(manager.presets.map { $0.fileURL.lastPathComponent }),
            ["First.wav", "Second.wav"]
        )
    }

    func testFailedReplacementKeepsPriorManagedFile() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.waitForLibrarySync()
        let source = root.appendingPathComponent("sources/Curve.wav")
        try writeWAV(to: source, gain: 0.5)
        let first = await manager.importPresetsAsync([source], collisionPolicy: .reject)
        let preset = try XCTUnwrap(first.imported.first)
        let originalBytes = try Data(contentsOf: preset.fileURL)

        try FileManager.default.removeItem(at: source)
        try Data("not a WAV\n".utf8).write(to: source)
        let failed = await manager.importPresetsAsync([source], collisionPolicy: .replace)
        XCTAssertTrue(failed.imported.isEmpty)
        XCTAssertEqual(failed.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: preset.fileURL), originalBytes)
        XCTAssertEqual(manager.presets.count, 1)
    }

    func testStaleSameFileReplacementKeepsWorkingPresetAndSelection() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.waitForLibrarySync()
        let source = root.appendingPathComponent("sources/Curve.wav")
        try writeWAV(to: source, gain: 0.25)
        let first = await manager.importPresetsAsync([source], collisionPolicy: .reject)
        let preset = try XCTUnwrap(first.imported.first)
        let presetID = preset.id
        // Select the working preset through the production activation path.
        // The 2-channel file maps through the default 14-channel table with
        // no matching renderers, so activation fails; retry with the bundled
        // 14-channel fixture for a working active preset.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            manager.activatePreset(preset, targetSampleRate: 48_000, inputLayout: .stereo) { _ in
                continuation.resume()
            }
        }
        let activeBeforeStale: HRIRPreset?
        if manager.activePreset?.id == presetID {
            activeBeforeStale = manager.activePreset
        } else {
            let bundled = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-NeutralSH1.0.wav")
            let source14 = Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: "assets/hrtf")!
                .first { $0.lastPathComponent == "NeutralSH1.0.wav" }!
            try FileManager.default.copyItem(at: source14, to: bundled)
            defer { try? FileManager.default.removeItem(at: bundled) }
            let wide = await manager.importPresetsAsync([bundled], collisionPolicy: .reject)
            let widePreset = try XCTUnwrap(wide.imported.first)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                manager.activatePreset(widePreset, targetSampleRate: 48_000, inputLayout: .stereo) { _ in
                    continuation.resume()
                }
            }
            // The stale same-file request below targets Curve.wav; the
            // selected wide preset must survive it untouched.
            activeBeforeStale = manager.activePreset
            XCTAssertEqual(activeBeforeStale?.id, widePreset.id)
        }
        XCTAssertNotNil(activeBeforeStale)
        let activeID = try XCTUnwrap(activeBeforeStale?.id)
        XCTAssertTrue(manager.isConvolutionActive)
        let originalBytes = try Data(contentsOf: preset.fileURL)

        // A stale replacement of the same filename validates after a newer
        // generation exists. The pre-commit check must discard it before it
        // replaces the managed file or republishes the preset.
        try writeWAV(to: source, gain: 0.75)
        let staleTicket = await manager.takeImportTicketForTesting()
        _ = await manager.takeImportTicketForTesting()
        let stale = await manager.importPresetsStagedForTesting(
            [source],
            collisionPolicy: .replace,
            generation: staleTicket,
            workerGate: nil
        )

        XCTAssertTrue(stale.imported.isEmpty)
        XCTAssertNotNil(manager.presets.first { $0.id == presetID })
        XCTAssertEqual(try Data(contentsOf: preset.fileURL), originalBytes)
        XCTAssertEqual(manager.activePreset?.id, activeID)
        XCTAssertTrue(manager.isConvolutionActive)
    }

    func testCancelledWorkerImportCommitsNothing() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.waitForLibrarySync()
        let source = root.appendingPathComponent("sources/Curve.wav")
        try writeWAV(to: source, gain: 0.5)
        let gate = LockedFlag(true)
        let ticket = await manager.takeImportTicketForTesting()
        let importTask = Task {
            await manager.importPresetsStagedForTesting(
                [source],
                collisionPolicy: .replace,
                generation: ticket,
                workerGate: { gate.value },
                onWorkerEntry: {}
            )
        }
        // Wait until the worker blocks inside validation, then supersede the
        // generation and cancel the request. The stale commit must not run.
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = await manager.takeImportTicketForTesting()
        importTask.cancel()
        gate.value = false
        let result = await importTask.value

        XCTAssertTrue(result.imported.isEmpty)
        XCTAssertTrue(manager.presets.isEmpty)
        let managed = try FileManager.default.contentsOfDirectory(
            atPath: manager.presetsDirectoryForTesting.path
        ).filter { $0.hasSuffix(".wav") && !$0.hasPrefix(".") }
        XCTAssertTrue(managed.isEmpty)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool

    init(_ value: Bool) { flag = value }

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

final class ConvolutionCharacterizationTests: XCTestCase {
    private let blockSize = 512
    private let blocks = 8

    func testPartitionedConvolutionMatchesDirectConvolutionForBothEars() {
        let leftIR = Self.impulseResponse(taps: 1_200, seed: 7)
        let rightIR = Self.impulseResponse(taps: 1_200, seed: 11)
        let input = Self.noise(count: blockSize * blocks, seed: 3)

        let (left, right) = Self.render(input: input, leftIR: leftIR, rightIR: rightIR, blockSize: blockSize)
        let expectedLeft = Self.directConvolution(input: input, impulseResponse: leftIR)
        let expectedRight = Self.directConvolution(input: input, impulseResponse: rightIR)

        XCTAssertEqual(left.count, input.count)
        XCTAssertLessThan(Self.maximumError(left, expectedLeft), 1e-4)
        XCTAssertLessThan(Self.maximumError(right, expectedRight), 1e-4)
    }

    // MARK: - Helpers

    /// Runs the production engine block by block. Updated alongside the engine API.
    private static func render(
        input: [Float],
        leftIR: [Float],
        rightIR: [Float],
        blockSize: Int
    ) -> ([Float], [Float]) {
        let engine = StereoConvolutionEngine(
            leftEarHRIR: leftIR,
            rightEarHRIR: rightIR,
            blockSize: blockSize
        )!
        var left = [Float](repeating: 0, count: input.count)
        var right = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { inputPtr in
            left.withUnsafeMutableBufferPointer { leftPtr in
                right.withUnsafeMutableBufferPointer { rightPtr in
                    for block in stride(from: 0, to: input.count, by: blockSize) {
                        engine.process(
                            input: inputPtr.baseAddress!.advanced(by: block),
                            outputLeft: leftPtr.baseAddress!.advanced(by: block),
                            outputRight: rightPtr.baseAddress!.advanced(by: block)
                        )
                    }
                }
            }
        }
        return (left, right)
    }

    private static func directConvolution(input: [Float], impulseResponse: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        for n in 0..<input.count {
            var sum: Float = 0
            for k in 0..<min(impulseResponse.count, n + 1) {
                sum += impulseResponse[k] * input[n - k]
            }
            output[n] = sum
        }
        return output
    }

    private static func maximumError(_ actual: [Float], _ expected: [Float]) -> Float {
        zip(actual, expected).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    private static func impulseResponse(taps: Int, seed: UInt64) -> [Float] {
        var generator = LinearCongruential(seed: seed)
        return (0..<taps).map { index in
            let decay = 1 - Float(index) / Float(taps)
            return 0.02 * decay * generator.nextUnit()
        }
    }

    private static func noise(count: Int, seed: UInt64) -> [Float] {
        var generator = LinearCongruential(seed: seed)
        return (0..<count).map { _ in generator.nextUnit() }
    }

    private struct LinearCongruential {
        private var state: UInt64

        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

        mutating func nextUnit() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
        }
    }
}
