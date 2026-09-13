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

    /// Read WAV header metadata with bounded reads and seeks.
    /// Use this for library scans; full sample validation still runs at import.
    /// Frame sizing uses the format chunk block alignment, not an assumed
    /// sample width, so PCM widths other than 32-bit float report correctly.
    static func headerInfo(from url: URL) throws -> WAVHeaderInfo {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize <= maximumFileSize else { throw WAVError.fileTooLarge }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WAVError.fileReadError("Failed to open WAV file: \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        func readExactly(_ count: Int) throws -> [UInt8] {
            do {
                guard let data = try handle.read(upToCount: count), data.count == count else {
                    throw WAVError.fileReadError("WAV file ends inside its header.")
                }
                return [UInt8](data)
            } catch let error as WAVError {
                throw error
            } catch {
                throw WAVError.fileReadError("Failed to read WAV header: \(error.localizedDescription)")
            }
        }
        func seek(to offset: UInt64) throws {
            do {
                try handle.seek(toOffset: offset)
            } catch {
                throw WAVError.fileReadError("Failed to read WAV header: \(error.localizedDescription)")
            }
        }
        func ascii(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> String {
            guard offset + count <= bytes.count else { return "" }
            return String(bytes: bytes[offset..<(offset + count)], encoding: .ascii) ?? ""
        }

        let riff = try readExactly(12)
        guard ascii(riff, 0, 4) == "RIFF", ascii(riff, 8, 4) == "WAVE" else {
            throw WAVError.fileReadError("Not a WAV file.")
        }

        // Walk chunk headers with seeks, so metadata of any size before the
        // data chunk cannot hide the data size. Never derive frames from the
        // total file size: that counts metadata as audio.
        var channelCount: Int?
        var sampleRate: Double?
        var blockAlign: Int?
        var audioFormat: Int?
        var dataByteCount: Int?
        var offset: UInt64 = 12
        for _ in 0..<64 {
            try seek(to: offset)
            let header: [UInt8]
            do {
                guard let data = try handle.read(upToCount: 8) else {
                    throw WAVError.fileReadError("WAV header is missing the data chunk.")
                }
                header = [UInt8](data)
            } catch let error as WAVError {
                throw error
            } catch {
                throw WAVError.fileReadError("Failed to read WAV header: \(error.localizedDescription)")
            }
            guard header.count == 8 else { break }
            let chunkID = ascii(header, 0, 4)
            let chunkSize = UInt64(header[4]) | (UInt64(header[5]) << 8)
                | (UInt64(header[6]) << 16) | (UInt64(header[7]) << 24)
            if chunkID == "fmt ", channelCount == nil {
                guard chunkSize >= 16 else {
                    throw WAVError.fileReadError("WAV header has an invalid format chunk.")
                }
                try seek(to: offset + 8)
                let body = try readExactly(Int(min(chunkSize, 40)))
                audioFormat = Int(body[0]) | (Int(body[1]) << 8)
                channelCount = Int(body[2]) | (Int(body[3]) << 8)
                let rate = UInt32(body[4]) | (UInt32(body[5]) << 8)
                    | (UInt32(body[6]) << 16) | (UInt32(body[7]) << 24)
                sampleRate = Double(rate)
                blockAlign = Int(body[12]) | (Int(body[13]) << 8)
            } else if chunkID == "data", dataByteCount == nil {
                guard chunkSize > 0, chunkSize <= UInt64(Int.max) else {
                    throw WAVError.fileReadError("WAV data chunk has an invalid size.")
                }
                dataByteCount = Int(chunkSize)
            }
            if channelCount != nil, sampleRate != nil, dataByteCount != nil { break }
            let advance = chunkSize + 8 + (chunkSize & 1)
            guard advance >= 8, offset <= UInt64.max - advance else {
                throw WAVError.fileReadError("WAV header lists an invalid chunk size.")
            }
            offset += advance
            if fileSize > 0, offset >= UInt64(fileSize) { break }
        }
        guard let channelCount, let sampleRate else {
            throw WAVError.fileReadError("WAV header is missing the format chunk.")
        }
        guard let dataByteCount else {
            throw WAVError.fileReadError("WAV header is missing the data chunk.")
        }
        if let audioFormat, audioFormat != 1, audioFormat != 3, audioFormat != 0xFFFE {
            throw WAVError.unsupportedFormat
        }
        guard (1...maximumChannelCount).contains(channelCount) else {
            throw WAVError.invalidChannelCount(channelCount)
        }
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            throw WAVError.invalidSampleRate(sampleRate)
        }
        guard let blockAlign, (1...(maximumChannelCount * 8)).contains(blockAlign) else {
            throw WAVError.fileReadError("WAV header has an invalid block alignment.")
        }
        let (frameCount, remainder) = dataByteCount.quotientAndRemainder(dividingBy: blockAlign)
        guard remainder == 0, frameCount > 0 else {
            throw WAVError.fileReadError("WAV data chunk has an invalid size.")
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
                guard floatSamples.allSatisfy(\.isFinite) else { throw WAVError.nonFiniteSample }
                audioData.append(floatSamples)
            }
        } else if let int32ChannelData = buffer.int32ChannelData {
            // Convert from Int32 to Float
            for channel in 0..<channelCount {
                let channelPointer = int32ChannelData[channel]
                let int32Samples = UnsafeBufferPointer(start: channelPointer, count: Int(buffer.frameLength))
                let floatSamples = int32Samples.map { Float($0) / 2147483648.0 }
                guard floatSamples.allSatisfy(\.isFinite) else { throw WAVError.nonFiniteSample }
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
