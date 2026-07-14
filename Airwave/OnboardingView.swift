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

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 590)
        .background(OnboardingWindowAccessor())
        .onAppear {
            viewModel.beginLaunch()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Airwave")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)

            ForEach(SetupStep.allCases) { step in
                let isNavigable = viewModel.canSelectStep(step)

                Button {
                    viewModel.selectStep(step)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: step.systemImage)
                            .frame(width: 18)
                        Text(step.title)
                            .lineLimit(1)
                        Spacer()
                        if let status = viewModel.snapshot.status(for: step) {
                            Image(systemName: status.icon)
                                .foregroundStyle(statusColor(status))
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(viewModel.currentStep == step ? Color.accentColor.opacity(0.12) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(viewModel.currentStep == step ? Color.accentColor : .primary)
                .disabled(!isNavigable)
                .opacity(isNavigable ? 1 : 0.5)
                .accessibilityElement(children: .combine)
            }

            Spacer()

            Text("You can finish setup later. Airwave will remind you about incomplete steps in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    stepHeader
                    stepBody
                }
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            infoCard("Before you begin", systemImage: "checklist", text: "You’ll need a virtual audio driver and the headphones or speakers you want to use. Airwave does not install drivers or create devices.")
            infoCard("Pause setup", systemImage: "pause.circle", text: "Finish Later saves your progress. If a driver requires a restart, quit Airwave first, restart your Mac, then resume from the menu bar.")
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 7) {
                Text("Current audio route")
                    .fontWeight(.semibold)
                summaryRow("Aggregate", value: viewModel.snapshot.route.aggregateName)
                summaryRow("Input", value: viewModel.snapshot.route.inputName)
                summaryRow("Output", value: viewModel.snapshot.route.outputName)
                summaryRow("HRIR", value: viewModel.snapshot.route.presetName)
            }
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

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
            viewModel.selectStep(step)
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
        HStack {
            Button("Finish Later") {
                viewModel.finishLater()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Back") { viewModel.goBack() }
                .disabled(viewModel.currentStep == .introduction)

            if viewModel.currentStep == .completion {
                Button("Start Airwave") {
                    if viewModel.startUsingAirwave() { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.snapshot.isReadyToRun)
            } else {
                Button(viewModel.currentStep == .introduction ? "Begin Setup" : "Continue") {
                    viewModel.advance()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canContinue)
                .keyboardShortcut(.defaultAction)
            }
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
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func infoCard(_ title: String, systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
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
