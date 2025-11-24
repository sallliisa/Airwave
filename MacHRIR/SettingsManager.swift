//
//  SettingsManager.swift
//  MacHRIR
//
//  UserDefaults-based settings persistence (sandbox-compatible)
//

import Foundation
import CoreAudio

/// Application settings
struct AppSettings: Codable {
    // Device persistence using UIDs (persistent across reconnections)
    var aggregateDeviceUID: String?
    var selectedOutputDeviceUID: String?
    
    // Legacy fields for migration (deprecated)
    var aggregateDeviceID: UInt32?
    var selectedOutputDeviceID: UInt32?
    
    var activePresetID: UUID?
    var convolutionEnabled: Bool
    var autoStart: Bool
    var bufferSize: Int
    var targetSampleRate: Double

    static var `default`: AppSettings {
        return AppSettings(
            aggregateDeviceUID: nil,
            selectedOutputDeviceUID: nil,
            aggregateDeviceID: nil,
            selectedOutputDeviceID: nil,
            activePresetID: nil,
            convolutionEnabled: false,
            autoStart: false,
            bufferSize: 65536,
            targetSampleRate: 48000.0
        )
    }
    
    // MARK: - Migration Helpers
    
    /// Returns true if this settings instance needs migration from device IDs to UIDs
    var needsUIDMigration: Bool {
        return (aggregateDeviceID != nil || selectedOutputDeviceID != nil) &&
               (aggregateDeviceUID == nil || selectedOutputDeviceUID == nil)
    }
    
    /// Migrate device IDs to UIDs using provided lookup functions
    mutating func migrateToUIDs(
        aggregateLookup: (UInt32) -> String?,
        outputLookup: (UInt32) -> String?
    ) {
        if let deviceID = aggregateDeviceID, aggregateDeviceUID == nil {
            aggregateDeviceUID = aggregateLookup(deviceID)
            print("[Settings] Migrated aggregate device ID \(deviceID) to UID: \(aggregateDeviceUID ?? "nil")")
        }
        
        if let deviceID = selectedOutputDeviceID, selectedOutputDeviceUID == nil {
            selectedOutputDeviceUID = outputLookup(deviceID)
            print("[Settings] Migrated output device ID \(deviceID) to UID: \(selectedOutputDeviceUID ?? "nil")")
        }
        
        // Clear old IDs after migration
        if aggregateDeviceUID != nil {
            aggregateDeviceID = nil
        }
        if selectedOutputDeviceUID != nil {
            selectedOutputDeviceID = nil
        }
    }
}


/// Manages application settings persistence using UserDefaults
class SettingsManager {
    
    // Singleton instance for easy access
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard
    private let settingsKey = "MacHRIR.AppSettings"
    
    private var cachedSettings: AppSettings?
    private var saveWorkItem: DispatchWorkItem?

    init() {
        print("[Settings] Initialized with UserDefaults")
    }

    /// Load settings from memory cache or UserDefaults
    func loadSettings() -> AppSettings {
        if let settings = cachedSettings {
            return settings
        }
        let settings = loadSettingsFromDisk()
        cachedSettings = settings
        return settings
    }

    /// Load settings from UserDefaults (internal)
    private func loadSettingsFromDisk() -> AppSettings {
        print("[Settings] Loading settings from UserDefaults")
        
        guard let data = defaults.data(forKey: settingsKey) else {
            print("[Settings] No settings found in UserDefaults, using defaults")
            return .default
        }
        
        // Try to decode new schema
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            print("[Settings] Loaded settings from disk")
            return settings
        }
        
        // Migration: If we fail to decode, it might be the old schema.
        print("[Settings] Failed to decode settings (possible schema mismatch). Resetting to defaults.")
        return .default
    }

    /// Save settings to memory cache and schedule disk write
    func saveSettings(_ settings: AppSettings) {
        cachedSettings = settings
        debounceSave()
    }
    
    private func debounceSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Write cached settings to UserDefaults
    private func flush() {
        guard let settings = cachedSettings else { return }
        
        print("[Settings] Saving settings to UserDefaults:")
        print("  - Aggregate Device ID: \(settings.aggregateDeviceID?.description ?? "nil")")
        print("  - Output Device ID: \(settings.selectedOutputDeviceID?.description ?? "nil")")
        print("  - Active Preset ID: \(settings.activePresetID?.uuidString ?? "nil")")
        print("  - Convolution Enabled: \(settings.convolutionEnabled)")
        print("  - Auto Start: \(settings.autoStart)")
        
        guard let data = try? JSONEncoder().encode(settings) else {
            print("[Settings] Failed to encode settings")
            return
        }

        defaults.set(data, forKey: settingsKey)
        // defaults.synchronize() is unnecessary in modern macOS
    }
    
    // MARK: - Helper Methods
    
    func setAggregateDevice(_ deviceID: AudioDeviceID) {
        var settings = loadSettings()
        settings.aggregateDeviceID = deviceID
        saveSettings(settings)
    }
    
    func getAggregateDevice() -> AudioDeviceID? {
        return loadSettings().aggregateDeviceID
    }
    
    func setOutputDevice(_ deviceID: AudioDeviceID) {
        var settings = loadSettings()
        settings.selectedOutputDeviceID = deviceID
        saveSettings(settings)
    }
    
    func getOutputDevice() -> AudioDeviceID? {
        return loadSettings().selectedOutputDeviceID
    }
}
