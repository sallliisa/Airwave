import Foundation

nonisolated struct EqualizerStereoChannels: OptionSet, Equatable {
    let rawValue: UInt8

    static let left = Self(rawValue: 1)
    static let right = Self(rawValue: 2)
    static let both: Self = [.left, .right]
}

nonisolated enum EqualizerStereoChannel: Equatable {
    case left
    case right

    init(_ spelling: Substring) throws {
        switch spelling.uppercased() {
        case "L", "1": self = .left
        case "R", "2": self = .right
        default: throw EqualizerStereoCommandError.unsupportedChannel(String(spelling))
        }
    }

    var mask: EqualizerStereoChannels {
        switch self {
        case .left: .left
        case .right: .right
        }
    }
}

nonisolated enum EqualizerDelay: Equatable {
    case milliseconds(Double)
    case samples(Double)
}

nonisolated struct EqualizerCopyAssignment: Equatable {
    nonisolated enum Term: Equatable {
        case channel(EqualizerStereoChannel, factor: Float)
        case constant(Float)
    }

    let target: EqualizerStereoChannel
    let terms: [Term]
}

nonisolated enum EqualizerStereoCommandError: LocalizedError {
    case unsupportedChannel(String)
    case invalidChannelSelection
    case invalidCopy
    case invalidDelay
    case delayTooLong

    var errorDescription: String? {
        switch self {
        case .unsupportedChannel(let channel):
            "Channel '\(channel)' is unavailable in stereo. Use L, R, 1, or 2."
        case .invalidChannelSelection:
            "Channel requires a stereo channel or all."
        case .invalidCopy:
            "Copy requires assignments such as L=L+0.5*R or R=0.0."
        case .invalidDelay:
            "Delay requires a nonnegative number followed by ms or samples."
        case .delayTooLong:
            "Delay exceeds Airwave's 10-second or 1,920,000-sample limit."
        }
    }
}

nonisolated enum EqualizerStereoCommand: Equatable {
    static let maximumCopyAssignments = 64
    static let maximumCopyTerms = 64

    case channel(EqualizerStereoChannels)
    case copy([EqualizerCopyAssignment])
    case delay(EqualizerDelay)

    static func parse(command: String, parameters: String) throws -> Self? {
        switch command.lowercased() {
        case "channel":
            let channels = parameters.split(whereSeparator: \.isWhitespace)
            guard !channels.isEmpty else { throw EqualizerStereoCommandError.invalidChannelSelection }
            var selection: EqualizerStereoChannels = []
            for channel in channels {
                if channel.lowercased() == "all" {
                    selection = .both
                } else {
                    selection.formUnion(try EqualizerStereoChannel(channel).mask)
                }
            }
            return .channel(selection)
        case "copy":
            let assignments = parameters.split(maxSplits: maximumCopyAssignments, whereSeparator: \.isWhitespace)
            guard !assignments.isEmpty, assignments.count <= maximumCopyAssignments else {
                throw EqualizerStereoCommandError.invalidCopy
            }
            return .copy(try assignments.map(parseAssignment))
        case "delay":
            return .delay(try parseDelay(parameters))
        default:
            return nil
        }
    }

    private static func parseAssignment(_ assignment: Substring) throws -> EqualizerCopyAssignment {
        let fields = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
            throw EqualizerStereoCommandError.invalidCopy
        }
        let target = try EqualizerStereoChannel(fields[0])
        let terms = fields[1].split(separator: "+", maxSplits: maximumCopyTerms, omittingEmptySubsequences: false)
        guard terms.count <= maximumCopyTerms else { throw EqualizerStereoCommandError.invalidCopy }
        return EqualizerCopyAssignment(target: target, terms: try terms.map(parseTerm))
    }

    private static func parseTerm(_ term: Substring) throws -> EqualizerCopyAssignment.Term {
        let fields = term.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
        guard !term.isEmpty else { throw EqualizerStereoCommandError.invalidCopy }
        if fields.count == 2 {
            let isDecibel = fields[0].lowercased().hasSuffix("db")
            let number = isDecibel ? fields[0].dropLast(2) : fields[0]
            guard let value = Double(number), value.isFinite, !fields[1].isEmpty else {
                throw EqualizerStereoCommandError.invalidCopy
            }
            let factor = Float(isDecibel ? pow(10, value / 20) : value)
            guard factor.isFinite else { throw EqualizerStereoCommandError.invalidCopy }
            return .channel(try EqualizerStereoChannel(fields[1]), factor: factor)
        }
        if term == "0" || term.contains(".") {
            guard let value = Float(term), value.isFinite else { throw EqualizerStereoCommandError.invalidCopy }
            return .constant(value)
        }
        return .channel(try EqualizerStereoChannel(term), factor: 1)
    }

    private static func parseDelay(_ parameters: String) throws -> EqualizerDelay {
        let value = parameters.trimmingCharacters(in: .whitespaces).lowercased()
        let unit: String
        if value.hasSuffix("ms") {
            unit = "ms"
        } else if value.hasSuffix("samples") {
            unit = "samples"
        } else {
            throw EqualizerStereoCommandError.invalidDelay
        }
        let number = value.dropLast(unit.count).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let delay = Double(number), delay.isFinite, delay >= 0 else {
            throw EqualizerStereoCommandError.invalidDelay
        }
        return unit == "ms" ? .milliseconds(delay) : .samples(delay)
    }
}

nonisolated struct EqualizerStereoCopy {
    private let leftMix: Mix?
    private let rightMix: Mix?

    init(assignments: [EqualizerCopyAssignment]) {
        leftMix = assignments.last(where: { $0.target == .left }).map { Mix($0.terms) }
        rightMix = assignments.last(where: { $0.target == .right }).map { Mix($0.terms) }
    }

    // BEGIN REALTIME CALLBACK
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        for frame in 0..<frameCount {
            let leftInput = left[frame]
            let rightInput = right[frame]
            if let leftMix { left[frame] = leftMix.sample(left: leftInput, right: rightInput) }
            if let rightMix { right[frame] = rightMix.sample(left: leftInput, right: rightInput) }
        }
    }
    // END REALTIME CALLBACK

    nonisolated private struct Mix {
        private var leftFactor = 0.0
        private var rightFactor = 0.0
        private var constant = 0.0

        init(_ terms: [EqualizerCopyAssignment.Term]) {
            for term in terms {
                switch term {
                case .channel(.left, let factor): leftFactor += Double(factor)
                case .channel(.right, let factor): rightFactor += Double(factor)
                case .constant(let value): constant += Double(value)
                }
            }
        }

        func sample(left: Float, right: Float) -> Float {
            let value = Float(leftFactor * Double(left) + rightFactor * Double(right) + constant)
            return value.isFinite ? value : 0
        }
    }
}

nonisolated final class EqualizerStereoDelay {
    static let maximumSampleCount = 1_920_000

    let sampleCount: Int
    private let leftHistory: UnsafeMutablePointer<Float>?
    private let rightHistory: UnsafeMutablePointer<Float>?
    private var position = 0

    init(delay: EqualizerDelay, sampleRate: Double, channels: EqualizerStereoChannels) throws {
        guard sampleRate.isFinite, sampleRate > 0 else { throw EqualizerStereoCommandError.invalidDelay }
        let samples: Double
        switch delay {
        case .milliseconds(let value): samples = sampleRate * value / 1_000
        case .samples(let value): samples = value
        }
        guard samples >= 0 else { throw EqualizerStereoCommandError.invalidDelay }
        let rounded = samples.rounded()
        let limit = min(sampleRate * 10, Double(Self.maximumSampleCount))
        guard rounded <= limit else { throw EqualizerStereoCommandError.delayTooLong }
        sampleCount = Int(rounded)
        leftHistory = Self.makeHistory(count: sampleCount, enabled: channels.contains(.left))
        rightHistory = Self.makeHistory(count: sampleCount, enabled: channels.contains(.right))
    }

    deinit {
        leftHistory?.deallocate()
        rightHistory?.deallocate()
    }

    private static func makeHistory(count: Int, enabled: Bool) -> UnsafeMutablePointer<Float>? {
        guard count > 0, enabled else { return nil }
        let history = UnsafeMutablePointer<Float>.allocate(capacity: count)
        history.initialize(repeating: 0, count: count)
        return history
    }

    func reset() {
        position = 0
        leftHistory?.update(repeating: 0, count: sampleCount)
        rightHistory?.update(repeating: 0, count: sampleCount)
    }

    // BEGIN REALTIME CALLBACK
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard sampleCount > 0 else { return }
        if let leftHistory { process(left, history: leftHistory, frameCount: frameCount) }
        if let rightHistory { process(right, history: rightHistory, frameCount: frameCount) }
        position = (position + frameCount) % sampleCount
    }

    private func process(_ samples: UnsafeMutablePointer<Float>, history: UnsafeMutablePointer<Float>, frameCount: Int) {
        var cursor = position
        for frame in 0..<frameCount {
            let delayed = history[cursor]
            history[cursor] = samples[frame]
            samples[frame] = delayed
            cursor += 1
            if cursor == sampleCount { cursor = 0 }
        }
    }
    // END REALTIME CALLBACK
}
