//
//  WAVLoader.swift
//  Airwave
//
//  Loads multi-channel WAV files for HRIR presets
//

import Foundation
import AVFoundation

/// Represents loaded WAV file data
struct WAVData {
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let audioData: [[Float]]  // Array of channels, each containing samples
}

/// Metadata read from a WAV header without decoding samples.
struct WAVHeaderInfo: Equatable {
    let channelCount: Int
    let sampleRate: Double
    let frameCount: Int
    /// Advertised data bytes when present in the header.
    let dataByteCount: Int?
}

/// Loads and parses WAV files
class WAVLoader {
    static let maximumFileSize = 64 * 1_024 * 1_024
    static let maximumChannelCount = 32
    static let maximumDuration = 0.5

    /// Read WAV header metadata with a bounded byte read.
    /// Use this for library scans; full sample validation still runs at import.
    static func headerInfo(from url: URL) throws -> WAVHeaderInfo {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WAVError.fileReadError("Failed to open WAV file: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 4 * 1_024) ?? Data()
        } catch {
            throw WAVError.fileReadError("Failed to read WAV header: \(error.localizedDescription)")
        }
        guard prefix.count >= 44 else {
            throw WAVError.fileReadError("WAV file is too small to hold a header.")
        }
        let bytes = [UInt8](prefix)
        func ascii(_ offset: Int, _ count: Int) -> String {
            String(bytes: bytes[offset..<(offset + count)], encoding: .ascii) ?? ""
        }
        guard ascii(0, 4) == "RIFF", ascii(8, 4) == "WAVE" else {
            throw WAVError.fileReadError("Not a WAV file.")
        }
        // Walk chunks inside the bounded prefix. Headers carry fact/PEAK/bext
        // chunks before data, so the loop must skip unknown chunk IDs.
        var cursor = 12
        var channelCount: Int?
        var sampleRate: Double?
        var dataByteCount: Int?
        while cursor + 8 <= bytes.count {
            let chunkID = ascii(cursor, 4)
            let rawSize = Int(bytes[cursor + 4]) | (Int(bytes[cursor + 5]) << 8)
                | (Int(bytes[cursor + 6]) << 16) | (Int(bytes[cursor + 7]) << 24)
            guard rawSize >= 0 else {
                throw WAVError.fileReadError("WAV header lists a negative chunk size.")
            }
            if chunkID == "fmt ", cursor + 8 + 16 <= bytes.count {
                channelCount = Int(bytes[cursor + 10]) | (Int(bytes[cursor + 11]) << 8)
                let rate = UInt32(bytes[cursor + 12]) | (UInt32(bytes[cursor + 13]) << 8)
                    | (UInt32(bytes[cursor + 14]) << 16) | (UInt32(bytes[cursor + 15]) << 24)
                sampleRate = Double(rate)
            } else if chunkID == "data", dataByteCount == nil {
                dataByteCount = rawSize
            }
            if channelCount != nil, sampleRate != nil, dataByteCount != nil { break }
            // A data chunk larger than the prefix ends the walk: its size is
            // known even when its samples are not in the prefix.
            if chunkID == "data" { break }
            let advance = 8 + rawSize + (rawSize % 2)
            guard advance > 0, cursor + advance <= bytes.count else { break }
            cursor += advance
        }
        guard let channelCount, let sampleRate else {
            throw WAVError.fileReadError("WAV header is missing the format chunk.")
        }
        guard (1...maximumChannelCount).contains(channelCount) else {
            throw WAVError.invalidChannelCount(channelCount)
        }
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            throw WAVError.invalidSampleRate(sampleRate)
        }
        let frameCount: Int
        if let dataByteCount {
            let bytesPerFrame = channelCount * 4
            let (quotient, remainder) = dataByteCount.quotientAndRemainder(dividingBy: bytesPerFrame)
            guard dataByteCount >= 0, remainder == 0, quotient > 0 else {
                throw WAVError.fileReadError("WAV data chunk has an invalid size.")
            }
            frameCount = quotient
        } else {
            // Fall back to the file size as an upper bound; treat as frames of
            // 32-bit float samples so an undersized header cannot pass.
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard fileSize > 44 else {
                throw WAVError.fileReadError("WAV header is missing the data chunk.")
            }
            let bytesPerFrame = channelCount * 4
            let (quotient, remainder) = (fileSize - 44).quotientAndRemainder(dividingBy: bytesPerFrame)
            guard remainder == 0, quotient > 0 else {
                throw WAVError.fileReadError("WAV file has an invalid size.")
            }
            frameCount = quotient
        }
        guard Double(frameCount) <= sampleRate * maximumDuration else {
            throw WAVError.tooManyFrames(frameCount)
        }
        return WAVHeaderInfo(
            channelCount: channelCount,
            sampleRate: sampleRate,
            frameCount: frameCount,
            dataByteCount: dataByteCount
        )
    }

    /// Load a WAV file and extract audio data
    /// - Parameter url: URL to the WAV file
    /// - Returns: WAVData containing the loaded audio
    /// - Throws: Error if loading or parsing fails
    static func load(from url: URL) throws -> WAVData {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize <= maximumFileSize else { throw WAVError.fileTooLarge }
        // Use AVAudioFile for robust WAV loading
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw WAVError.fileReadError("Failed to open WAV file: \(error.localizedDescription)")
        }

        let format = audioFile.processingFormat
        let channelCount = Int(format.channelCount)
        let sampleRate = format.sampleRate
        let frameCount = Int(audioFile.length)

        guard (1...maximumChannelCount).contains(channelCount) else {
            throw WAVError.invalidChannelCount(channelCount)
        }

        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            throw WAVError.invalidSampleRate(sampleRate)
        }

        guard frameCount > 0 else {
            throw WAVError.emptyFile
        }
        guard Double(frameCount) <= sampleRate * maximumDuration,
              frameCount <= Int(AVAudioFrameCount.max) else {
            throw WAVError.tooManyFrames(frameCount)
        }

        // Allocate buffer to read audio data
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw WAVError.bufferAllocationFailed
        }

        // Read entire file
        do {
            try audioFile.read(into: buffer)
        } catch {
            throw WAVError.fileReadError("Failed to read audio data: \(error.localizedDescription)")
        }

        // Extract samples from buffer
        var audioData: [[Float]] = []

        guard Int(buffer.frameLength) == frameCount else { throw WAVError.unexpectedFrameCount }
        if let floatChannelData = buffer.floatChannelData {
            // Audio is already in float format
            for channel in 0..<channelCount {
                let channelPointer = floatChannelData[channel]
                let samples = Array(UnsafeBufferPointer(start: channelPointer, count: Int(buffer.frameLength)))
                guard samples.allSatisfy(\.isFinite) else { throw WAVError.nonFiniteSample }
                audioData.append(samples)
            }
        } else if let int16ChannelData = buffer.int16ChannelData {
            // Convert from Int16 to Float
            for channel in 0..<channelCount {
                let channelPointer = int16ChannelData[channel]
                let int16Samples = UnsafeBufferPointer(start: channelPointer, count: Int(buffer.frameLength))
                let floatSamples = int16Samples.map { Float($0) / 32768.0 }
                audioData.append(floatSamples)
            }
        } else if let int32ChannelData = buffer.int32ChannelData {
            // Convert from Int32 to Float
            for channel in 0..<channelCount {
                let channelPointer = int32ChannelData[channel]
                let int32Samples = UnsafeBufferPointer(start: channelPointer, count: Int(buffer.frameLength))
                let floatSamples = int32Samples.map { Float($0) / 2147483648.0 }
                audioData.append(floatSamples)
            }
        } else {
            throw WAVError.unsupportedFormat
        }

        return WAVData(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            audioData: audioData
        )
    }

    /// Extract stereo channels from multi-channel HRIR
    /// - Parameter wavData: The loaded WAV data
    /// - Returns: Tuple of (leftChannel, rightChannel)
    /// - Throws: Error if channel extraction fails
    static func extractStereoChannels(from wavData: WAVData) throws -> (left: [Float], right: [Float]) {
        guard wavData.channelCount >= 1 else {
            throw WAVError.invalidChannelCount(wavData.channelCount)
        }

        let leftChannel = wavData.audioData[0]

        let rightChannel: [Float]
        if wavData.channelCount >= 2 {
            // Use channel 1 for right
            rightChannel = wavData.audioData[1]
        } else {
            // Mono file: duplicate left channel
            rightChannel = leftChannel
        }

        return (leftChannel, rightChannel)
    }
}

// MARK: - Error Types

enum WAVError: LocalizedError {
    case fileReadError(String)
    case invalidChannelCount(Int)
    case emptyFile
    case bufferAllocationFailed
    case unsupportedFormat
    case fileTooLarge
    case invalidSampleRate(Double)
    case tooManyFrames(Int)
    case unexpectedFrameCount
    case nonFiniteSample

    var errorDescription: String? {
        switch self {
        case .fileReadError(let detail):
            return "WAV file read error: \(detail)"
        case .invalidChannelCount(let count):
            return "Invalid channel count: \(count). WAV file must have at least 1 channel."
        case .emptyFile:
            return "WAV file is empty (0 frames)"
        case .bufferAllocationFailed:
            return "Failed to allocate audio buffer"
        case .unsupportedFormat:
            return "Unsupported WAV format"
        case .fileTooLarge:
            return "WAV file exceeds 64 MiB."
        case .invalidSampleRate(let rate):
            return "Invalid WAV sample rate: \(rate)."
        case .tooManyFrames(let count):
            return "WAV file is too long: \(count) frames."
        case .unexpectedFrameCount:
            return "WAV file read returned an unexpected frame count."
        case .nonFiniteSample:
            return "WAV file contains a non-finite sample."
        }
    }
}
