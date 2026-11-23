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
    case invalidBandwidth
    case invalidShelfSlope
    case nonFiniteInput
    case nonFiniteCoefficients

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate: return "Sample rate must be finite and positive."
        case .invalidFrequency: return "Frequency must be finite, positive, and below Nyquist."
        case .invalidQ: return "Q must be finite and positive."
        case .invalidBandwidth: return "Bandwidth must be finite and positive."
        case .invalidShelfSlope: return "Shelf slope must produce a finite, positive damping coefficient."
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
        try make(type: type, gainDB: gainDB, frequencyHz: frequencyHz, shape: .q(q), sampleRate: sampleRate)
    }

    static func make(
        type: EqualizerFilterType,
        gainDB: Double,
        frequencyHz: Double,
        shape: EqualizerFilterShape,
        sampleRate: Double
    ) throws -> BiquadCoefficients {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw BiquadCoefficientError.invalidSampleRate
        }
        guard gainDB.isFinite, frequencyHz.isFinite else {
            throw BiquadCoefficientError.nonFiniteInput
        }
        guard frequencyHz > 0 else {
            throw BiquadCoefficientError.invalidFrequency
        }
        let amplitude = pow(10, gainDB / 40)
        let centerFrequency = try centerFrequency(
            for: type, frequencyHz: frequencyHz, gainDB: gainDB, amplitude: amplitude, shape: shape
        )
        guard centerFrequency.isFinite, centerFrequency > 0, centerFrequency < sampleRate / 2 else {
            throw BiquadCoefficientError.invalidFrequency
        }
        let omega = 2 * Double.pi * centerFrequency / sampleRate
        let sine = sin(omega)
        let cosine = cos(omega)
        let alpha: Double
        switch shape {
        case .q(let q, _):
            guard q.isFinite else { throw BiquadCoefficientError.nonFiniteInput }
            guard q > 0 else { throw BiquadCoefficientError.invalidQ }
            alpha = sine / (2 * q)
        case .bandwidthOctaves(let bandwidth):
            guard bandwidth.isFinite, bandwidth > 0 else { throw BiquadCoefficientError.invalidBandwidth }
            alpha = sine * sinh(log(2) * bandwidth * omega / (2 * sine))
        case .shelfSlope(let slope, _):
            let damping = (amplitude + 1 / amplitude) * (1 / slope - 1) + 2
            guard slope.isFinite, slope > 0, damping.isFinite, damping > 0 else {
                throw BiquadCoefficientError.invalidShelfSlope
            }
            alpha = sine / 2 * sqrt(damping)
        }

        let raw: (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double)
        switch type {
        case .lowPass:
            let b1 = 1 - cosine
            raw = (b1 / 2, b1, b1 / 2, 1 + alpha, -2 * cosine, 1 - alpha)
        case .highPass:
            let b0 = (1 + cosine) / 2
            raw = (b0, -2 * b0, b0, 1 + alpha, -2 * cosine, 1 - alpha)
        case .bandPass:
            raw = (alpha, 0, -alpha, 1 + alpha, -2 * cosine, 1 - alpha)
        case .notch:
            raw = (1, -2 * cosine, 1, 1 + alpha, -2 * cosine, 1 - alpha)
        case .allPass:
            raw = (1 - alpha, -2 * cosine, 1 + alpha, 1 + alpha, -2 * cosine, 1 - alpha)
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
            let beta = 2 * sqrt(amplitude) * alpha
            raw = (
                amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + beta),
                2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine),
                amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - beta),
                (amplitude + 1) + (amplitude - 1) * cosine + beta,
                -2 * ((amplitude - 1) + (amplitude + 1) * cosine),
                (amplitude + 1) + (amplitude - 1) * cosine - beta
            )
        case .highShelf:
            let beta = 2 * sqrt(amplitude) * alpha
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

    private static func centerFrequency(
        for type: EqualizerFilterType,
        frequencyHz: Double,
        gainDB: Double,
        amplitude: Double,
        shape: EqualizerFilterShape
    ) throws -> Double {
        let slope: Double
        switch shape {
        case .q(let q, frequency: .corner):
            guard q.isFinite, q > 0 else { throw BiquadCoefficientError.invalidQ }
            slope = 1 / ((1 / (q * q) - 2) / (amplitude + 1 / amplitude) + 1)
        case .shelfSlope(let value, frequency: .corner):
            slope = value
        default:
            return frequencyHz
        }
        guard slope.isFinite, slope > 0 else { throw BiquadCoefficientError.invalidShelfSlope }

        // Equalizer APO adjusts DCX2496 shelf corners to the biquad's center frequency.
        let factor = pow(10, abs(gainDB) / (80 * slope))
        return type == .lowShelf ? frequencyHz * factor : frequencyHz / factor
    }
}
