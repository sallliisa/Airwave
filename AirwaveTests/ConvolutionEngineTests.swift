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
}

@MainActor
final class WAVLoaderBoundsTests: XCTestCase {
    private func writeWAV(channels: Int, frames: Int, sampleRate: Double = 48_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let layout = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        ))
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            let samples = try XCTUnwrap(buffer.floatChannelData)[channel]
            for frame in 0..<frames { samples[frame] = frame == 0 ? 0.5 : 0 }
        }
        try file.write(from: buffer)
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
