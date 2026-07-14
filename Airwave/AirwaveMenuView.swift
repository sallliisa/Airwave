import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject private var runtime = AudioRuntimeState.shared

    var body: some View {
        Image(systemName: runtime.status.isProcessing ? "waveform.circle.fill" : "waveform.circle")
            .accessibilityLabel("Airwave: \(runtime.status.title)")
    }
}

struct AirwaveMenuView: View {
    @EnvironmentObject private var viewModel: MenuBarViewModel
    @ObservedObject private var runtime = AudioRuntimeState.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(runtime.status.title)
                    .font(.headline)
                Text(runtime.status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if hrirManager.presets.isEmpty {
                Text("No HRIR presets found")
                    .foregroundStyle(.secondary)
            } else {
                Picker("HRIR preset", selection: Binding(
                    get: { hrirManager.activePreset?.id },
                    set: { id in
                        guard let preset = hrirManager.presets.first(where: { $0.id == id }) else { return }
                        viewModel.selectPreset(preset)
                    }
                )) {
                    Text("None").tag(UUID?.none)
                    ForEach(hrirManager.presets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
            }

            Button("Manage HRIR Presets") {
                viewModel.openPresetsDirectory()
            }

            Divider()

            HStack {
                Button("Settings") { openWindow(id: "settings") }
                Spacer()
                Button("About") { viewModel.showAbout() }
                Button("Quit") { viewModel.quitApp() }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
