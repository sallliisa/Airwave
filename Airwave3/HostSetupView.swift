import SwiftUI

enum HostSetupStep: String, CaseIterable, Identifiable {
    case welcome, capture, effect, finish

    var id: Self { self }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .capture: "System Audio Capture"
        case .effect: "Choose an Audio Unit"
        case .finish: "Finish Setup"
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

    var body: some View {
        ZStack(alignment: .bottom) {
            HostCompactPage(title: step.title) {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .hostPageReveal)
            .padding(.bottom, 64)

            footer.padding(.horizontal, 24).padding(.bottom, 24)
        }
        .animation(reduceMotion ? nil : HostAppearance.setupPageAnimation, value: step)
        .sheet(isPresented: $showingEffects) {
            EffectPicker(host: host) { component in
                if let current = host.editingDevices.first(where: \.isCurrent) {
                    host.selectEditingDevice(current.id)
                    host.addEditing(component)
                }
                showingEffects = false
            }
        }
    }

    private var canFinish: Bool {
        guard host.editingDevices.contains(where: \.isCurrent) else { return false }
        switch host.captureCheck {
        case .verified: return true
        case .idle: return shell.setupCompleted
        case .checking, .failed: return false
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomePage
        case .capture: capturePage
        case .effect: effectPage
        case .finish: finishPage
        }
    }

    private var welcomePage: some View {
        Text("Apply Audio Unit effects to sound from your Mac. Each output can have its own effect chain.")
            .foregroundStyle(.secondary)
    }

    private var capturePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch host.captureCheck {
            case .idle:
                Text("The test plays a short sound. Allow system audio recording if macOS asks.")
                captureButton("Test System Audio Capture")
            case .checking:
                ProgressView("Checking system audio…").controlSize(.small)
            case .verified:
                infoCard("Capture verified", icon: "checkmark.circle.fill", color: .green)
                captureButton("Test Again")
            case .failed(let reason):
                infoCard("System audio capture needs attention", icon: "exclamationmark.triangle.fill",
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
            Text(host.outputName)
                .foregroundStyle(.secondary)
            let chosen = host.editingDevices.first(where: \.isCurrent)?.id == host.editingDeviceUID
                ? host.editingSlots : []
            if let effect = chosen.last {
                infoCard(effect.name, icon: "checkmark.circle.fill", color: .green)
            }
            Button("Add Effect…") {
                host.rescan()
                showingEffects = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!host.editingDevices.contains(where: \.isCurrent))
            .accessibilityIdentifier("setup-add-effect")
        }
    }

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if canFinish {
                infoCard("Current output", icon: "speaker.wave.2", detail: host.outputName, color: .green)
            } else {
                infoCard("Check system audio capture", icon: "exclamationmark.triangle.fill",
                         detail: "A successful capture test is required to finish.", color: .orange)
                Button("Review Capture") { step = .capture }
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
                step == .finish ? "Finish Setup" : (step == .welcome ? "Begin Setup" : "Continue"),
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
