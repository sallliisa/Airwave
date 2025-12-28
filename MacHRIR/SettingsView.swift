//
//  SettingsView.swift
//  MacHRIR
//
//  Shows a checklist of setup requirements for the app
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @StateObject private var diagnosticsManager = SystemDiagnosticsManager.shared
    @StateObject private var launchAtLogin = LaunchAtLoginManager.shared
    @StateObject private var hrirManager = HRIRManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.blue.gradient)
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    // General Settings
                    generalSection
                    
                    // Diagnostics (with status card inside)
                    checklistSection
                }
                .padding(24)
            }
        }
        .frame(width: 500, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Subviews
    
    private var overallStatusCard: some View {
        let diagnostics = diagnosticsManager.diagnostics
        let isReady = diagnostics.isFullyConfigured
        
        return HStack(spacing: 12) {
            Image(systemName: isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(isReady ? .green : .orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isReady ? "Ready to Use" : "Setup Required")
                    .font(.headline)
                    .foregroundStyle(isReady ? .green : .orange)
                
                Text(isReady ? "All requirements are met. MacHRIR is ready for audio processing." : "Some setup steps need to be completed before using MacHRIR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isReady ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isReady ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General")
                .font(.headline)
                .padding(.bottom, 12)
            
            VStack(spacing: 0) {
                // Run on Startup
                HStack(spacing: 12) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                        .frame(width: 32)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run on Startup")
                            .font(.system(size: 13, weight: .medium))
                        Text("Start MacHRIR automatically when you log in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $launchAtLogin.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                
                Divider().padding(.leading, 44)
                
                // HRIR Preset Selector
                HStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.purple)
                        .frame(width: 32)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HRIR Preset")
                            .font(.system(size: 13, weight: .medium))
                        Text("Select spatial audio profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Picker("", selection: Binding(
                        get: { hrirManager.activePreset?.id ?? UUID() },
                        set: { newID in
                            if let preset = hrirManager.presets.first(where: { $0.id == newID }) {
                                let sampleRate = 48000.0
                                let inputLayout = InputLayout.detect(channelCount: 2)
                                hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
                            } else {
                                hrirManager.activePreset = nil
                            }
                        }
                    )) {
                        Text("None").tag(UUID())
                        ForEach(hrirManager.presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                
                Divider().padding(.leading, 44)
                
                // Open HRIR Folder
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                        .frame(width: 32)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manage HRIRs")
                            .font(.system(size: 13, weight: .medium))
                        Text("Manage your HRIR preset files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("Open") {
                        hrirManager.openPresetsDirectory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }
    
    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Diagnostics")
                    .font(.headline)
                
                Spacer()
                
                Button(action: {
                    diagnosticsManager.refresh()
                }) {
                    HStack(spacing: 4) {
                        if diagnosticsManager.isRefreshing {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh")
                    }
                    .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(diagnosticsManager.isRefreshing)
            }
            .padding(.bottom, 12)
            
            // Overall Status Card
            overallStatusCard
                .padding(.bottom, 12)

            // Help Section
            helpSection
                .padding(.bottom, 12)
            
            VStack(spacing: 0) {
                // Virtual Audio Driver
                ChecklistRow(
                    title: "Virtual Audio Driver",
                    subtitle: diagnosticsManager.diagnostics.virtualDriverInstalled
                        ? diagnosticsManager.diagnostics.detectedVirtualDrivers.joined(separator: ", ")
                        : "BlackHole, Loopback, or Soundflower",
                    status: diagnosticsManager.diagnostics.virtualDriverInstalled ? .complete : .missing,
                    actionTitle: diagnosticsManager.diagnostics.virtualDriverInstalled ? nil : "Install BlackHole",
                    action: {
                        if let url = URL(string: "https://existential.audio/blackhole/") {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    secondaryActionTitle: "Setup Guide",
                    secondaryAction: {
                        if let url = URL(string: "https://github.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                
                Divider().padding(.leading, 44)
                
                // Aggregate Device
                ChecklistRow(
                    title: "Aggregate Device",
                    subtitle: aggregateSubtitle,
                    status: aggregateStatus,
                    actionTitle: diagnosticsManager.diagnostics.validAggregateExists ? nil : "Open Audio MIDI Setup",
                    action: {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                    },
                    secondaryActionTitle: "Configure...",
                    secondaryAction: {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                    }
                )
                
                Divider().padding(.leading, 44)
                
                // Microphone Permission
                ChecklistRow(
                    title: "Microphone Permission",
                    subtitle: micPermissionSubtitle,
                    status: micPermissionStatus,
                    secondaryActionTitle: "Configure...",
                    secondaryAction: {
                        PermissionManager.shared.openSystemSettings()
                    }
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }
    
    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Need Help?")
                .font(.headline)
            
            Text("MacHRIR requires a virtual audio driver (like BlackHole) and an aggregate device that combines it with your output device. This allows system audio to be processed through HRIR convolution before reaching your headphones.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
    
    // MARK: - Computed Properties
    
    private var aggregateSubtitle: String {
        let d = diagnosticsManager.diagnostics
        if d.validAggregateExists {
            return "\(d.aggregateCount) configured"
        } else if d.aggregateDevicesExist {
            return "Found but needs input + output devices"
        } else {
            return "Create in Audio MIDI Setup"
        }
    }
    
    private var aggregateStatus: ChecklistStatus {
        let d = diagnosticsManager.diagnostics
        if d.validAggregateExists {
            return .complete
        } else if d.aggregateDevicesExist {
            return .warning
        } else {
            return .missing
        }
    }
    
    private var micPermissionSubtitle: String {
        let d = diagnosticsManager.diagnostics
        if d.microphonePermissionGranted {
            return "Granted"
        } else if d.microphonePermissionDetermined {
            return "Denied - open System Settings to enable"
        } else {
            return "Not yet requested"
        }
    }
    
    private var micPermissionStatus: ChecklistStatus {
        let d = diagnosticsManager.diagnostics
        if d.microphonePermissionGranted {
            return .complete
        } else if d.microphonePermissionDetermined {
            return .missing
        } else {
            return .warning
        }
    }
}

// MARK: - Supporting Types

enum ChecklistStatus {
    case complete
    case warning
    case missing
    
    var color: Color {
        switch self {
        case .complete: return .green
        case .warning: return .orange
        case .missing: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .complete: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        }
    }
}

// MARK: - Checklist Row

struct ChecklistRow: View {
    let title: String
    let subtitle: String
    let status: ChecklistStatus
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.icon)
                .font(.system(size: 20))
                .foregroundStyle(status.color)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Secondary action button (always shown if provided)
            if let secondaryActionTitle = secondaryActionTitle, let secondaryAction = secondaryAction {
                Button(secondaryActionTitle) {
                    secondaryAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            // Primary action button (conditional)
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Aggregate Device Row

struct AggregateDeviceRow: View {
    let health: AggregateHealth
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: health.isValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(health.isValid ? .green : .orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(health.name)
                    .font(.system(size: 13, weight: .medium))
                
                HStack(spacing: 8) {
                    Label("\(health.inputDeviceCount) input", systemImage: "mic.fill")
                    Label("\(health.outputDeviceCount) output", systemImage: "speaker.wave.2.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                
                if !health.missingDevices.isEmpty {
                    Text("Missing: \(health.missingDevices.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Diagnostics Window Controller

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacHRIR Settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func showSettings() {
        // Refresh diagnostics when opening
        SystemDiagnosticsManager.shared.refresh()
        
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    SettingsView()
}
