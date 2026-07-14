import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject private var runtime = AudioRuntimeState.shared
    @ObservedObject private var onboarding = OnboardingViewModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let presentation = RuntimeMenuPresentation.make(from: runtime.status)
        Image(systemName: presentation.iconName)
            .accessibilityLabel("Airwave: \(presentation.healthTitle)")
            .task {
                if onboarding.shouldPresentAutomatically {
                    openWindow(id: "onboarding")
                }
            }
    }
}

struct AirwaveMenuView: View {
    @EnvironmentObject private var viewModel: MenuBarViewModel
    @ObservedObject private var runtime = AudioRuntimeState.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let presentation = RuntimeMenuPresentation.make(from: runtime.status)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: presentation.iconName)
                    .foregroundStyle(runtime.status.isProcessing ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.healthTitle).font(.headline)
                    Text(presentation.healthDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if presentation.canRetry {
                Button("Retry") { viewModel.retryAudio() }
            }

            Divider()

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

            LabeledContent("Current output", value: runtime.currentOutput?.name ?? "Not available")
                .font(.caption)

            Divider()

            HStack {
                Button("Settings") { openWindow(id: "settings") }
                Spacer()
                Button("Quit") { viewModel.quitApp() }
            }
        }
        .padding(16)
        .frame(width: 350)
    }
}
