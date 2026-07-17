import SwiftUI

enum OnboardingNavigationDirection {
    case forward
    case backward
}

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Binding var navigationDirection: OnboardingNavigationDirection
    var canReturnToSettings = false
    var onComplete: () -> Void = {}
    var onReturnToSettings: () -> Void = {}
    @ObservedObject private var runtime = AudioRuntimeState.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @ObservedObject private var profiles = DeviceProfileManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var menuVisibility = MenuBarVisibilityManager.shared
    @EnvironmentObject private var menuViewModel: MenuBarViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            AirwavePalette.canvas.ignoresSafeArea()
            content
            AirwaveScrollEdgeFades()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                footer
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
            }
        }
        .frame(
            width: SettingsWindowPresenter.contentSize.width,
            height: SettingsWindowPresenter.contentSize.height
        )
        .preferredColorScheme(.dark)
    }

    private var content: some View {
        AirwavePageLayout(mode: .compact) {
            VStack(alignment: .leading, spacing: AirwaveLayout.pageHeaderContentMinimumSpacing) {
                stepHeader
                stepBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(viewModel.currentStep)
            .transition(pageTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var currentPageNumber: Int {
        (OnboardingStepV2.allCases.firstIndex(of: viewModel.currentStep) ?? 0) + 1
    }

    private var pageTransition: AnyTransition {
        .opacity
    }

    private var pageAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .smooth(duration: 0.26)
    }

    private func navigate(to step: OnboardingStepV2) {
        guard step != viewModel.currentStep else { return }
        navigationDirection = index(of: step) > index(of: viewModel.currentStep) ? .forward : .backward
        withAnimation(pageAnimation) { viewModel.selectStep(step) }
    }

    private func navigateForward() {
        navigationDirection = .forward
        withAnimation(pageAnimation) { viewModel.advance() }
    }

    private func navigateBackward() {
        navigationDirection = .backward
        withAnimation(pageAnimation) { viewModel.goBack() }
    }

    private func index(of step: OnboardingStepV2) -> Int {
        OnboardingStepV2.allCases.firstIndex(of: step) ?? 0
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(currentStepTitle).font(.largeTitle.weight(.semibold))
            Text(stepProgressLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var currentStepTitle: String {
        if viewModel.currentStep == .liveHealth { return readinessPresentation.title }
        return viewModel.currentStep.title
    }

    private var stepProgressLabel: String {
        switch viewModel.currentStep {
        case .welcome: "Before you begin"
        case .liveHealth: viewModel.canComplete ? "All is set. Airwave is now set up." : "Finish setup to use Airwave."
        default: "Step \(currentPageNumber - 1) of 2"
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch viewModel.currentStep {
        case .welcome: welcomeStep
        case .systemAudio: systemAudioStep
        case .hrirPreset: hrirStep
        case .liveHealth: liveHealthStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            Text("Set up Airwave for spatial audio.").font(.title3)
            Text("Airwave processes sound from your Mac and creates a spacious listening experience. Setup only takes a moment.")
                .foregroundStyle(.secondary)

            VStack(spacing: AirwaveLayout.cardSpacing) {
                infoCard(
                    "One macOS permission",
                    systemImage: "waveform.badge.mic",
                    text: "Allow System Audio Capture so Airwave can apply spatial processing to sound from your Mac."
                )
                infoCard(
                    "Choose a spatial profile",
                    systemImage: "waveform.circle",
                    text: "Pick the HRIR preset that sounds best to you. You can change it any time from the menu bar or Settings."
                )
            }
        }
    }

    private var systemAudioStep: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            Text("Allow Airwave to capture system audio so it can apply the selected HRIR preset. Airwave does not use microphone access.")
            captureAccessCard
            if let guidance = viewModel.captureFailureGuidance {
                captureFailureGuidance(guidance)
            }
            captureTestControls
        }
    }

    @ViewBuilder
    private var captureTestControls: some View {
        HStack {
            switch viewModel.captureAccessPresentation {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Playing a short test sound…").font(.callout).foregroundStyle(.secondary)
            case .unverified:
                if viewModel.captureFailureGuidance == nil {
                    Button("Test System Audio Capture") { viewModel.requestPermission() }
                        .buttonStyle(.borderedProminent)
                }
            case .verified:
                Button("System Audio Capture Verified") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            case .permissionRequired, .failed:
                EmptyView()
            }
        }
    }

    private func captureFailureGuidance(_ guidance: CaptureFailureGuidance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try these fixes")
                .font(.system(size: 13, weight: .medium))

            if let reason = guidance.reason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(guidance.suggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                Button("Open System Settings") { viewModel.openPermissionSettings() }
                    .buttonStyle(.link)
                Button("Test Again") { viewModel.requestPermission() }
                    .buttonStyle(.link)
            }
        }
        .padding(AirwaveLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture troubleshooting suggestions")
    }

    private var hrirStep: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            Text("Choose the HRIR preset Airwave uses for spatial audio.")

            AirwaveHRIRPicker(
                manager: hrirManager,
                selectedID: profiles.currentProfile?.hrirPresetID,
                onSelect: menuViewModel.selectPreset,
                onDelete: { preset in
                    if profiles.currentProfile?.hrirPresetID == preset.id {
                        menuViewModel.selectPreset(nil)
                    }
                }
            )
            .frame(height: 300, alignment: .top)
            .disabled(profiles.currentDeviceUID == nil)
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        }
    }

    private var liveHealthStep: some View {
        let presentation = readinessPresentation
        return VStack(alignment: .leading, spacing: AirwaveLayout.sectionSpacing) {
            statusCard(
                icon: viewModel.canComplete
                    ? "checkmark.seal.fill"
                    : (presentation.isAttention ? "exclamationmark.triangle.fill" : "info.circle.fill"),
                color: viewModel.canComplete ? .green : (presentation.isAttention ? .orange : .secondary),
                title: presentation.title,
                detail: presentation.detail
            )

            if let actionStep = presentation.actionStep {
                Button(presentation.actionTitle ?? (actionStep == .systemAudio ? "Review Capture" : "Choose a Preset")) {
                    navigate(to: actionStep)
                }
                .buttonStyle(.borderedProminent)
            }

            if presentation.canRetry {
                Button("Retry") { viewModel.retry() }.buttonStyle(.borderedProminent)
            }

            VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
                AirwaveSectionHeader(
                    title: "Application",
                    subtitle: "Choose whether Airwave starts automatically."
                )

                VStack(spacing: 0) {
                    applicationToggleRow(icon: "play.circle.fill", title: "Launch at Login", subtitle: "Start Airwave automatically when you log in", isOn: $launchAtLogin.isEnabled)
                    Divider().padding(.leading, 42)
                    applicationToggleRow(icon: "menubar.rectangle", title: "Show in Menu Bar", subtitle: "Keep Airwave available from the macOS menu bar.", isOn: menuBarVisibilityBinding)
                }
                .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
            }
        }
    }

    private func applicationToggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
        .padding(.vertical, AirwaveLayout.rowVerticalPadding)
    }

    private var menuBarVisibilityBinding: Binding<Bool> {
        Binding(
            get: { menuVisibility.isVisible },
            set: { value in
                guard value != menuVisibility.isVisible else { return }
                DispatchQueue.main.async { menuVisibility.setVisible(value) }
            }
        )
    }

    private var footer: some View {
        let isCompletion = viewModel.currentStep == .liveHealth
        let primaryLabel = isCompletion
            ? (profiles.currentProfile?.hrirPresetID == nil ? "Finish Setup" : "Start Airwave")
            : (viewModel.currentStep == .welcome ? "Begin Setup" : "Continue")

        return HStack {
            if canReturnToSettings {
                Button("Back to Settings", action: onReturnToSettings)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            AirwaveIconButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Back",
                help: "Back",
                isProminent: false,
                isEnabled: viewModel.currentStep != .welcome,
                action: navigateBackward
            )

            AirwaveIconButton(
                systemImage: isCompletion ? "play.fill" : "arrow.right",
                accessibilityLabel: primaryLabel,
                help: primaryLabel,
                isProminent: true,
                isEnabled: isCompletion ? viewModel.canComplete : true
            ) {
                if isCompletion {
                    if viewModel.complete() { onComplete() }
                } else {
                    navigateForward()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var captureAccessCard: some View {
        let icon: String
        let color: Color
        let detail: String
        switch viewModel.captureAccessPresentation {
        case .unverified:
            icon = "circle"
            color = .secondary
            detail = "Airwave will play a short sound and listen for captured system audio."
        case .checking:
            icon = "hourglass"
            color = .secondary
            detail = "A short test sound may play while Airwave verifies captured PCM."
        case .verified:
            icon = "checkmark.seal.fill"
            color = .green
            detail = "Airwave successfully captured system audio."
        case .permissionRequired:
            icon = "exclamationmark.triangle.fill"
            color = .orange
            detail = "Enable Airwave in Privacy & Security, then test again."
        case .failed(let reason):
            icon = "exclamationmark.triangle.fill"
            color = .orange
            detail = reason
        }
        return statusCard(icon: icon, color: color, title: "System Audio Capture", detail: detail)
    }

    private var readinessPresentation: OnboardingReadinessPresentation {
        OnboardingReadinessPresentation.make(
            captureAccess: viewModel.captureAccessPresentation,
            hasPreset: profiles.currentProfile?.hrirPresetID != nil,
            runtimeStatus: runtime.status,
            isReady: viewModel.canComplete
        )
    }

    private func statusCard(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(AirwaveLayout.cardPadding)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
    }

    private func infoCard(_ title: String, systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.primary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(AirwaveLayout.cardPadding)
        .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
    }

}

struct OnboardingProgressIndicator: View {
    let currentStep: OnboardingStepV2
    let permission: CaptureAccessPresentation
    let hasPreset: Bool
    let isReady: Bool
    let onSelect: (OnboardingStepV2) -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStepV2.allCases, id: \.self) { step in
                OnboardingProgressItem(
                    step: step,
                    status: status(for: step),
                    isCurrent: currentStep == step,
                    action: { onSelect(step) }
                )
            }
        }
        .animation(nil, value: currentStep)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Onboarding progress")
    }

    private func status(for step: OnboardingStepV2) -> ProgressStatus {
        switch step {
        case .welcome: .complete
        case .systemAudio:
            switch permission {
            case .verified: .complete
            case .permissionRequired, .failed: .attention
            case .checking, .unverified: .unknown
            }
        case .hrirPreset: .complete
        case .liveHealth: isReady ? .complete : .incomplete
        }
    }
}

private enum ProgressStatus {
    case checking
    case unknown
    case incomplete
    case attention
    case complete
}

private struct OnboardingProgressItem: View {
    let step: OnboardingStepV2
    let status: ProgressStatus
    let isCurrent: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: step.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background { Circle().fill(indicatorBackground) }
                .contentShape(Circle())
        }
        .buttonStyle(AirwavePressedButtonStyle())
        .help("\(step.title) — \(statusDescription)")
        .accessibilityLabel(step.title)
        .accessibilityValue(isCurrent ? "Current page, \(statusDescription)" : statusDescription)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { isHovering = hovering }
        }
    }

    private var iconColor: Color {
        if isCurrent { return AirwavePalette.canvas }
        switch status {
        case .complete: return Color.white
        case .attention: return Color.orange
        case .checking, .unknown: return Color.primary
        case .incomplete: return Color.secondary
        }
    }

    private var indicatorBackground: Color {
        if isCurrent { return Color.primary.opacity(isHovering ? 0.78 : 0.92) }
        return isHovering ? AirwavePalette.hover : .clear
    }

    private var statusDescription: String {
        switch status {
        case .checking: "Checking"
        case .unknown: "Not checked"
        case .incomplete: "Needs setup"
        case .attention: "Action needed"
        case .complete: "Complete"
        }
    }
}
