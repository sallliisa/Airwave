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
    var selectedInputDeviceID: UInt32?
    var selectedOutputDeviceID: UInt32?
    var activePresetID: UUID?
    var convolutionEnabled: Bool
    var autoStart: Bool
    var bufferSize: Int
    var targetSampleRate: Double

    static var `default`: AppSettings {
        return AppSettings(
            selectedInputDeviceID: nil,
            selectedOutputDeviceID: nil,
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

    private let defaults = UserDefaults.standard
    private let settingsKey = "MacHRIR.AppSettings"

    init() {
        print("[Settings] Initialized with UserDefaults")
    }

    /// Load settings from UserDefaults
    func loadSettings() -> AppSettings {
        print("[Settings] Loading settings from UserDefaults")
        
        guard let data = defaults.data(forKey: settingsKey) else {
            print("[Settings] No settings found in UserDefaults, using defaults")
            return .default
        }
        
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            print("[Settings] Failed to decode settings from UserDefaults")
            return .default
        }
        
        print("[Settings] Loaded settings:")
        print("  - Input Device ID: \(settings.selectedInputDeviceID?.description ?? "nil")")
        print("  - Output Device ID: \(settings.selectedOutputDeviceID?.description ?? "nil")")
        print("  - Active Preset ID: \(settings.activePresetID?.uuidString ?? "nil")")
        print("  - Convolution Enabled: \(settings.convolutionEnabled)")
        print("  - Auto Start: \(settings.autoStart)")

        return settings
    }

    /// Save settings to UserDefaults
    func saveSettings(_ settings: AppSettings) {
        print("[Settings] Saving settings to UserDefaults:")
        print("  - Input Device ID: \(settings.selectedInputDeviceID?.description ?? "nil")")
        print("  - Output Device ID: \(settings.selectedOutputDeviceID?.description ?? "nil")")
        print("  - Active Preset ID: \(settings.activePresetID?.uuidString ?? "nil")")
        print("  - Convolution Enabled: \(settings.convolutionEnabled)")
        print("  - Auto Start: \(settings.autoStart)")
        
        guard let data = try? JSONEncoder().encode(settings) else {
            print("[Settings] Failed to encode settings")
            return
        }

        defaults.set(data, forKey: settingsKey)
        
        // Force synchronization to ensure data is written immediately
        if defaults.synchronize() {
            print("[Settings] Successfully saved and synchronized to UserDefaults")
        } else {
            print("[Settings] Warning: synchronize() returned false")
        }
    }
}
