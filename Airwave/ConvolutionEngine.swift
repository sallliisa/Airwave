//
//  ConvolutionEngine.swift
//  Airwave
//
//  Uniform Partitioned Convolution using Accelerate framework
//  Implements the Uniform Partitioned Overlap-Save (UPOLS) algorithm
//  to efficiently handle long HRIR filters with zero added latency.
//

import Foundation
import Accelerate

/// Real-time partitioned convolution of one input channel against a pair of
/// ear impulse responses.
///
/// Both ears see the same input, so the forward FFT and the frequency delay
/// line (FDL) are computed once per block and shared: only the partitioned
/// multiply-accumulate and the inverse FFT run per ear.
nonisolated final class StereoConvolutionEngine {

    // MARK: - Properties

    private let log2n: vDSP_Length
    private let fftSize: Int
    private let fftSizeHalf: Int
    private let blockSize: Int
    private let partitionCount: Int

    private let fftSetup: FFTSetup
    private let ownsFFTSetup: Bool

    // Input buffering (overlap-save)
    private let inputBuffer: UnsafeMutablePointer<Float>
    private var position = 0
    private var rightTailReady = false
    private let cachedTail: UnsafeMutablePointer<Float>

    // Frequency delay line, shared by both ears. Contiguous flat buffers.
    private let fdlRealData: UnsafeMutablePointer<Float>
    private let fdlImagData: UnsafeMutablePointer<Float>
    private var fdlIndex = 0

    // HRIR partitions (frequency domain), one set per ear.
    private let leftRealData: UnsafeMutablePointer<Float>
    private let leftImagData: UnsafeMutablePointer<Float>
    private let rightRealData: UnsafeMutablePointer<Float>
    private let rightImagData: UnsafeMutablePointer<Float>

    private let accumulatorReal: UnsafeMutablePointer<Float>
    private let accumulatorImag: UnsafeMutablePointer<Float>
    private var accumulator: DSPSplitComplex

    // MARK: - Initialization

    /// - Parameters:
    ///   - leftEarHRIR: impulse response for the left ear
    ///   - rightEarHRIR: impulse response for the right ear
    ///   - blockSize: processing block size (FFT size is twice this)
    ///   - sharedFFTSetup: shared setup; one is created privately when nil
    init?(
        leftEarHRIR: [Float],
        rightEarHRIR: [Float],
        blockSize: Int = 512,
        sharedFFTSetup: FFTSetup? = nil
    ) {
        guard blockSize > 0, blockSize.nonzeroBitCount == 1, !leftEarHRIR.isEmpty || !rightEarHRIR.isEmpty else { return nil }

        self.blockSize = blockSize
        self.fftSize = blockSize * 2
        self.fftSizeHalf = fftSize / 2
        self.log2n = vDSP_Length(log2(Double(fftSize)))

        if let sharedFFTSetup {
            self.fftSetup = sharedFFTSetup
            self.ownsFFTSetup = false
        } else {
            guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                Logger.log("[Convolution] Failed to create FFT setup")
                return nil
            }
            self.fftSetup = setup
            self.ownsFFTSetup = true
        }

        // Both ears share one partition count; the shorter response is zero-padded.
        let longestTapCount = max(leftEarHRIR.count, rightEarHRIR.count)
        self.partitionCount = Int(ceil(Double(longestTapCount) / Double(blockSize)))

        inputBuffer = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        inputBuffer.initialize(repeating: 0, count: fftSize)
        cachedTail = .allocate(capacity: 4 * blockSize)

        accumulatorReal = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        accumulatorImag = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        accumulatorReal.initialize(repeating: 0, count: fftSizeHalf)
        accumulatorImag.initialize(repeating: 0, count: fftSizeHalf)
        accumulator = DSPSplitComplex(realp: accumulatorReal, imagp: accumulatorImag)

        let partitionedSize = partitionCount * fftSizeHalf
        fdlRealData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        fdlImagData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        leftRealData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        leftImagData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        rightRealData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        rightImagData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        fdlRealData.initialize(repeating: 0, count: partitionedSize)
        fdlImagData.initialize(repeating: 0, count: partitionedSize)

        Self.partition(
            impulseResponse: leftEarHRIR,
            into: leftRealData,
            imaginary: leftImagData,
            partitionCount: partitionCount,
            blockSize: blockSize,
            fftSize: fftSize,
            fftSizeHalf: fftSizeHalf,
            fftSetup: fftSetup,
            log2n: log2n
        )
        Self.partition(
            impulseResponse: rightEarHRIR,
            into: rightRealData,
            imaginary: rightImagData,
            partitionCount: partitionCount,
            blockSize: blockSize,
            fftSize: fftSize,
            fftSizeHalf: fftSizeHalf,
            fftSetup: fftSetup,
            log2n: log2n
        )
    }

    deinit {
        if ownsFFTSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }

        inputBuffer.deallocate()
        cachedTail.deallocate()

        accumulatorReal.deallocate()
        accumulatorImag.deallocate()

        fdlRealData.deallocate()
        fdlImagData.deallocate()
        leftRealData.deallocate()
        leftImagData.deallocate()
        rightRealData.deallocate()
        rightImagData.deallocate()
    }

    private static func partition(
        impulseResponse: [Float],
        into real: UnsafeMutablePointer<Float>,
        imaginary: UnsafeMutablePointer<Float>,
        partitionCount: Int,
        blockSize: Int,
        fftSize: Int,
        fftSizeHalf: Int,
        fftSetup: FFTSetup,
        log2n: vDSP_Length
    ) {
        var padded = [Float](repeating: 0, count: fftSize)
        for partition in 0..<partitionCount {
            let start = partition * blockSize
            let end = min(start + blockSize, impulseResponse.count)
            for index in 0..<fftSize { padded[index] = 0 }
            if end > start {
                for index in 0..<(end - start) {
                    padded[index] = impulseResponse[start + index]
                }
            }

            let offset = partition * fftSizeHalf
            var split = DSPSplitComplex(
                realp: real.advanced(by: offset),
                imagp: imaginary.advanced(by: offset)
            )
            padded.withUnsafeBufferPointer { pointer in
                pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complex in
                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSizeHalf))
                }
            }
            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            // Normalize the reusable filter spectra once, before entering the render thread.
            var scale = 0.25 / Float(fftSize)
            vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, vDSP_Length(fftSizeHalf))
            vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, vDSP_Length(fftSizeHalf))
        }
    }

    // MARK: - Processing

    // BEGIN REALTIME CALLBACK
    /// Convolve one `blockSize` input block against the requested responses.
    func process(
        input: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>?
    ) {
        process(input: input, outputLeft: outputLeft, outputRight: outputRight, frames: blockSize)
    }

    /// Emit the causal prefix immediately. A partial block stays in the newest
    /// FDL slot until complete; only its newly arrived samples need output.
    func process(input: UnsafePointer<Float>, outputLeft: UnsafeMutablePointer<Float>,
                 outputRight: UnsafeMutablePointer<Float>?, frames: Int) {
        var offset = 0
        while offset < frames {
            let n = min(blockSize - position, frames - offset)
            if position == 0 {
                if n < blockSize {
                    memset(inputBuffer + blockSize + n, 0, (blockSize - n) * MemoryLayout<Float>.stride)
                }
                rightTailReady = false
                fdlIndex = fdlIndex == 0 ? partitionCount - 1 : fdlIndex - 1
            }
            (inputBuffer + blockSize + position).update(from: input + offset, count: n)
            transformInput()
            renderEar(real: leftRealData, imag: leftImagData, cache: cachedTail, refreshTail: position == 0,
                      output: outputLeft + offset, frames: n)
            if let outputRight {
                renderEar(real: rightRealData, imag: rightImagData, cache: cachedTail + 2 * blockSize,
                          refreshTail: !rightTailReady, output: outputRight + offset, frames: n)
                rightTailReady = true
            }
            position += n
            offset += n
            if position == blockSize {
                inputBuffer.update(from: inputBuffer + blockSize, count: blockSize)
                position = 0
            }
        }
    }

    private func transformInput() {
        let headOffset = fdlIndex * fftSizeHalf
        var head = DSPSplitComplex(
            realp: fdlRealData.advanced(by: headOffset),
            imagp: fdlImagData.advanced(by: headOffset)
        )
        inputBuffer.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complex in
            vDSP_ctoz(complex, 2, &head, 1, vDSP_Length(fftSizeHalf))
        }
        vDSP_fft_zrip(fftSetup, &head, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }

    private func renderEar(real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>,
                           cache: UnsafeMutablePointer<Float>, refreshTail: Bool,
                           output: UnsafeMutablePointer<Float>, frames: Int) {
        if frames == blockSize || partitionCount == 1 {
            accumulate(0..<partitionCount, real: real, imag: imag, into: &accumulator)
        } else {
            // Older blocks cannot change while the current block fills.
            var past = DSPSplitComplex(realp: cache, imagp: cache + blockSize)
            if refreshTail { accumulate(1..<partitionCount, real: real, imag: imag, into: &past) }
            let head = fdlIndex * blockSize
            var signal = DSPSplitComplex(realp: fdlRealData + head, imagp: fdlImagData + head)
            var filter = DSPSplitComplex(realp: real, imagp: imag)
            vDSP_zvma(&signal, 1, &filter, 1, &past, 1, &accumulator, 1, vDSP_Length(blockSize))
            accumulator.realp[0] = past.realp[0] + signal.realp[0] * real[0]
            accumulator.imagp[0] = past.imagp[0] + signal.imagp[0] * imag[0]
        }
        vDSP_fft_zrip(fftSetup, &accumulator, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        // The inverse real FFT packs even and odd time samples into separate arrays.
        var start = blockSize + position
        var count = frames
        var dst = output
        if !start.isMultiple(of: 2) {
            dst[0] = accumulator.imagp[start / 2]
            start += 1
            dst += 1
            count -= 1
        }
        let pairs = count / 2
        if pairs > 0 {
            var valid = DSPSplitComplex(realp: accumulator.realp + start / 2, imagp: accumulator.imagp + start / 2)
            dst.withMemoryRebound(to: DSPComplex.self, capacity: pairs) {
                vDSP_ztoc(&valid, 1, $0, 2, vDSP_Length(pairs))
            }
        }
        if !count.isMultiple(of: 2) { dst[count - 1] = accumulator.realp[start / 2 + pairs] }
    }

    private func accumulate(_ partitions: Range<Int>, real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>,
                            into sum: inout DSPSplitComplex) {
        let bins = vDSP_Length(fftSizeHalf)
        var dc: Float = 0
        var nyquist: Float = 0
        var index = fdlIndex + partitions.lowerBound
        if index == partitionCount { index = 0 }
        for partition in partitions {
            let f = index * fftSizeHalf
            let h = partition * fftSizeHalf
            var signal = DSPSplitComplex(realp: fdlRealData + f, imagp: fdlImagData + f)
            var filter = DSPSplitComplex(realp: real + h, imagp: imag + h)
            dc += signal.realp[0] * filter.realp[0]
            nyquist += signal.imagp[0] * filter.imagp[0]
            if partition == partitions.lowerBound {
                vDSP_zvmul(&signal, 1, &filter, 1, &sum, 1, bins, 1)
            } else {
                var prior = sum
                vDSP_zvma(&signal, 1, &filter, 1, &prior, 1, &sum, 1, bins)
            }
            index += 1
            if index == partitionCount { index = 0 }
        }
        // A real FFT packs DC and Nyquist into the first complex bin.
        sum.realp[0] = dc
        sum.imagp[0] = nyquist
    }
    // END REALTIME CALLBACK

    /// Reset the engine state
    func reset() {
        memset(inputBuffer, 0, fftSize * MemoryLayout<Float>.size)
        position = 0
        rightTailReady = false

        let partitionedSize = partitionCount * fftSizeHalf
        memset(fdlRealData, 0, partitionedSize * MemoryLayout<Float>.size)
        memset(fdlImagData, 0, partitionedSize * MemoryLayout<Float>.size)

        fdlIndex = 0
    }
}
