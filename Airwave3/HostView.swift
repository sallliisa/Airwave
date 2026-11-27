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
        .animation(reduceMotion || showsSetup ? nil : .easeInOut(duration: 0.16), value: selectedTab)
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
        Button { confirmsQuit = true } label: {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
    @State private var hovered = false

    var body: some View {
        Button {
            host.setEnabled(!host.isEnabled)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                Text(host.isEnabled ? "On" : "Off")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(host.isEnabled ? Color.primary : .orange)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: HostAppearance.cornerRadius)
                    .fill(hovered ? Color.white.opacity(0.16) : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(host.isEnabled ? "Bypass all effects and app volume adjustments" : "Resume audio processing")
        .accessibilityLabel(host.isEnabled ? "Bypass Processing" : "Resume Processing")
        .accessibilityValue(host.isEnabled ? "On" : "Off")
        .accessibilityIdentifier("global-bypass")
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: HostAppearance.audioPageSpacing) {
            HostPageHeader(title: title)
            content()
        }
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
        HostAudioPage(title: "Effect Chain") {
            VStack(alignment: .leading, spacing: HostAppearance.audioPageSpacing) {
                deviceBar
                if host.editingSlots.isEmpty {
                    emptyChain
                } else {
                    effectChain
                        .id(host.editingDeviceUID)
                }
            }
        }
        .sheet(isPresented: $showingEffects) {
            EffectPicker(host: host) { component in
                host.addEditing(component)
                showingEffects = false
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

            if editingDevice != nil {
                Button("Manage Devices", action: manageDevices)
                    .fixedSize()
                    .accessibilityIdentifier("registered-devices")
            }

            Button {
                host.rescan()
                showingEffects = true
            } label: {
                Label("Add Effect…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(editingDevice == nil)
            .accessibilityLabel("Add Effect")
            .accessibilityIdentifier("add-effect")
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

    private var emptyChain: some View {
        Text(editingDevice == nil ? "Connect a supported audio output." : "No effects on this device.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: HostAppearance.audioRowHeight, alignment: .leading)
            .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))
    }

    private var effectChain: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(host.editingSlots) { slot in
                    EffectRow(
                        slot: slot,
                        issue: host.editingSlotIssues[slot.id],
                        canMoveUp: host.editingSlots.first?.id != slot.id,
                        canMoveDown: host.editingSlots.last?.id != slot.id,
                        openEditor: { host.openEditingEditor(slot.id) },
                        toggleBypass: { host.setEditingBypass(slot.id, !slot.isBypassed) },
                        remove: { host.removeEditing(slot.id) },
                        move: { distance in move(slot.id, by: distance) },
                        drop: { source in move(source, to: slot.id) }
                    )
                    if host.editingSlots.last?.id != slot.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))
        }
        .defaultScrollAnchor(.top)
        .accessibilityIdentifier("effect-chain")
    }

    private func move(_ id: UUID, by distance: Int) {
        guard let index = host.editingSlots.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + distance
        guard host.editingSlots.indices.contains(destination) else { return }
        host.moveEditing(from: IndexSet(integer: index), to: destination > index ? destination + 1 : destination)
    }

    private func move(_ id: UUID, to target: UUID) -> Bool {
        guard id != target,
              let source = host.editingSlots.firstIndex(where: { $0.id == id }),
              let destination = host.editingSlots.firstIndex(where: { $0.id == target }) else { return false }
        host.moveEditing(from: IndexSet(integer: source), to: destination > source ? destination + 1 : destination)
        return true
    }
}

struct HostBrand: View {
    var markSize: CGFloat = 24
    var titleFont: Font = .headline

    var body: some View {
        HStack(spacing: markSize > 16 ? 12 : 8) {
            Image(systemName: "waveform")
                .font(.system(size: markSize * 0.8, weight: .semibold))
                .frame(width: markSize, height: markSize)
                .accessibilityHidden(true)
            Text("Airwave").font(titleFont)
        }
    }
}

private struct HostPageHeader: View {
    let title: String

    var body: some View {
        Text(title).font(.largeTitle.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HostPageHeader(title: title)
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
            HStack(spacing: 14) {
                HostBackButton(action: shell.showEffects)
                    .accessibilityIdentifier("back-to-effects")
                HostPageHeader(title: "Manage Devices")
            }

            if host.editingDevices.isEmpty {
                Text("No supported outputs or saved devices.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))
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
        HostAudioPage(title: "App Mixer") {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    mixerSection("Playing & Recent", rows: host.mixerRows.filter(\.isRecent))
                    let saved = host.mixerRows.filter { $0.isAdjusted && !$0.isRecent }
                    if !saved.isEmpty { mixerSection("Saved Adjustments", rows: saved) }
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
            LazyVStack(spacing: 0) {
                if rows.isEmpty {
                    Text("Play audio to see apps here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: HostAppearance.audioRowHeight, alignment: .leading)
                } else {
                    ForEach(rows) { row in
                        HostMixerRow(host: host, row: row)
                        if rows.last?.id != row.id { Divider().padding(.leading, 42) }
                    }
                }
            }
            .background(HostAppearance.raised, in: .rect(cornerRadius: HostAppearance.cornerRadius))
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

private struct EffectDrag: Codable, Transferable {
    var id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

private struct EffectRow: View {
    let slot: EffectSlot
    let issue: String?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let openEditor: () -> Void
    let toggleBypass: () -> Void
    let remove: () -> Void
    let move: (Int) -> Void
    let drop: (UUID) -> Bool
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 25, height: 32)
                .accessibilityHidden(true)

            labels
            Spacer(minLength: 6)
            if let issue {
                HostNoticeButton(notice: .warning(issue))
                    .accessibilityLabel("Issue with \(slot.name)")
                    .accessibilityIdentifier("effect-issue")
            }
            Button(action: toggleBypass) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(slot.isBypassed ? Color.secondary : Color.accentColor)
                    .frame(width: 27, height: 29)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(slot.isBypassed ? "Enable \(slot.name)" : "Bypass \(slot.name)")
            .accessibilityLabel(slot.isBypassed ? "Enable \(slot.name)" : "Bypass \(slot.name)")
            .accessibilityIdentifier("bypass-effect")

            Button(action: openEditor) {
                Label("Controls", systemImage: "slider.horizontal.3")
            }
            .controlSize(.small)
            .help("Open \(slot.name) controls")
            .accessibilityLabel("Open \(slot.name) controls")
            .accessibilityIdentifier("open-editor")

            Menu {
                Button("Move Up") { move(-1) }
                    .disabled(!canMoveUp)
                Button("Move Down") { move(1) }
                    .disabled(!canMoveDown)
                Divider()
                Button("Remove Effect", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions for \(slot.name)")
            .accessibilityLabel("More actions for \(slot.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: HostAppearance.audioRowHeight)
        .background {
            RoundedRectangle(cornerRadius: HostAppearance.cornerRadius)
                .fill(isDropTarget ? Color.accentColor.opacity(0.13) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: HostAppearance.cornerRadius)
                .strokeBorder(isDropTarget ? Color.accentColor : .clear)
                .allowsHitTesting(false)
        }
        .contentShape(.rect)
        .draggable(EffectDrag(id: slot.id))
        .dropDestination(for: EffectDrag.self) { items, _ in
            guard items.count == 1, let item = items.first else { return false }
            return drop(item.id)
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(slot.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(slot.isBypassed ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .help(slot.name)
                    .accessibilityIdentifier("effect-name")
                if slot.isBypassed {
                    Text("Bypassed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
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

struct EffectPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: HostController
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    let add: (EffectComponent) -> Void

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
            Text("Add Effect")
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
                            add(component)
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
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 450, height: 380)
        .background(HostAppearance.canvas)
        .onAppear { searchFocused = true }
    }

    private var results: some View {
        Group {
            if filteredComponents.isEmpty {
                Text(host.components.isEmpty ? "No compatible Audio Units found." : "No matching Audio Units.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredComponents) { component in
                            Button {
                                add(component)
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
