import Foundation

/// Plan 025 corrected benchmark: synthetic per-speaker DSP estimate, not the
/// production crossfader. Documents the included work so a two-state block is
/// twice its one-state counterpart. Label: synthetic-DSP-estimate.
@main enum Benchmark {
    static let blockSize = 512
    static let blocks = 120
    static let sampleRate = 48_000.0

    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    static func engines(channels: Int, taps: Int, seed: Int) -> [StereoConvolutionEngine] {
        (0..<channels).map { channel in
            // Same per-speaker IR shape as the prior harness (sine decay,
            // 1/100 scale). Kept for result comparison; no L1 normalization
            // here because each engine must see both its full one-state and
            // two-state workloads at identical input gain.
            let ir = (0..<taps).map { Float(sin(Double($0 + channel + seed) * 0.013)) * pow(0.9995, Float($0)) / 100 }
            return StereoConvolutionEngine(leftEarHRIR: ir, rightEarHRIR: Array(ir.reversed()), blockSize: blockSize)!
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    static func main() {
        let args = CommandLine.arguments
        // Guarded CLI parsing: non-numeric input exits nonzero with a message.
        var runs = 5
        if let runsFlag = args.firstIndex(of: "--runs") {
            guard runsFlag + 1 < args.count, let parsed = Int(args[runsFlag + 1]), parsed > 0 else {
                fail("usage: benchmark --runs <positive-int> --json <path>")
            }
            runs = parsed
        }
        var path = "build/benchmark.json"
        if let jsonFlag = args.firstIndex(of: "--json") {
            guard jsonFlag + 1 < args.count, !args[jsonFlag + 1].isEmpty else {
                fail("usage: benchmark --runs <positive-int> --json <path>")
            }
            path = args[jsonFlag + 1]
        }
        guard runs > 0 else { fail("usage: benchmark --runs <positive-int> --json <path>") }

        var records: [[String: Any]] = []
        for channels in [2, 8, 16] { for taps in [4_320, 24_000] { for stateCount in [1, 2] {
            let states = (0..<stateCount).map { engines(channels: channels, taps: taps, seed: $0 * 17) }
            // Owned preallocated buffers. Deterministic nonconstant inputs.
            let inputs = (0..<channels).map { channel -> UnsafeMutablePointer<Float> in
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
                for frame in 0..<blockSize { pointer[frame] = Float(sin(Double(frame + channel) * 0.021)) }
                return pointer
            }
            defer { inputs.forEach { $0.deallocate() } }
            let left = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
            let totalLeft = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
            let totalRight = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
            // Fixed complementary crossfade gains for the two-state mix.
            // A distinct pair (0.35, 0.65) guards against an accidental
            // constant-gain shortcut; the one-state path uses gain 1.
            let fromGain: Float = 0.35
            let toGain: Float = 0.65
            defer { left.deallocate(); right.deallocate(); totalLeft.deallocate(); totalRight.deallocate() }

            // Warm every state before timing, with the same per-block
            // structure as the timed region.
            for state in 0..<stateCount {
                for block in 0..<16 {
                    memset(totalLeft, 0, blockSize * MemoryLayout<Float>.size)
                    memset(totalRight, 0, blockSize * MemoryLayout<Float>.size)
                    if stateCount == 1 {
                        for channel in 0..<channels {
                            states[state][channel].process(input: inputs[channel], outputLeft: left, outputRight: right)
                            for frame in 0..<blockSize { totalLeft[frame] += left[frame]; totalRight[frame] += right[frame] }
                        }
                    } else {
                        for channel in 0..<channels {
                            states[0][channel].process(input: inputs[channel], outputLeft: left, outputRight: right)
                            for frame in 0..<blockSize { totalLeft[frame] += left[frame] * fromGain; totalRight[frame] += right[frame] * fromGain }
                            states[1][channel].process(input: inputs[channel], outputLeft: left, outputRight: right)
                            for frame in 0..<blockSize { totalLeft[frame] += left[frame] * toGain; totalRight[frame] += right[frame] * toGain }
                        }
                    }
                    _ = totalLeft[block % blockSize] + totalRight[(block * 7) % blockSize]
                }
            }

            /// Renders one timed block. One-state: every speaker engine runs
            /// once per block. Two-state: every speaker engine of BOTH states
            /// runs for EVERY block, then mixes with fixed complementary
            /// gains. Alternating states is not a two-state workload. The
            /// timed region holds convolution plus the stereo sum only;
            /// per-block input perturbation and checksum sampling sit outside
            /// the block timer but inside the run timer (documented overhead).
            func render() -> Float {
                memset(totalLeft, 0, blockSize * MemoryLayout<Float>.size)
                memset(totalRight, 0, blockSize * MemoryLayout<Float>.size)
                if stateCount == 1 {
                    for channel in 0..<channels {
                        states[0][channel].process(input: inputs[channel], outputLeft: left, outputRight: right)
                        for frame in 0..<blockSize { totalLeft[frame] += left[frame]; totalRight[frame] += right[frame] }
                    }
                } else {
                    for channel in 0..<channels {
                        states[0][channel].process(input: inputs[channel], outputLeft: left, outputRight: right)
                        for frame in 0..<blockSize { totalLeft[frame] += left[frame] * fromGain; totalRight[frame] += right[frame] * fromGain }
                        states[1][channel].process(input: inputs[channel], outputLeft: left, outputRight: right)
                        for frame in 0..<blockSize { totalLeft[frame] += left[frame] * toGain; totalRight[frame] += right[frame] * toGain }
                    }
                }
                return totalLeft[11] + totalLeft[101] + totalLeft[301] + totalRight[57] + totalRight[407]
            }

            var times: [Double] = []
            var blockMsSamples: [Double] = []
            var maximumBlockMs = 0.0
            var checksum: Float = 0
            for _ in 0..<runs {
                // Same reset and warm-up before every run.
                for state in states.flatMap({ $0 }) { state.reset() }
                for _ in 0..<4 { _ = render() }
                checksum = 0
                let start = DispatchTime.now().uptimeNanoseconds
                for block in 0..<blocks {
                    inputs[block % channels][block % blockSize] += 0.000001
                    let blockStart = DispatchTime.now().uptimeNanoseconds
                    let sample = render()
                    let blockEnd = DispatchTime.now().uptimeNanoseconds
                    let blockMs = Double(blockEnd - blockStart) / 1_000_000
                    maximumBlockMs = max(maximumBlockMs, blockMs)
                    blockMsSamples.append(blockMs)
                    // Checksum accumulation after the block timer closes.
                    checksum += sample
                }
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let renderedFrames = blocks * blockSize
            let renderedSeconds = Double(renderedFrames) / sampleRate
            // One division by rendered audio time, irrespective of speaker or
            // state count: a two-state block costs twice the state work per
            // block, which shows up as a higher ratio, not more frames.
            let ratio = median(times) / (renderedSeconds * 1_000)
            guard checksum.isFinite, maximumBlockMs.isFinite,
                  !checksum.isZero,
                  times.allSatisfy({ $0.isFinite && $0 > 0 }), ratio < 1 else {
                fail("non-finite output or real-time ratio >= 1 for channels=\(channels) irFrames=\(taps) states=\(stateCount)")
            }
            records.append(["channels": channels, "irFrames": taps, "states": stateCount,
                "stateWorkPerBlock": stateCount,
                "timesMs": times, "medianMs": median(times), "maximumBlockMs": maximumBlockMs,
                "realtimeRatio": ratio, "checksum": checksum,
                "renderedFrames": renderedFrames, "sampleRate": sampleRate,
                "blockSize": blockSize, "blocks": blocks,
                "workload": "synthetic-DSP-estimate",
                "notes": stateCount == 2
                    ? "every timed block processes both states with fixed complementary gains 0.35/0.65"
                    : "every timed block processes the single state with gain 1"])
        } } }
        let payload: [String: Any] = ["machine": ProcessInfo.processInfo.hostName,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "compiler": "swiftc -O",
            "architecture": ProcessInfo.processInfo.machineHardwareName,
            "label": "synthetic-DSP-estimate",
            "date": ISO8601DateFormatter().string(from: Date()),
            "runs": runs, "blocks": blocks, "records": records]
        do {
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path))
        } catch {
            fail("could not write JSON to \(path): \(error)")
        }
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &value, &size, nil, 0)
        return String(cString: value)
    }
}
