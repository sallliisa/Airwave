import SwiftUI

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            SettingsWindowPresenter.register(window)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct OnboardingWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            OnboardingWindowPresenter.register(window)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SettingsView: View {
    @ObservedObject private var runtime = AudioRuntimeState.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @EnvironmentObject private var viewModel: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Health") {
                LabeledContent("Status", value: runtime.status.title)
                Text(runtime.status.detail).foregroundStyle(.secondary)
                LabeledContent("Current output", value: runtime.currentOutput?.name ?? "Not available")
                LabeledContent("Sample rate", value: sampleRate)
                LabeledContent("Process tap", value: runtime.status.isProcessing ? "Active" : "Inactive")
                if RuntimeMenuPresentation.make(from: runtime.status).canRetry {
                    Button("Retry Audio Setup") { viewModel.retryAudio() }
                }
                if runtime.status == .needsPermission {
                    Button("Open System Audio Recording Settings") {
                        viewModel.openSystemAudioRecordingSettings()
                    }
                }
            }

            Section("HRIR presets") {
                LabeledContent("Available", value: "\(hrirManager.presets.count)")
                LabeledContent("Selected", value: hrirManager.activePreset?.name ?? "None")
                Button("Manage Preset Files") { viewModel.openPresetsDirectory() }
                Button("Run Setup") {
                    openWindow(id: "onboarding")
                    OnboardingWindowPresenter.presentExistingWindow()
                }
            }

            Section("Application") {
                Toggle("Launch at login", isOn: $launchAtLogin.isEnabled)
                Text("Launch at login is off by default after upgrading to Airwave 2.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Version", value: updateManager.installedVersion)
                Button("Check for Updates") { updateManager.checkForUpdates() }
                    .disabled(!updateManager.canCheckForUpdates)
            }

            Section("About & Support") {
                Text("Airwave uses native macOS System Audio Recording and never changes your output device or its volume.")
                    .foregroundStyle(.secondary)
                Button("About Airwave") { viewModel.showAbout() }
                Button("Support") { viewModel.openSupport() }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 600, height: 620)
        .background(SettingsWindowAccessor())
    }

    private var sampleRate: String {
        guard let rate = runtime.currentOutput?.nominalSampleRate else { return "—" }
        return "\(Int(rate.rounded())) Hz"
    }
}
