import AppKit
import SwiftUI

private struct OnboardingWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> OnboardingWindowObservingView {
        let view = OnboardingWindowObservingView()
        view.onWindowAvailable = { window in
            OnboardingWindowPresenter.present(window)
        }
        return view
    }

    func updateNSView(_ nsView: OnboardingWindowObservingView, context: Context) {}
}

private final class OnboardingWindowObservingView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        onWindowAvailable?(window)
    }
}

private enum OnboardingPalette {
    static let canvas = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let raised = Color(red: 29 / 255, green: 29 / 255, blue: 29 / 255)
    static let accent = Color(red: 77 / 255, green: 116 / 255, blue: 158 / 255)
    static let hover = Color.white.opacity(0.08)
}

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var navigationDirection: NavigationDirection = .forward
    @State private var isFinishLaterHovered = false

    private enum NavigationDirection {
        case forward
        case backward
    }

    var body: some View {
        ZStack {
            OnboardingPalette.canvas
                .ignoresSafeArea()

            content

            scrollEdgeFades

            VStack(spacing: 0) {
                topChrome
                Spacer(minLength: 0)
                footer
                    .padding(.horizontal, 24)
                    .padding(.top, 26)
                    .padding(.bottom, 14)
            }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 590)
        .background(OnboardingWindowAccessor())
        .preferredColorScheme(.dark)
        .tint(OnboardingPalette.accent)
        .onAppear {
            viewModel.beginLaunch()
        }
    }

    private var topChrome: some View {
        ZStack {
            HStack {
                Image("AirwaveIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Airwave")
                Spacer()
                Text("Page \(currentPageNumber) of \(SetupStep.allCases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            OnboardingProgressIndicator(
                currentStep: viewModel.currentStep,
                snapshot: viewModel.snapshot,
                canSelect: viewModel.canSelectStep,
                onSelect: navigate(to:)
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
                    .init(color: OnboardingPalette.canvas, location: 0),
                    .init(color: OnboardingPalette.canvas, location: 0.3),
                    .init(color: OnboardingPalette.canvas.opacity(0.55), location: 0.58),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 112)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [.clear, OnboardingPalette.canvas.opacity(0.94), OnboardingPalette.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 110)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stepHeader
                stepBody
            }
            .padding(.horizontal, 30)
            .padding(.top, 94)
            .padding(.bottom, 104)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
            .id(viewModel.currentStep)
            .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentPageNumber: Int {
        (SetupStep.allCases.firstIndex(of: viewModel.currentStep) ?? 0) + 1
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let insertionEdge: Edge = navigationDirection == .forward ? .trailing : .leading
        let removalEdge: Edge = navigationDirection == .forward ? .leading : .trailing
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: insertionEdge)),
            removal: .opacity.combined(with: .move(edge: removalEdge))
        )
    }

    private var pageAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .smooth(duration: 0.26)
    }

    private func navigate(to step: SetupStep) {
        guard step != viewModel.currentStep else { return }
        navigationDirection = index(of: step) > index(of: viewModel.currentStep) ? .forward : .backward
        withAnimation(pageAnimation) {
            viewModel.selectStep(step)
        }
    }

    private func navigateForward() {
        navigationDirection = .forward
        withAnimation(pageAnimation) {
            viewModel.advance()
        }
    }

    private func navigateBackward() {
        navigationDirection = .backward
        withAnimation(pageAnimation) {
            viewModel.goBack()
        }
    }

    private func index(of step: SetupStep) -> Int {
        SetupStep.allCases.firstIndex(of: step) ?? 0
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(viewModel.currentStep.title)
                .font(.largeTitle.weight(.semibold))
            Text(stepProgressLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stepProgressLabel: String {
        switch viewModel.currentStep {
        case .introduction: return "Before you begin"
        case .completion: return "Diagnostics summary"
        default: return "Step \(stepNumber) of 5"
        }
    }

    private var stepNumber: Int {
        switch viewModel.currentStep {
        case .introduction: return 0
        case .virtualDriver: return 1
        case .aggregateDevice: return 2
        case .microphonePermission: return 3
        case .hrirPreset: return 4
        case .audioRoute: return 5
        case .completion: return 5
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch viewModel.currentStep {
        case .introduction: introduction
        case .virtualDriver: driver
        case .aggregateDevice: aggregate
        case .microphonePermission: microphone
        case .hrirPreset: hrir
        case .audioRoute: route
        case .completion: completion
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Airwave for spatial audio.")
                .font(.title3)
            Text("Airwave processes sound from your Mac and sends it to your headphones or speakers. Setup usually takes a few minutes.")
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                infoCard("Before you begin", systemImage: "checklist", text: "You’ll need a virtual audio driver and the headphones or speakers you want to use. Airwave does not install drivers or create devices.")
                infoCard("Pause setup", systemImage: "pause.circle", text: "Finish Later saves your progress. If a driver requires a restart, quit Airwave first, restart your Mac, then resume from the menu bar.")
            }
        }
    }

    private var driver: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Airwave needs a virtual audio device to receive sound from your Mac. BlackHole 2ch is recommended and tested; other supported drivers may also work.")
            statusCard(status: viewModel.snapshot.driverStatus, detail: driverDetail)
            if !viewModel.snapshot.detectedDrivers.isEmpty {
                Text("Detected: \(viewModel.snapshot.detectedDrivers.joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("If the driver does not appear, finish the installation, wait for CoreAudio to reload, or restart your Mac if required. Then choose Refresh.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Get BlackHole 2ch") { viewModel.openBlackHoleDownload() }
                    .buttonStyle(.borderedProminent)
                Button("Quit Airwave") { viewModel.quitAirwave() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var aggregate: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Combine the virtual driver with your headphones or speakers in macOS Audio MIDI Setup. Follow these steps:")
            statusCard(status: viewModel.snapshot.aggregateStatus, detail: aggregateDetail)
            instructionCard(
                title: "Audio MIDI Setup",
                steps: [
                    "Click + and choose Create Aggregate Device.",
                    "Select BlackHole 2ch (or the virtual driver you installed).",
                    "Select the connected headphones or speakers to use.",
                    "Set the virtual device as the Clock Source, and turn on Drift Correction only for it.",
                    "Return here. Airwave will check the device automatically."
                ]
            )
            Button("Open Audio MIDI Setup") { viewModel.openAudioMIDISetup() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Airwave uses macOS’s audio capture path to receive sound from the aggregate device. Microphone permission is required and is requested when you select the button below.")
            statusCard(status: viewModel.snapshot.permissionStatus, detail: permissionDetail)
            if case .blocked = viewModel.snapshot.permissionStatus {
                Text("After changing the permission, return to Airwave. The status will refresh when the app becomes active.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings") { viewModel.openMicrophoneSettings() }
                    Button("Check permission again") { viewModel.refresh() }
                        .buttonStyle(.bordered)
                }
            } else {
                Button("Allow Microphone Access") {
                    viewModel.requestMicrophonePermission()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var hrir: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose an HRIR preset for the spatial audio effect. Airwave supports WAV presets from the HeSuVi HRTF Database and stores them in its presets folder.")
            statusCard(status: viewModel.snapshot.hrirStatus, detail: viewModel.presets.isEmpty ? "We haven’t found any usable HRIR presets yet." : "We found \(viewModel.presets.count) usable preset\(viewModel.presets.count == 1 ? "" : "s").")
            HStack {
                Button("Browse HRIR Presets") { viewModel.openHRTFDatabase() }
                    .buttonStyle(.borderedProminent)
                Button("Open Preset Folder") { viewModel.openHRIRFolder() }
                    .buttonStyle(.bordered)
            }
            instructionCard(
                title: "Add an HRIR preset",
                steps: [
                    "Download a HeSuVi-compatible HRIR preset in WAV format.",
                    "Click Open Preset Folder and copy the downloaded .wav file into that folder.",
                    "Return here and wait for Airwave to rescan the folder, then continue once the preset appears."
                ]
            )
        }
    }

    private var route: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the devices and HRIR preset Airwave should use. These options match Settings and include only currently available devices.")
            statusCard(status: viewModel.snapshot.routeStatus, detail: routeDetail)
            VStack(spacing: 0) {
                routePicker(
                    title: "Aggregate Device",
                    systemImage: "rectangle.stack",
                    selectedValue: viewModel.selectedAggregate?.name,
                    selection: selectedAggregateKey,
                    options: viewModel.aggregateDevices.map { (key($0), $0.name) }
                ) { value in
                    if let device = viewModel.aggregateDevices.first(where: { key($0) == value }) { viewModel.selectAggregate(device) }
                }
                Divider().padding(.leading, 42)
                routePicker(
                    title: "Input Device",
                    systemImage: "mic",
                    selectedValue: viewModel.selectedInput?.name,
                    selection: selectedInputKey,
                    options: viewModel.availableInputs.map { ($0.uid, $0.name) }
                ) { value in
                    if let input = viewModel.availableInputs.first(where: { $0.uid == value }) { viewModel.selectInput(input) }
                }
                Divider().padding(.leading, 42)
                routePicker(
                    title: "Output Device",
                    systemImage: "speaker.wave.2",
                    selectedValue: viewModel.selectedOutput?.name,
                    selection: selectedOutputKey,
                    options: viewModel.availableOutputs.map { ($0.uid, $0.name) }
                ) { value in
                    if let output = viewModel.availableOutputs.first(where: { $0.uid == value }) { viewModel.selectOutput(output) }
                }
                Divider().padding(.leading, 42)
                routePicker(
                    title: "HRIR Preset",
                    systemImage: "waveform.circle",
                    selectedValue: viewModel.selectedPreset?.name,
                    selection: viewModel.selectedPreset?.id.uuidString ?? "",
                    options: viewModel.presets.map { ($0.id.uuidString, $0.name) }
                ) { value in
                    if let preset = viewModel.presets.first(where: { $0.id.uuidString == value }) { viewModel.selectPreset(preset) }
                }
            }
            .background(OnboardingPalette.raised, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: 16) {
            finalChecksOverview

            VStack(spacing: 0) {
                ForEach(SetupStep.requirementSteps) { step in
                    finalCheckRow(step)
                    if step.id != SetupStep.requirementSteps.last?.id {
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .background(OnboardingPalette.raised, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 7) {
                Text("Current audio route")
                    .fontWeight(.semibold)
                summaryRow("Aggregate", value: viewModel.snapshot.route.aggregateName)
                summaryRow("Input", value: viewModel.snapshot.route.inputName)
                summaryRow("Output", value: viewModel.snapshot.route.outputName)
                summaryRow("HRIR", value: viewModel.snapshot.route.presetName)
            }
            .padding(14)
            .background(OnboardingPalette.raised, in: RoundedRectangle(cornerRadius: 8))

            Text("You can change these choices later in Settings. Select a check above to return to the relevant setup step.")
                .foregroundStyle(.secondary)
        }
    }

    private var finalChecksOverview: some View {
        let isChecking = viewModel.snapshot.isChecking
        let isReady = viewModel.snapshot.isReadyToRun
        let icon = isChecking
            ? "hourglass"
            : (isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
        let color: Color = isChecking ? .secondary : (isReady ? .green : .orange)
        let title = isChecking
            ? "Checking setup..."
            : (isReady ? "All checks passed" : "Setup needs attention")
        let message = isChecking
            ? "Airwave is checking the current audio configuration."
            : (isReady
                ? "All requirements are met. Airwave is ready for audio processing."
                : "Some requirements still need attention. Select a check below to continue setup.")

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(13)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private func finalCheckRow(_ step: SetupStep) -> some View {
        let status = viewModel.snapshot.status(for: step) ?? .checking

        return Button {
            navigate(to: step)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: status.icon)
                    .foregroundStyle(statusColor(status))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(finalCheckDetail(for: step))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func finalCheckDetail(for step: SetupStep) -> String {
        if viewModel.snapshot.status(for: step) == .checking {
            return "Checking the current setup state..."
        }

        switch step {
        case .virtualDriver: return driverDetail
        case .aggregateDevice: return aggregateDetail
        case .microphonePermission: return permissionDetail
        case .hrirPreset:
            return viewModel.presets.isEmpty
                ? "We haven’t found any usable HRIR presets yet."
                : "We found \(viewModel.presets.count) usable preset\(viewModel.presets.count == 1 ? "" : "s")."
        case .audioRoute: return routeDetail
        case .introduction, .completion: return ""
        }
    }

    private var footer: some View {
        let isCompletion = viewModel.currentStep == .completion
        let primaryLabel = isCompletion
            ? "Start Airwave"
            : (viewModel.currentStep == .introduction ? "Begin Setup" : "Continue")

        return HStack {
            HStack(spacing: 12) {
                Button("Finish Later") {
                    viewModel.finishLater()
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(isFinishLaterHovered ? .primary : .secondary)
                .keyboardShortcut(.cancelAction)
                .help("Save progress and finish setup later")
                .onHover { hovering in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                        isFinishLaterHovered = hovering
                    }
                }

                Text("Your progress is saved automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            OnboardingIconButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Back",
                help: "Back",
                isProminent: false,
                isEnabled: viewModel.currentStep != .introduction,
                action: navigateBackward
            )

            OnboardingIconButton(
                systemImage: isCompletion ? "play.fill" : "arrow.right",
                accessibilityLabel: primaryLabel,
                help: primaryLabel,
                isProminent: true,
                isEnabled: isCompletion ? viewModel.snapshot.isReadyToRun : viewModel.canContinue
            ) {
                if isCompletion {
                    if viewModel.startUsingAirwave() { dismiss() }
                } else {
                    navigateForward()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var driverDetail: String {
        if viewModel.snapshot.driverStatus.isComplete { return "Supported virtual audio driver detected." }
        return "Install BlackHole 2ch or another supported virtual driver, then return here to check again."
    }

    private var aggregateDetail: String {
        switch viewModel.snapshot.aggregateStatus {
        case .complete: return "A valid aggregate device is connected."
        case .blocked(let reason): return reason
        default: return "No usable aggregate device detected yet."
        }
    }

    private var permissionDetail: String {
        switch viewModel.snapshot.permissionStatus {
        case .complete: return "Microphone access is allowed."
        case .blocked(let reason): return reason
        default: return "Microphone permission has not been requested."
        }
    }

    private var routeDetail: String {
        switch viewModel.snapshot.routeStatus {
        case .complete: return "All four audio route choices are valid."
        case .blocked(let reason): return reason
        default: return "Select a value for each audio route field."
        }
    }

    private var selectedAggregateKey: String { viewModel.selectedAggregate.map(key) ?? "" }
    private var selectedInputKey: String { viewModel.selectedInput?.uid ?? "" }
    private var selectedOutputKey: String { viewModel.selectedOutput?.uid ?? "" }

    private func key(_ device: AudioDevice) -> String {
        device.uid ?? "id:\(device.id)"
    }

    private func routePicker(
        title: String,
        systemImage: String,
        selectedValue: String?,
        selection: String,
        options: [(String, String)],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                Text(selectedValue ?? (options.isEmpty ? "None available" : "Select an option"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
            if options.isEmpty {
                Text("None available")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .trailing)
            } else {
                Picker("", selection: Binding(get: { selection }, set: onSelect)) {
                    Text("Select…").tag("")
                    ForEach(options, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
                .labelsHidden()
                .frame(width: 140, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusCard(status: SetupRequirementStatus, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.icon)
                .foregroundStyle(statusColor(status))
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle(status))
                    .fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(13)
        .background(statusColor(status).opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private func instructionCard(title: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).fontWeight(.semibold)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)").font(.caption.weight(.semibold)).frame(width: 18)
                    Text(step).font(.callout)
                }
            }
        }
        .padding(14)
        .background(OnboardingPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func infoCard(_ title: String, systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(OnboardingPalette.accent)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(OnboardingPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func summaryRow(_ title: String, value: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value ?? "Not selected")
        }
    }

    private func statusTitle(_ status: SetupRequirementStatus) -> String {
        switch status {
        case .checking: return "Checking…"
        case .incomplete: return "Needs setup"
        case .blocked: return "Action needed"
        case .complete: return "Ready"
        }
    }

    private func statusColor(_ status: SetupRequirementStatus) -> Color {
        switch status {
        case .checking: return .secondary
        case .incomplete: return .orange
        case .blocked: return .red
        case .complete: return .green
        }
    }
}

private struct OnboardingProgressIndicator: View {
    let currentStep: SetupStep
    let snapshot: SetupSnapshot
    let canSelect: (SetupStep) -> Bool
    let onSelect: (SetupStep) -> Void

    var body: some View {
        let currentIndex = SetupStep.allCases.firstIndex(of: currentStep) ?? 0

        HStack(spacing: 7) {
            ForEach(Array(SetupStep.allCases.enumerated()), id: \.element.id) { index, step in
                OnboardingProgressItem(
                    step: step,
                    pageNumber: index + 1,
                    pageCount: SetupStep.allCases.count,
                    status: snapshot.status(for: step),
                    isCurrent: currentStep == step,
                    isPast: index < currentIndex,
                    isSetupReady: snapshot.isReadyToRun,
                    isEnabled: canSelect(step),
                    action: { onSelect(step) }
                )
            }
        }
        .animation(nil, value: currentStep)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Onboarding progress")
    }
}

private struct OnboardingProgressItem: View {
    let step: SetupStep
    let pageNumber: Int
    let pageCount: Int
    let status: SetupRequirementStatus?
    let isCurrent: Bool
    let isPast: Bool
    let isSetupReady: Bool
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: step.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(indicatorBackground)
                }
                .contentShape(Circle())
        }
        .buttonStyle(OnboardingProgressButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .help(helpText)
        .accessibilityLabel("\(step.title), page \(pageNumber) of \(pageCount)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }

    private var iconColor: Color {
        if isCurrent { return Color.white.opacity(0.94) }
        switch step {
        case .introduction:
            return isPast ? .white : .secondary
        case .completion:
            return isSetupReady ? .white : .secondary
        default:
            guard let status else { return .secondary }
            switch status {
            case .complete: return .white
            case .blocked: return .orange
            case .checking, .incomplete: return .secondary
            }
        }
    }

    private var indicatorBackground: Color {
        if isCurrent {
            return OnboardingPalette.accent.opacity(isHovering ? 0.78 : 0.62)
        }
        return isHovering ? OnboardingPalette.hover : .clear
    }

    private var helpText: String {
        "\(step.title) — \(statusDescription)"
    }

    private var accessibilityValue: String {
        [isCurrent ? "Current page" : nil, statusDescription].compactMap { $0 }.joined(separator: ", ")
    }

    private var statusDescription: String {
        if step == .introduction { return isPast ? "Complete" : "Setup page" }
        if step == .completion { return isSetupReady ? "Complete" : "Needs setup" }
        guard let status else { return "Needs setup" }
        switch status {
        case .checking: return "Checking"
        case .incomplete: return "Needs setup"
        case .blocked: return "Action needed"
        case .complete: return "Complete"
        }
    }

}

private struct OnboardingProgressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct OnboardingIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let help: String
    let isProminent: Bool
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isProminent ? Color.white : (isHovering ? Color.primary : Color.secondary))
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(buttonBackground)
                }
                .contentShape(Circle())
        }
        .buttonStyle(OnboardingProgressButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }

    private var buttonBackground: Color {
        if isProminent {
            return isHovering ? OnboardingPalette.accent.opacity(0.82) : OnboardingPalette.accent
        }
        return isHovering ? OnboardingPalette.hover : .clear
    }
}
