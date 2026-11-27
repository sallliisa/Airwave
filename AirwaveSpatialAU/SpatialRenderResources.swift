import AudioToolbox
import Foundation
import os
import Synchronization

nonisolated final class SpatialRenderAccess {
    let resources = Atomic<UnsafeMutableRawPointer?>(nil)
    let bypass = Atomic<Bool>(false)
    let shouldReset = Atomic<Bool>(false)
}

nonisolated final class SpatialRenderResources {
    private struct PresetUpdate {
        var incoming: SpatialProcessor?
        var retired: SpatialProcessor?
    }

    let layout: SpatialInputLayout
    let sampleRate: Double
    private let maxFrames: Int
    private let inputInterleaved: Bool
    private let outputInterleaved: Bool
    private let fadeFrames = 128
    private let presetWarmupFrames = 512
    private let update = OSAllocatedUnfairLock(uncheckedState: PresetUpdate())
    private let hasPendingPreset = Atomic<Bool>(false)

    private var processor: SpatialProcessor
    private var previousProcessor: SpatialProcessor?
    private var transitionRemaining = 0
    private var bypassAmount: Float?

    private let inputList: UnsafeMutableAudioBufferListPointer
    private let input: UnsafeMutablePointer<Float>
    private let interleavedInput: UnsafeMutablePointer<Float>?
    private let downmixStorage: UnsafeMutablePointer<Float>?
    private let inputChannels: UnsafeMutablePointer<UnsafePointer<Float>?>?
    private let wet: UnsafeMutablePointer<Float>
    private let previousWet: UnsafeMutablePointer<Float>
    private let outputStorage: UnsafeMutablePointer<Float>

    init(processor: SpatialProcessor, layout: SpatialInputLayout, sampleRate: Double, maxFrames: Int,
         inputInterleaved: Bool, outputInterleaved: Bool) {
        self.processor = processor
        self.layout = layout
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        self.inputInterleaved = inputInterleaved
        self.outputInterleaved = outputInterleaved
        let channels = layout.channelCount
        inputList = AudioBufferList.allocate(maximumBuffers: inputInterleaved ? 1 : channels)
        input = .allocate(capacity: channels * maxFrames)
        interleavedInput = inputInterleaved ? .allocate(capacity: channels * maxFrames) : nil
        if channels == 2 && layout.layout.channels == [.FL, .FR] {
            downmixStorage = nil
            inputChannels = nil
        } else {
            downmixStorage = .allocate(capacity: 2 * maxFrames)
            let pointers = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: channels)
            for channel in 0..<channels {
                (pointers + channel).initialize(to: UnsafePointer(input + channel * maxFrames))
            }
            inputChannels = pointers
        }
        wet = .allocate(capacity: 2 * maxFrames)
        previousWet = .allocate(capacity: 2 * maxFrames)
        outputStorage = .allocate(capacity: 2 * maxFrames)
    }

    deinit {
        inputList.unsafeMutablePointer.deallocate()
        input.deallocate()
        interleavedInput?.deallocate()
        downmixStorage?.deallocate()
        inputChannels?.deinitialize(count: layout.channelCount)
        inputChannels?.deallocate()
        wet.deallocate()
        previousWet.deallocate()
        outputStorage.deallocate()
    }

    func publish(_ processor: SpatialProcessor) {
        update.withLockUnchecked {
            $0.incoming = processor
            $0.retired = nil
            hasPendingPreset.store(true, ordering: .releasing)
        }
    }

    func reset() {
        processor.reset()
        transitionRemaining = 0
        bypassAmount = nil
    }

    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AUAudioFrameCount,
        output: UnsafeMutablePointer<AudioBufferList>,
        bypass: Bool,
        pullInput: AURenderPullInputBlock
    ) -> AUAudioUnitStatus {
        let frames = Int(frameCount)
        guard frames <= maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }
        guard frames > 0 else { return noErr }

        let outputList = UnsafeMutableAudioBufferListPointer(output)
        guard prepareOutput(outputList, frames: frames) else { return kAudioUnitErr_InvalidPropertyValue }
        prepareInput(frames: frames)
        var inputFlags = flags.pointee
        inputFlags.remove(.unitRenderAction_OutputIsSilence)
        let status = pullInput(&inputFlags, timestamp, frameCount, 0, inputList.unsafeMutablePointer)
        guard status == noErr else { return status }
        guard readInput(frames: frames, silent: inputFlags.contains(.unitRenderAction_OutputIsSilence)) else {
            return kAudioUnitErr_InvalidPropertyValue
        }

        adoptPendingPreset()
        processor.process(
            input: input, channelStride: maxFrames,
            leftOutput: wet, rightOutput: wet + maxFrames, frameCount: frames
        )
        if transitionRemaining > 0, let previousProcessor {
            previousProcessor.process(
                input: input, channelStride: maxFrames,
                leftOutput: previousWet, rightOutput: previousWet + maxFrames, frameCount: frames
            )
        }
        writeOutput(outputList, frames: frames, bypass: bypass)
        flags.pointee.remove(.unitRenderAction_OutputIsSilence)
        return noErr
    }

    private func adoptPendingPreset() {
        guard transitionRemaining == 0, hasPendingPreset.load(ordering: .acquiring) else { return }
        _ = update.withLockIfAvailableUnchecked { slot in
            guard let incoming = slot.incoming else { return }
            // Keep the previous processor alive until control can release it.
            slot.retired = previousProcessor
            previousProcessor = processor
            processor = incoming
            slot.incoming = nil
            hasPendingPreset.store(false, ordering: .relaxed)
            transitionRemaining = presetWarmupFrames + fadeFrames
        }
    }

    private func prepareInput(frames: Int) {
        let channels = layout.channelCount
        let channelBytes = UInt32(frames * MemoryLayout<Float>.stride)
        inputList.unsafeMutablePointer.pointee.mNumberBuffers = inputInterleaved ? 1 : UInt32(channels)
        if let interleavedInput {
            inputList[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(channels) * channelBytes,
                                       mData: interleavedInput)
        } else {
            for channel in 0..<channels {
                inputList[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: channelBytes,
                                                 mData: input + channel * maxFrames)
            }
        }
    }

    private func readInput(frames: Int, silent: Bool) -> Bool {
        let channels = layout.channelCount
        let channelBytes = frames * MemoryLayout<Float>.stride
        if silent {
            for channel in 0..<channels {
                memset(input + channel * maxFrames, 0, channelBytes)
            }
            return true
        }
        if inputInterleaved {
            guard inputList.count == 1, inputList[0].mNumberChannels == channels,
                  inputList[0].mDataByteSize >= channels * channelBytes,
                  let source = inputList[0].mData?.assumingMemoryBound(to: Float.self) else { return false }
            for channel in 0..<channels {
                let destination = input + channel * maxFrames
                for frame in 0..<frames {
                    destination[frame] = source[channels * frame + channel]
                }
            }
        } else {
            guard inputList.count == channels else { return false }
            for channel in 0..<channels {
                let buffer = inputList[channel]
                guard buffer.mNumberChannels == 1, buffer.mDataByteSize >= channelBytes,
                      let source = buffer.mData?.assumingMemoryBound(to: Float.self) else { return false }
                let destination = input + channel * maxFrames
                if source != destination {
                    memmove(destination, source, channelBytes)
                }
            }
        }
        return true
    }

    private func prepareOutput(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) -> Bool {
        guard list.count == (outputInterleaved ? 1 : 2) else { return false }
        let channels: UInt32 = outputInterleaved ? 2 : 1
        let byteCount = UInt32(frames * MemoryLayout<Float>.stride) * channels
        for index in list.indices {
            var buffer = list[index]
            guard buffer.mNumberChannels == channels else { return false }
            if buffer.mData == nil {
                buffer.mData = UnsafeMutableRawPointer(outputStorage + index * maxFrames)
            } else if buffer.mDataByteSize < byteCount {
                return false
            }
            buffer.mDataByteSize = byteCount
            list[index] = buffer
        }
        return true
    }

    private func writeOutput(_ output: UnsafeMutableAudioBufferListPointer, frames: Int, bypass: Bool) {
        let outputLeft = output[0].mData!.assumingMemoryBound(to: Float.self)
        let outputRight = outputInterleaved ? outputLeft + 1 : output[1].mData!.assumingMemoryBound(to: Float.self)
        let stride = outputInterleaved ? 2 : 1
        let fadeStep = 1 / Float(fadeFrames)
        var amount = bypassAmount ?? (bypass ? 1 : 0)
        let dry = downmixStorage ?? input
        if (bypass || amount > 0), let downmixStorage, let inputChannels {
            StereoDownmixGains.downmix(
                inputChannels: UnsafePointer(inputChannels), inputChannelCount: layout.channelCount,
                inputOffset: 0, inputSpeakers: layout.layout.channels, outputLeft: downmixStorage,
                outputRight: downmixStorage + maxFrames, frameCount: frames
            )
        }

        if transitionRemaining == 0, amount == (bypass ? 1 : 0) {
            let source = bypass ? dry : wet
            if outputInterleaved {
                for i in 0..<frames {
                    outputLeft[2 * i] = source[i]
                    outputRight[2 * i] = source[maxFrames + i]
                }
            } else {
                outputLeft.update(from: source, count: frames)
                outputRight.update(from: source + maxFrames, count: frames)
            }
            bypassAmount = amount
            return
        }

        for frame in 0..<frames {
            var left = wet[frame]
            var right = wet[maxFrames + frame]
            if transitionRemaining > 0 {
                let progress = Float(max(0, fadeFrames - transitionRemaining)) * fadeStep
                left = previousWet[frame] * (1 - progress) + left * progress
                right = previousWet[maxFrames + frame] * (1 - progress) + right * progress
                transitionRemaining -= 1
            }

            amount = bypass ? min(1, amount + fadeStep) : max(0, amount - fadeStep)
            if amount == 1 {
                outputLeft[stride * frame] = dry[frame]
                outputRight[stride * frame] = dry[maxFrames + frame]
            } else if amount == 0 {
                outputLeft[stride * frame] = left
                outputRight[stride * frame] = right
            } else {
                outputLeft[stride * frame] = left * (1 - amount) + dry[frame] * amount
                outputRight[stride * frame] = right * (1 - amount) + dry[maxFrames + frame] * amount
            }
        }
        bypassAmount = amount
    }
}
