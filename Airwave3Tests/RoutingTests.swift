import AudioToolbox
import AVFoundation
import CoreAudio
import Synchronization
import XCTest
@testable import Airwave3

final class RoutingTests: XCTestCase {
    @MainActor
    func testSurroundFollowsTheFirstRunnableEffect() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = ProfileStore(url: scratch.appending(path: "profiles.plist"))
        let domain = "Airwave3RoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(false, forKey: "ProcessingEnabled")
        defer { defaults.removePersistentDomain(forName: domain) }
        let output = OutputDevice(
            id: 1, uid: "surround", name: "Surround", sampleRate: 48_000,
            routing: OutputDeviceDescriptor(
                id: .init(1), uid: "surround", name: "Surround", transport: "USB",
                channelLabels: nil, outputChannelCount: 6, nominalSampleRate: 48_000,
                isVirtual: false, isAggregate: false, outputStreamCount: 1,
                outputStreams: [OutputStreamDescriptor(streamIndex: 0, startingChannel: 1, channelCount: 6)],
                preferredStereoChannels: StereoOutputChannels(left: 1, right: 2)
            )
        )
        XCTAssertEqual(output.captureLayout, InputLayout.surround51)
        let spatialComponent = EffectComponent(id: .airwaveSpatial, name: "Spatial", manufacturer: "Airwave")
        let spatial = EffectSlot(spatialComponent)
        let lowPass = ComponentID(AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_LowPassFilter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        ))
        let apple = EffectComponent(id: lowPass, name: "Lowpass", manufacturer: "Apple")
        let missing = EffectSlot(EffectComponent(
            id: ComponentID(AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: 0x0000FFAA,
                componentManufacturer: 0x00000123, componentFlags: 0, componentFlagsMask: 0
            )),
            name: "Uninstalled Audio Unit", manufacturer: "Test"
        ))
        var failed = EffectSlot(apple)
        failed.state = Data([0])
        var bypassed = EffectSlot(apple)
        bypassed.isBypassed = true
        try store.save([output.uid: DeviceProfile(
            name: output.name, sampleRate: output.sampleRate, slots: [missing, failed, bypassed, spatial]
        )])

        let chain = RenderChain()
        let catalog = EffectCatalog(list: { [spatialComponent, apple] }, instantiate: { id in
            if id == .airwaveSpatial { return try RoutingSpatialUnit(componentDescription: id.description) }
            return try await EffectCatalog.systemInstantiate(id)
        })
        let host = HostController(store: store, defaults: defaults, currentOutput: { output },
                                  availableOutputs: { [output] }, chain: chain, effectCatalog: catalog)
        defer { host.shutdown() }

        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        // The test unit forwards the captured rear channel in surround mode
        // and emits a negative sentinel once its stereo replacement is ready.
        func spatialWidth() -> Int? {
            let frames = 1_024
            let silence = [Float](repeating: 0, count: frames)
            let signal = [Float](repeating: 0.25, count: frames)
            var left = silence
            var right = silence
            silence.withUnsafeBufferPointer { quiet in
                signal.withUnsafeBufferPointer { rear in
                    let planes = [quiet.baseAddress, quiet.baseAddress, quiet.baseAddress,
                                  quiet.baseAddress, rear.baseAddress, quiet.baseAddress]
                    planes.withUnsafeBufferPointer {
                        chain.renderCaptured(&time, $0, quiet.baseAddress!, quiet.baseAddress!, &left, &right,
                                             UInt32(frames))
                    }
                }
            }
            time.mSampleTime += Double(frames)
            if left.first == 0.25 { return 6 }
            if left.first == -0.25 { return 2 }
            return nil
        }
        func waitForSpatialWidth(_ expected: Int, line: UInt = #line) async throws {
            for _ in 0..<50 {
                if spatialWidth() == expected, host.slotIssues[failed.id] != nil { return }
                try await Task.sleep(for: .milliseconds(40))
            }
            let issue = host.slotIssues[spatial.id] ?? "no Audio Unit error"
            XCTFail("Expected Spatial to render \(expected) input channels; \(issue)", line: line)
        }

        try await waitForSpatialWidth(6)
        XCTAssertNotNil(host.slotIssues[missing.id])
        XCTAssertNotNil(host.slotIssues[failed.id])

        host.setBypass(bypassed.id, false)
        try await waitForSpatialWidth(2)
        host.move(from: IndexSet(integer: 3), to: 0)
        try await waitForSpatialWidth(6)
        host.move(from: IndexSet(integer: 0), to: 4)
        try await waitForSpatialWidth(2)
        host.setBypass(bypassed.id, true)
        try await waitForSpatialWidth(6)
        XCTAssertNil(host.slotIssues[spatial.id])
    }

    @MainActor
    func testNativeSpatialBypassPreservesDrySamplesAndUnbypassRestoresHeadroom() async throws {
        let component = try XCTUnwrap(EffectCatalog.discover().first { $0.id == .airwaveSpatial })
        var slot = EffectSlot(component)
        slot.state = try PropertyListSerialization.data(
            fromPropertyList: ["AirwaveSpatial.bypass": true], format: .binary, options: 0
        )
        let frames = 1_024
        let spatial = try await LiveEffect.load(slot, sampleRate: 48_000, maximumFrames: UInt32(frames))
        let chain = RenderChain()
        chain.replace(with: [spatial])

        var dryLeft = (0..<frames).map { sin(Float($0) * 0.32) * 10 }
        dryLeft[0] = -0.0
        let inputRight = Array(dryLeft.reversed())
        var left = [Float](repeating: 0, count: frames)
        var right = left
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        func render() {
            chain.render(&time, dryLeft, inputRight, &left, &right, UInt32(frames))
            time.mSampleTime += Double(frames)
        }
        func assertDry() {
            XCTAssertEqual(left.map(\.bitPattern), dryLeft.map(\.bitPattern))
            XCTAssertEqual(right.map(\.bitPattern), inputRight.map(\.bitPattern))
        }

        render()
        assertDry()

        spatial.unit.shouldBypassEffect = false
        for _ in 0..<4 { render() }
        let peak = max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
        XCTAssertGreaterThan(peak, 0.9)
        XCTAssertLessThanOrEqual(peak, 0.98)

        spatial.unit.shouldBypassEffect = true
        for _ in 0..<4 { render() }
        assertDry()
        XCTAssertEqual(spatial.stage.failure.load(ordering: .relaxed), noErr)
    }

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
        host.addEditing(EffectComponent(id: .airwaveSpatial, name: "Spatial", manufacturer: "Airwave"))
        XCTAssertEqual(host.editingSlots.count, 1)
        host.resetEffects(for: output.uid)
        XCTAssertTrue(host.editingSlots.isEmpty)
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

private final class RoutingSpatialUnit: AUAudioUnit {
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private let renderInput = AudioBufferList.allocate(maximumBuffers: 6)
    private lazy var inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
    private lazy var outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputBus = try AUAudioUnitBus(format: stereo)
        inputBus.maximumChannelCount = 6
        outputBus = try AUAudioUnitBus(format: stereo)
        try super.init(componentDescription: componentDescription, options: options)
    }

    deinit {
        renderInput.unsafeMutablePointer.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var channelCapabilities: [NSNumber]? { [2, 2, 6, 2] }

    override func allocateRenderResources() throws {
        XCTAssertFalse(Thread.isMainThread, "Audio Unit allocation can wait on Core Audio.")
        try super.allocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let input = renderInput
        let channels = Int(inputBus.format.channelCount)
        return { flags, time, frames, _, outputList, _, pull in
            guard let pull else { return kAudioUnitErr_NoConnection }
            let bytes = frames * UInt32(MemoryLayout<Float>.size)
            input.count = channels
            for channel in input.indices {
                input[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: nil)
            }
            let status = pull(flags, time, frames, 0, input.unsafeMutablePointer)
            guard status == noErr else { return status }
            let output = UnsafeMutableAudioBufferListPointer(outputList)
            for channel in output.indices {
                guard let target = output[channel].mData else { return kAudioUnitErr_FormatNotSupported }
                if channels == 6, let rearLeft = input[4].mData {
                    target.copyMemory(from: rearLeft, byteCount: Int(bytes))
                } else {
                    target.assumingMemoryBound(to: Float.self).update(repeating: -0.25, count: Int(frames))
                }
            }
            return noErr
        }
    }
}
