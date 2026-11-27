import AudioToolbox
import Foundation
import os
import Synchronization

nonisolated final class EqualizerRenderAccess {
    let resources = Atomic<UnsafeMutableRawPointer?>(nil)
    let bypass = Atomic<Bool>(false)
    let shouldReset = Atomic<Bool>(false)
}

nonisolated final class EqualizerRenderResources {
    private struct RenderProgram {
        let processor: ParametricEqualizerState?
    }

    private struct PresetUpdate {
        var incoming: RenderProgram?
        var retired: RenderProgram?
    }

    private let fadeFrames: Int
    private let maxFrames: Int
    private let inputInterleaved: Bool
    private let outputInterleaved: Bool
    private let update = OSAllocatedUnfairLock(uncheckedState: PresetUpdate())
    private let hasPendingPreset = Atomic<Bool>(false)

    private var current: RenderProgram
    private var previous: RenderProgram?
    private var transitionRemaining = 0
    private var bypassAmount: Float?

    private let inputList = AudioBufferList.allocate(maximumBuffers: 2)
    private let input: UnsafeMutablePointer<Float>
    private let interleavedInput: UnsafeMutablePointer<Float>?
    private let wet: UnsafeMutablePointer<Float>
    private let previousWet: UnsafeMutablePointer<Float>
    private let outputStorage: UnsafeMutablePointer<Float>

    init(processor: ParametricEqualizerState?, sampleRate: Double, maxFrames: Int,
         inputInterleaved: Bool, outputInterleaved: Bool) {
        fadeFrames = max(1, Int((sampleRate * ParametricEqualizerProcessor.crossfadeDurationSeconds).rounded()))
        current = RenderProgram(processor: processor)
        self.maxFrames = maxFrames
        self.inputInterleaved = inputInterleaved
        self.outputInterleaved = outputInterleaved
        input = .allocate(capacity: 2 * maxFrames)
        interleavedInput = inputInterleaved ? .allocate(capacity: 2 * maxFrames) : nil
        wet = .allocate(capacity: 2 * maxFrames)
        previousWet = .allocate(capacity: 2 * maxFrames)
        outputStorage = .allocate(capacity: 2 * maxFrames)
    }

    deinit {
        inputList.unsafeMutablePointer.deallocate()
        input.deallocate()
        interleavedInput?.deallocate()
        wet.deallocate()
        previousWet.deallocate()
        outputStorage.deallocate()
    }

    func publish(_ processor: ParametricEqualizerState?) {
        update.withLockUnchecked {
            $0.incoming = RenderProgram(processor: processor)
            $0.retired = nil
            hasPendingPreset.store(true, ordering: .releasing)
        }
    }

    func reset() {
        current.processor?.reset()
        previous?.processor?.reset()
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
        if current.processor != nil || transitionRemaining > 0 {
            process(current, into: wet, frames: frames)
            if transitionRemaining > 0, let previous {
                process(previous, into: previousWet, frames: frames)
            }
        }
        writeOutput(outputList, frames: frames, bypass: bypass)
        flags.pointee.remove(.unitRenderAction_OutputIsSilence)
        return noErr
    }

    private func adoptPendingPreset() {
        guard transitionRemaining == 0, hasPendingPreset.load(ordering: .acquiring) else { return }
        _ = update.withLockIfAvailableUnchecked { slot in
            guard let incoming = slot.incoming else { return }
            slot.retired = previous
            previous = current
            current = incoming
            slot.incoming = nil
            hasPendingPreset.store(false, ordering: .relaxed)
            transitionRemaining = previous?.processor == nil && incoming.processor == nil ? 0 : fadeFrames
        }
    }

    private func process(_ program: RenderProgram, into destination: UnsafeMutablePointer<Float>, frames: Int) {
        if let processor = program.processor {
            processor.process(inputLeft: input, inputRight: input + maxFrames,
                              leftOutput: destination, rightOutput: destination + maxFrames,
                              frameCount: frames)
        } else {
            let bytes = frames * MemoryLayout<Float>.stride
            memcpy(destination, input, bytes)
            memcpy(destination + maxFrames, input + maxFrames, bytes)
        }
    }

    private func prepareInput(frames: Int) {
        let channelBytes = UInt32(frames * MemoryLayout<Float>.stride)
        inputList.unsafeMutablePointer.pointee.mNumberBuffers = inputInterleaved ? 1 : 2
        if let interleavedInput {
            inputList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 2 * channelBytes, mData: interleavedInput)
        } else {
            inputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: channelBytes, mData: input)
            inputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: channelBytes, mData: input + maxFrames)
        }
    }

    private func readInput(frames: Int, silent: Bool) -> Bool {
        let right = input + maxFrames
        let channelBytes = frames * MemoryLayout<Float>.stride
        if silent {
            memset(input, 0, channelBytes)
            memset(right, 0, channelBytes)
            return true
        }
        if inputInterleaved {
            guard inputList.count == 1, inputList[0].mNumberChannels == 2,
                  inputList[0].mDataByteSize >= 2 * channelBytes,
                  let source = inputList[0].mData?.assumingMemoryBound(to: Float.self) else { return false }
            for frame in 0..<frames {
                input[frame] = source[2 * frame]
                right[frame] = source[2 * frame + 1]
            }
        } else {
            guard inputList.count == 2 else { return false }
            for channel in 0..<2 {
                let buffer = inputList[channel]
                guard buffer.mNumberChannels == 1, buffer.mDataByteSize >= channelBytes,
                      let source = buffer.mData?.assumingMemoryBound(to: Float.self) else { return false }
                let destination = input + channel * maxFrames
                if source != destination { memmove(destination, source, channelBytes) }
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

        if transitionRemaining == 0, current.processor == nil || (bypass && amount == 1) {
            if outputInterleaved {
                for frame in 0..<frames {
                    outputLeft[2 * frame] = input[frame]
                    outputRight[2 * frame] = input[maxFrames + frame]
                }
            } else {
                outputLeft.update(from: input, count: frames)
                outputRight.update(from: input + maxFrames, count: frames)
            }
            bypassAmount = bypass ? 1 : 0
            return
        }

        for frame in 0..<frames {
            var left = wet[frame]
            var right = wet[maxFrames + frame]
            if transitionRemaining > 0 {
                transitionRemaining -= 1
                let progress = Float(fadeFrames - transitionRemaining) * fadeStep
                left = previousWet[frame] * (1 - progress) + left * progress
                right = previousWet[maxFrames + frame] * (1 - progress) + right * progress
            }

            amount = bypass ? min(1, amount + fadeStep) : max(0, amount - fadeStep)
            if amount == 1 {
                outputLeft[stride * frame] = input[frame]
                outputRight[stride * frame] = input[maxFrames + frame]
            } else if amount == 0 {
                outputLeft[stride * frame] = left
                outputRight[stride * frame] = right
            } else {
                outputLeft[stride * frame] = left * (1 - amount) + input[frame] * amount
                outputRight[stride * frame] = right * (1 - amount) + input[maxFrames + frame] * amount
            }
        }
        bypassAmount = amount
    }
}
