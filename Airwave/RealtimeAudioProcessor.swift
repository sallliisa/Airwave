//
//  RealtimeAudioProcessor.swift
//  Airwave
//
//  Adapts arbitrary CoreAudio callback sizes to ConvolutionEngine's fixed block.
//

import Accelerate

/// Fixed-storage frame adapter for the audio render thread.
///
/// Capture width (inputChannelCount) follows the tapped device stream. Paired
/// renderers convolve their channels; unpaired channels fold into the stereo
/// mix through equal-power downmix gains. Output stays stereo.
nonisolated final class RealtimeAudioProcessor {
    let blockSize: Int
    let maxFramesPerCallback: Int
    let inputChannelCount: Int

    private let renderers: [VirtualSpeakerRenderer]
    /// Speaker identity of every captured channel, used to fold down channels
    /// without a paired convolution renderer.
    private let fallbackSpeakers: [VirtualSpeaker]
    private let pendingInputs: [UnsafeMutablePointer<Float>]
    /// Mono capture (width 1) duplicates its single feed so a front pair of
    /// renderers both consume it (CATap mono contract).
    private let feedCount: Int
    private let blockLeft: UnsafeMutablePointer<Float>
    private let blockRight: UnsafeMutablePointer<Float>
    private let leftTempBuffers: [UnsafeMutablePointer<Float>]
    private let rightTempBuffers: [UnsafeMutablePointer<Float>]
    private let fifoLeft: UnsafeMutablePointer<Float>
    private let fifoRight: UnsafeMutablePointer<Float>
    private let fifoCapacity: Int

    private var pendingCount = 0
    private var fifoReadIndex = 0
    private var fifoCount = 0

    init(
        renderers: [VirtualSpeakerRenderer],
        inputChannelCount: Int,
        fallbackSpeakers: [VirtualSpeaker],
        blockSize: Int = 512,
        maxFramesPerCallback: Int = 4096
    ) {
        precondition(blockSize > 0)
        precondition(maxFramesPerCallback > 0)
        precondition((1...16).contains(inputChannelCount))
        let feedCount = inputChannelCount == 1 ? min(max(renderers.count, 1), 2) : inputChannelCount
        precondition(renderers.count <= feedCount)
        precondition(fallbackSpeakers.count == inputChannelCount)

        self.renderers = renderers
        self.inputChannelCount = inputChannelCount
        self.feedCount = feedCount
        self.fallbackSpeakers = fallbackSpeakers
        self.blockSize = blockSize
        self.maxFramesPerCallback = maxFramesPerCallback
        self.fifoCapacity = maxFramesPerCallback + blockSize

        pendingInputs = (0..<max(feedCount, inputChannelCount)).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        }
        blockLeft = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        blockRight = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        fifoLeft = UnsafeMutablePointer<Float>.allocate(capacity: fifoCapacity)
        fifoRight = UnsafeMutablePointer<Float>.allocate(capacity: fifoCapacity)

        var leftTemps: [UnsafeMutablePointer<Float>] = []
        var rightTemps: [UnsafeMutablePointer<Float>] = []
        leftTemps.reserveCapacity(renderers.count)
        rightTemps.reserveCapacity(renderers.count)
        for _ in renderers {
            leftTemps.append(UnsafeMutablePointer<Float>.allocate(capacity: blockSize))
            rightTemps.append(UnsafeMutablePointer<Float>.allocate(capacity: blockSize))
        }
        leftTempBuffers = leftTemps
        rightTempBuffers = rightTemps

        resetStorage()
    }

    deinit {
        for pointer in pendingInputs { pointer.deallocate() }
        blockLeft.deallocate()
        blockRight.deallocate()
        fifoLeft.deallocate()
        fifoRight.deallocate()
        for buffer in leftTempBuffers { buffer.deallocate() }
        for buffer in rightTempBuffers { buffer.deallocate() }
    }

    /// Process any positive callback size up to maxFramesPerCallback.
    /// Underflow is deliberate: newly buffered samples produce silence until a full DSP block exists.
    /// A nil channel pointer contributes silence rather than aliasing another channel.
    /// `inputOffset` is the frame position within every source channel buffer,
    /// so callers can hand segment views without copying.
    func process(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        inputOffset: Int,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        precondition(frameCount <= maxFramesPerCallback)
        precondition(inputChannelCount == self.inputChannelCount)

        var segmentOffset = 0
        while segmentOffset < frameCount {
            let copyCount = min(blockSize - pendingCount, frameCount - segmentOffset)
            for channel in 0..<self.inputChannelCount {
                let destination = pendingInputs[channel].advanced(by: pendingCount)
                if let source = inputChannels[channel] {
                    memcpy(
                        destination,
                        source.advanced(by: inputOffset + segmentOffset),
                        copyCount * MemoryLayout<Float>.size
                    )
                } else {
                    memset(destination, 0, copyCount * MemoryLayout<Float>.size)
                }
            }

            pendingCount += copyCount
            segmentOffset += copyCount

            if pendingCount == blockSize {
                processPendingBlock()
                pendingCount = 0
            }
        }

        drain(leftOutput: leftOutput, rightOutput: rightOutput, frameCount: frameCount)
    }

    func reset() {
        for renderer in renderers {
            renderer.convolver.reset()
        }
        resetStorage()
    }

    private func resetStorage() {
        for pointer in pendingInputs {
            memset(pointer, 0, blockSize * MemoryLayout<Float>.size)
        }
        memset(blockLeft, 0, blockSize * MemoryLayout<Float>.size)
        memset(blockRight, 0, blockSize * MemoryLayout<Float>.size)
        memset(fifoLeft, 0, fifoCapacity * MemoryLayout<Float>.size)
        memset(fifoRight, 0, fifoCapacity * MemoryLayout<Float>.size)
        pendingCount = 0
        fifoReadIndex = 0
        fifoCount = 0
    }

    private func processPendingBlock() {
        memset(blockLeft, 0, blockSize * MemoryLayout<Float>.size)
        memset(blockRight, 0, blockSize * MemoryLayout<Float>.size)

        // Mono: replicate the captured feed before pairing so renderer 1 sees
        // it as the right-ear input. Width >= 2 never enters this branch.
        if feedCount > inputChannelCount {
            memcpy(pendingInputs[1], pendingInputs[0], blockSize * MemoryLayout<Float>.size)
        }

        for rendererIndex in 0..<renderers.count {
            let input = pendingInputs[rendererIndex]
            let renderer = renderers[rendererIndex]
            renderer.convolver.process(
                input: input,
                outputLeft: leftTempBuffers[rendererIndex],
                outputRight: rightTempBuffers[rendererIndex]
            )

            vDSP_vadd(
                blockLeft, 1,
                leftTempBuffers[rendererIndex], 1,
                blockLeft, 1,
                vDSP_Length(blockSize)
            )
            vDSP_vadd(
                blockRight, 1,
                rightTempBuffers[rendererIndex], 1,
                blockRight, 1,
                vDSP_Length(blockSize)
            )
        }

        // Channels without a paired renderer fold straight into the stereo mix.
        // Mono duplication derives every renderer feed from channel 0, so no
        // captured channel is unpaired there.
        if feedCount == inputChannelCount {
            for channel in renderers.count..<inputChannelCount {
                foldDown(channel: channel)
            }
        }

        // At most two segments: up to the end of the ring, then the wrap.
        let writeIndex = (fifoReadIndex + fifoCount) % fifoCapacity
        let firstCount = min(blockSize, fifoCapacity - writeIndex)
        memcpy(fifoLeft.advanced(by: writeIndex), blockLeft, firstCount * MemoryLayout<Float>.size)
        memcpy(fifoRight.advanced(by: writeIndex), blockRight, firstCount * MemoryLayout<Float>.size)
        if firstCount < blockSize {
            let remainder = blockSize - firstCount
            memcpy(fifoLeft, blockLeft.advanced(by: firstCount), remainder * MemoryLayout<Float>.size)
            memcpy(fifoRight, blockRight.advanced(by: firstCount), remainder * MemoryLayout<Float>.size)
        }
        fifoCount += blockSize
    }

    private func foldDown(channel: Int) {
        let gains = StereoDownmixGains.gains(for: fallbackSpeakers[channel])
        var leftGain = gains.left
        var rightGain = gains.right
        let input = pendingInputs[channel]
        if leftGain != 0 {
            vDSP_vsma(input, 1, &leftGain, blockLeft, 1, blockLeft, 1, vDSP_Length(blockSize))
        }
        if rightGain != 0 {
            vDSP_vsma(input, 1, &rightGain, blockRight, 1, blockRight, 1, vDSP_Length(blockSize))
        }
    }

    private func drain(
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        let available = min(fifoCount, frameCount)
        if available > 0 {
            let firstCount = min(available, fifoCapacity - fifoReadIndex)
            memcpy(leftOutput, fifoLeft.advanced(by: fifoReadIndex), firstCount * MemoryLayout<Float>.size)
            memcpy(rightOutput, fifoRight.advanced(by: fifoReadIndex), firstCount * MemoryLayout<Float>.size)
            if firstCount < available {
                let remainder = available - firstCount
                memcpy(leftOutput.advanced(by: firstCount), fifoLeft, remainder * MemoryLayout<Float>.size)
                memcpy(rightOutput.advanced(by: firstCount), fifoRight, remainder * MemoryLayout<Float>.size)
            }
            fifoReadIndex = (fifoReadIndex + available) % fifoCapacity
            fifoCount -= available
        }

        // Underflow is deliberate: silence until a full DSP block exists.
        if available < frameCount {
            let missing = frameCount - available
            memset(leftOutput.advanced(by: available), 0, missing * MemoryLayout<Float>.size)
            memset(rightOutput.advanced(by: available), 0, missing * MemoryLayout<Float>.size)
        }
    }
}
