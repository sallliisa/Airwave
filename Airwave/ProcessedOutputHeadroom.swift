nonisolated struct ProcessedOutputHeadroom {
    private static let ceiling: Float = 0.98
    private static let recoverySeconds = 0.1

    private var currentGain: Float = 1
    private var recoveryGainPerFrame: Float = 1 / (48_000 * Float(recoverySeconds))

    mutating func prepare(sampleRate: Double) {
        currentGain = 1
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        recoveryGainPerFrame = Float(1 / (rate * Double(Self.recoverySeconds)))
    }

    mutating func reset() {
        currentGain = 1
    }

    mutating func apply(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        var peak: Float = 0
        for index in 0..<frameCount {
            let leftMagnitude = abs(left[index])
            if leftMagnitude.isFinite && leftMagnitude > peak {
                peak = leftMagnitude
            }
            let rightMagnitude = abs(right[index])
            if rightMagnitude.isFinite && rightMagnitude > peak {
                peak = rightMagnitude
            }
        }

        // Keep a small numerical margin below the advertised ceiling so Float
        // division and multiplication cannot round a protected peak above it.
        let targetPeak = Self.ceiling.nextDown
        let safeGain = peak > Self.ceiling ? targetPeak / peak : 1
        let startGain: Float
        let targetGain: Float
        if safeGain < currentGain {
            // Reduce the whole callback immediately to keep every sample safe.
            startGain = safeGain
            targetGain = safeGain
        } else {
            let maximumRecovery = recoveryGainPerFrame * Float(frameCount)
            startGain = currentGain
            targetGain = min(safeGain, currentGain + maximumRecovery)
        }
        currentGain = targetGain

        guard startGain != 1 || targetGain != 1 else { return }
        let gainStep = (targetGain - startGain) / Float(frameCount)
        for index in 0..<frameCount {
            let sampleGain = min(targetGain, startGain + gainStep * Float(index))
            left[index] *= sampleGain
            right[index] *= sampleGain
        }
    }
}
