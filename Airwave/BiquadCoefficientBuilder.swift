import Foundation

nonisolated struct BiquadCoefficients: Equatable, Sendable {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double
}

nonisolated enum BiquadCoefficientError: Error, Equatable, LocalizedError {
    case invalidSampleRate
    case invalidFrequency
    case invalidQ
    case nonFiniteInput
    case nonFiniteCoefficients

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate: return "Sample rate must be finite and positive."
        case .invalidFrequency: return "Frequency must be finite, positive, and below Nyquist."
        case .invalidQ: return "Q must be finite and positive."
        case .nonFiniteInput: return "Filter parameters must be finite."
        case .nonFiniteCoefficients: return "Filter coefficients must be finite."
        }
    }
}

nonisolated enum BiquadCoefficientBuilder {
    static func make(
        type: EqualizerFilterType,
        gainDB: Double,
        frequencyHz: Double,
        q: Double,
        sampleRate: Double
    ) throws -> BiquadCoefficients {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw BiquadCoefficientError.invalidSampleRate
        }
        guard gainDB.isFinite, frequencyHz.isFinite, q.isFinite else {
            throw BiquadCoefficientError.nonFiniteInput
        }
        guard frequencyHz > 0, frequencyHz < sampleRate / 2 else {
            throw BiquadCoefficientError.invalidFrequency
        }
        guard q > 0 else {
            throw BiquadCoefficientError.invalidQ
        }

        let amplitude = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequencyHz / sampleRate
        let sine = sin(omega)
        let cosine = cos(omega)
        let alpha = sine / (2 * q)
        let beta = 2 * sqrt(amplitude) * alpha

        let raw: (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double)
        switch type {
        case .peaking:
            raw = (
                1 + alpha * amplitude,
                -2 * cosine,
                1 - alpha * amplitude,
                1 + alpha / amplitude,
                -2 * cosine,
                1 - alpha / amplitude
            )
        case .lowShelf:
            raw = (
                amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + beta),
                2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine),
                amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - beta),
                (amplitude + 1) + (amplitude - 1) * cosine + beta,
                -2 * ((amplitude - 1) + (amplitude + 1) * cosine),
                (amplitude + 1) + (amplitude - 1) * cosine - beta
            )
        case .highShelf:
            raw = (
                amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + beta),
                -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine),
                amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - beta),
                (amplitude + 1) - (amplitude - 1) * cosine + beta,
                2 * ((amplitude - 1) - (amplitude + 1) * cosine),
                (amplitude + 1) - (amplitude - 1) * cosine - beta
            )
        }

        guard raw.a0.isFinite, raw.a0 != 0 else {
            throw BiquadCoefficientError.nonFiniteCoefficients
        }

        let coefficients = BiquadCoefficients(
            b0: raw.b0 / raw.a0,
            b1: raw.b1 / raw.a0,
            b2: raw.b2 / raw.a0,
            a1: raw.a1 / raw.a0,
            a2: raw.a2 / raw.a0
        )
        guard coefficients.b0.isFinite,
              coefficients.b1.isFinite,
              coefficients.b2.isFinite,
              coefficients.a1.isFinite,
              coefficients.a2.isFinite else {
            throw BiquadCoefficientError.nonFiniteCoefficients
        }
        return coefficients
    }
}
