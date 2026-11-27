import SwiftUI

enum HostSetupStep: String, CaseIterable, Identifiable {
    case welcome, capture, effect, finish

    var id: Self { self }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .capture: "Allow System Audio"
        case .effect: "Add Effects"
        case .finish: "Finish Setup"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "Use effects on your Mac’s audio and adjust each app’s volume."
        case .capture: "Airwave needs audio access to apply effects and adjust app volume."
        case .effect: "Add Audio Units for this output, or continue without effects."
        case .finish: "Choose how Airwave starts and where it appears."
        }
    }

    var icon: String {
        switch self {
        case .welcome: "sparkles"
        case .capture: "waveform.badge.mic"
        case .effect: "slider.horizontal.3"
        case .finish: "checkmark.seal"
        }
    }
}

struct HostSetupProgress: View {
    @ObservedObject var host: HostController
    @Binding var step: HostSetupStep

    var body: some View {
        HStack(spacing: 7) {
            ForEach(HostSetupStep.allCases) { item in
                Button { step = item } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint(for: item))
                        .frame(width: 32, height: 32)
                        .background {
                            Circle().fill(step == item ? Color.primary.opacity(0.92) : .clear)
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(step == item ? .isSelected : [])
                .accessibilityIdentifier("setup-step-\(item.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup progress")
    }

    private func tint(for item: HostSetupStep) -> Color {
        if step == item { return HostAppearance.canvas }
        if item == .capture, case .failed = host.captureCheck { return .orange }
        return item.index <= step.index ? .primary : .secondary
    }
}

struct HostSetupView: View {
    @ObservedObject var host: HostController
    @ObservedObject var shell: ShellModel
    @Binding var step: HostSetupStep

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingEffects = false

    private var currentOutput: HostDeviceTarget? {
        host.editingDevices.first(where: \.isCurrent)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HostCompactPage(title: step.title, subtitle: step.subtitle) {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(step)
            .transition(.opacity)
            .padding(.bottom, 64)

            footer.padding(.horizontal, 24).padding(.bottom, 24)
        }
        .animation(reduceMotion ? nil : HostAppearance.pageFade, value: step)
        .sheet(isPresented: $showingEffects) {
            EffectPicker(host: host, allowsMultiple: true) { component in
                guard let currentOutput else { return false }
                host.selectEditingDevice(currentOutput.id)
                let previousCount = host.editingSlots.count
                host.addEditing(component)
                return host.editingSlots.count > previousCount
            }
        }
        .onChange(of: currentOutput?.id) { _, _ in showingEffects = false }
    }

    private var canFinish: Bool {
        guard currentOutput != nil else { return false }
        switch host.captureCheck {
        case .verified: return true
        case .idle: return shell.setupCompleted
        case .checking, .failed: return false
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: EmptyView()
        case .capture: capturePage
        case .effect: effectPage
        case .finish: finishPage
        }
    }

    private var capturePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch host.captureCheck {
            case .idle:
                Text("The test plays a short sound. If prompted, allow system audio recording.")
                    .foregroundStyle(.secondary)
                captureButton("Test Audio Access")
            case .checking:
                ProgressView("Testing audio access…").controlSize(.small)
            case .verified:
                infoCard("System audio is ready", icon: "checkmark.circle.fill", color: .green)
                captureButton("Test Again")
            case .failed(let reason):
                infoCard("Audio access test failed", icon: "exclamationmark.triangle.fill",
                         detail: reason, color: .orange)
                HStack {
                    Button("Open System Settings", action: host.openCaptureSettings)
                    captureButton("Test Again")
                }
            }
        }
    }

    private var effectPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(host.outputName)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Effects…") {
                    host.rescan()
                    showingEffects = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(currentOutput == nil)
                .accessibilityIdentifier("setup-add-effect")
            }
            if let currentOutput, currentOutput.id == host.editingDeviceUID, !host.editingSlots.isEmpty {
                EffectChain(host: host)
                    .id(currentOutput.id)
            }
        }
    }

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if canFinish {
                infoCard("Audio output ready", icon: "speaker.wave.2", detail: host.outputName, color: .green)
            } else {
                infoCard("Audio access is required", icon: "exclamationmark.triangle.fill",
                         detail: "Run the audio test to finish setup.", color: .orange)
                Button("Review Audio Access") { step = .capture }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            VStack(spacing: 0) {
                HostPreferenceRows(shell: shell)
            }
            .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))
        }
    }

    private func captureButton(_ title: String) -> some View {
        Button(title, action: host.checkCapturePermission)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("test-capture")
    }

    private func infoCard(_ title: String, icon: String, detail: String? = nil, color: Color = .secondary) -> some View {
        HostSettingsRow(icon: icon, title: title, subtitle: detail, iconColor: color) { EmptyView() }
            .padding(.vertical, 4)
            .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if shell.setupCompleted {
                Button(action: shell.returnFromSetup) {
                    Label("Exit Setup", systemImage: "chevron.left")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("exit-setup")
            }
            Spacer()
            navigationButton("Back", icon: "chevron.left", prominent: false) {
                step = HostSetupStep.allCases[step.index - 1]
            }
            .disabled(step == .welcome)
            .opacity(step == .welcome ? 0.35 : 1)
            .accessibilityIdentifier("setup-back")

            navigationButton(
                step == .finish ? "Finish Setup" : (step == .welcome ? "Get Started" : "Continue"),
                icon: step == .finish ? "play.fill" : "arrow.right",
                prominent: true
            ) {
                if step == .finish {
                    guard canFinish else { return }
                    shell.finishSetup()
                } else {
                    step = HostSetupStep.allCases[step.index + 1]
                }
            }
            .disabled(step == .finish && !canFinish)
            .opacity(step == .finish && !canFinish ? 0.35 : 1)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(step == .finish ? "finish-setup" : "setup-next")
        }
    }

    private func navigationButton(_ label: String, icon: String, prominent: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? HostAppearance.canvas : Color.secondary)
                .frame(width: 34, height: 34)
                .background {
                    Circle().fill(prominent ? Color.primary.opacity(0.92) : HostAppearance.hover)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
