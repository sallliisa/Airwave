import Accelerate
import Foundation

nonisolated enum GraphicEqualizerImpulseResponse {
    static let tapCount = 16_384

    static func make(points: [EqualizerGraphicPoint], sampleRate: Double) -> [Float]? {
        guard let first = points.first,
              points.allSatisfy({ $0.frequencyHz.isFinite && $0.frequencyHz >= 0 && $0.gainDB.isFinite }),
              zip(points, points.dropFirst()).allSatisfy({ $0.frequencyHz < $1.frequencyHz }) else {
            return nil
        }
        if points.allSatisfy({ $0.gainDB == first.gainDB }) {
            let gain = Float(pow(10, max(-100, first.gainDB) / 20))
            return gain.isFinite ? [gain] : nil
        }

        let fftSize = 2 * tapCount
        let exponent = vDSP_Length(fftSize.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetupD(exponent, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetupD(setup) }

        // Equalizer APO samples the log magnitude up to Nyquist and mirrors
        // it about the half-bin. Keep that grid and its -100 dB floor.
        var real = [Double](repeating: 0, count: fftSize)
        var imaginary = [Double](repeating: 0, count: fftSize)
        let logFrequencies = points.map { log($0.frequencyHz) }
        var upper = 0
        for bin in 0..<tapCount {
            let frequency = Double(bin) * (sampleRate / Double(fftSize))
            while upper < points.count - 1 && frequency > points[upper].frequencyHz {
                upper += 1
            }
            let gain: Double
            if upper == 0 || frequency >= points[upper].frequencyHz || points[upper - 1].frequencyHz == 0 {
                gain = points[upper].gainDB
            } else {
                let logLow = logFrequencies[upper - 1]
                let fraction = (log(frequency) - logLow) / (logFrequencies[upper] - logLow)
                gain = (1 - fraction) * points[upper - 1].gainDB + fraction * points[upper].gainDB
            }
            let logGain = max(gain, -100) * (log(10) / 20)
            guard logGain.isFinite, logGain <= log(Double(Float.greatestFiniteMagnitude)) else {
                return nil
            }
            real[bin] = logGain
            real[fftSize - 1 - bin] = logGain
        }

        return real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var spectrum = DSPDoubleSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                vDSP_fft_zipD(setup, &spectrum, 1, exponent, FFTDirection(kFFTDirection_Inverse))
                let scale = 1 / Double(fftSize)
                spectrum.realp[0] *= scale
                spectrum.imagp[0] *= scale
                for index in 1..<tapCount {
                    let mirror = fftSize - index
                    spectrum.realp[index] = (spectrum.realp[index] + spectrum.realp[mirror]) * scale
                    spectrum.imagp[index] = (spectrum.imagp[index] - spectrum.imagp[mirror]) * scale
                    spectrum.realp[mirror] = 0
                    spectrum.imagp[mirror] = 0
                }
                spectrum.realp[tapCount] *= scale
                spectrum.imagp[tapCount] *= -scale
                vDSP_fft_zipD(setup, &spectrum, 1, exponent, FFTDirection(kFFTDirection_Forward))

                for index in 0..<fftSize {
                    let magnitude = exp(spectrum.realp[index])
                    let phase = spectrum.imagp[index]
                    spectrum.realp[index] = magnitude * cos(phase)
                    spectrum.imagp[index] = magnitude * sin(phase)
                }
                vDSP_fft_zipD(setup, &spectrum, 1, exponent, FFTDirection(kFFTDirection_Inverse))

                var response = [Float]()
                response.reserveCapacity(tapCount)
                for index in 0..<tapCount {
                    let window = 0.5 * (1 + cos(2 * Double.pi * Double(index) * scale))
                    let tap = Float(spectrum.realp[index] * scale * window)
                    guard tap.isFinite else { return nil }
                    response.append(tap)
                }
                return response
            }
        }
    }
}

nonisolated final class GraphicEqualizerFilter {
    private let left: Channel
    private let right: Channel

    init?(impulseResponse: [Float]) {
        guard let left = Channel(impulseResponse: impulseResponse),
              let right = Channel(impulseResponse: impulseResponse) else { return nil }
        self.left = left
        self.right = right
    }

    func process(
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int,
        channels: EqualizerStereoChannels = .both
    ) {
        if channels.contains(.left) { self.left.process(left, frameCount: frameCount) }
        if channels.contains(.right) { self.right.process(right, frameCount: frameCount) }
    }

    func reset() {
        left.reset()
        right.reset()
    }

    nonisolated private final class Channel {
        private static let blockSize = 256
        private let head: UnsafeMutablePointer<Float>
        private let headCount: Int
        private let inputHistory: UnsafeMutablePointer<Float>
        private let tailOutput: UnsafeMutablePointer<Float>
        private let tail: StereoConvolutionEngine?
        private var blockOffset = 0

        init?(impulseResponse: [Float]) {
            let head = impulseResponse.prefix(Self.blockSize)
            guard !head.isEmpty else { return nil }
            if impulseResponse.count > Self.blockSize {
                guard let engine = StereoConvolutionEngine(
                    leftEarHRIR: Array(impulseResponse.dropFirst(Self.blockSize)),
                    rightEarHRIR: [],
                    blockSize: Self.blockSize
                ) else { return nil }
                tail = engine
            } else {
                tail = nil
            }
            headCount = head.count
            self.head = .allocate(capacity: head.count)
            for (index, tap) in head.reversed().enumerated() { self.head[index] = tap }
            inputHistory = .allocate(capacity: head.count - 1 + Self.blockSize)
            inputHistory.initialize(repeating: 0, count: head.count - 1 + Self.blockSize)
            tailOutput = .allocate(capacity: Self.blockSize)
            tailOutput.initialize(repeating: 0, count: Self.blockSize)
        }

        deinit {
            head.deallocate()
            inputHistory.deallocate()
            tailOutput.deallocate()
        }

        // BEGIN REALTIME CALLBACK
        func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
            let blockSize = Self.blockSize
            let historyCount = headCount - 1
            let blockInput = inputHistory + historyCount
            var offset = 0
            while offset < frameCount {
                let count = min(frameCount - offset, blockSize - blockOffset)
                let output = samples + offset
                memcpy(blockInput + blockOffset, output, count * MemoryLayout<Float>.size)
                vDSP_conv(inputHistory + blockOffset, 1, head, 1, output, 1, vDSP_Length(count), vDSP_Length(headCount))
                if let tail {
                    vDSP_vadd(output, 1, tailOutput + blockOffset, 1, output, 1, vDSP_Length(count))
                    if blockOffset + count == blockSize {
                        // The tail starts one block later than the direct head.
                        tail.process(input: blockInput, outputLeft: tailOutput, outputRight: nil)
                    }
                }
                blockOffset += count
                offset += count
                if blockOffset == blockSize {
                    memcpy(inputHistory, inputHistory + blockSize, historyCount * MemoryLayout<Float>.size)
                    blockOffset = 0
                }
            }
        }
        // END REALTIME CALLBACK

        func reset() {
            inputHistory.update(repeating: 0, count: headCount - 1 + Self.blockSize)
            tailOutput.update(repeating: 0, count: Self.blockSize)
            tail?.reset()
            blockOffset = 0
        }
    }
}
