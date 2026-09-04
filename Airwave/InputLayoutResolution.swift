//
//  InputLayoutResolution.swift
//  Airwave
//
//  Pure resolution from device channel data to a VirtualSpeaker layout, plus
//  the equal-power stereo downmix gains used by passthrough fold-down and
//  unpaired-channel mixing. No Core Audio import: callers pass raw labels.
//

import Accelerate
import Foundation

/// Resolves an `InputLayout` for a captured device stream.
///
/// Channel labels from `kAudioDevicePropertyChannelLayout` are authoritative
/// when present and fully recognized; otherwise the channel count alone
/// decides via `InputLayout.detect(channelCount:)`.
nonisolated enum InputLayoutResolver {
    static func layout(channelLabels: [UInt32]?, channelCount: Int) -> InputLayout {
        if let channelLabels,
           channelLabels.count == channelCount,
           !channelLabels.isEmpty {
            var speakers: [VirtualSpeaker] = []
            speakers.reserveCapacity(channelLabels.count)
            for label in channelLabels {
                guard let speaker = speaker(forLabel: label) else {
                    return InputLayout.detect(channelCount: channelCount)
                }
                speakers.append(speaker)
            }
            return InputLayout(channels: speakers, name: "Device layout")
        }
        return InputLayout.detect(channelCount: channelCount)
    }

    private static func speaker(forLabel label: UInt32) -> VirtualSpeaker? {
        // Raw kAudioChannelLabel* values from CoreAudioTypes.h.
        switch label {
        case 1: // kAudioChannelLabel_Left
            .FL
        case 2: // kAudioChannelLabel_Right
            .FR
        case 3: // kAudioChannelLabel_Center
            .FC
        case 4, 34: // kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2
            .LFE
        case 5: // kAudioChannelLabel_LeftSurround
            .SL
        case 6: // kAudioChannelLabel_RightSurround
            .SR
        case 10: // kAudioChannelLabel_RearSurroundLeft
            .BL
        case 11: // kAudioChannelLabel_RearSurroundRight
            .BR
        default:
            nil
        }
    }
}

/// Equal-power stereo downmix gains, shared by the passthrough fold-down and
/// by captured channels that have no paired convolution renderer.
///
/// LFE maps to zero: headphone binaural has no LFE position (see
/// docs/multichannel-known-tradeoffs.md).
nonisolated enum StereoDownmixGains {
    static func gains(for speaker: VirtualSpeaker) -> (left: Float, right: Float) {
        switch speaker {
        case .FL, .FLC:
            (0.707, 0.0)
        case .FR, .FRC:
            (0.0, 0.707)
        case .FC:
            (0.707, 0.707)
        case .LFE:
            (0.0, 0.0)
        case .BL, .SL, .TFL, .TBL:
            (0.5, 0.0)
        case .BR, .SR, .TFR, .TBR:
            (0.0, 0.5)
        case .BC, .custom:
            (0.354, 0.354)
        }
    }

    /// Writes one stereo fallback buffer without allocating or resolving a
    /// layout on the render thread.
    @inline(__always)
    static func downmix(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        inputOffset: Int,
        inputSpeakers: [VirtualSpeaker],
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        let byteCount = frameCount * MemoryLayout<Float>.size

        if inputChannelCount == 2 && inputSpeakers.count == 2 {
            if let left = inputChannels[0] {
                memcpy(outputLeft, left.advanced(by: inputOffset), byteCount)
            } else {
                memset(outputLeft, 0, byteCount)
            }
            if let right = inputChannels[1] {
                memcpy(outputRight, right.advanced(by: inputOffset), byteCount)
            } else if let left = inputChannels[0] {
                // Mono capture can expose a missing second pointer.
                memcpy(outputRight, left.advanced(by: inputOffset), byteCount)
            } else {
                memset(outputRight, 0, byteCount)
            }
            return
        }

        if inputChannelCount == 1 {
            if let source = inputChannels[0] {
                let source = source.advanced(by: inputOffset)
                memcpy(outputLeft, source, byteCount)
                memcpy(outputRight, source, byteCount)
            } else {
                memset(outputLeft, 0, byteCount)
                memset(outputRight, 0, byteCount)
            }
            return
        }

        memset(outputLeft, 0, byteCount)
        memset(outputRight, 0, byteCount)
        for channel in 0..<min(inputChannelCount, inputSpeakers.count) {
            guard let source = inputChannels[channel] else { continue }
            let gains = gains(for: inputSpeakers[channel])
            var leftGain = gains.left
            var rightGain = gains.right
            let offsetSource = source.advanced(by: inputOffset)
            if leftGain != 0 {
                vDSP_vsma(offsetSource, 1, &leftGain, outputLeft, 1, outputLeft, 1, vDSP_Length(frameCount))
            }
            if rightGain != 0 {
                vDSP_vsma(offsetSource, 1, &rightGain, outputRight, 1, outputRight, 1, vDSP_Length(frameCount))
            }
        }
    }
}
