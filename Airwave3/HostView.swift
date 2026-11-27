import AppKit
import SwiftUI

enum HostAppearance {
    static let canvas = Color(white: 17.0 / 255)
    static let raised = Color(white: 29.0 / 255)
    static let hover = Color.white.opacity(0.08)
    static let cornerRadius: CGFloat = 8
    static let audioPageSpacing: CGFloat = 14
    static let audioSectionHeaderHeight: CGFloat = 28
    static let audioRowHeight: CGFloat = 52
    static let setupPageAnimation = Animation.smooth(duration: 0.3)
    static let pageFade = Animation.easeInOut(duration: 0.16)

    static func powerTint(isOn: Bool) -> Color {
        isOn ? .primary : .secondary
    }
}

@MainActor
struct HostWindow: View {
    static let contentSize = CGSize(width: 720, height: 540)

    @ObservedObject var host: HostController
    @ObservedObject var shell: ShellModel
    @ObservedObject var updates: HostUpdateManager
    let requestQuit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmsQuit = false

    private var showsSetup: Bool { shell.page == .setup }
    private var modeTransition: AnyTransition { reduceMotion ? .opacity : .hostPageReveal }
    private var selectedTab: ShellPage {
        switch shell.page {
        case .setup, .devices: .effects
        case .effects, .mixer, .settings: shell.page
        }
    }

    private var setupStep: Binding<HostSetupStep> {
        Binding(
            get: { HostSetupStep(rawValue: shell.setupCheckpoint) ?? .welcome },
            set: { shell.setupCheckpoint = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack(alignment: .top) {
                if showsSetup {
                    HostSetupView(host: host, shell: shell, step: setupStep)
                        .transition(modeTransition)
                } else {
                    workspace
                        .transition(modeTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(HostAppearance.canvas.ignoresSafeArea())
        .clipped()
        .animation(reduceMotion ? nil : HostAppearance.setupPageAnimation, value: showsSetup)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .confirmationDialog("Quit Airwave?", isPresented: $confirmsQuit) {
            Button("Quit Airwave", role: .destructive, action: requestQuit)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Audio processing will stop.")
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(height: 44)
                .overlay(alignment: .leading) {
                    HStack(spacing: 4) {
                        HostBrand()
                        if !showsSetup, let notice = host.processingNotice, notice.isWarning {
                            HostNoticeButton(notice: notice, openTroubleshooting: openTroubleshooting)
                                .accessibilityIdentifier("route-status")
                                .transition(modeTransition)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

            ZStack {
                if showsSetup {
                    HostSetupProgress(host: host, step: setupStep)
                        .transition(modeTransition)
                } else {
                    tabs.transition(modeTransition)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Color.clear.frame(height: 44)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 4) {
                        if !showsSetup {
                            HostProcessingButton(host: host)
                                .transition(modeTransition)
                        }
                        if shell.setupCompleted {
                            quitButton.transition(modeTransition)
                        }
                    }
                }
        }
        .frame(height: 44)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var workspace: some View {
        ZStack(alignment: .topLeading) {
            pageContent
                .id(selectedTab)
                .transition(.opacity)
        }
        .animation(reduceMotion || showsSetup ? nil : HostAppearance.pageFade, value: selectedTab)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedTab {
        case .effects:
            effectsWorkspace
        case .mixer:
            HostMixerPage(host: host).padding(24)
        case .settings:
            HostSettingsPage(shell: shell, updates: updates).padding(24)
        case .setup, .devices:
            EmptyView()
        }
    }

    private var effectsWorkspace: some View {
        let showsDevices = shell.page == .devices
        return ZStack(alignment: .topLeading) {
            if showsDevices {
                HostDevicesPage(host: host, shell: shell)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(HostAppearance.canvas)
                    .transition(.hostPageSlide(edge: .trailing))
            } else {
                HostEffectsPage(host: host) {
                    shell.page = .devices
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(HostAppearance.canvas)
                .transition(.hostPageSlide(edge: .leading))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .animation(reduceMotion || selectedTab != .effects || showsSetup ? nil : HostAppearance.setupPageAnimation,
                   value: showsDevices)
    }

    private func openTroubleshooting() {
        shell.showSetup()
        setupStep.wrappedValue = .capture
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            HostWorkspaceButton(title: "Effects", icon: "slider.horizontal.3",
                                isSelected: shell.page == .effects || shell.page == .devices,
                                action: shell.showEffects)
                .accessibilityIdentifier("effects")
            HostWorkspaceButton(title: "App Mixer", icon: "slider.vertical.3", isSelected: shell.page == .mixer) {
                shell.page = .mixer
            }
            .accessibilityIdentifier("app-mixer")
            HostWorkspaceButton(title: "Settings", icon: "gearshape", isSelected: shell.page == .settings) {
                shell.page = .settings
            }
            .accessibilityIdentifier("application-settings")
        }
    }

    private var quitButton: some View {
        HostHeaderIconButton(symbol: "rectangle.portrait.and.arrow.right", tint: .red) { confirmsQuit = true }
            .help("Quit Airwave")
            .accessibilityLabel("Quit Airwave")
            .accessibilityIdentifier("quit-host")
    }
}

private struct HostWorkspaceButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.primary : .secondary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background {
                    RoundedRectangle(cornerRadius: HostAppearance.cornerRadius)
                        .fill(isSelected ? HostAppearance.raised : isHovered ? HostAppearance.hover.opacity(0.45) : .clear)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

@MainActor
private struct HostProcessingButton: View {
    @ObservedObject var host: HostController

    var body: some View {
        let state = host.isEnabled ? "On" : "Off"
        HostHeaderIconButton(symbol: "power", tint: HostAppearance.powerTint(isOn: host.isEnabled), title: state) {
            host.setEnabled(!host.isEnabled)
        }
        .help(host.isEnabled ? "Bypass all effects and app volume adjustments" : "Resume audio processing")
        .accessibilityLabel(host.isEnabled ? "Bypass Processing" : "Resume Processing")
        .accessibilityValue(state)
        .accessibilityIdentifier("global-bypass")
    }
}

private struct HostHeaderIconButton: View {
    let symbol: String
    let tint: Color
    var title: String? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 22, alignment: .leading)
                }
            }
            .foregroundStyle(tint)
            .frame(width: title == nil ? 34 : 62, height: 34)
            .background(hovered ? Color.white.opacity(0.16) : .clear, in: .rect(cornerRadius: HostAppearance.cornerRadius))
            .padding(5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct HostNoticeButton: View {
    let notice: HostProcessingNotice
    var openTroubleshooting: (() -> Void)?
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails.toggle() } label: {
            Image(systemName: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                .frame(width: 26, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(notice.message)
        .accessibilityLabel("Audio Issue")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(notice.message).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notice-details")
                if case .captureFailure = notice, let openTroubleshooting {
                    Button("Troubleshoot…") {
                        showsDetails = false
                        openTroubleshooting()
                    }
                    .accessibilityIdentifier("troubleshoot-capture")
                }
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
        }
    }
}

private struct HostAudioPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: HostAppearance.audioPageSpacing) {
            HostPageHeader(title: title, subtitle: subtitle)
            content()
        }
    }
}

private struct HostEmptyState: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var action: Button<Text>?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 290)

            if let action {
                action.buttonStyle(.bordered)
                    .padding(.top, 2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct HostEffectsPage: View {
    @ObservedObject var host: HostController
    let manageDevices: () -> Void

    @State private var showingEffects = false

    private var editingDevice: HostDeviceTarget? {
        host.editingDevices.first { $0.id == host.editingDeviceUID }
    }

    var body: some View {
        HostAudioPage(title: "Effects", subtitle: "Build an effect chain for each audio output.") {
            VStack(alignment: .leading, spacing: HostAppearance.audioPageSpacing) {
                if !host.editingDevices.isEmpty { deviceBar }
                if host.editingSlots.isEmpty {
                    emptyChain
                } else {
                    EffectChain(host: host)
                        .id(host.editingDeviceUID)
                }
            }
        }
        .sheet(isPresented: $showingEffects) {
            EffectPicker(host: host) { component in
                guard host.editingDeviceUID != nil else { return false }
                host.addEditing(component)
                return true
            }
        }
        .onChange(of: host.editingDeviceUID) { _, _ in showingEffects = false }
    }

    private var deviceBar: some View {
        HStack(spacing: 10) {
            if let editingDevice {
                deviceMenu(editingDevice)

                if !editingDevice.isCurrent, let live = host.editingDevices.first(where: \.isCurrent) {
                    Button(action: host.selectCurrentOutputForEditing) {
                        Label("Edit Live Output", systemImage: "arrow.uturn.backward")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .help("Edit the chain for \(live.name)")
                    .accessibilityHint(live.name)
                    .accessibilityIdentifier("live-output")
                }
            }

            Spacer(minLength: 12)

            Button("Manage Devices", action: manageDevices)
                .fixedSize()
                .accessibilityIdentifier("registered-devices")

            if editingDevice != nil {
                Button {
                    host.rescan()
                    showingEffects = true
                } label: {
                    Label("Add Effect…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .accessibilityLabel("Add Effect")
                .accessibilityIdentifier("add-effect")
            }
        }
        .frame(minHeight: HostAppearance.audioSectionHeaderHeight)
    }

    private func deviceMenu(_ editingDevice: HostDeviceTarget) -> some View {
        Menu {
            ForEach(host.editingDevices) { device in
                Button {
                    host.selectEditingDevice(device.id)
                } label: {
                    if device.id == editingDevice.id {
                        Label(device.name, systemImage: "checkmark")
                    } else if device.isCurrent {
                        Label(device.name, systemImage: "speaker.wave.2")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if editingDevice.isCurrent {
                    Image(systemName: "speaker.wave.2").accessibilityHidden(true)
                }
                Text(editingDevice.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(editingDevice.name)
        .accessibilityLabel("Editing audio device")
        .accessibilityValue(editingDevice.isCurrent ? "\(editingDevice.name), live output" : editingDevice.name)
        .accessibilityIdentifier("current-output")
    }

    @ViewBuilder
    private var emptyChain: some View {
        if editingDevice != nil {
            HostEmptyState(icon: "slider.horizontal.3", title: "No effects yet",
                           detail: "Add an Audio Unit to process audio for this output.")
        } else if !host.editingDevices.isEmpty {
            HostEmptyState(icon: "speaker.wave.2", title: "Choose a device",
                           detail: "Open Manage Devices to choose an effect chain.")
        } else {
            HostEmptyState(icon: "speaker.slash", title: "No audio output",
                           detail: "Connect a supported output to add effects.")
        }
    }
}

struct HostBrand: View {
    var markSize: CGFloat = 24
    var titleFont: Font = .headline

    var body: some View {
        HStack(spacing: markSize > 16 ? 12 : 8) {
            Image("AirwaveMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .accessibilityHidden(true)
            Text("Airwave").font(titleFont)
        }
    }
}

private struct HostPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HostSettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var iconColor: Color = .secondary
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(iconColor)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }
}

struct HostCompactPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HostPageHeader(title: title, subtitle: subtitle)
            content()
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private extension HostDeviceTarget {
    var profileStatus: String {
        if isCurrent { return "Current output" }
        return isConnected ? "Connected" : "Offline profile"
    }
}

private struct HostBackButton: View {
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? Color.primary : .secondary)
                .frame(width: 34, height: 34)
                .background(hovering ? HostAppearance.hover : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(PressedStyle())
        .help("Back to Effects")
        .accessibilityLabel("Back to Effects")
        .onHover { isHovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                hovering = isHovering
            }
        }
    }

    private struct PressedStyle: ButtonStyle {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .opacity(configuration.isPressed ? 0.82 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

private struct HostDevicesPage: View {
    @ObservedObject var host: HostController
    @ObservedObject var shell: ShellModel

    private enum Action {
        case reset(HostDeviceTarget)
        case forget(HostDeviceTarget)

        var device: HostDeviceTarget {
            switch self {
            case .reset(let device), .forget(let device): device
            }
        }

        var title: String {
            switch self {
            case .reset: "Reset Effect Chain"
            case .forget: "Forget Device"
            }
        }
    }

    @State private var action: Action?
    @State private var configuringOutput: HostDeviceTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                HostBackButton(action: shell.showEffects)
                    .accessibilityIdentifier("back-to-effects")
                HostPageHeader(title: "Manage Devices", subtitle: "Edit effects and channel settings for each output.")
            }

            if host.editingDevices.isEmpty {
                HostEmptyState(icon: "headphones", title: "No devices yet",
                               detail: "Connect an audio output to set up its effect chain.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(host.editingDevices) { device in
                            HostSettingsRow(icon: device.isCurrent ? "speaker.wave.2" : "headphones",
                                            title: device.name, subtitle: device.profileStatus) {
                                Button("Edit Chain") {
                                    host.selectEditingDevice(device.id)
                                    shell.showEffects()
                                }
                                .controlSize(.small)
                                .accessibilityIdentifier("edit-device.\(device.id)")
                                Menu {
                                    Button("Configure Output…") { configuringOutput = device }
                                        .disabled(!(2...16).contains(device.outputChannelCount) && device.outputChannels == nil)
                                    Button("Reset Effect Chain…") { action = .reset(device) }
                                        .disabled(!device.hasProfile)
                                    Button("Forget Device…", role: .destructive) { action = .forget(device) }
                                        .disabled(device.isCurrent || !device.hasProfile)
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Manage \(device.name)")
                                .accessibilityLabel("Manage \(device.name)")
                            }
                            if host.editingDevices.last?.id != device.id { Divider().padding(.leading, 42) }
                        }
                    }
                    .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
        .sheet(item: $configuringOutput) { target in
            HostOutputConfigurationView(host: host, target: target)
        }
        .confirmationDialog("Manage Effect Chain", isPresented: Binding(
            get: { action != nil },
            set: { if !$0 { action = nil } }
        ), presenting: action) { action in
            Button(action.title, role: .destructive) {
                switch action {
                case .reset(let device): host.resetProfile(device.id)
                case .forget(let device): host.forgetProfile(device.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text("This removes all saved effects from \(action.device.name).")
        }
    }
}

private struct HostOutputConfigurationView: View {
    @ObservedObject var host: HostController
    let target: HostDeviceTarget
    @Environment(\.dismiss) private var dismiss
    @State private var left: Int
    @State private var right: Int
    @State private var error: String?

    init(host: HostController, target: HostDeviceTarget) {
        self.host = host
        self.target = target
        let pair = target.outputChannels ?? target.preferredOutputChannels ?? StereoOutputChannels(left: 1, right: 2)
        _left = State(initialValue: pair.left)
        _right = State(initialValue: pair.right)
    }

    private var current: HostDeviceTarget? { host.editingDevices.first { $0.id == target.id } }
    private var channelCount: Int { current?.outputChannelCount ?? 0 }
    private var available: Bool { (2...16).contains(channelCount) }
    private var pair: StereoOutputChannels { StereoOutputChannels(left: left, right: right) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure Output")
                .font(.title2.weight(.semibold))
            Text(target.name)
                .foregroundStyle(.secondary)
            Form {
                picker("Left output", selection: $left)
                picker("Right output", selection: $right)
            }
            .disabled(!available)
            if let message = error ?? validationMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Use macOS Default") { save(nil) }
                    .disabled(current?.outputChannels == nil)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(pair) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onChange(of: left) { error = nil }
        .onChange(of: right) { error = nil }
    }

    private var validationMessage: String? {
        if !available { return "Reconnect this output to choose its channels." }
        if left == right { return "Choose different channels for left and right." }
        if !pair.isInRange(channelCount: channelCount) { return "The saved channel pair is unavailable on this output." }
        return nil
    }

    private func picker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            if available {
                ForEach(1...channelCount, id: \.self) { channel in
                    Text("Channel \(channel)").tag(channel)
                }
            }
            if !(available && (1...channelCount).contains(selection.wrappedValue)) {
                Text("Channel \(selection.wrappedValue) (Unavailable)").tag(selection.wrappedValue)
            }
        }
    }

    private func save(_ pair: StereoOutputChannels?) {
        do {
            try host.configureOutput(for: target.id, channels: pair)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
private struct HostMixerPage: View {
    @ObservedObject var host: HostController

    var body: some View {
        let recent = host.mixerRows.filter(\.isRecent)
        let saved = host.mixerRows.filter { $0.isAdjusted && !$0.isRecent }
        HostAudioPage(title: "App Mixer", subtitle: "Adjust volume for individual apps.") {
            Group {
                if recent.isEmpty && saved.isEmpty {
                    HostEmptyState(icon: "speaker.wave.2", title: "No apps to mix",
                                   detail: "Play audio in an app to adjust its volume here.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            mixerSection("Playing & Recent", rows: recent)
                            if !saved.isEmpty { mixerSection("Saved Adjustments", rows: saved) }
                        }
                    }
                }
            }
            .accessibilityIdentifier("app-mixer-list")
        }
    }

    private func mixerSection(_ title: String, rows: [AppMixerRow]) -> some View {
        VStack(alignment: .leading, spacing: HostAppearance.audioPageSpacing) {
            Text(title)
                .font(.headline)
                .frame(minHeight: HostAppearance.audioSectionHeaderHeight)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text("Play audio to see apps here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        HostMixerRow(host: host, row: row)
                        if rows.last?.id != row.id { Divider().padding(.leading, 42) }
                    }
                }
                .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))
            }
        }
    }
}

@MainActor
private struct HostMixerRow: View {
    let host: HostController
    let row: AppMixerRow
    var compact = false

    private var percentage: String { (row.volume / 100).formatted(.percent.precision(.fractionLength(0))) }
    private var muteAction: String { row.isMuted ? "Unmute \(row.name)" : "Mute \(row.name)" }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "app").foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)

            Text(row.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: compact ? 76 : 156, alignment: .leading)
                .help(row.name)
                .accessibilityIdentifier("app-mixer-name.\(row.id)")

            Slider(value: Binding(get: { row.volume }, set: { host.setAppVolume($0, for: row.id) }),
                   in: 0...100, step: 1) {
                Text("\(row.name) volume")
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityValue(row.isMuted ? "\(percentage), muted" : percentage)
            .accessibilityIdentifier("app-mixer-volume.\(row.id)")

            Text(percentage)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 33, alignment: .trailing)
                .accessibilityHidden(true)

            Button {
                host.setAppMuted(!row.isMuted, for: row.id)
            } label: {
                Image(systemName: row.isMuted ? "speaker.slash" : "speaker.wave.2")
                    .foregroundStyle(row.isMuted ? Color.accentColor : .primary)
                    .frame(width: 30, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(muteAction)
            .accessibilityLabel(muteAction)
            .accessibilityIdentifier("app-mixer-mute.\(row.id)")

        }
        .padding(.horizontal, 12)
        .frame(height: compact ? 36 : HostAppearance.audioRowHeight)
        .contentShape(.rect)
        .contextMenu {
            if !compact, row.isAdjusted, !row.isRecent {
                Button("Clear Saved Adjustment") { host.resetAppVolume(for: row.id) }
            }
        }
    }
}

private struct HostSettingsPage: View {
    @ObservedObject var shell: ShellModel
    @ObservedObject var updates: HostUpdateManager

    var body: some View {
        HostAudioPage(title: "Settings", subtitle: "Manage startup, menu bar access, and updates.") {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 0) {
                        HostPreferenceRows(shell: shell)
                    }
                    .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))

                    utilityRows
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var utilityRows: some View {
        VStack(spacing: 0) {
            Button(action: shell.showSetup) {
                HostSettingsRow(icon: "wrench.and.screwdriver", title: "Setup & Troubleshooting") {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Setup & Troubleshooting")
            .accessibilityIdentifier("setup-troubleshooting")

            Divider().padding(.leading, 42)
            HostSettingsRow(icon: "arrow.trianglehead.clockwise.rotate.90",
                            title: "Software Update", subtitle: updates.statusLabel) {
                if !updates.isAvailable {
                    Text("Unavailable in this build")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if updates.isChecking {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Checking for updates")
                } else {
                    Button(updates.actionTitle, action: updates.checkForUpdates)
                        .controlSize(.small)
                        .disabled(!updates.canCheck)
                        .accessibilityIdentifier("check-for-updates")
                }
            }
            Divider().padding(.leading, 42)
            HostSettingsRow(icon: "info", title: "Version") {
                Text(updates.installedVersion)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))
    }
}

struct HostPreferenceRows: View {
    @ObservedObject var shell: ShellModel

    var body: some View {
        HostSettingsRow(icon: "play.circle.fill", title: "Launch at Login",
                        subtitle: shell.loginItemError,
                        iconColor: shell.loginItemError == nil ? .secondary : .orange) {
            Toggle("Launch at Login", isOn: Binding(get: { shell.launchesAtLogin }, set: shell.setLaunchAtLogin))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier("launch-at-login")
        }
        Divider().padding(.leading, 42)
        HostSettingsRow(icon: "menubar.rectangle", title: "Show in Menu Bar") {
            Toggle("Show in Menu Bar", isOn: Binding(get: { shell.showsMenuBar }, set: shell.setMenuBarVisible))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier("show-in-menu-bar")
        }
    }
}

@MainActor
struct HostMenuPopover: View {
    @ObservedObject var host: HostController
    @ObservedObject var shell: ShellModel
    let openWindow: () -> Void
    let openMixer: () -> Void
    let openSetup: () -> Void
    let quit: () -> Void
    @State private var mixerRows: [AppMixerRow] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HostBrand(markSize: 16, titleFont: .system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            divider
            processingStatus
            if shell.setupCompleted {
                mixer
                divider
            }
            VStack(spacing: 2) {
                if !shell.setupCompleted {
                    HostMenuAction(title: "Complete Set Up…", action: openSetup)
                }
                HostMenuAction(title: "Open Airwave", action: openWindow)
            }
            .padding(.vertical, 4)
            divider
            HostMenuAction(title: "Quit Airwave", action: quit)
                .padding(.vertical, 4)
        }
        .frame(width: shell.setupCompleted ? 310 : 280)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .environment(\.colorScheme, .dark)
        .background(HostAppearance.canvas)
    }

    @ViewBuilder
    private var processingStatus: some View {
        let notice = host.processingNotice
        let canResume = shell.setupCompleted && !host.isEnabled
        if canResume || notice?.isWarning == true {
            VStack(alignment: .leading, spacing: 8) {
                if canResume {
                    HStack {
                        Text("Processing off")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Resume") { host.setEnabled(true) }
                            .controlSize(.small)
                            .accessibilityLabel("Resume Processing")
                            .accessibilityIdentifier("menu-resume-processing")
                    }
                }
                if let notice, notice.isWarning {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(notice.message)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("menu-warning-details")
                            if case .captureFailure = notice {
                                Button("Troubleshoot…", action: openSetup)
                                    .controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    } label: {
                        Label("Audio Issue", systemImage: "exclamationmark.triangle")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    .accessibilityIdentifier("menu-audio-issue")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            divider
        }
    }

    private var mixer: some View {
        let currentIDs = Set(host.mixerRows.map(\.id))
        return VStack(alignment: .leading, spacing: 0) {
            Text("App Mixer")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            if mixerRows.isEmpty {
                Text("Play audio to see apps here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(mixerRows) { row in
                            HostMixerRow(host: host, row: row, compact: true)
                                .disabled(!currentIDs.contains(row.id))
                        }
                    }
                }
                .frame(height: CGFloat(min(mixerRows.count, 6)) * 36)
                .accessibilityIdentifier("menu-app-mixer-list")
            }
            HostMenuAction(title: "Open App Mixer", action: openMixer)
                .accessibilityIdentifier("open-app-mixer")
                .padding(.bottom, 4)
        }
        .onAppear { mixerRows = host.mixerRows.filter(\.isRecent) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  HostWindowLifecycle.isMenuBarPopover(window) else { return }
            mixerRows = host.mixerRows.filter(\.isRecent)
        }
        .onReceive(host.$mixerRows, perform: updateMixerRows)
    }

    private func updateMixerRows(_ rows: [AppMixerRow]) {
        let currentByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let shownIDs = Set(mixerRows.map(\.id))
        mixerRows = mixerRows.map { row in
            currentByID[row.id] ?? row
        } + rows.filter { $0.isRecent && !shownIDs.contains($0.id) }
    }

    private var divider: some View { Divider().padding(.horizontal, 10) }
}

private struct HostMenuAction: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(hovered ? HostAppearance.hover : .clear, in: .rect(cornerRadius: 12))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

extension AnyTransition {
    static var hostPageReveal: Self {
        .modifier(active: HostPageReveal(revealed: false), identity: HostPageReveal(revealed: true))
    }

    fileprivate static func hostPageSlide(edge: Edge) -> Self {
        .move(edge: edge).combined(with: .modifier(
            active: HostPageSlideAppearance(revealed: false),
            identity: HostPageSlideAppearance(revealed: true)
        ))
    }
}

private struct HostPageSlideAppearance: ViewModifier {
    let revealed: Bool

    func body(content: Content) -> some View {
        content.blur(radius: revealed ? 0 : 8)
            .opacity(revealed ? 1 : 0.72)
    }
}

private struct HostPageReveal: ViewModifier {
    let revealed: Bool

    func body(content: Content) -> some View {
        content.scaleEffect(revealed ? 1 : 0.97)
            .blur(radius: revealed ? 0 : 8)
            .opacity(revealed ? 1 : 0)
    }
}

@MainActor
struct HostEditorHeader: View {
    static let height: CGFloat = 44

    @ObservedObject var host: HostController
    let slot: EffectSlot
    let deviceUID: String

    var body: some View {
        let current = host.effectSlot(slot.id, for: deviceUID)
        let bypassed = current?.isBypassed ?? true
        let state = bypassed ? "Off" : "On"
        let actionTitle = bypassed ? "Enable \(slot.name)" : "Bypass \(slot.name)"

        HStack(spacing: 8) {
            Text(slot.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("editor-effect-title")

            Spacer(minLength: 0)

            HostHeaderIconButton(symbol: "power", tint: HostAppearance.powerTint(isOn: !bypassed)) {
                host.setBypass(slot.id, !bypassed, for: deviceUID)
            }
            .disabled(current == nil || current?.migrationIssue != nil)
            .help(actionTitle)
            .accessibilityLabel(actionTitle)
            .accessibilityValue(state)
            .accessibilityIdentifier("editor-bypass-effect")
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .frame(height: Self.height)
        .background(HostAppearance.canvas)
    }
}

@MainActor
struct EffectChain: View {
    private struct Drag {
        let id: UUID
        let startY: CGFloat
        let startScrollY: CGFloat
        var location: CGPoint

        func displacement(at scrollY: CGFloat) -> CGFloat {
            location.y - startY + scrollY - startScrollY
        }
    }

    @ObservedObject var host: HostController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: Drag?
    @State private var liftedID: UUID?
    @State private var escapeMonitor: Any?
    @State private var viewport = CGRect.zero
    @State private var scrollY: CGFloat = 0
    @State private var scrollPosition = ScrollPosition()

    private let rowHeight = HostAppearance.audioRowHeight
    private var slots: [EffectSlot] { host.editingSlots }
    private var chainHeight: CGFloat { CGFloat(slots.count) * rowHeight }
    private var spring: Animation? { reduceMotion ? nil : .interactiveSpring(duration: 0.24, extraBounce: 0) }

    var body: some View {
        let source = drag.flatMap { active in slots.firstIndex { $0.id == active.id } }
        let target = source.flatMap { index in drag.map { insertionIndex(for: $0, from: index) } }
        ScrollView {
            ZStack(alignment: .top) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    let isDragged = drag?.id == slot.id
                    EffectRow(
                        slot: slot,
                        issue: host.editingSlotIssues[slot.id],
                        isLifted: isDragged && !reduceMotion,
                        hasDivider: index != slots.count - 1,
                        canMoveUp: index > 0,
                        canMoveDown: index < slots.count - 1,
                        openEditor: { host.openEditingEditor(slot.id) },
                        toggleBypass: { host.setEditingBypass(slot.id, !slot.isBypassed) },
                        remove: { host.removeEditing(slot.id) },
                        move: { distance in withAnimation(spring) { move(from: index, to: index + distance) } },
                        startDrag: { start, location in startDrag(slot.id, from: start, at: location) },
                        updateDrag: { drag?.location = $0 },
                        endDrag: endDrag,
                        canDrag: slots.count > 1
                    )
                    .offset(y: rowPosition(index, source: source, target: target))
                    .zIndex(liftedID == slot.id ? 1 : 0)
                    .animation(isDragged ? nil : spring, value: target)
                }
                if reduceMotion, let source, let target, target != source {
                    let boundary = target > source ? target + 1 : target
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 6)
                        .offset(y: min(chainHeight - 2, max(0, CGFloat(boundary) * rowHeight - 1)))
                        .zIndex(2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: chainHeight, alignment: .top)
            .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))
        }
        .defaultScrollAnchor(.top)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.visibleRect.minY }) { _, y in scrollY = y }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { viewport = $0 }
        .task(id: scrollStep) { await scrollWhileDragging(step: scrollStep) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            finishDrag()
        }
        .onDisappear { removeEscapeMonitor() }
        .accessibilityIdentifier("effect-chain")
    }

    private func rowPosition(_ index: Int, source: Int?, target: Int?) -> CGFloat {
        let initial = CGFloat(index) * rowHeight
        guard !reduceMotion, let drag, let source, let target else { return initial }
        if index == source { return initial + drag.displacement(at: scrollY) }
        if source < index, index <= target { return initial - rowHeight }
        if target <= index, index < source { return initial + rowHeight }
        return initial
    }

    private func insertionIndex(for drag: Drag, from source: Int) -> Int {
        let sourceCenter = CGFloat(source) + 0.5
        let center = sourceCenter + drag.displacement(at: scrollY) / rowHeight
        let crossed = center < sourceCenter ? center + 0.5 : center - 0.5
        return min(slots.count - 1, max(0, Int(floor(crossed))))
    }

    private var scrollStep: CGFloat {
        guard let drag, viewport.contains(drag.location) else { return 0 }
        if drag.location.y < viewport.minY + 28, scrollY > 0 { return -6 }
        if drag.location.y > viewport.maxY - 28, scrollY < chainHeight - viewport.height { return 6 }
        return 0
    }

    private func scrollWhileDragging(step: CGFloat) async {
        guard step != 0 else { return }
        while !Task.isCancelled, drag != nil {
            scrollPosition.scrollTo(y: min(max(0, scrollY + step), max(0, chainHeight - viewport.height)))
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func startDrag(_ id: UUID, from start: CGPoint, at location: CGPoint) {
        drag = Drag(id: id, startY: start.y, startScrollY: scrollY, location: location)
        liftedID = reduceMotion ? nil : id
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            finishDrag()
            return nil
        }
    }

    private func endDrag(at location: CGPoint) {
        guard var active = drag,
              viewport.contains(location),
              let source = slots.firstIndex(where: { $0.id == active.id }) else {
            finishDrag()
            return
        }
        active.location = location
        finishDrag(to: insertionIndex(for: active, from: source))
    }

    private func finishDrag(to destination: Int? = nil) {
        guard let active = drag else { return }
        removeEscapeMonitor()
        withAnimation(spring) {
            drag = nil
            if let destination, let source = slots.firstIndex(where: { $0.id == active.id }) {
                move(from: source, to: destination)
            }
        } completion: {
            if drag == nil, liftedID == active.id { liftedID = nil }
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func move(from source: Int, to destination: Int) {
        guard source != destination, slots.indices.contains(destination) else { return }
        host.moveEditing(from: IndexSet(integer: source), to: destination > source ? destination + 1 : destination)
    }
}

private struct EffectActionAppearance: ViewModifier {
    static let size: CGFloat = 32

    let hovered: Bool
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: Self.size, height: Self.size)
            .background(hovered ? HostAppearance.hover : .clear, in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
    }
}

private struct EffectRow: View {
    private enum Target: Hashable { case card, power, actions, issue }

    let slot: EffectSlot
    let issue: String?
    let isLifted: Bool
    let hasDivider: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let openEditor: () -> Void
    let toggleBypass: () -> Void
    let remove: () -> Void
    let move: (Int) -> Void
    let startDrag: (CGPoint, CGPoint) -> Void
    let updateDrag: (CGPoint) -> Void
    let endDrag: (CGPoint) -> Void
    let canDrag: Bool
    @State private var hovered: Target?
    @FocusState private var focus: Target?

    private let actionSpacing: CGFloat = 2
    private let actionInset: CGFloat = 8
    private var showsPower: Bool { slot.migrationIssue == nil }
    private var actionsWidth: CGFloat {
        let count = CGFloat(1 + (showsPower ? 1 : 0) + (issue != nil ? 1 : 0))
        return count * EffectActionAppearance.size + (count - 1) * actionSpacing + actionInset
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: openEditor) {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 25, height: 32)
                        .accessibilityHidden(true)
                    labels
                }
                .padding(.leading, 12)
                .padding(.trailing, actionsWidth + 12)
                .frame(maxWidth: .infinity, minHeight: HostAppearance.audioRowHeight, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .card)
            .focusEffectDisabled()
            .help("Open \(slot.name) controls")
            .accessibilityLabel("Open \(slot.name) controls")
            .accessibilityValue(slot.isBypassed ? "Bypassed" : "Enabled")
            .accessibilityIdentifier("open-editor")
            .overlay {
                EffectCardPointer(
                    click: openEditor, start: startDrag, move: updateDrag, end: endDrag,
                    canDrag: canDrag, hover: updateHover
                )
                .accessibilityHidden(true)
            }

            HStack(spacing: actionSpacing) {
                if let issue {
                    HostNoticeButton(notice: .warning(issue))
                        .accessibilityLabel("Issue with \(slot.name)")
                        .accessibilityIdentifier("effect-issue")
                        .frame(width: EffectActionAppearance.size)
                }
                if showsPower { power }
                moreActions
            }
            .padding(.trailing, actionInset)
        }
        .frame(height: HostAppearance.audioRowHeight)
        .background {
            if isLifted {
                HostAppearance.raised
            }
            if isLifted || hovered == .card {
                HostAppearance.hover
                    .opacity(isLifted ? 1 : 0.55)
                    .clipShape(.rect(cornerRadius: HostAppearance.cornerRadius))
            }
        }
        .overlay(alignment: .bottom) {
            if hasDivider, !isLifted { Divider().padding(.leading, 46).allowsHitTesting(false) }
        }
        .clipShape(.rect(cornerRadius: isLifted ? HostAppearance.cornerRadius : 0))
        .shadow(color: isLifted ? .black.opacity(0.35) : .clear, radius: 9, y: 4)
        .overlay {
            RoundedRectangle(cornerRadius: HostAppearance.cornerRadius)
                .strokeBorder(focus == .card ? Color.accentColor : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
    }

    private var power: some View {
        let title = slot.isBypassed ? "Enable \(slot.name)" : "Bypass \(slot.name)"
        return Button(action: toggleBypass) {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HostAppearance.powerTint(isOn: !slot.isBypassed))
                .modifier(EffectActionAppearance(hovered: hovered == .power, focused: focus == .power))
        }
        .buttonStyle(.plain)
        .focused($focus, equals: .power)
        .focusEffectDisabled()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(slot.isBypassed ? "Off" : "On")
        .accessibilityIdentifier("bypass-effect")
    }

    private var moreActions: some View {
        Menu {
            Button("Move Up") { move(-1) }.disabled(!canMoveUp)
            Button("Move Down") { move(1) }.disabled(!canMoveDown)
            Divider()
            Button("Remove Effect", role: .destructive, action: remove)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: EffectActionAppearance.size, height: EffectActionAppearance.size)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(EffectActionAppearance(hovered: hovered == .actions, focused: focus == .actions))
        .focused($focus, equals: .actions)
        .focusEffectDisabled()
        .help("More actions for \(slot.name)")
        .accessibilityLabel("More actions for \(slot.name)")
        .accessibilityIdentifier("effect-actions")
    }

    private func updateHover(_ point: CGPoint?, width: CGFloat) {
        guard let point else {
            hovered = nil
            return
        }
        let size = EffectActionAppearance.size
        let step = size + actionSpacing
        let x = width - actionInset - point.x
        let targets: [Target] = [.actions] + (showsPower ? [.power] : []) + (issue == nil ? [] : [.issue])
        let control = abs(point.y - HostAppearance.audioRowHeight / 2) <= size / 2
            ? targets.enumerated().first { (step * CGFloat($0.offset)..<(step * CGFloat($0.offset) + size)).contains(x) }?.element
            : nil
        hovered = control ?? .card
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(slot.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(slot.isBypassed ? Color.secondary : Color.primary)
                    .lineLimit(1)
                if slot.isBypassed {
                    Image(systemName: "circle.slash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            if !slot.manufacturer.isEmpty {
                Text(slot.manufacturer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EffectCardPointer: NSViewRepresentable {
    let click: () -> Void
    let start: (CGPoint, CGPoint) -> Void
    let move: (CGPoint) -> Void
    let end: (CGPoint) -> Void
    let canDrag: Bool
    let hover: (CGPoint?, CGFloat) -> Void

    func makeNSView(context: Context) -> PointerView { PointerView() }

    func updateNSView(_ view: PointerView, context: Context) {
        view.input = self
    }

    // Keep pointer tracking separate from the SwiftUI button so AppKit can deliver Escape during a drag.
    final class PointerView: NSView {
        var input: EffectCardPointer?
        private var press: CGPoint?
        private var dragging = false
        private var pointerTracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerTracking { removeTrackingArea(pointerTracking) }
            let tracking = NSTrackingArea(
                rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                owner: self, userInfo: nil
            )
            addTrackingArea(tracking)
            pointerTracking = tracking
        }

        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

        override func mouseExited(with event: NSEvent) {
            input?.hover(nil, bounds.width)
        }

        override func mouseMoved(with event: NSEvent) {
            input?.hover(convert(event.locationInWindow, from: nil), bounds.width)
        }

        override func mouseDown(with event: NSEvent) {
            press = location(event)
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let input, let press else { return }
            let current = location(event)
            if dragging {
                input.move(current)
            } else if input.canDrag, hypot(current.x - press.x, current.y - press.y) >= 5 {
                dragging = true
                input.start(press, current)
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard let press else { return }
            let current = location(event)
            self.press = nil
            if dragging {
                dragging = false
                input?.end(current)
            } else if hypot(current.x - press.x, current.y - press.y) < 5,
                      bounds.contains(convert(event.locationInWindow, from: nil)) {
                input?.click()
            }
        }

        private func location(_ event: NSEvent) -> CGPoint {
            guard let content = window?.contentView else { return .zero }
            let point = content.convert(event.locationInWindow, from: nil)
            return CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
        }
    }
}

struct EffectPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: HostController
    var allowsMultiple = false
    @State private var search = ""
    @State private var addedCount = 0
    @FocusState private var searchFocused: Bool
    let add: (EffectComponent) -> Bool

    private var filteredComponents: [EffectComponent] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = host.components
        guard !query.isEmpty else { return available }
        return available.filter {
            "\($0.manufacturer) \($0.name)".localizedStandardContains(query)
                || $0.name.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(allowsMultiple ? "Add Effects" : "Add Effect")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search Audio Units", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("effect-search")
                    .onSubmit {
                        if filteredComponents.count == 1, let component = filteredComponents.first {
                            addEffect(component)
                        }
                    }
            }
            .padding(8)
            .background(HostAppearance.raised, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)) }

            results

            HStack {
                Button("Rescan", action: host.rescan)
                Spacer()
                if allowsMultiple && addedCount > 0 {
                    Text("\(addedCount) added")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button(allowsMultiple ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 450, height: 380)
        .background(HostAppearance.canvas)
        .onAppear { searchFocused = true }
    }

    private func addEffect(_ component: EffectComponent) {
        guard add(component) else { return }
        if allowsMultiple {
            addedCount += 1
        } else {
            dismiss()
        }
    }

    private var results: some View {
        Group {
            if filteredComponents.isEmpty {
                if host.components.isEmpty {
                    HostEmptyState(icon: "puzzlepiece", title: "No compatible Audio Units",
                                   detail: "Install an Audio Unit effect, then rescan.")
                } else {
                    HostEmptyState(icon: "magnifyingglass", title: "No matches",
                                   detail: "Try a different effect or manufacturer name.",
                                   action: Button("Clear Search") {
                                       search = ""
                                       searchFocused = true
                                   })
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredComponents) { component in
                            Button {
                                addEffect(component)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(component.name)
                                            .font(.body.weight(.medium))
                                        if !component.manufacturer.isEmpty {
                                            Text(component.manufacturer)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "plus")
                                        .foregroundStyle(Color.accentColor)
                                }
                                .padding(8)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Add \(component.name)")
                            Divider()
                        }
                    }
                }
            }
        }
    }
}
