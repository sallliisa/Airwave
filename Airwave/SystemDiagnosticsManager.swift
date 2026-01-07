//
//  SystemDiagnosticsManager.swift
//  Airwave
//
//  Centralized diagnostics for audio setup validation
//

import Foundation
import CoreAudio
import Combine
import AVFoundation

/// Represents the diagnostic status of the audio system setup
struct DiagnosticsResult {
    /// Virtual audio driver (BlackHole, Loopback, Soundflower) detection
    var virtualDriverInstalled: Bool = false
    var virtualDriverName: String? = nil
    var detectedVirtualDrivers: [String] = []
    
    /// Aggregate device status
    var aggregateDevicesExist: Bool = false
    var validAggregateExists: Bool = false
    var aggregateCount: Int = 0
    var aggregateHealth: [AggregateHealth] = []
    
    /// Permissions
    var microphonePermissionGranted: Bool = false
    var microphonePermissionDetermined: Bool = false
    
    /// Overall status
    var isFullyConfigured: Bool {
        virtualDriverInstalled && validAggregateExists && microphonePermissionGranted
    }
    
    /// Get a summary of issues
    var issues: [String] {
        var result: [String] = []
        if !virtualDriverInstalled {
            result.append("No virtual audio driver installed (BlackHole, Loopback, or Soundflower)")
        }
        if !aggregateDevicesExist {
            result.append("No aggregate devices found")
        } else if !validAggregateExists {
            result.append("No properly configured aggregate device (needs both input and output)")
        }
        if !microphonePermissionGranted {
            result.append("Microphone permission not granted")
        }
        return result
    }
}

/// Health status for a single aggregate device
struct AggregateHealth: Identifiable {
    let id = UUID()
    let name: String
    let deviceUID: String?
    let hasInput: Bool
    let hasOutput: Bool
    let inputDeviceCount: Int
    let outputDeviceCount: Int
    let missingDevices: [String]
    
    var isValid: Bool {
        hasInput && hasOutput
    }
}

/// Known virtual audio driver patterns
enum VirtualAudioDriver: CaseIterable {
    case blackHole2ch
    case blackHole16ch
    case blackHole64ch
    case loopback
    case soundflower2ch
    case soundflower64ch
    case existentialAudioDevice
    
    var namePattern: String {
        switch self {
        case .blackHole2ch: return "BlackHole 2ch"
        case .blackHole16ch: return "BlackHole 16ch"
        case .blackHole64ch: return "BlackHole 64ch"
        case .loopback: return "Loopback"
        case .soundflower2ch: return "Soundflower (2ch)"
        case .soundflower64ch: return "Soundflower (64ch)"
        case .existentialAudioDevice: return "Existential Audio Device"
        }
    }
    
    var displayName: String {
        switch self {
        case .blackHole2ch, .blackHole16ch, .blackHole64ch:
            return "BlackHole"
        case .loopback:
            return "Loopback"
        case .soundflower2ch, .soundflower64ch:
            return "Soundflower"
        case .existentialAudioDevice:
            return "Existential Audio Device"
        }
    }
    
    /// Check if a device name matches this virtual driver
    func matches(deviceName: String) -> Bool {
        deviceName.localizedCaseInsensitiveContains(namePattern) ||
        deviceName.lowercased().contains(namePattern.lowercased())
    }
    
    /// Check if a device name matches any BlackHole variant
    static func isBlackHole(deviceName: String) -> Bool {
        deviceName.localizedCaseInsensitiveContains("blackhole")
    }
    
    /// Check if a device name matches any virtual audio driver
    static func isVirtualDriver(deviceName: String) -> Bool {
        let lowercased = deviceName.lowercased()
        return lowercased.contains("blackhole") ||
               lowercased.contains("loopback") ||
               lowercased.contains("soundflower") ||
               lowercased.contains("existential audio")
    }
}

/// Manager for system-wide audio diagnostics
class SystemDiagnosticsManager: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = SystemDiagnosticsManager()
    
    // MARK: - Published Properties
    
    @Published var diagnostics: DiagnosticsResult = DiagnosticsResult()
    @Published var isRefreshing: Bool = false
    
    // MARK: - Private Properties
    
    private let inspector = AggregateDeviceInspector()
    private var cancellables = Set<AnyCancellable>()
    private var aggregateSubDeviceListeners: [AudioDeviceID: Bool] = [:]  // Track which aggregates we're listening to
    
    // MARK: - Initialization
    
    private init() {
        // Configure inspector for diagnostics (skip missing devices gracefully)
        inspector.missingDeviceStrategy = .skipMissing
        
        // Initial refresh
        refresh()
        
        // Listen for aggregate device list changes
        AudioDeviceManager.shared.$aggregateDevices
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] aggregates in
                self?.updateAggregateListeners(for: aggregates)
                self?.refresh()
            }
            .store(in: &cancellables)
        
        // Listen for input device changes
        AudioDeviceManager.shared.$inputDevices
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
        
        // Listen for output device changes
        AudioDeviceManager.shared.$outputDevices
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
        
        // Setup initial aggregate listeners
        updateAggregateListeners(for: AudioDeviceManager.shared.aggregateDevices)
        
        // Listen for microphone permission changes
        // This handles the case where the user grants permission from the macOS prompt on launch
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMicrophonePermissionChange),
            name: PermissionManager.microphonePermissionDidChangeNotification,
            object: nil
        )
    }
    
    // MARK: - Aggregate Sub-Device Listeners
    
    /// Update listeners for all aggregate devices' sub-device lists
    private func updateAggregateListeners(for aggregates: [AudioDevice]) {
        let currentIDs = Set(aggregates.map { $0.id })
        let listeningIDs = Set(aggregateSubDeviceListeners.keys)
        
        // Add listeners for new aggregates
        for aggregate in aggregates {
            if !aggregateSubDeviceListeners.keys.contains(aggregate.id) {
                addSubDeviceListener(for: aggregate)
            }
        }
        
        // Remove listeners for removed aggregates (they're already gone, just clean up tracking)
        for id in listeningIDs.subtracting(currentIDs) {
            aggregateSubDeviceListeners.removeValue(forKey: id)
        }
    }
    
    private func addSubDeviceListener(for aggregate: AudioDevice) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectAddPropertyListener(
            aggregate.id,
            &propertyAddress,
            aggregateSubDeviceChangeCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        
        if status == noErr {
            aggregateSubDeviceListeners[aggregate.id] = true
            Logger.log("[Diagnostics] Added sub-device listener for aggregate: \(aggregate.name)")
        }
    }
    
    @objc private func handleMicrophonePermissionChange(_ notification: Notification) {
        Logger.log("[Diagnostics] Microphone permission changed, refreshing...")
        refresh()
    }
    
    // MARK: - Public Methods
    
    /// Refresh all diagnostics
    func refresh() {
        isRefreshing = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var result = DiagnosticsResult()
            
            // Check virtual drivers
            self.checkVirtualDrivers(&result)
            
            // Check aggregate devices
            self.checkAggregateDevices(&result)
            
            // Check permissions
            self.checkPermissions(&result)
            
            DispatchQueue.main.async {
                self.diagnostics = result
                self.isRefreshing = false
                Logger.log("[Diagnostics] Refresh complete: \(result.isFullyConfigured ? "✅ Ready" : "⚠️ Issues found")")
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func checkVirtualDrivers(_ result: inout DiagnosticsResult) {
        let allDevices = AudioDeviceManager.getAllDevices()
        var detectedDrivers: [String] = []
        
        for device in allDevices {
            let name = device.name
            
            // Check for specific virtual driver patterns
            if VirtualAudioDriver.isBlackHole(deviceName: name) {
                if !detectedDrivers.contains(where: { $0.contains("BlackHole") }) {
                    detectedDrivers.append(name)
                }
            } else if name.localizedCaseInsensitiveContains("loopback") {
                if !detectedDrivers.contains(where: { $0.contains("Loopback") }) {
                    detectedDrivers.append(name)
                }
            } else if name.localizedCaseInsensitiveContains("soundflower") {
                if !detectedDrivers.contains(where: { $0.contains("Soundflower") }) {
                    detectedDrivers.append(name)
                }
            }
        }
        
        result.detectedVirtualDrivers = detectedDrivers
        result.virtualDriverInstalled = !detectedDrivers.isEmpty
        result.virtualDriverName = detectedDrivers.first
    }
    
    private func checkAggregateDevices(_ result: inout DiagnosticsResult) {
        let allDevices = AudioDeviceManager.getAllDevices()
        let aggregates = allDevices.filter { inspector.isAggregateDevice($0) }
        
        result.aggregateDevicesExist = !aggregates.isEmpty
        result.aggregateCount = aggregates.count
        
        var healthRecords: [AggregateHealth] = []
        var hasValidAggregate = false
        
        for aggregate in aggregates {
            let health = inspector.getDeviceHealth(aggregate: aggregate)
            
            do {
                let inputs = try inspector.getInputDevices(aggregate: aggregate)
                let allOutputs = try inspector.getOutputDevices(aggregate: aggregate)
                
                // Filter out virtual loopback devices from outputs (same logic as SettingsView)
                let outputs = allOutputs.filter { output in
                    let name = output.name.lowercased()
                    return !name.contains("blackhole") && !name.contains("soundflower")
                }
                
                let hasInput = !inputs.isEmpty
                let hasOutput = !outputs.isEmpty
                
                let record = AggregateHealth(
                    name: aggregate.name,
                    deviceUID: aggregate.uid,
                    hasInput: hasInput,
                    hasOutput: hasOutput,
                    inputDeviceCount: inputs.count,
                    outputDeviceCount: outputs.count,
                    missingDevices: health.missingUIDs
                )
                
                healthRecords.append(record)
                
                if hasInput && hasOutput {
                    hasValidAggregate = true
                }
            } catch {
                // Device inspection failed - mark as unhealthy
                let record = AggregateHealth(
                    name: aggregate.name,
                    deviceUID: aggregate.uid,
                    hasInput: false,
                    hasOutput: false,
                    inputDeviceCount: 0,
                    outputDeviceCount: 0,
                    missingDevices: health.missingUIDs
                )
                healthRecords.append(record)
            }
        }
        
        result.aggregateHealth = healthRecords
        result.validAggregateExists = hasValidAggregate
    }
    
    private func checkPermissions(_ result: inout DiagnosticsResult) {
        // Check microphone permission synchronously for diagnostics display
        let permissionStatus = PermissionManager.shared.currentMicrophoneStatus
        
        switch permissionStatus {
        case .authorized:
            result.microphonePermissionGranted = true
            result.microphonePermissionDetermined = true
        case .denied, .restricted:
            result.microphonePermissionGranted = false
            result.microphonePermissionDetermined = true
        case .notDetermined:
            result.microphonePermissionGranted = false
            result.microphonePermissionDetermined = false
        @unknown default:
            result.microphonePermissionGranted = false
            result.microphonePermissionDetermined = false
        }
    }
    
    // MARK: - Helper Methods
    
    /// Get a human-readable summary of the current state
    func getSummary() -> String {
        let d = diagnostics
        var lines: [String] = []
        
        lines.append("=== Airwave Diagnostics ===")
        lines.append("")
        
        // Virtual driver
        if d.virtualDriverInstalled {
            lines.append("✅ Virtual Audio Driver: \(d.detectedVirtualDrivers.joined(separator: ", "))")
        } else {
            lines.append("❌ Virtual Audio Driver: Not installed")
            lines.append("   → Install BlackHole from \(ConfigurationManager.ExternalLinks.blackHoleDownload.absoluteString)")
        }
        
        // Aggregate devices
        if d.validAggregateExists {
            lines.append("✅ Aggregate Device: Configured (\(d.aggregateCount) found)")
        } else if d.aggregateDevicesExist {
            lines.append("⚠️ Aggregate Device: Found but missing input or output")
            for health in d.aggregateHealth {
                lines.append("   • \(health.name): Input=\(health.hasInput ? "✓" : "✗") Output=\(health.hasOutput ? "✓" : "✗")")
            }
        } else {
            lines.append("❌ Aggregate Device: None found")
            lines.append("   → Create one in Audio MIDI Setup")
        }
        
        // Permissions
        if d.microphonePermissionGranted {
            lines.append("✅ Microphone Permission: Granted")
        } else if d.microphonePermissionDetermined {
            lines.append("❌ Microphone Permission: Denied")
            lines.append("   → Enable in System Settings → Privacy & Security → Microphone")
        } else {
            lines.append("⚠️ Microphone Permission: Not yet requested")
        }
        
        lines.append("")
        lines.append(d.isFullyConfigured ? "Status: Ready to use" : "Status: Setup required")
        
        return lines.joined(separator: "\n")
    }
}

// MARK: - Core Audio Callbacks

/// Callback function for aggregate device sub-device list changes
private func aggregateSubDeviceChangeCallback(
    _ inObjectID: AudioObjectID,
    _ inNumberAddresses: UInt32,
    _ inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else {
        return noErr
    }
    
    let manager = Unmanaged<SystemDiagnosticsManager>.fromOpaque(clientData).takeUnretainedValue()
    
    DispatchQueue.main.async {
        Logger.log("[Diagnostics] Aggregate sub-device list changed, refreshing...")
        manager.refresh()
    }
    
    return noErr
}
