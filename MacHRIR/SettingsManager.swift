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
    // DEPRECATED: Keep for backward compatibility
    var aggregateDeviceID: UInt32?
    var selectedOutputDeviceID: UInt32?

    // NEW: Persistent identifiers
    var aggregateDeviceUID: String?
    var selectedOutputDeviceUID: String?

    var activePresetID: UUID?
    var convolutionEnabled: Bool
    var autoStart: Bool
    var bufferSize: Int
    var targetSampleRate: Double

    static var `default`: AppSettings {
        return AppSettings(
            aggregateDeviceID: nil,
            selectedOutputDeviceID: nil,
            aggregateDeviceUID: nil,
            selectedOutputDeviceUID: nil,
            activePresetID: nil,
            convolutionEnabled: false,
            autoStart: false,
            bufferSize: 65536,
            targetSampleRate: 48000.0
        )
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
        print("  - Aggregate Device UID: \(settings.aggregateDeviceUID ?? "nil")")
        print("  - Output Device UID: \(settings.selectedOutputDeviceUID ?? "nil")")
        print("  - Active Preset ID: \(settings.activePresetID?.uuidString ?? "nil")")
        print("  - Convolution Enabled: \(settings.convolutionEnabled)")
        print("  - Auto Start: \(settings.autoStart)")

        guard let data = try? JSONEncoder().encode(settings) else {
            print("[Settings] Failed to encode settings")
            return
        }

        defaults.set(data, forKey: settingsKey)
    }
    
    // MARK: - Helper Methods
    
    func setAggregateDevice(_ device: AudioDevice) {
        guard let uid = device.uid else {
            print("[Settings] ⚠️ Could not get UID for device \(device.name)")
            return
        }
        var settings = loadSettings()
        settings.aggregateDeviceUID = uid
        saveSettings(settings)
    }

    func getAggregateDevice() -> AudioDevice? {
        guard let uid = loadSettings().aggregateDeviceUID else { return nil }
        return AudioDeviceManager.getDeviceByUID(uid)
    }

    func setOutputDevice(_ device: AudioDevice) {
        guard let uid = device.uid else {
            print("[Settings] ⚠️ Could not get UID for device \(device.name)")
            return
        }
        var settings = loadSettings()
        settings.selectedOutputDeviceUID = uid
        saveSettings(settings)
    }

    func getOutputDevice() -> AudioDevice? {
        guard let uid = loadSettings().selectedOutputDeviceUID else { return nil }
        return AudioDeviceManager.getDeviceByUID(uid)
    }
}
