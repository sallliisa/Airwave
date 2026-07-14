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

struct SettingsView: View {
    @ObservedObject private var runtime = AudioRuntimeState.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared

    var body: some View {
        Form {
            Section("Audio runtime") {
                LabeledContent("Status", value: runtime.status.title)
                Text(runtime.status.detail)
                    .foregroundStyle(.secondary)
            }

            Section("HRIR presets") {
                LabeledContent("Available", value: "\(hrirManager.presets.count)")
                Button("Manage Preset Files") {
                    hrirManager.openPresetsDirectory()
                }
            }

            Section("Application") {
                Toggle("Launch at login", isOn: $launchAtLogin.isEnabled)
                LabeledContent("Version", value: updateManager.installedVersion)
                Button("Check for Updates") {
                    updateManager.checkForUpdates()
                }
                .disabled(!updateManager.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560, height: 420)
        .background(SettingsWindowAccessor())
    }
}
