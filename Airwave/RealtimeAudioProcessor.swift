//
//  RealtimeAudioProcessor.swift
//  Airwave
//
//  Adapts arbitrary CoreAudio callback sizes to ConvolutionEngine's fixed block.
//

import Accelerate

/// Fixed-storage frame adapter for the audio render thread.
final class RealtimeAudioProcessor {
    let blockSize: Int
    let maxFramesPerCallback: Int

    private let renderers: [VirtualSpeakerRenderer]
    private let pendingLeft: UnsafeMutablePointer<Float>
    private let pendingRight: UnsafeMutablePointer<Float>
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
        blockSize: Int = 512,
        maxFramesPerCallback: Int = 4096
    ) {
        precondition(blockSize > 0)
        precondition(maxFramesPerCallback > 0)

        self.renderers = renderers
        self.blockSize = blockSize
        self.maxFramesPerCallback = maxFramesPerCallback
        self.fifoCapacity = maxFramesPerCallback + blockSize

        pendingLeft = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        pendingRight = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
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
        pendingLeft.deallocate()
        pendingRight.deallocate()
        blockLeft.deallocate()
        blockRight.deallocate()
        fifoLeft.deallocate()
        fifoRight.deallocate()
        for buffer in leftTempBuffers { buffer.deallocate() }
        for buffer in rightTempBuffers { buffer.deallocate() }
    }

    /// Process any positive callback size up to maxFramesPerCallback.
    /// Underflow is deliberate: newly buffered samples produce silence until a full DSP block exists.
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        precondition(frameCount <= maxFramesPerCallback)

        var inputOffset = 0
        while inputOffset < frameCount {
            let copyCount = min(blockSize - pendingCount, frameCount - inputOffset)
            memcpy(
                pendingLeft.advanced(by: pendingCount),
                inputLeft.advanced(by: inputOffset),
                copyCount * MemoryLayout<Float>.size
            )
            if let inputRight {
                memcpy(
                    pendingRight.advanced(by: pendingCount),
                    inputRight.advanced(by: inputOffset),
                    copyCount * MemoryLayout<Float>.size
                )
            } else {
                memcpy(
                    pendingRight.advanced(by: pendingCount),
                    inputLeft.advanced(by: inputOffset),
                    copyCount * MemoryLayout<Float>.size
                )
            }

            pendingCount += copyCount
            inputOffset += copyCount

            if pendingCount == blockSize {
                processPendingBlock()
                pendingCount = 0
            }
        }

        drain(leftOutput: leftOutput, rightOutput: rightOutput, frameCount: frameCount)
    }

    func reset() {
        for renderer in renderers {
            renderer.convolverLeftEar.reset()
            renderer.convolverRightEar.reset()
        }
        resetStorage()
    }

    private func resetStorage() {
        memset(pendingLeft, 0, blockSize * MemoryLayout<Float>.size)
        memset(pendingRight, 0, blockSize * MemoryLayout<Float>.size)
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

        let rendererCount = min(renderers.count, 2)
        for rendererIndex in 0..<rendererCount {
            let input = rendererIndex == 0 ? pendingLeft : pendingRight
            let renderer = renderers[rendererIndex]
            renderer.convolverLeftEar.process(input: input, output: leftTempBuffers[rendererIndex])
            renderer.convolverRightEar.process(input: input, output: rightTempBuffers[rendererIndex])

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

        for index in 0..<blockSize {
            let writeIndex = (fifoReadIndex + fifoCount) % fifoCapacity
            fifoLeft[writeIndex] = blockLeft[index]
            fifoRight[writeIndex] = blockRight[index]
            fifoCount += 1
        }
    }

    private func drain(
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        for index in 0..<frameCount {
            if fifoCount > 0 {
                leftOutput[index] = fifoLeft[fifoReadIndex]
                rightOutput[index] = fifoRight[fifoReadIndex]
                fifoReadIndex = (fifoReadIndex + 1) % fifoCapacity
                fifoCount -= 1
            } else {
                leftOutput[index] = 0
                rightOutput[index] = 0
            }
        }
    }
}
