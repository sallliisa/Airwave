import AudioToolbox
import AVFoundation
import Darwin
import Foundation

/// Run the AU from this checkout in-process, so CPU includes the actual filter work.
private final class RenderProbe {
    let unit: AirwaveSpatialAudioUnit
    let input: AVAudioPCMBuffer
    let output: AVAudioPCMBuffer
    let render: AURenderBlock
    let pull: AURenderPullInputBlock
    var time = AudioTimeStamp()

    init(preset: URL?, rate: Double) throws {
        let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x41777370,
                                                    componentManufacturer: 0x41777665, componentFlags: 0, componentFlagsMask: 0)
        unit = try AirwaveSpatialAudioUnit(componentDescription: description)
        if let preset { try unit.importPreset(from: preset) }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = 8192
        unit.inputBusses[0].isEnabled = true
        try unit.allocateRenderResources()
        input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: unit.maximumFramesToRender)!
        output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: unit.maximumFramesToRender)!
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        pull = { _, _, frames, _, destination in
            let buffers = UnsafeMutableAudioBufferListPointer(destination)
            for channel in source.indices {
                let bytes = Int(frames) * Int(source[channel].mNumberChannels) * MemoryLayout<Float>.size
                memcpy(buffers[channel].mData!, source[channel].mData!, bytes)
            }
            return noErr
        }
        render = unit.renderBlock
        time.mFlags = .sampleTimeValid
    }

    deinit { unit.deallocateRenderResources() }

    func process(_ frames: Int) {
        var flags = AudioUnitRenderActionFlags()
        output.frameLength = UInt32(frames)
        precondition(render(&flags, &time, UInt32(frames), 0, output.mutableAudioBufferList, pull) == noErr)
        time.mSampleTime += Double(frames)
    }

    func verify(response: WAVData) {
        let map = response.channelCount == 7 ? HRIRChannelMap.hesuvi7Channel(speakers: [.FL, .FR])
                                             : HRIRChannelMap.hesuvi14Channel(speakers: [.FL, .FR])
        let schedule = [1, 63, 7, 128, 513, 1023, 8192]
        precondition(unit.latency == 0)
        let expectedTail = Double(response.frameCount - 1) / response.sampleRate
        precondition(abs(unit.tailTime - expectedTail) < 1 / response.sampleRate)
        for (side, speaker) in [VirtualSpeaker.FL, .FR].enumerated() {
            unit.reset()
            let pair = map.getIndices(for: speaker)!
            var leftMagnitudes: [Float] = []
            var offset = 0
            var block = 0
            while offset < response.frameCount + 512 {
                let frames = schedule[block % schedule.count]
                input.frameLength = UInt32(frames)
                for buffer in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList) {
                    memset(buffer.mData!, 0, Int(buffer.mDataByteSize))
                }
                if offset == 0 { input.floatChannelData![side][0] = 1 }
                process(frames)
                for (ear, channel) in [pair.0, pair.1].enumerated() {
                    let samples = output.floatChannelData![ear]
                    for i in 0..<frames {
                        let expected = offset + i < response.frameCount ? response.audioData[channel][offset + i] : 0
                        precondition(abs(samples[i] - expected) < 2e-5, "Impulse differs from WAV")
                        if side == 0 && ear == 0 { leftMagnitudes.append(abs(samples[i])) }
                    }
                }
                offset += frames
                block += 1
            }
            if let peak = leftMagnitudes.max(), peak > 0,
               let onset = leftMagnitudes.firstIndex(where: { $0 >= 0.01 * peak }),
               let peakFrame = leftMagnitudes.firstIndex(of: peak) {
                print(String(format: "Left impulse onset %d frames (%.3f ms), peak %d frames (%.3f ms)",
                             onset, Double(onset) * 1000 / response.sampleRate,
                             peakFrame, Double(peakFrame) * 1000 / response.sampleRate))
            }
        }
        unit.shouldBypassEffect = true
        unit.reset()
        input.frameLength = 1
        input.floatChannelData![0][0] = 0.25
        process(1)
        precondition(output.floatChannelData![0][0] == 0.25, "Bypass delayed the dry input")
        unit.shouldBypassEffect = false
        unit.reset()
    }

    func benchmark(frames: Int, rate: Double) {
        input.frameLength = UInt32(frames)
        for i in 0..<frames {
            input.floatChannelData![0][i] = Float(sin(Double(i) * 0.17) * 0.1)
            input.floatChannelData![1][i] = Float(cos(Double(i) * 0.23) * 0.08)
        }
        for _ in 0..<1000 { process(frames) }
        let blocks = 8_192_000 / frames
        let start = cpuSeconds()
        for _ in 0..<blocks { process(frames) }
        let percent = 100 * (cpuSeconds() - start) / (Double(blocks * frames) / rate)
        var durations = [UInt64](repeating: 0, count: 12_000)
        for i in durations.indices {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            process(frames)
            durations[i] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
        }
        durations.sort()
        print(String(format: "%d frames  %.3f%% of one core  p99 %.2f µs  max %.2f µs", frames, percent,
                     Double(durations[durations.count * 99 / 100 - 1]) / 1000, Double(durations.last!) / 1000))
    }
}

private func cpuSeconds() -> Double {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

@main enum VerifySpatialRender {
    static func main() throws {
        for (index, path) in CommandLine.arguments.dropFirst().enumerated() {
            let url = URL(fileURLWithPath: path)
            let wav = try WAVLoader.load(from: url)
            print("\(url.lastPathComponent), \(wav.sampleRate) Hz")
            let probe = try RenderProbe(preset: index == 0 ? nil : url, rate: wav.sampleRate)
            probe.verify(response: wav)
            print("Both input impulses matched both ears at zero added frames.")
            for frames in [64, 128, 512] { probe.benchmark(frames: frames, rate: wav.sampleRate) }
            if wav.sampleRate == 48_000 {
                let rate = 44_100.0
                let channels = try wav.audioData.map {
                    try Resampler.resampleHighQuality(input: $0, fromRate: wav.sampleRate, toRate: rate)
                }
                let reference = WAVData(sampleRate: rate, channelCount: channels.count,
                                        frameCount: channels[0].count, audioData: channels)
                let converted = try RenderProbe(preset: index == 0 ? nil : url, rate: rate)
                print("Checking resampled response at 44100 Hz")
                converted.verify(response: reference)
            }
        }
    }
}
