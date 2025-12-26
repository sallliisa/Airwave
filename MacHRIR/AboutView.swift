//
//  AboutView.swift
//  MacHRIR
//
//  Custom About window with tabs for About and Diagnostics
//

import SwiftUI

struct AboutView: View {
    @State private var selectedTab: AboutTab = .about
    
    enum AboutTab: String, CaseIterable {
        case about = "About"
        case diagnostics = "Diagnostics"
        
        var icon: String {
            switch self {
            case .about: return "info.circle"
            case .diagnostics: return "stethoscope"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab Picker
            Picker("", selection: $selectedTab) {
                ForEach(AboutTab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            // Tab Content
            Group {
                switch selectedTab {
                case .about:
                    AboutContentView()
                case .diagnostics:
                    DiagnosticsContentView()
                }
            }
        }
        .frame(width: 500, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - About Content

struct AboutContentView: View {
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    
    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // App Icon
            if let appIcon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
            }
            
            // App Name
            Text("MacHRIR")
                .font(.system(size: 28, weight: .bold))
            
            // Version
            Text("Version \(appVersion) (\(buildNumber))")
                .font(.callout)
                .foregroundStyle(.secondary)
            
            // Description
            Text("System-wide HRIR-based spatial audio processing for macOS")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
            
            // Links
            HStack(spacing: 16) {
                Button("GitHub") {
                    if let url = URL(string: "https://github.com") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                
                Button("BlackHole Audio") {
                    if let url = URL(string: "https://existential.audio/blackhole/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
            
            // Copyright
            Text("© 2025 MacHRIR. All rights reserved.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Diagnostics Content (Embedded version)

struct DiagnosticsContentView: View {
    @StateObject private var diagnosticsManager = SystemDiagnosticsManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with refresh
            HStack {
                Text("System Diagnostics")
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
                .disabled(diagnosticsManager.isRefreshing)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    // Overall Status
                    overallStatusCard
                    
                    // Checklist
                    checklistSection
                    
                    // Aggregate Device Details
                    if !diagnosticsManager.diagnostics.aggregateHealth.isEmpty {
                        aggregateDetailsSection
                    }
                    
                    // Copy diagnostics button
                    HStack {
                        Spacer()
                        Button("Copy Diagnostics to Clipboard") {
                            let summary = diagnosticsManager.getSummary()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summary, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(.top, 8)
                }
                .padding(24)
            }
        }
    }
    
    // MARK: - Subviews
    
    private var overallStatusCard: some View {
        let diagnostics = diagnosticsManager.diagnostics
        let isReady = diagnostics.isFullyConfigured
        
        return HStack(spacing: 12) {
            Image(systemName: isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(isReady ? .green : .orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isReady ? "Ready to Use" : "Setup Required")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isReady ? .green : .orange)
                
                Text(isReady ? "All requirements met." : "Complete the checklist below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isReady ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isReady ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var checklistSection: some View {
        VStack(spacing: 0) {
            // Virtual Audio Driver
            CompactChecklistRow(
                title: "Virtual Audio Driver",
                subtitle: diagnosticsManager.diagnostics.virtualDriverInstalled
                    ? diagnosticsManager.diagnostics.detectedVirtualDrivers.joined(separator: ", ")
                    : "Install BlackHole or similar",
                status: diagnosticsManager.diagnostics.virtualDriverInstalled ? .complete : .missing,
                actionTitle: diagnosticsManager.diagnostics.virtualDriverInstalled ? nil : "Get BlackHole",
                action: {
                    if let url = URL(string: "https://existential.audio/blackhole/") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
            
            Divider().padding(.leading, 36)
            
            // Aggregate Device
            CompactChecklistRow(
                title: "Aggregate Device",
                subtitle: aggregateSubtitle,
                status: aggregateStatus,
                actionTitle: diagnosticsManager.diagnostics.validAggregateExists ? nil : "Audio MIDI Setup",
                action: {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                }
            )
            
            Divider().padding(.leading, 36)
            
            // Microphone Permission
            CompactChecklistRow(
                title: "Microphone Permission",
                subtitle: micPermissionSubtitle,
                status: micPermissionStatus,
                actionTitle: !diagnosticsManager.diagnostics.microphonePermissionGranted ? "Settings" : nil,
                action: {
                    PermissionManager.shared.openSystemSettings()
                }
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
    
    private var aggregateDetailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aggregate Devices")
                .font(.subheadline.weight(.medium))
            
            ForEach(diagnosticsManager.diagnostics.aggregateHealth) { health in
                CompactAggregateRow(health: health)
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var aggregateSubtitle: String {
        let d = diagnosticsManager.diagnostics
        if d.validAggregateExists {
            return "\(d.aggregateCount) configured"
        } else if d.aggregateDevicesExist {
            return "Needs input + output devices"
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
            return "Denied"
        } else {
            return "Not requested"
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

// MARK: - Compact Checklist Row

struct CompactChecklistRow: View {
    let title: String
    let subtitle: String
    let status: ChecklistStatus
    var actionTitle: String?
    var action: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.icon)
                .font(.system(size: 16))
                .foregroundStyle(status.color)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Compact Aggregate Row

struct CompactAggregateRow: View {
    let health: AggregateHealth
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: health.isValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(health.isValid ? .green : .orange)
            
            Text(health.name)
                .font(.system(size: 11, weight: .medium))
            
            Spacer()
            
            HStack(spacing: 6) {
                Label("\(health.inputDeviceCount)", systemImage: "mic.fill")
                Label("\(health.outputDeviceCount)", systemImage: "speaker.wave.2.fill")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - About Window Controller

class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About MacHRIR"
        window.center()
        window.contentView = NSHostingView(rootView: AboutView())
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func showAbout() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func showDiagnostics() {
        // Open the window and switch to diagnostics tab
        showAbout()
        // Note: We'd need to pass state to switch tabs, but for now just open the window
    }
}

#Preview {
    AboutView()
}
