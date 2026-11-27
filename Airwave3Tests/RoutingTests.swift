import AudioToolbox
import CoreAudio
import Synchronization
import XCTest
@testable import Airwave3

final class RoutingTests: XCTestCase {
    func testSurroundMixPreservesOriginalChannelsAndRoutesToSelectedOutputPair() {
        let frames = 3
        let mainSamples = (0..<(6 * frames)).map { Float($0) }
        let appSamples = (0..<(6 * frames)).map { _ in Float(4) }
        var firstOutput = [Float](repeating: 99, count: 2 * frames)
        var secondOutput = firstOutput
        let nativeInputs = AudioBufferList.allocate(maximumBuffers: 2)
        let nativeOutputs = AudioBufferList.allocate(maximumBuffers: 2)
        nativeInputs.count = 2
        nativeOutputs.count = 2
        defer {
            nativeInputs.unsafeMutablePointer.deallocate()
            nativeOutputs.unsafeMutablePointer.deallocate()
        }

        let layout = InputLayout.surround51
        let appGain = AppMixerGain(0.25)
        let mainInput = (0..<6).map { BufferChannel(buffer: 0, offset: $0, stride: 6) }
        let appInput = (0..<6).map { BufferChannel(buffer: 1, offset: $0, stride: 6) }
        let route = StereoIOBridge(
            tapInputs: [], sampleRate: 48_000,
            outputLeft: BufferChannel(buffer: 1, offset: 1, stride: 2),
            outputRight: BufferChannel(buffer: 0, offset: 0, stride: 2),
            verification: false,
            wideInputs: [
                MultichannelTapInput(channels: mainInput, gain: nil),
                MultichannelTapInput(channels: appInput, gain: appGain),
            ],
            inputLayout: layout, clearsUnusedOutputs: true,
            capturedRender: { _, planes, _, _, left, right, frames in
                XCTAssertEqual(planes?.count, 6)
                guard let planes, let backLeft = planes[4], let backRight = planes[5] else { return }
                left.update(from: backLeft, count: Int(frames))
                right.update(from: backRight, count: Int(frames))
            },
            render: { _, _, _, _, _, _ in XCTFail("Expected the multichannel input.") }
        )
        route.enabled.store(true, ordering: .releasing)

        mainSamples.withUnsafeBufferPointer { main in
            appSamples.withUnsafeBufferPointer { app in
                firstOutput.withUnsafeMutableBufferPointer { first in
                    secondOutput.withUnsafeMutableBufferPointer { second in
                        nativeInputs[0] = buffer(main, channelCount: 6)
                        nativeInputs[1] = buffer(app, channelCount: 6)
                        nativeOutputs[0] = buffer(UnsafeBufferPointer(first), channelCount: 2)
                        nativeOutputs[1] = buffer(UnsafeBufferPointer(second), channelCount: 2)
                        var timestamp = AudioTimeStamp()
                        route.process(
                            input: UnsafePointer(nativeInputs.unsafeMutablePointer),
                            output: nativeOutputs.unsafeMutablePointer, timestamp: &timestamp
                        )
                    }
                }
            }
        }

        XCTAssertTrue(route.rendered.load(ordering: .relaxed))
        XCTAssertEqual(firstOutput, [6, 0, 12, 0, 18, 0])
        XCTAssertEqual(secondOutput, [0, 5, 0, 11, 0, 17])
    }

    @MainActor
    func testSavedOutputPairSurvivesResettingTheEffectsAndCanReturnToDefault() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = ProfileStore(url: scratch.appending(path: "profiles.plist"))
        let domain = "Airwave3RoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(false, forKey: "ProcessingEnabled")
        defer { defaults.removePersistentDomain(forName: domain) }
        let output = OutputDevice(
            id: 1, uid: "audio-interface", name: "Audio Interface", sampleRate: 48_000,
            routing: OutputDeviceDescriptor(
                id: .init(1), uid: "audio-interface", name: "Audio Interface", transport: "USB",
                channelLabels: [1, 2, 1, 2], outputChannelCount: 4, nominalSampleRate: 48_000,
                isVirtual: false, isAggregate: false, outputStreamCount: 2,
                outputStreams: [
                    OutputStreamDescriptor(streamIndex: 0, startingChannel: 1, channelCount: 2),
                    OutputStreamDescriptor(streamIndex: 1, startingChannel: 3, channelCount: 2),
                ], preferredStereoChannels: StereoOutputChannels(left: 1, right: 2)
            )
        )
        let host = HostController(store: store, defaults: defaults,
                                  currentOutput: { output }, availableOutputs: { [output] })
        defer { host.shutdown() }

        let pair = StereoOutputChannels(left: 4, right: 2)
        try host.configureOutput(for: output.uid, channels: pair)
        XCTAssertThrowsError(try host.configureOutput(
            for: output.uid, channels: StereoOutputChannels(left: 4, right: 4)
        ))
        host.resetProfile(output.uid)
        XCTAssertEqual(try store.load()[output.uid]?.outputChannels, pair)
        XCTAssertEqual(host.editingDevices.first?.outputChannels, pair)
        try host.configureOutput(for: output.uid, channels: nil)
        XCTAssertNil(try store.load()[output.uid]?.outputChannels)
        XCTAssertNil(host.editingDevices.first?.outputChannels)
    }

    private func buffer(_ samples: UnsafeBufferPointer<Float>, channelCount: UInt32) -> AudioBuffer {
        AudioBuffer(mNumberChannels: channelCount, mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(mutating: samples.baseAddress))
    }
}
