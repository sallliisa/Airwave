//
//  SettingsView.swift
//  Airwave
//
//  Shows a checklist of setup requirements for the app
//

import SwiftUI
import AppKit
private typealias PlatformColor = NSColor
import AppKit
import CoreAudio

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowObservingView {
        let view = SettingsWindowObservingView()
        view.onWindowAvailable = { window in
            SettingsWindowPresenter.present(window)
        }
        return view
    }

    func updateNSView(_ nsView: SettingsWindowObservingView, context: Context) {}
}

private final class SettingsWindowObservingView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window else { return }
        onWindowAvailable?(window)
    }
}

struct SettingsView: View {
    // Shared singleton instances - not owned by this view
    @ObservedObject private var diagnosticsManager = SystemDiagnosticsManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @ObservedObject private var audioManager = AudioGraphManager.shared
    @ObservedObject private var deviceManager = AudioDeviceManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var onboardingViewModel = OnboardingViewModel.shared
    @Environment(\.openWindow) private var openWindow
    
    // Inspector for aggregate device info
    private let inspector = AggregateDeviceInspector()
    
    // Static UUID for "None" option in HRIR picker
    private static let nonePresetID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    
    var body: some View {
        ZStack {
            AirwavePalette.canvas
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AirwaveLayout.sectionSpacing) {
                    pageHeader
                    overallStatusCard
                    generalSection
                    applicationSection
                    checklistSection

                    #if DEBUG
                    debugSection
                    #endif
                }
                .padding(.horizontal, 30)
                .padding(.top, 94)
                .padding(.bottom, 64)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            scrollEdgeFades

            VStack(spacing: 0) {
                topChrome
                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 650)
        .background(SettingsWindowAccessor())
        .preferredColorScheme(.dark)
        .tint(AirwavePalette.accent)
        .onAppear {
            guard !RuntimeEnvironment.useSelectionCoordinator else { return }
            // Start monitoring if there's already an aggregate device selected
            if let device = audioManager.aggregateDevice {
                deviceManager.startMonitoringAggregateDevice(device)
            }
            refreshAvailableOutputs()
            diagnosticsManager.refresh()
        }
        .onChange(of: audioManager.aggregateDevice?.id) {
            guard !RuntimeEnvironment.useSelectionCoordinator else { return }
            // Start monitoring the new aggregate device for sub-device changes
            if let device = audioManager.aggregateDevice {
                deviceManager.startMonitoringAggregateDevice(device)
            } else {
                deviceManager.stopMonitoringAggregateDevice()
            }
            refreshAvailableOutputs()
        }
        .onChange(of: deviceManager.aggregateDevices.count) {
            guard !RuntimeEnvironment.useSelectionCoordinator else { return }
            // Aggregate devices added/removed - validate current selection and refresh UI
            validateCurrentSelection()
            
            // Auto-select first aggregate device if none selected and devices became available
            if audioManager.aggregateDevice == nil && !deviceManager.aggregateDevices.isEmpty {
                if let firstDevice = deviceManager.aggregateDevices.first {
                    selectAggregateDevice(firstDevice)
                }
            }
            
            refreshAvailableOutputs()
        }
        .onChange(of: deviceManager.outputDevices.count) {
            guard !RuntimeEnvironment.useSelectionCoordinator else { return }
            // Output devices changed - refresh outputs for current aggregate (catches sub-device additions)
            refreshAvailableOutputs()
            diagnosticsManager.refresh()
        }
        .onChange(of: deviceManager.inputDevices.count) {
            guard !RuntimeEnvironment.useSelectionCoordinator else { return }
            // Input devices changed - refresh diagnostics
            diagnosticsManager.refresh()
        }
        .onChange(of: deviceManager.aggregateSubDeviceChangeCount) {
            guard !RuntimeEnvironment.useSelectionCoordinator else { return }
            // Sub-devices added/removed from the currently monitored aggregate device
            refreshAvailableOutputs()
            diagnosticsManager.refresh()
        }
    }
    
    // MARK: - Subviews

    private var topChrome: some View {
        HStack(spacing: 12) {
            Image("AirwaveIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
                .accessibilityLabel("Airwave")

            Text("Settings")
                .font(.headline)

            Spacer()

            AirwaveIconButton(
                systemImage: "arrow.clockwise",
                accessibilityLabel: "Refresh settings",
                help: diagnosticsManager.isRefreshing ? "Refreshing…" : "Refresh",
                isProminent: true,
                isEnabled: !diagnosticsManager.isRefreshing,
                action: refreshAll
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 24)
    }

    private var scrollEdgeFades: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: AirwavePalette.canvas, location: 0),
                    .init(color: AirwavePalette.canvas, location: 0.3),
                    .init(color: AirwavePalette.canvas.opacity(0.55), location: 0.58),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 112)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [.clear, AirwavePalette.canvas.opacity(0.94), AirwavePalette.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 58)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Airwave Settings")
                .font(.largeTitle.weight(.semibold))
            Text("Manage your audio route, spatial profile, and application preferences.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
    
    private var overallStatusCard: some View {
        let diagnostics = diagnosticsManager.diagnostics
        let isFullyConfigured = diagnostics.isFullyConfigured
        let isRunning = audioManager.isRunning
        let hasAggregateDevice = audioManager.aggregateDevice != nil
        let hasOutputDevice = audioManager.selectedOutputDevice != nil
        
        // Determine state:
        // WARNING: Diagnostics not fulfilled
        // INFO: Ready to run but not running (engine off, no aggregate/output device selected)
        // RUNNING: Actually running
        let (statusIcon, statusColor, statusTitle, statusMessage) = getStatusInfo(
            isFullyConfigured: isFullyConfigured,
            isRunning: isRunning,
            hasAggregateDevice: hasAggregateDevice,
            hasOutputDevice: hasOutputDevice
        )
        
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 18))
                .foregroundStyle(statusColor)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(statusColor)
                
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(13)
        .background(statusColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
    
    private func getStatusInfo(
        isFullyConfigured: Bool,
        isRunning: Bool,
        hasAggregateDevice: Bool,
        hasOutputDevice: Bool
    ) -> (icon: String, color: Color, title: String, message: String) {
        // WARNING: Diagnostics not fulfilled
        if !isFullyConfigured {
            return (
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                title: "Setup Required",
                message: "Some setup steps need to be completed before using Airwave."
            )
        }
        
        // RUNNING: Actually running
        if isRunning && hasAggregateDevice && hasOutputDevice {
            return (
                icon: "checkmark.seal.fill",
                color: .green,
                title: "Running",
                message: "Audio engine is active and processing audio."
            )
        }
        
        // INFO: Ready to run but not running
        return (
            icon: "info.circle.fill",
            color: .blue,
            title: "Ready to Use",
            message: "All requirements are met. Airwave is ready for audio processing."
        )
    }
    
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionSpacing) {
            sectionHeader("Audio Route", subtitle: "Choose where Airwave receives and sends audio.")
            
            VStack(spacing: 0) {
                // Aggregate Device Selector
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Aggregate Device")
                            .font(.system(size: 12))
                        Text(audioManager.aggregateDevice?.name ?? "Select an aggregate device")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if validAggregateDevices.isEmpty {
                        Text("No aggregate devices found")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: Binding(
                            get: { audioManager.aggregateDevice?.id ?? validAggregateDevices.first?.id },
                            set: { newID in
                                if let newID = newID,
                                   let device = validAggregateDevices.first(where: { $0.id == newID }) {
                                    selectAggregateDevice(device)
                                }
                            }
                        )) {
                            ForEach(validAggregateDevices, id: \.id) { device in
                                Text(device.name).tag(device.id as AudioDeviceID?)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                // Input Device Selector
                Divider().padding(.leading, 30)
                
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Input Device")
                            .font(.system(size: 12))
                        Text(audioManager.selectedInputDevice?.name ?? "Select an input device")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if audioManager.aggregateDevice == nil {
                        Text("Select aggregate device first")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if audioManager.availableInputs.isEmpty {
                        Text("No input devices in aggregate")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: Binding(
                            get: { audioManager.selectedInputDevice?.device.id ?? audioManager.availableInputs.first?.device.id },
                            set: { newID in
                                // Only process if this is a real user change, not just the Picker evaluating the binding
                                guard let currentID = audioManager.selectedInputDevice?.device.id else {
                                    // No current selection - this is initial setup, don't switch system audio
                                    if let newID = newID,
                                       let input = audioManager.availableInputs.first(where: { $0.device.id == newID }) {
                                        selectInputDevice(input, switchSystemAudio: false)
                                    }
                                    return
                                }
                                
                                // User explicitly changed the selection - allow system audio switch
                                if let newID = newID, newID != currentID,
                                   let input = audioManager.availableInputs.first(where: { $0.device.id == newID }) {
                                    selectInputDevice(input, switchSystemAudio: true)
                                }
                            }
                        )) {
                            ForEach(audioManager.availableInputs, id: \.device.id) { input in
                                Text(input.name).tag(input.device.id as AudioDeviceID?)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                // Output Device Selector (always shown)
                Divider().padding(.leading, 30)
                
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Output Device")
                            .font(.system(size: 12))
                        Text(audioManager.selectedOutputDevice?.name ?? "Select an output device")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if audioManager.aggregateDevice == nil {
                        Text("Select aggregate device first")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if audioManager.availableOutputs.isEmpty {
                        Text("No devices in aggregate")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: Binding(
                            get: { audioManager.selectedOutputDevice?.device.id ?? audioManager.availableOutputs.first?.device.id },
                            set: { newID in
                                if let newID = newID,
                                   let output = audioManager.availableOutputs.first(where: { $0.device.id == newID }) {
                                    selectOutputDevice(output)
                                }
                            }
                        )) {
                            ForEach(audioManager.availableOutputs, id: \.device.id) { output in
                                Text(output.name).tag(output.device.id as AudioDeviceID?)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                Divider().padding(.leading, 30)

                // HRIR Preset Selector
                HStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("HRIR Preset")
                            .font(.system(size: 12))
                        HStack(spacing: 4) {
                            Text("Spatial audio profile •")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Button(action: {
                                SystemSetupActions.shared.openHRIRFolder()
                            }) {
                                Text("Manage files")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    Spacer()
                    
                    Picker("", selection: Binding(
                        get: { hrirManager.activePreset?.id ?? Self.nonePresetID },
                        set: { newID in
                            if let preset = hrirManager.presets.first(where: { $0.id == newID }) {
                                let sampleRate = 48000.0
                                let inputLayout = InputLayout.detect(channelCount: 2)
                                hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
                            } else {
                                hrirManager.deactivatePreset()
                            }
                        }
                    )) {
                        Text("None").tag(Self.nonePresetID)
                        ForEach(hrirManager.presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                Divider().padding(.leading, 30)

                // Audio Engine Toggle
                HStack(spacing: 10) {
                    Image(audioManager.isRunning ? "MenuBarIcon.filled" : "MenuBarIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Audio Engine")
                            .font(.system(size: 12))
                        if !diagnosticsManager.diagnostics.isFullyConfigured {
                            Text("Complete diagnostics setup to continue")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        } else if audioManager.aggregateDevice == nil {
                            Text("Select a device to continue")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        } else {
                            Text(audioManager.isRunning ? "Processing audio" : "Stopped")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: Binding(
                        get: { audioManager.isRunning },
                        set: { shouldRun in
                            MenuBarViewModel.shared.setEngineRunning(shouldRun)
                        }
                    ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!diagnosticsManager.diagnostics.isFullyConfigured || audioManager.aggregateDevice == nil)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: 8))

            getMoreHRIRSection
        }
    }

    private var applicationSection: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionSpacing) {
            sectionHeader("Application", subtitle: "Control startup behavior and software updates.")
            VStack(spacing: 0) {
                // Run on Startup
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Run on Startup")
                            .font(.system(size: 12))
                        Text("Start Airwave automatically when you log in")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $launchAtLogin.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider().padding(.leading, 30)

                HStack(spacing: 10) {
                    Image(systemName: updateIconName)
                        .font(.system(size: 13))
                        .foregroundStyle(updateIconColor)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Software Update")
                            .font(.system(size: 12))
                        Text(updateStatusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    if case .checking = updateManager.state {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(updateButtonTitle) {
                            if case .available = updateManager.state {
                                updateManager.presentAvailableUpdate()
                            } else {
                                updateManager.checkForUpdates()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!updateManager.canCheckForUpdates)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var updateStatusText: String {
        switch updateManager.state {
        case .idle:
            return "Airwave \(updateManager.installedVersion)"
        case .checking:
            return "Checking for updates…"
        case .current:
            return "Airwave \(updateManager.installedVersion) is up to date"
        case .available(let version):
            return "Airwave \(version) is available"
        case .error(let message):
            return "Update check failed: \(message)"
        }
    }

    private var updateButtonTitle: String {
        if case .available = updateManager.state {
            return "Update…"
        }
        return "Check for Updates…"
    }

    private var updateIconName: String {
        switch updateManager.state {
        case .available:
            return "arrow.down.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        default:
            return "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private var updateIconColor: Color {
        switch updateManager.state {
        case .available:
            return .blue
        case .error:
            return .orange
        default:
            return .secondary
        }
    }
    
    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionSpacing) {
            sectionHeader("Diagnostics", subtitle: "Check the system requirements Airwave depends on.")

            VStack(spacing: AirwaveLayout.cardSpacing) {
                helpSection
                setupAirwaveSection

                VStack(spacing: 0) {
                    ChecklistRow(
                        title: "Virtual Audio Driver",
                        subtitle: diagnosticsManager.diagnostics.virtualDriverInstalled
                            ? diagnosticsManager.diagnostics.detectedVirtualDrivers.joined(separator: ", ")
                            : "BlackHole, Loopback, or Soundflower",
                        status: diagnosticsManager.diagnostics.virtualDriverInstalled ? .complete : .missing,
                        actionTitle: diagnosticsManager.diagnostics.virtualDriverInstalled ? nil : "Install BlackHole",
                        action: {
                            SystemSetupActions.shared.openBlackHoleDownload()
                        },
                        secondaryActionLink: ConfigurationManager.ExternalLinks.setupGuide,
                        secondaryActionLinkTitle: "Setup Guide"
                    )

                    Divider().padding(.leading, 30)

                    ChecklistRow(
                        title: "Aggregate Device",
                        subtitle: aggregateSubtitle,
                        status: aggregateStatus,
                        secondaryActionTitle: "Configure...",
                        secondaryAction: {
                            SystemSetupActions.shared.openAudioMIDISetup()
                        }
                    )

                    Divider().padding(.leading, 30)

                    ChecklistRow(
                        title: "Microphone Permission",
                        subtitle: micPermissionSubtitle,
                        status: micPermissionStatus,
                        secondaryActionTitle: "Configure...",
                        secondaryAction: {
                            SystemSetupActions.shared.openMicrophoneSettings()
                        }
                    )
                }
                .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var setupAirwaveSection: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checklist")
                .foregroundStyle(AirwavePalette.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Set Up Airwave Again")
                    .fontWeight(.semibold)
                Text("Reopen the guided setup to review your devices, permissions, and audio route.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("Open Setup") {
                onboardingViewModel.resume()
                openWindow(id: "onboarding")
                OnboardingWindowPresenter.presentExistingWindow()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(14)
        .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private var getMoreHRIRSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Get HRIR Presets")
                    .font(.system(size: 12, weight: .semibold))
                
                Spacer()
                
                Link(destination: ConfigurationManager.ExternalLinks.hrtfDatabase) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                        Text("Open HRTF Database")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.blue)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Airwave works with any HRIR compatible with HeSuVi. These HRIR presets can be obtained for free from the HRTF database.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }
    
    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Need Help?")
                .font(.system(size: 12, weight: .semibold))
            
            Text("Airwave requires a virtual audio driver (like BlackHole) and an aggregate device that combines it with your output device. This allows system audio to be processed through HRIR convolution before reaching your headphones.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }
    
    #if DEBUG
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionSpacing) {
            sectionHeader("Debug Info", subtitle: "Inspect the active channel mappings.")
            
            VStack(spacing: 0) {
                // Input Device
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Input Device")
                            .font(.system(size: 11, weight: .medium))
                        Text(audioManager.selectedInputDevice?.name ?? "None")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    // Show ACTUAL channels being read by engine
                    if let inputRange = audioManager.selectedInputChannelRange {
                        Text("Ch \(inputRange.lowerBound)-\(inputRange.upperBound - 1)")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                Divider().padding(.leading, 28)
                
                // Output Device
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Output Device")
                            .font(.system(size: 11, weight: .medium))
                        Text(audioManager.selectedOutputDevice?.name ?? "None")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    // Show ACTUAL channels being written by engine
                    if let outputRange = audioManager.selectedOutputChannelRange {
                        Text("Ch \(outputRange.lowerBound)-\(outputRange.upperBound - 1)")
                            .font(.system(size: 10))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    #endif

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Computed Properties
    
    private var aggregateSubtitle: String {
        let d = diagnosticsManager.diagnostics
        
        // State 1: No aggregate devices at all
        if !d.aggregateDevicesExist {
            return "Create in Audio MIDI Setup"
        }
        
        // Check all aggregates to determine the overall state
        let validCount = d.aggregateHealth.filter { $0.hasInput && $0.hasOutput }.count
        let invalidAggregates = d.aggregateHealth.filter { !$0.hasInput || !$0.hasOutput }
        
        // State 5: All aggregates are fully configured
        if validCount == d.aggregateCount && d.aggregateCount > 0 {
            return "\(d.aggregateCount) configured"
        }
        
        // States 2-4: Some or all aggregates need configuration
        // Check the first invalid aggregate to determine what's missing
        if let firstInvalid = invalidAggregates.first {
            let hasInput = firstInvalid.hasInput
            let hasOutput = firstInvalid.hasOutput
            
            if !hasInput && !hasOutput {
                // State 2: No input + output device in aggregate
                return "Found but needs input + output devices"
            } else if !hasInput {
                // State 3: No input device in aggregate
                return "Found but needs input device"
            } else if !hasOutput {
                // State 4: No output device in aggregate
                return "Found but needs output device"
            }
        }
        
        // Fallback (shouldn't reach here)
        return "Create in Audio MIDI Setup"
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
    
    // MARK: - Device Selection
    
    /// Get all aggregate devices (show all, validation happens on selection)
    private var validAggregateDevices: [AudioDevice] {
        deviceManager.aggregateDevices
    }
    
    /// Select an aggregate device and configure outputs
    private func selectAggregateDevice(_ device: AudioDevice) {
        if RuntimeEnvironment.useSelectionCoordinator {
            MenuBarViewModel.shared.selectAggregateDevice(device)
            return
        }
        // Stop audio if running
        let wasRunning = audioManager.isRunning
        if wasRunning {
            audioManager.stop()
        }
        
        audioManager.selectAggregateDevice(device)
        
        // Load available outputs
        do {
            let allOutputs = try inspector.getOutputDevices(aggregate: device)
            
            // Filter out virtual loopback devices
            audioManager.availableOutputs = filterAvailableOutputs(allOutputs)
            
            // Auto-select first output if available
            if let firstOutput = audioManager.availableOutputs.first {
                audioManager.selectedOutputDevice = firstOutput
                
                // Setup audio graph
                try audioManager.setupAudioUnit(
                    aggregateDevice: device,
                    outputChannelRange: firstOutput.stereoChannelRange
                )
            } else {
                audioManager.selectedOutputDevice = nil
            }
            
            // Restart if was running
            if wasRunning && audioManager.selectedOutputDevice != nil {
                audioManager.start()
            }
            
        } catch {
            Logger.log("Failed to configure aggregate device: \(error)")
        }
    }
    
    /// Select an output device
    private func selectOutputDevice(_ output: AggregateDeviceInspector.SubDeviceInfo) {
        // Use shared controller for consistent behavior (volume setting, etc.)
        MenuBarViewModel.shared.selectOutputDevice(output)
    }
    
    /// Select an input device
    /// - Parameter switchSystemAudio: Whether to switch system audio output to this device (default: true)
    private func selectInputDevice(_ input: AggregateDeviceInspector.SubDeviceInfo, switchSystemAudio: Bool = true) {
        if RuntimeEnvironment.useSelectionCoordinator {
            MenuBarViewModel.shared.selectionCoordinator?.selectInput(uid: input.uid)
            return
        }
        // VOLUME SYNC: Get volume from previous input device before switching
        var previousVolume: Float? = nil
        if let previousInput = audioManager.selectedInputDevice {
            previousVolume = AudioDeviceManager.shared.getDeviceVolume(previousInput.device)
            if let volume = previousVolume {
                Logger.log("[Settings] Previous input device volume: \(Int(volume * 100))%")
            }
        }
        
        audioManager.selectedInputDevice = input
        
        // Set the input channel range to the first 2 channels of the selected input device
        if let inputRange = input.inputChannelRange {
            let stereoRange = inputRange.lowerBound..<min(inputRange.lowerBound + 2, inputRange.upperBound)
            audioManager.setInputChannels(stereoRange)
        }
        
        // Only switch system audio output if explicitly requested AND audio engine is running
        if switchSystemAudio && audioManager.isRunning {
            // VOLUME SYNC: Set volume on new input device BEFORE switching to it
            if let volume = previousVolume {
                let volumeSet = AudioDeviceManager.shared.setDeviceVolume(input.device, volume: volume)
                if volumeSet {
                    Logger.log("[Settings] 🔊 Volume matched from previous input device (\(Int(volume * 100))%)")
                }
            }
            
            let success = AudioDeviceManager.shared.setSystemDefaultOutputDevice(input.device)
            if success {
                Logger.log("[Settings] System audio output switched to: \(input.name)")
            }
        }
        
        // Persist selection
        SettingsManager.shared.setInputDevice(input.device)
    }
    
    /// Refresh available outputs from current aggregate device
    private func refreshAvailableOutputs() {
        guard !RuntimeEnvironment.useSelectionCoordinator else { return }
        guard let currentAggregate = audioManager.aggregateDevice else {
            audioManager.availableOutputs = []
            audioManager.selectedOutputDevice = nil
            audioManager.availableInputs = []
            audioManager.selectedInputDevice = nil
            return
        }
        
        // Get fresh device reference from device manager to ensure we have latest sub-device info
        // The stored audioManager.aggregateDevice might be stale after device list refresh
        guard let freshDevice = deviceManager.aggregateDevices.first(where: { $0.id == currentAggregate.id }) else {
            // Device no longer exists - stop engine and clear selection
            if audioManager.isRunning {
                audioManager.stop()
            }
            audioManager.aggregateDevice = nil
            audioManager.availableOutputs = []
            audioManager.selectedOutputDevice = nil
            audioManager.availableInputs = []
            audioManager.selectedInputDevice = nil
            return
        }
        
        // Update the reference to the fresh device
        audioManager.aggregateDevice = freshDevice
        
        do {
            // Refresh outputs
            let allOutputs = try inspector.getOutputDevices(aggregate: freshDevice)
            
            // Filter out virtual loopback devices
            audioManager.availableOutputs = filterAvailableOutputs(allOutputs)
            
            // If no outputs available, stop the engine
            if audioManager.availableOutputs.isEmpty {
                if audioManager.isRunning {
                    audioManager.stop()
                }
                audioManager.selectedOutputDevice = nil
            } else {
                // Try to maintain current selection if it still exists
                if let currentOutput = audioManager.selectedOutputDevice,
                   let stillExists = audioManager.availableOutputs.first(where: { $0.device.id == currentOutput.device.id }) {
                    audioManager.selectedOutputDevice = stillExists
                } else if let firstOutput = audioManager.availableOutputs.first {
                    // Auto-select first output if current selection is gone
                    audioManager.selectedOutputDevice = firstOutput
                } else {
                    audioManager.selectedOutputDevice = nil
                }
            }
            
            // Refresh inputs
            let allInputs = try inspector.getInputDevices(aggregate: freshDevice)
            audioManager.availableInputs = allInputs
            
            // Try to maintain current input selection if it still exists
            if let currentInput = audioManager.selectedInputDevice,
               let stillExists = audioManager.availableInputs.first(where: { $0.device.id == currentInput.device.id }) {
                // Input still exists - just update the reference (don't call selectInputDevice to avoid re-triggering setup)
                audioManager.selectedInputDevice = stillExists
                
                // Update the input channel range in case it changed
                if let inputRange = stillExists.inputChannelRange {
                    let stereoRange = inputRange.lowerBound..<min(inputRange.lowerBound + 2, inputRange.upperBound)
                    audioManager.setInputChannels(stereoRange)
                }
                
                // Persist the input device to ensure it's saved
                SettingsManager.shared.setInputDevice(stillExists.device)
            } else if audioManager.availableInputs.isEmpty {
                // No inputs available - clear selection
                audioManager.selectedInputDevice = nil
            } else if let firstInput = audioManager.availableInputs.first {
                // Current selection is gone OR no selection - auto-select first available input
                // Switch system audio only if the audio engine is running (needs the new input for audio flow)
                selectInputDevice(firstInput, switchSystemAudio: audioManager.isRunning)
            }
            
            
        } catch {
            Logger.log("Failed to refresh outputs: \(error)")
            if audioManager.isRunning {
                audioManager.stop()
            }
            audioManager.availableOutputs = []
            audioManager.selectedOutputDevice = nil
            audioManager.availableInputs = []
            audioManager.selectedInputDevice = nil
        }
    }
    
    /// Refresh everything - device lists, outputs, and diagnostics
    private func refreshAll() {
        // Refresh system device lists
        deviceManager.refreshDevices()
        
        // Give device manager time to update, then refresh outputs and diagnostics
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.refreshAvailableOutputs()
            self.diagnosticsManager.refresh()
        }
    }
    
    /// Validate that current selections still exist in system device list
    private func validateCurrentSelection() {
        guard !RuntimeEnvironment.useSelectionCoordinator else { return }
        // If we had an aggregate selected but it no longer exists, clear it
        if let currentAggregate = audioManager.aggregateDevice {
            let stillExists = deviceManager.aggregateDevices.contains { $0.id == currentAggregate.id }
            if !stillExists {
                // Stop audio engine if running since aggregate device is gone
                if audioManager.isRunning {
                    audioManager.stop()
                }
                audioManager.aggregateDevice = nil
                audioManager.availableOutputs = []
                audioManager.selectedOutputDevice = nil
                audioManager.availableInputs = []
                audioManager.selectedInputDevice = nil
            }
        }
        diagnosticsManager.refresh()
    }
    
    /// Filter out virtual loopback devices (BlackHole, Soundflower, etc.)
    private func filterAvailableOutputs(_ allOutputs: [AggregateDeviceInspector.SubDeviceInfo]) -> [AggregateDeviceInspector.SubDeviceInfo] {
        DeviceOutputEligibility.filter(allOutputs)
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
    var secondaryActionLink: URL?
    var secondaryActionLinkTitle: String?
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.icon)
                .font(.system(size: 13))
                .foregroundStyle(status.color)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Secondary action link (if provided)
            if let secondaryActionLink = secondaryActionLink, let secondaryActionLinkTitle = secondaryActionLinkTitle {
                Link(destination: secondaryActionLink) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                        Text(secondaryActionLinkTitle)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.blue)
            }
            // Secondary action button (if provided and no link)
            else if let secondaryActionTitle = secondaryActionTitle, let secondaryAction = secondaryAction {
                Button(secondaryActionTitle) {
                    secondaryAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 11))
            }
            
            // Primary action button (conditional)
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

#Preview {
    SettingsView()
}
