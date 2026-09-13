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
///
/// Supported layout means one that reaches a real HRIR renderer: explicit
/// `[.FL, .FR]` stereo, an unlabeled 2/6/8/12 fallback order, or a complete
/// label mapping with no unknown label, no length mismatch, and no duplicate
/// explicit stereo pair (two independent stereo pairs can share one device;
/// labels do not prove rear speakers). All other widths accept only a
/// complete usable label mapping.
nonisolated enum InputLayoutResolver {
    /// Outcome shared by descriptor support, discovery, persistence, and
    /// runtime resolution. One rule: no parallel layout decisions.
    nonisolated enum Support: Equatable, Sendable {
        /// Resolves to meaningful speakers (HRIR renderers or gain fold-down).
        case supported(InputLayout)
        /// Rejected with a specific reason for the unsupported-layout notice.
        case unsupported(reason: String)
    }

    static func layout(channelLabels: [UInt32]?, channelCount: Int) -> InputLayout {
        switch resolve(channelLabels: channelLabels, channelCount: channelCount) {
        case .supported(let layout):
            return layout
        case .unsupported:
            return InputLayout.detect(channelCount: channelCount)
        }
    }

    /// One shared support decision for descriptor, discovery, persistence,
    /// and runtime resolution. Keeps the physical-device, one-stream,
    /// nonempty-UID, and 2-16 width checks in the descriptor; this covers
    /// layout shape only.
    ///
    /// Core Audio description rows report Unknown
    /// (kAudioChannelLabel_Unknown = 0xFFFFFFFF) for channels whose use is
    /// not mapped. Built-in stereo outputs (MacBook speakers, External
    /// Headphones) report two Unknown rows. Unused
    /// (kAudioChannelLabel_Unused = 0) is also "no mapping". No mapped row
    /// at all means no mapping was supplied (count fallback); any mapped
    /// row keeps the full checks below, so mixed known+unknown stays
    /// unsupported. Raw values: this file imports no CoreAudio.
    static func resolve(channelLabels: [UInt32]?, channelCount: Int) -> Support {
        guard (2...16).contains(channelCount) else {
            return .unsupported(reason: "Airwave supports 2 to 16 output channels on physical devices.")
        }
        guard let channelLabels else {
            return .supported(fallbackLayout(channelCount: channelCount))
        }
        // No mapping supplied at all: every row is Unknown
        // (kAudioChannelLabel_Unknown = 0xFFFFFFFF) or Unused
        // (kAudioChannelLabel_Unused = 0). Built-in stereo outputs
        // (MacBook speakers, External Headphones) report two Unknown rows.
        // Fall back to count detection, like nil. Any mapped row keeps the
        // full checks below, so mixed known+unknown stays unsupported.
        // Raw values: this file imports no CoreAudio.
        if channelLabels.allSatisfy({ $0 == 0xFFFF_FFFF || $0 == 0 }) {
            return .supported(fallbackLayout(channelCount: channelCount))
        }
        guard channelLabels.count == channelCount, !channelLabels.isEmpty else {
            return .unsupported(reason: "Airwave could not read this output layout. Change output in macOS Settings.")
        }
        var speakers: [VirtualSpeaker] = []
        speakers.reserveCapacity(channelLabels.count)
        for label in channelLabels {
            guard let speaker = speaker(forLabel: label) else {
                return .unsupported(reason: "Airwave could not map this output layout. Change output in macOS Settings.")
            }
            speakers.append(speaker)
        }
        if hasDuplicateStereoPair(speakers) {
            return .unsupported(reason: "Airwave could not map this output layout. Change output in macOS Settings.")
        }
        return .supported(InputLayout(channels: speakers, name: "Device layout"))
    }

    /// Generic unlabeled fallback. Only 2/6/8/12 have a standard order.
    /// Other widths hold custom speakers (no HRIR renderer; mono fold-down).
    /// The unlabeled 4-channel order [.FL, .FR, .BL, .BR] is a generic
    /// fallback, not verified channel identity for any device or for BOOM.
    static func fallbackLayout(channelCount: Int) -> InputLayout {
        switch channelCount {
        case 4:
            InputLayout(channels: [.FL, .FR, .BL, .BR], name: "Quad fallback")
        default:
            InputLayout.detect(channelCount: channelCount)
        }
    }

    /// True when explicit labels hold two independent stereo pairs
    /// (L/R repeated). Four channels do not prove a surround quad device.
    /// Duplicates must not become guessed rear speakers; they need
    /// independent pair selection, which stays a separate product task.
    private static func hasDuplicateStereoPair(_ speakers: [VirtualSpeaker]) -> Bool {
        let leftCount = speakers.filter { $0 == .FL }.count
        let rightCount = speakers.filter { $0 == .FR }.count
        return leftCount > 1 || rightCount > 1
    }

    private static func speaker(forLabel label: UInt32) -> VirtualSpeaker? {
        // Raw kAudioChannelLabel* values from CoreAudioTypes.h.
        switch label {
        case 1: // kAudioChannelLabel_Left
            .FL
        case 2: // kAudioChannelLabel_Right
            .FR
        case 38, 39: // kAudioChannelLabel_LeftTotal/RightTotal (matrix Lt/Rt)
            // Matrix-encoded stereo pair: treat as its L/R ears.
            label == 38 ? .FL : .FR
        case 208, 209: // kAudioChannelLabel_BinauralLeft/Right
            label == 208 ? .FL : .FR
        case 301, 302: // kAudioChannelLabel_HeadphonesLeft/Right
            label == 301 ? .FL : .FR
        case 42: // kAudioChannelLabel_Mono (dual-mono fallback mixes via FC)
            .FC
        case 3: // kAudioChannelLabel_Center
            .FC
        case 4, 37: // kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2
            .LFE
        case 5: // kAudioChannelLabel_LeftSurround
            .SL
        case 6: // kAudioChannelLabel_RightSurround
            .SR
        case 7: // kAudioChannelLabel_LeftCenter
            .FLC
        case 8: // kAudioChannelLabel_RightCenter
            .FRC
        case 9: // kAudioChannelLabel_CenterSurround (WAVE back center)
            .BC
        case 10, 33: // kAudioChannelLabel_LeftSurroundDirect, RearSurroundLeft
            .BL
        case 11, 34: // kAudioChannelLabel_RightSurroundDirect, RearSurroundRight
            .BR
        case 12: // kAudioChannelLabel_TopCenterSurround
            .BC
        case 13: // kAudioChannelLabel_VerticalHeightLeft (WAVE top front left)
            .TFL
        case 14: // kAudioChannelLabel_VerticalHeightCenter
            .FC
        case 15: // kAudioChannelLabel_VerticalHeightRight (WAVE top front right)
            .TFR
        case 16: // kAudioChannelLabel_TopBackLeft
            .TBL
        case 17: // kAudioChannelLabel_TopBackCenter
            .BC
        case 18: // kAudioChannelLabel_TopBackRight
            .TBR
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

        if inputChannelCount == 2 && inputSpeakers == [.FL, .FR] {
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
