import Foundation

nonisolated struct EqualizerCustomIIR: Equatable {
    static let maximumOrder = 32
    static let maximumCombinedOrder = 512
    let sourceLine: Int
    let feedforward: [Double]
    let feedback: [Double]

    init(order: Int, coefficients: [Double], sourceLine: Int) throws {
        guard (1...Self.maximumOrder).contains(order) else {
            throw ValidationError.order
        }
        guard coefficients.count == 2 * (order + 1), coefficients.allSatisfy(\.isFinite),
              coefficients[order + 1] != 0 else {
            throw ValidationError.coefficients
        }

        let a0 = coefficients[order + 1]
        let b = coefficients.prefix(order + 1).map { $0 / a0 }
        let a = coefficients.dropFirst(order + 2).map { $0 / a0 }
        guard b.allSatisfy({ Float($0).isFinite }), a.allSatisfy(\.isFinite),
              Self.isStable(a) else { throw ValidationError.unstable }
        self.sourceLine = sourceLine
        feedforward = b
        feedback = a
    }

    static func parse(_ parameters: String, sourceLine: Int) throws -> Self {
        let parts = parameters.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 5, parts[1].caseInsensitiveCompare("Order") == .orderedSame,
              parts[3].caseInsensitiveCompare("Coefficients") == .orderedSame,
              let order = Int(parts[2]) else {
            throw ValidationError.coefficients
        }
        guard (1...maximumOrder).contains(order) else { throw ValidationError.order }
        let coefficients = parts.dropFirst(4).compactMap { Double($0) }
        guard coefficients.count == parts.count - 4 else { throw ValidationError.coefficients }
        return try Self(order: order, coefficients: coefficients, sourceLine: sourceLine)
    }

    private static func isStable(_ denominator: [Double]) -> Bool {
        // Schur recursion tests the normalized denominator without finding its roots.
        var polynomial = [1.0] + denominator
        for order in stride(from: denominator.count, through: 1, by: -1) {
            let reflection = polynomial[order]
            guard reflection.isFinite && abs(reflection) < 1 else { return false }
            let scale = 1 - reflection * reflection
            let previous = polynomial
            for index in 1..<order {
                polynomial[index] = (previous[index] - reflection * previous[order - index]) / scale
            }
        }
        return true
    }

    nonisolated enum ValidationError: LocalizedError {
        case order
        case coefficients
        case unstable

        var errorDescription: String? {
            switch self {
            case .order: "IIR order must be from 1 to \(EqualizerCustomIIR.maximumOrder)."
            case .coefficients: "IIR needs 2 × (order + 1) finite coefficients and a nonzero a0."
            case .unstable: "IIR coefficients must produce a finite, stable filter."
            }
        }
    }
}

nonisolated final class EqualizerCustomIIRFilter {
    private let coefficients: EqualizerCustomIIR
    private let channels: EqualizerStereoChannels
    private let leftHistory: UnsafeMutablePointer<Double>
    private let rightHistory: UnsafeMutablePointer<Double>

    init(_ coefficients: EqualizerCustomIIR, channels: EqualizerStereoChannels) {
        let order = coefficients.feedback.count
        self.coefficients = coefficients
        self.channels = channels
        leftHistory = .allocate(capacity: order)
        rightHistory = .allocate(capacity: order)
        leftHistory.initialize(repeating: 0, count: order)
        rightHistory.initialize(repeating: 0, count: order)
    }

    deinit {
        leftHistory.deallocate()
        rightHistory.deallocate()
    }

    func reset() {
        leftHistory.update(repeating: 0, count: coefficients.feedback.count)
        rightHistory.update(repeating: 0, count: coefficients.feedback.count)
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        if channels.contains(.left) { process(left, history: leftHistory, frameCount: frameCount) }
        if channels.contains(.right) { process(right, history: rightHistory, frameCount: frameCount) }
    }

    private func process(_ samples: UnsafeMutablePointer<Float>, history: UnsafeMutablePointer<Double>, frameCount: Int) {
        let order = coefficients.feedback.count
        for frame in 0..<frameCount {
            let input = Double(samples[frame])
            let value = input * coefficients.feedforward[0] + history[0]
            let output = Float(value)
            guard output.isFinite else {
                history.update(repeating: 0, count: order)
                samples[frame] = 0
                continue
            }
            for index in 0..<(order - 1) {
                history[index] = history[index + 1] + coefficients.feedforward[index + 1] * input
                    - coefficients.feedback[index] * value
            }
            history[order - 1] = coefficients.feedforward[order] * input
                - coefficients.feedback[order - 1] * value
            samples[frame] = output
        }
        for index in 0..<order where abs(history[index]) < Double.leastNormalMagnitude {
            history[index] = 0
        }
    }
}
