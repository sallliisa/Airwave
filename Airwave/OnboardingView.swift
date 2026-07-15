import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject private var runtime = AudioRuntimeState.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                ForEach(OnboardingStepV2.allCases, id: \.self) { step in
                    Label(step.title, systemImage: step == viewModel.currentStep ? "circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(step == viewModel.currentStep ? .primary : .secondary)
                    if step != .liveHealth { Divider().frame(width: 18) }
                }
            }

            Divider()
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            HStack {
                Button("Back") { viewModel.goBack() }
                    .disabled(viewModel.currentStep == .welcome)
                Button("Finish Later") {
                    viewModel.finishLater()
                    dismiss()
                }
                Spacer()
                if viewModel.currentStep == .liveHealth {
                    Button("Start Using Airwave") {
                        if viewModel.complete() { dismiss() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canComplete)
                } else {
                    Button("Continue") { viewModel.advance() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 720, height: 480)
        .background(OnboardingWindowAccessor())
    }

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.currentStep {
        case .welcome:
            VStack(alignment: .leading, spacing: 12) {
                Text("Airwave 2").font(.largeTitle.bold())
                Text("Airwave now captures system audio with native macOS process taps. It never changes the system output device or its volume.")
                Label("macOS volume remains the only authoritative listening volume.", systemImage: "ear.badge.checkmark")
                Label("Keep playback paused while changing physical listening equipment.", systemImage: "exclamationmark.triangle")
            }
        case .systemAudio:
            VStack(alignment: .leading, spacing: 12) {
                Text("Allow System Audio Recording").font(.title2.bold())
                Text("macOS asks for this permission when Airwave performs a safe native-audio setup attempt. Microphone access is not used.")
                permissionStatus
                HStack {
                    Button("Allow System Audio Recording") { viewModel.requestPermission() }
                    if viewModel.permissionPresentation == .denied {
                        Button("Open Privacy Settings") { viewModel.openPermissionSettings() }
                        Button("Retry") { viewModel.retry() }
                    }
                }
            }
        case .hrirPreset:
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose an HRIR preset").font(.title2.bold())
                if hrirManager.presets.isEmpty {
                    Text("No presets were found. Add a compatible WAV file, then return here.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Preset", selection: Binding(
                        get: { hrirManager.activePreset?.id },
                        set: { id in
                            guard let preset = hrirManager.presets.first(where: { $0.id == id }) else {
                                hrirManager.deactivatePreset()
                                return
                            }
                            hrirManager.activatePreset(preset, targetSampleRate: runtime.currentOutput?.nominalSampleRate ?? 48_000, inputLayout: .stereo)
                        }
                    )) {
                        Text("None").tag(UUID?.none)
                        ForEach(hrirManager.presets) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Button("Open Preset Folder") { hrirManager.openPresetsDirectory() }
            }
        case .liveHealth:
            VStack(alignment: .leading, spacing: 12) {
                Text("Live health check").font(.title2.bold())
                LabeledContent("Status", value: runtime.status.title)
                LabeledContent("Current output", value: runtime.currentOutput?.name ?? "Not available")
                LabeledContent("Preset", value: hrirManager.activePreset?.name ?? "None")
                Text(runtime.status.detail).foregroundStyle(.secondary)
                if let guidance = viewModel.virtualOutputGuidance {
                    Label(guidance, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if RuntimeMenuPresentation.make(from: runtime.status).canRetry {
                    Button("Retry") { viewModel.retry() }
                }
            }
        }
    }

    @ViewBuilder
    private var permissionStatus: some View {
        switch viewModel.permissionPresentation {
        case .unknown: Label("Ready to request", systemImage: "circle")
        case .requesting: Label("Requesting access…", systemImage: "hourglass")
        case .granted: Label("System Audio Recording is available", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied: Label("Access is off. Enable Airwave in Privacy & Security, then retry.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
