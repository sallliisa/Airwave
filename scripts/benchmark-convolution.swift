import Foundation

@main enum Benchmark {
    static let blockSize = 512
    static let blocks = 120
    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    static func engines(channels: Int, taps: Int, seed: Int) -> [StereoConvolutionEngine] {
        (0..<channels).map { channel in
            let ir = (0..<taps).map { Float(sin(Double($0 + channel + seed) * 0.013)) * pow(0.9995, Float($0)) / 100 }
            return StereoConvolutionEngine(leftEarHRIR: ir, rightEarHRIR: Array(ir.reversed()), blockSize: blockSize)!
        }
    }

    static func main() throws {
        let args = CommandLine.arguments
        let runs = Int(args.firstIndex(of: "--runs").map { args[$0 + 1] } ?? "5")!
        let path = args.firstIndex(of: "--json").map { args[$0 + 1] } ?? "build/benchmark.json"
        guard runs > 0 else { throw NSError(domain: "Benchmark", code: 1) }
        var records: [[String: Any]] = []
        for channels in [2, 8, 16] { for taps in [4_320, 24_000] { for stateCount in [1, 2] {
            let states = (0..<stateCount).map { engines(channels: channels, taps: taps, seed: $0 * 17) }
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
            defer { left.deallocate(); right.deallocate(); totalLeft.deallocate(); totalRight.deallocate() }
            func render(_ block: Int) -> Float {
                memset(totalLeft, 0, blockSize * MemoryLayout<Float>.size)
                memset(totalRight, 0, blockSize * MemoryLayout<Float>.size)
                let state = (block / 8) % stateCount
                for channel in 0..<channels {
                    states[state][channel].process(input: inputs[channel], outputLeft: left, outputRight: right)
                    for frame in 0..<blockSize { totalLeft[frame] += left[frame]; totalRight[frame] += right[frame] }
                }
                return totalLeft[block % blockSize] + totalRight[(block * 7) % blockSize]
            }
            for block in 0..<16 { _ = render(block) }
            var times: [Double] = [], maximumBlockMs = 0.0, checksum: Float = 0
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                for block in 0..<blocks {
                    inputs[block % channels][block % blockSize] += 0.000001
                    let blockStart = DispatchTime.now().uptimeNanoseconds
                    checksum += render(block)
                    maximumBlockMs = max(maximumBlockMs, Double(DispatchTime.now().uptimeNanoseconds - blockStart) / 1_000_000)
                }
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let ratio = median(times) / (Double(blocks * blockSize) / 48_000 * 1_000)
            guard checksum.isFinite, maximumBlockMs.isFinite,
                  times.allSatisfy({ $0.isFinite && $0 > 0 }), ratio < 1 else {
                throw NSError(domain: "Benchmark", code: 2)
            }
            records.append(["channels": channels, "irFrames": taps, "states": stateCount,
                "timesMs": times, "medianMs": median(times), "maximumBlockMs": maximumBlockMs,
                "realtimeRatio": ratio, "checksum": checksum])
        } } }
        let payload: [String: Any] = ["machine": ProcessInfo.processInfo.hostName,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "compiler": "swiftc -O",
            "architecture": ProcessInfo.processInfo.machineHardwareName,
            "runs": runs, "blocks": blocks, "records": records]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path))
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
