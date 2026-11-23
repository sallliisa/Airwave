import Foundation

nonisolated struct EqualizerConvolutionAsset: Equatable {
    static let maximumFileSize = 8 * 1_024 * 1_024
    static let maximumTotalFileSize = 16 * 1_024 * 1_024

    let sourceLine: Int
    let filename: String
    let sampleRate: Double
    let channels: [[Float]]

    static func supports(filename: String) -> Bool {
        (filename as NSString).pathExtension.caseInsensitiveCompare("wav") == .orderedSame
    }

    static func decode(data: Data, filename: String, sourceLine: Int) throws -> Self {
        guard supports(filename: filename),
              data.starts(with: "RIFF".utf8), data.dropFirst(8).starts(with: "WAVE".utf8) else {
            throw AssetError.unsupportedFormat
        }
        guard data.count <= maximumFileSize else { throw AssetError.fileTooLarge }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("airwave-ir-\(UUID())", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }

        let url = directory.appendingPathComponent("impulse.wav")
        try data.write(to: url)
        let wav = try WAVLoader.load(from: url)
        return Self(sourceLine: sourceLine, filename: filename, sampleRate: wav.sampleRate, channels: wav.audioData)
    }

    nonisolated private enum AssetError: LocalizedError {
        case unsupportedFormat
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "Convolution requires a WAV impulse response."
            case .fileTooLarge: return "Convolution impulse response exceeds 8 MiB."
            }
        }
    }
}
