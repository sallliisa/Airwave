//
//  SubDeviceInfo+Extensions.swift
//  MacHRIR
//
//  Helper extensions for AggregateDeviceInspector.SubDeviceInfo
//

import Foundation

extension AggregateDeviceInspector.SubDeviceInfo {
    
    // MARK: - Virtual Loopback Detection
    
    /// Returns true if this device is a virtual loopback device (BlackHole, Soundflower, etc.)
    /// These devices are typically used for routing audio between apps, not for actual output.
    var isVirtualLoopback: Bool {
        let name = self.name.lowercased()
        return name.contains("blackhole") || name.contains("soundflower")
    }
    
    // MARK: - Channel Range Helpers
    
    /// Returns the channel range for stereo output (2 channels).
    /// Validates that the device has at least 2 output channels available.
    /// - Returns: A range representing the stereo output channels, or nil if insufficient channels
    func stereoChannelRange() -> Range<Int>? {
        guard let outputRange = outputChannelRange else {
            return nil
        }
        
        let availableChannels = outputRange.upperBound - outputRange.lowerBound
        guard availableChannels >= 2 else {
            return nil // Device doesn't have stereo capability
        }
        
        // Return stereo range starting from device's start channel
        return startChannel..<(startChannel + 2)
    }
    
    /// Returns the channel range for stereo output, with a fallback to the full output range
    /// if stereo is not available. Use this when you need a guaranteed range.
    /// - Returns: A range representing stereo channels, or the full output range as fallback
    func stereoChannelRangeOrFallback() -> Range<Int> {
        if let stereoRange = stereoChannelRange() {
            return stereoRange
        }
        
        // Fallback: use whatever channels are available
        if let outputRange = outputChannelRange {
            let availableChannels = outputRange.upperBound - outputRange.lowerBound
            return startChannel..<(startChannel + min(availableChannels, 2))
        }
        
        // Last resort: assume stereo starting at startChannel
        return startChannel..<(startChannel + 2)
    }
}
