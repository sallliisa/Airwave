import Accelerate
import Foundation

nonisolated final class SpatialProcessor {
    private let blockSize: Int
    let tailFrames: Int
    private let firstFilter: StereoConvolutionEngine
    private let secondFilter: StereoConvolutionEngine
    private let symmetric: Bool
    private let scratch: UnsafeMutablePointer<Float>

    init(url: URL, sampleRate: Double) throws {
        var pairs: [(left: [Float], right: [Float])] = []
        _ = try HRIRRenderPlan.readResponses(url: url, inputLayout: .stereo, sampleRate: sampleRate) { _, left, right in
            pairs.append((left, right))
        }
        guard pairs.count == 2 else { throw HRIRError.convolutionSetupFailed("Expected two virtual speakers.") }
        let left = pairs[0]
        let right = pairs[1]
        let length = max(left.left.count, left.right.count, right.left.count, right.right.count)
        // Short partitions keep small callbacks cheap. For long room responses,
        // larger partitions bound the number of spectral products per block.
        let size = length <= 8192 ? 128 : 512
        blockSize = size
        tailFrames = length - 1
        let setup = FFTSetupManager.shared.getSetup(log2n: vDSP_Length(log2(Double(2 * size))))
        func filter(_ left: [Float], _ right: [Float]) throws -> StereoConvolutionEngine {
            guard let engine = StereoConvolutionEngine(leftEarHRIR: left, rightEarHRIR: right,
                                                       blockSize: size, sharedFFTSetup: setup) else {
                throw HRIRError.convolutionSetupFailed("Could not prepare the stereo filters.")
            }
            return engine
        }

        // For a mirror-symmetric matrix [D C; C D], L+R and L-R are
        // independent signals with kernels (D+C)/2 and (D-C)/2.
        symmetric = left.left == right.right && left.right == right.left && left.left.count == left.right.count
        if symmetric {
            firstFilter = try filter(zip(left.left, left.right).map { ($0 + $1) * 0.5 }, [])
            secondFilter = try filter(zip(left.left, left.right).map { ($0 - $1) * 0.5 }, [])
        } else {
            firstFilter = try filter(left.left, left.right)
            secondFilter = try filter(right.left, right.right)
        }
        scratch = .allocate(capacity: blockSize * 2)
    }

    deinit { scratch.deallocate() }

    func reset() {
        firstFilter.reset()
        secondFilter.reset()
    }

    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, leftOutput: UnsafeMutablePointer<Float>,
                 rightOutput: UnsafeMutablePointer<Float>, frameCount: Int) {
        let size = blockSize
        var offset = 0
        while offset < frameCount {
            let n = min(frameCount - offset, size)
            let outL = leftOutput + offset, outR = rightOutput + offset
            if symmetric {
                vDSP_vadd(left + offset, 1, right + offset, 1, scratch, 1, vDSP_Length(n))
                vDSP_vsub(right + offset, 1, left + offset, 1, scratch + size, 1, vDSP_Length(n))
                firstFilter.process(input: scratch, outputLeft: scratch, outputRight: nil, frames: n)
                secondFilter.process(input: scratch + size, outputLeft: scratch + size, outputRight: nil, frames: n)
                vDSP_vadd(scratch, 1, scratch + size, 1, outL, 1, vDSP_Length(n))
                vDSP_vsub(scratch + size, 1, scratch, 1, outR, 1, vDSP_Length(n))
            } else {
                firstFilter.process(input: left + offset, outputLeft: outL, outputRight: outR, frames: n)
                secondFilter.process(input: right + offset, outputLeft: scratch, outputRight: scratch + size, frames: n)
                vDSP_vadd(outL, 1, scratch, 1, outL, 1, vDSP_Length(n))
                vDSP_vadd(outR, 1, scratch + size, 1, outR, 1, vDSP_Length(n))
            }
            offset += n
        }
    }
}
