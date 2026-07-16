import AppKit
import SwiftUI

private struct SettingsRightColumnHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            SettingsWindowPresenter.register(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            SettingsWindowPresenter.register(window)
        }
    }
}

struct SettingsWindowContent: View {
    @ObservedObject var state: SettingsWindowContentState
    @ObservedObject private var onboarding = OnboardingViewModel.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onboardingNavigationDirection: OnboardingNavigationDirection = .forward

    var body: some View {
        ZStack {
            pageContent

            VStack(spacing: 0) {
                AirwaveTopBar {
                    topBarCenter
                } trailing: {
                    topBarTrailing
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: SettingsWindowPresenter.contentSize.width, height: SettingsWindowPresenter.contentSize.height)
        .background(SettingsWindowAccessor())
        .clipped()
    }

    @ViewBuilder
    private var pageContent: some View {
        switch state.mode {
        case .setup:
            OnboardingView(
                viewModel: OnboardingViewModel.shared,
                navigationDirection: $onboardingNavigationDirection,
                canReturnToSettings: state.canReturnToSettings,
                onComplete: { state.show(.settings) },
                onReturnToSettings: { state.show(.settings) }
            )
            .transition(.opacity)
        case .settings:
            SettingsView(showSetup: {
                OnboardingViewModel.shared.prepareForPresentation(.voluntary)
                state.show(.setup, canReturnToSettings: true)
            }, page: Binding(
                get: { state.settingsPage },
                set: { state.selectSettingsPage($0) }
            ))
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var topBarCenter: some View {
        switch state.mode {
        case .setup:
            OnboardingProgressIndicator(
                currentStep: onboarding.currentStep,
                permission: onboarding.permissionPresentation,
                hasPreset: hrirManager.activePreset != nil,
                isReady: onboarding.canComplete,
                onSelect: { step in
                    onboardingNavigationDirection = onboardingIndex(of: step) > onboardingIndex(of: onboarding.currentStep)
                        ? .forward
                        : .backward
                    withAnimation(onboardingPageAnimation) {
                        onboarding.selectStep(step)
                    }
                }
            )
        case .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private var topBarTrailing: some View {
        switch state.mode {
        case .setup:
            Text("Page \(onboardingPageNumber) of \(OnboardingStepV2.allCases.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .settings:
            Button {
                ApplicationLifecycleCoordinator.shared.requestExplicitQuit()
            } label: {
                Label("Quit Airwave and Stop Processing", systemImage: "power")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.red)
            .help("Quit Airwave and stop audio processing")
        }
    }

    private var onboardingPageNumber: Int {
        (OnboardingStepV2.allCases.firstIndex(of: onboarding.currentStep) ?? 0) + 1
    }

    private var onboardingPageAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .smooth(duration: 0.26)
    }

    private func onboardingIndex(of step: OnboardingStepV2) -> Int {
        OnboardingStepV2.allCases.firstIndex(of: step) ?? 0
    }
}

struct SettingsView: View {
    var showSetup: () -> Void
    var page: Binding<SettingsPage> = .constant(.general)
    @ObservedObject private var onboarding = OnboardingViewModel.shared
    @ObservedObject private var runtime = AudioRuntimeState.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var menuVisibility = MenuBarVisibilityManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @EnvironmentObject private var viewModel: MenuBarViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rightColumnHeight: CGFloat = 0

    var body: some View {
        ZStack {
            AirwavePalette.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: AirwaveLayout.sectionSpacing) {
                pageHeader
                settingsPageContent

                #if DEBUG
                if page.wrappedValue == .general {
                    debugSection
                }
                #endif
            }
            .padding(.horizontal, 24)
            .padding(.top, 80)
            .padding(.bottom, 24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)

        }
        .frame(width: 900, height: 600)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var settingsPageContent: some View {
        switch page.wrappedValue {
        case .general:
            generalPage
        case .equalizer:
            EqualizerSettingsView()
                .transition(.opacity)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.16),
                    value: page.wrappedValue
                )
        case .application:
            applicationPage
                .transition(.opacity)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.16),
                    value: page.wrappedValue
                )
        }
    }

    private var generalPage: some View {
        HStack(alignment: .top, spacing: AirwaveLayout.cardSpacing) {
            spatialProfileSection
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: rightColumnHeight > 0 ? rightColumnHeight : nil, alignment: .top)
            rightColumn
        }
        .onPreferenceChange(SettingsRightColumnHeightKey.self) { height in
            guard abs(height - rightColumnHeight) > 0.5 else { return }
            rightColumnHeight = height
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionSpacing) {
            hrirResourcesSection
            applicationSection
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: SettingsRightColumnHeightKey.self, value: proxy.size.height)
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if page.wrappedValue != .general {
                    AirwaveIconButton(
                        systemImage: "chevron.left",
                        accessibilityLabel: "Back to Settings",
                        help: "Back to Settings",
                        isProminent: false,
                        isEnabled: true
                    ) {
                        page.wrappedValue = .general
                    }
                }
                Text(pageTitle).font(.largeTitle.weight(.semibold))
                if page.wrappedValue == .general, onboardingNeedsAttention {
                    Label("Reopen setup", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            Text(pageSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var pageTitle: String {
        page.wrappedValue == .general ? "Settings" : page.wrappedValue.title
    }

    private var pageSubtitle: String {
        switch page.wrappedValue {
        case .general:
            "Choose your spatial profile and application preferences."
        case .equalizer:
            "Import and inspect EqualizerAPO-style presets."
        case .application:
            "Manage startup, updates, and app information."
        }
    }

    private var spatialProfileSection: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            AirwaveSectionHeader(
                title: "Spatial Profile",
                subtitle: "Choose the HRIR preset Airwave uses for spatial audio."
            )

            VStack(spacing: 0) {
                AirwavePresetList(presets: hrirManager.presets, selectedID: hrirManager.activePreset?.id, onSelect: viewModel.selectPreset)

                AirwavePresetDropHint()

                Divider()

                AirwavePresetFilesRow(action: viewModel.openPresetsDirectory)
            }
            .frame(minHeight: 300, maxHeight: .infinity)
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
            .airwaveHRIRDropTarget(manager: hrirManager, onSelect: viewModel.selectPreset)

        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var applicationSection: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            AirwaveSectionHeader(
                title: "Application",
                subtitle: "Startup, updates, setup, and app information."
            )

            VStack(spacing: AirwaveLayout.cardSpacing) {
                AirwaveNavigationCard(
                    title: "Equalizer",
                    subtitle: "Configure your sound preference."
                ) {
                    page.wrappedValue = .equalizer
                }

                AirwaveNavigationCard(
                    title: "Setup",
                    subtitle: "Revisit the Airwave setup wizard."
                ) {
                    showSetup()
                }

                AirwaveNavigationCard(
                    title: "Application",
                    subtitle: "Preferences, updates, about."
                ) {
                    page.wrappedValue = .application
                }
            }
        }
    }

    private var applicationPage: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Launch at Login").font(.system(size: 12))
                        Text("Open Airwave automatically when you log in")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: $launchAtLogin.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
                .padding(.vertical, AirwaveLayout.rowVerticalPadding)

                Divider().padding(.leading, 30)

                HStack(spacing: 10) {
                    Image(systemName: "menubar.rectangle").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show in Menu Bar").font(.system(size: 12))
                        Text("Keep Airwave in the macOS menu bar.").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: menuBarVisibilityBinding).labelsHidden().toggleStyle(.switch)
                }
                .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
                .padding(.vertical, AirwaveLayout.rowVerticalPadding)

                Divider().padding(.leading, 30)

                HStack(spacing: 10) {
                    Image(systemName: updateIconName)
                        .font(.system(size: 13))
                        .foregroundStyle(updateIconColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Software Update").font(.system(size: 12))
                        Text(updateStatusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if case .checking = updateManager.state {
                        ProgressView().controlSize(.small)
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
                .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
                .padding(.vertical, AirwaveLayout.rowVerticalPadding)

                Divider().padding(.leading, 30)

                settingsActionRow(
                    icon: "info.circle.fill",
                    title: "About Airwave",
                    subtitle: "Version and app information",
                    buttonTitle: "About…",
                    action: viewModel.showAbout
                )
            }
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        }
    }

    private var hrirResourcesSection: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            AirwaveSectionHeader(
                title: "HRIR Resources",
                subtitle: "Find more compatible spatial profiles."
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Get HRIR Presets").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Link(destination: URL(string: "https://airtable.com/embed/appac4r1cu9UpBNAN/shrpUAbtyZxhDDMjg/tblopH2GznvFipWjq/viwnouWPGDuYEd8Go")!) {
                        Label("Open HRTF Database", systemImage: "link")
                    }
                    .font(.system(size: 11))
                }
                Text("Airwave works with HRIR presets compatible with HeSuVi.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(AirwaveLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        }
    }

    #if DEBUG
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            AirwaveSectionHeader(
                title: "Debug Health",
                subtitle: "Inspect the native process-tap runtime."
            )

            VStack(spacing: 0) {
                debugRow("Status", value: runtime.status.title)
                Divider().padding(.leading, 30)
                debugRow("Detail", value: runtime.status.detail)
                Divider().padding(.leading, 30)
                debugRow("Current Output", value: runtime.currentOutput?.name ?? "Not available")
                Divider().padding(.leading, 30)
                debugRow("Sample Rate", value: sampleRate)
                Divider().padding(.leading, 30)
                debugRow("Process Tap", value: runtime.status.isProcessing ? "Active" : "Inactive")

                if RuntimeMenuPresentation.make(from: runtime.status).canRetry {
                    Divider().padding(.leading, 30)
                    settingsActionRow(
                        icon: "arrow.clockwise",
                        title: "Retry Audio Setup",
                        subtitle: "Ask the runtime to retry immediately",
                        buttonTitle: "Retry",
                        action: viewModel.retryAudio
                    )
                }
                if runtime.status == .needsPermission {
                    Divider().padding(.leading, 30)
                    settingsActionRow(
                        icon: "lock.open.fill",
                        title: "System Audio Capture",
                        subtitle: "Open the macOS privacy setting for Airwave",
                        buttonTitle: "Open Settings",
                        action: viewModel.openSystemAudioRecordingSettings
                    )
                }
            }
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        }
    }

    private func debugRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 360, alignment: .trailing)
        }
        .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
        .padding(.vertical, AirwaveLayout.rowVerticalPadding)
    }
    #endif

    private func settingsActionRow(
        icon: String,
        title: String,
        subtitle: String,
        buttonTitle: String,
        showsWarning: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(showsWarning ? Color.orange : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .frame(width: 180, alignment: .trailing)
        }
        .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
        .padding(.vertical, AirwaveLayout.rowVerticalPadding)
        .background(showsWarning ? Color.orange.opacity(0.10) : Color.clear)
    }

    private var onboardingNeedsAttention: Bool {
        onboarding.needsSetupAttention
    }

    private var sampleRate: String {
        guard let rate = runtime.currentOutput?.nominalSampleRate else { return "—" }
        return "\(Int(rate.rounded())) Hz"
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

    private var updateStatusText: String {
        switch updateManager.state {
        case .idle: "Airwave \(updateManager.installedVersion)"
        case .checking: "Checking for updates…"
        case .current: "Airwave \(updateManager.installedVersion) is up to date"
        case .available(let version): "Airwave \(version) is available"
        case .error(let message): "Update check failed: \(message)"
        }
    }

    private var updateButtonTitle: String {
        if case .available = updateManager.state { return "Update…" }
        return "Check for Updates…"
    }

    private var updateIconName: String {
        switch updateManager.state {
        case .available: "arrow.down.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        default: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private var updateIconColor: Color {
        switch updateManager.state {
        case .available: .blue
        case .error: .orange
        default: .secondary
        }
    }
}
