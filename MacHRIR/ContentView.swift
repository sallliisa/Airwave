//
//  ContentView.swift
//  MacHRIR
//
//  Main application interface
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var audioManager = AudioGraphManager()
    @StateObject private var hrirManager = HRIRManager()
    @StateObject private var deviceManager = AudioDeviceManager.shared
    @State private var settingsManager = SettingsManager()

    @State private var showingError = false
    @State private var isInitialized = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
                Text("MacHRIR")
                    .font(.title)
                    .fontWeight(.bold)
            }
            .padding(.top)

            Divider()

            // Device Selection Section
            VStack(alignment: .leading, spacing: 15) {
                Text("Audio Devices")
                    .font(.headline)

                // Input Device Selector
                HStack {
                    Picker("Input Device", selection: Binding(
                        get: { audioManager.inputDevice },
                        set: { 
                            if let device = $0 { 
                                audioManager.selectInputDevice(device)
                                saveSettings()
                            } 
                        }
                    )) {
                        Text("Select Input...").tag(nil as AudioDevice?)
                        ForEach(deviceManager.inputDevices) { device in
                            Text(device.name).tag(device as AudioDevice?)
                        }
                    }
                    .frame(width: 300)
                }

                // Output Device Selector
                HStack {
                    Picker("Output Device", selection: Binding(
                        get: { audioManager.outputDevice },
                        set: { 
                            if let device = $0 { 
                                audioManager.selectOutputDevice(device)
                                saveSettings()
                            } 
                        }
                    )) {
                        Text("Select Output...").tag(nil as AudioDevice?)
                        ForEach(deviceManager.outputDevices) { device in
                            Text(device.name).tag(device as AudioDevice?)
                        }
                    }
                    .frame(width: 300)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)

            Divider()

            // HRIR Preset Section
            VStack(alignment: .leading, spacing: 15) {
                Text("HRIR Presets")
                    .font(.headline)

                HStack {
                    Picker("Preset", selection: Binding(
                        get: { hrirManager.activePreset },
                        set: { 
                            if let preset = $0 {
                                let sampleRate = audioManager.outputDevice?.sampleRate ?? 48000.0
                                let inputLayout = InputLayout.detect(channelCount: 2) // Will be updated when audio starts
                                hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
                                saveSettings()
                            } 
                        }
                    )) {
                        Text("None").tag(nil as HRIRPreset?)
                        ForEach(hrirManager.presets) { preset in
                            Text(preset.name).tag(preset as HRIRPreset?)
                        }
                    }
                    .frame(width: 200)

                    Button("Open HRIR Folder") {
                        hrirManager.openPresetsDirectory()
                    }

                    // if hrirManager.activePreset != nil {
                    //     Button("Remove") {
                    //         if let preset = hrirManager.activePreset {
                    //             hrirManager.removePreset(preset)
                    //         }
                    //     }
                    //     .foregroundColor(.red)
                    // }
                }

                // Convolution Toggle
                HStack {
                    Text("Convolution:")
                        .frame(width: 120, alignment: .trailing)
                    Toggle("Enable HRIR Processing", isOn: Binding(
                        get: { hrirManager.convolutionEnabled },
                        set: { 
                            hrirManager.convolutionEnabled = $0
                            saveSettings()
                        }
                    ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(hrirManager.activePreset == nil)

                    if hrirManager.activePreset == nil {
                        Text("(Select a preset first)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)

            Divider()

            // Control Buttons and Status
            HStack(spacing: 20) {
                Button(action: {
                    if audioManager.isRunning {
                        audioManager.stop()
                        saveSettings()
                    } else {
                        audioManager.start()
                        saveSettings()
                    }
                }) {
                    HStack {
                        Image(systemName: audioManager.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        Text(audioManager.isRunning ? "Stop" : "Start")
                    }
                    .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(audioManager.inputDevice == nil || audioManager.outputDevice == nil)

                // Status Indicator
                HStack {
                    Circle()
                        .fill(audioManager.isRunning ? Color.green : Color.gray)
                        .frame(width: 12, height: 12)
                    Text(audioManager.isRunning ? "Running" : "Stopped")
                        .font(.subheadline)
                }
            }
            .padding()

            // Error Message
            if let error = audioManager.errorMessage ?? hrirManager.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }
            
            // Device Change Notification
            if let notification = deviceManager.deviceChangeNotification {
                Text(notification)
                    .foregroundColor(.blue)
                    .font(.caption)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 600, minHeight: 600)
        .onAppear {
            print("[ContentView] onAppear called")
            if !isInitialized {
                // Connect HRIR manager to audio manager
                audioManager.hrirManager = hrirManager
                isInitialized = true
            }
            
            // Wait a bit for device lists to populate, then load settings
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                print("[ContentView] Device lists ready - Input: \(deviceManager.inputDevices.count), Output: \(deviceManager.outputDevices.count)")
                loadSettings()
                
                // Auto-start engine if it was running when app was last closed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    print("[ContentView] Checking auto-start...")
                    let settings = settingsManager.loadSettings()
                    print("[ContentView] Auto-start enabled: \(settings.autoStart)")
                    print("[ContentView] Input device: \(audioManager.inputDevice?.name ?? "nil")")
                    print("[ContentView] Output device: \(audioManager.outputDevice?.name ?? "nil")")
                    
                    if settings.autoStart && audioManager.inputDevice != nil && audioManager.outputDevice != nil {
                        print("[ContentView] Auto-starting audio engine...")
                        audioManager.start()
                    } else {
                        print("[ContentView] Not auto-starting (autoStart=\(settings.autoStart), hasInput=\(audioManager.inputDevice != nil), hasOutput=\(audioManager.outputDevice != nil))")
                    }
                }
            }
        }
        .onDisappear {
            print("[ContentView] onDisappear called - saving final settings")
            saveSettings()
        }
        .onChange(of: deviceManager.inputDevices) { _ in
            handleDeviceListChange()
        }
        .onChange(of: deviceManager.outputDevices) { _ in
            handleDeviceListChange()
        }
    }

    // MARK: - Helper Methods
    
    private func handleDeviceListChange() {
        // Check if currently selected input device is still available
        if let currentInput = audioManager.inputDevice,
           !deviceManager.inputDevices.contains(where: { $0.id == currentInput.id }) {
            // Input device disconnected - stop audio and show error
            if audioManager.isRunning {
                audioManager.stop()
            }
            audioManager.errorMessage = "Input device '\(currentInput.name)' was disconnected. Please select a new input device."
        }
        
        // Check if currently selected output device is still available
        if let currentOutput = audioManager.outputDevice,
           !deviceManager.outputDevices.contains(where: { $0.id == currentOutput.id }) {
            // Output device disconnected - try to switch to next available
            if audioManager.isRunning {
                switchToNextOutputDevice(disconnectedDevice: currentOutput)
            }
        }
    }
    
    private func switchToNextOutputDevice(disconnectedDevice: AudioDevice) {
        // Prefer system default output
        var newOutput = deviceManager.defaultOutputDevice
        
        // If default is not available, use first available output
        if newOutput == nil || !deviceManager.outputDevices.contains(where: { $0.id == newOutput?.id }) {
            newOutput = deviceManager.outputDevices.first
        }
        
        guard let newDevice = newOutput else {
            // No output devices available
            audioManager.stop()
            audioManager.errorMessage = "Output device '\(disconnectedDevice.name)' was disconnected and no other output devices are available."
            return
        }
        
        // Switch to new output device
        audioManager.selectOutputDevice(newDevice)
        
        // Show notification
        deviceManager.deviceChangeNotification = "Output switched to '\(newDevice.name)' (previous device disconnected)"
        
        // Clear notification after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            deviceManager.deviceChangeNotification = nil
        }
    }

    private func loadSettings() {
        print("[ContentView] loadSettings() called")
        let settings = settingsManager.loadSettings()
        
        // Log available devices
        print("[ContentView] Available input devices:")
        for device in deviceManager.inputDevices {
            print("  - ID: \(device.id), Name: \(device.name)")
        }
        print("[ContentView] Available output devices:")
        for device in deviceManager.outputDevices {
            print("  - ID: \(device.id), Name: \(device.name)")
        }

        // Restore input device
        if let deviceID = settings.selectedInputDeviceID,
           let device = deviceManager.inputDevices.first(where: { $0.id == deviceID }) {
            print("[ContentView] Restoring input device: \(device.name)")
            audioManager.selectInputDevice(device)
        } else {
            print("[ContentView] Saved input device ID \(settings.selectedInputDeviceID?.description ?? "nil") not found, trying BlackHole...")
            // Try to select BlackHole as default input if available
            if let blackHole = deviceManager.inputDevices.first(where: { $0.name.contains("BlackHole") }) {
                print("[ContentView] Selected BlackHole as input: \(blackHole.name)")
                audioManager.selectInputDevice(blackHole)
            } else {
                print("[ContentView] No BlackHole device found")
            }
        }

        // Restore output device
        if let deviceID = settings.selectedOutputDeviceID,
           let device = deviceManager.outputDevices.first(where: { $0.id == deviceID }) {
            print("[ContentView] Restoring output device: \(device.name)")
            audioManager.selectOutputDevice(device)
        } else {
            print("[ContentView] Saved output device not found, using system default...")
            // Select system default output
            if let defaultOutput = deviceManager.defaultOutputDevice {
                print("[ContentView] Selected default output: \(defaultOutput.name)")
                audioManager.selectOutputDevice(defaultOutput)
            } else {
                print("[ContentView] No default output device found")
            }
        }

        // Restore active preset
        if let presetID = settings.activePresetID,
           let preset = hrirManager.presets.first(where: { $0.id == presetID }) {
            print("[ContentView] Restoring HRIR preset: \(preset.name)")
            let inputLayout = InputLayout.detect(channelCount: 2) // Will be updated when audio starts
            hrirManager.activatePreset(preset, targetSampleRate: settings.targetSampleRate, inputLayout: inputLayout)
        } else {
            print("[ContentView] No saved preset or preset not found")
        }

        // Restore convolution state
        print("[ContentView] Restoring convolution enabled: \(settings.convolutionEnabled)")
        hrirManager.convolutionEnabled = settings.convolutionEnabled
    }

    private func saveSettings() {
        print("[ContentView] saveSettings() called")
        print("[ContentView] Current state - Running: \(audioManager.isRunning), Input: \(audioManager.inputDevice?.name ?? "nil"), Output: \(audioManager.outputDevice?.name ?? "nil")")
        
        let settings = AppSettings(
            selectedInputDeviceID: audioManager.inputDevice?.id,
            selectedOutputDeviceID: audioManager.outputDevice?.id,
            activePresetID: hrirManager.activePreset?.id,
            convolutionEnabled: hrirManager.convolutionEnabled,
            autoStart: audioManager.isRunning,
            bufferSize: 65536,
            targetSampleRate: audioManager.outputDevice?.sampleRate ?? 48000.0
        )
        settingsManager.saveSettings(settings)
    }
}

#Preview {
    ContentView()
}
