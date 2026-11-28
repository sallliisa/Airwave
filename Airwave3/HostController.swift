import AppKit
import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import CoreAudioKit
import SwiftUI
import Synchronization

struct HostDeviceTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let isCurrent: Bool
    let isConnected: Bool
    let hasProfile: Bool
    let outputChannels: StereoOutputChannels?
    let outputChannelCount: Int
    let preferredOutputChannels: StereoOutputChannels?
}

enum CaptureCheckStatus: Equatable {
    case idle
    case checking
    case verified
    case failed(String)
}

enum HostProcessingNotice {
    case information(String)
    case warning(String)
    case captureFailure(String)

    var message: String {
        switch self {
        case .information(let message), .warning(let message), .captureFailure(let message): message
        }
    }

    var isWarning: Bool {
        if case .information = self { return false }
        return true
    }
}

@MainActor
final class HostController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var outputName = "No audio output"
    @Published private(set) var slots: [EffectSlot] = []
    @Published private(set) var components: [EffectComponent] = []
    @Published private(set) var isEnabled = true
    @Published private(set) var status = "Normal macOS playback"
    @Published private(set) var slotIssues: [UUID: String] = [:]
    @Published private(set) var editingDeviceUID: String?
    @Published private(set) var captureCheck: CaptureCheckStatus = .idle
    @Published private(set) var mixerRows: [AppMixerRow] = []
    @Published private var profiles: [String: DeviceProfile] = [:]
    @Published private var connected: [String: OutputDevice] = [:]
    @Published private var currentDeviceUID: String?
    @Published private var offlineIssues: [UUID: String] = [:]

    private enum Playback {
        case native
        case startingCheck(explicit: Bool)
        case checking(SystemAudioRoute, CaptureSignal, explicit: Bool, started: Date)
        case processing(SystemAudioRoute)
        case failed(String)

        var route: SystemAudioRoute? {
            switch self {
            case .checking(let route, _, _, _), .processing(let route): route
            case .native, .startingCheck, .failed: nil
            }
        }
    }

    // A route is handed to the main actor only after the worker stops touching it.
    private enum VerificationStart: @unchecked Sendable {
        case started(SystemAudioRoute)
        case failed(String, cleanup: SystemAudioRoute?)

        var route: SystemAudioRoute? {
            switch self {
            case .started(let route): route
            case .failed(_, let cleanup): cleanup
            }
        }
    }

    private let store: ProfileStore
    private let defaults: UserDefaults
    private let presetLibrary: PresetMigrationStore?
    private let migrationWarning: String?
    @Published private var presetUpgradeWarning: String?
    private var presetUpgrade: Task<Void, Never>?
    private let currentOutput: () throws -> OutputDevice
    private let availableOutputs: () -> [OutputDevice]
    private let chain: RenderChain
    private let effectCatalog: EffectCatalog
    private let makeVerificationRoute: VerificationRouteFactory
    private let mixer: AppMixer
    private let audioApplications = AudioApplicationCatalog()
    private var mixerSources: [AppMixerSource] = []
    private var mixerRequiresRouting = false
    private var routedMixerSources: [AppMixerSource] = []
    private var rejectedMixerSources: [AppMixerSource]?
    private var lastDeviceScan = Date.distantPast
    private var suspendedForSleep = false
    private var storageError: String?
    private var storageReadOnly = false
    private var output: OutputDevice?
    private var effects: [UUID: LiveEffect] = [:]
    private var spatialLayouts: [UUID: InputLayout] = [:]
    private var loadTasks: [UUID: Task<Void, Never>] = [:]
    private var playback: Playback = .native
    private var verificationStartup: Task<VerificationStart, Never>?
    private var pendingCleanup: SystemAudioRoute?
    private var captureVerified = false
    private var lastCallbacks: UInt64 = 0
    private var lastCallbackTime = Date()
    private var recoveryAttempted = false
    private var heartbeat: Timer?
    private struct Editor {
        let deviceUID: String
        let effect: LiveEffect
        let spatialLayout: InputLayout?
        let window: NSWindow
    }

    private var editors: [UUID: Editor] = [:]
    private var openingEditors: [UUID: UUID] = [:]
    private var probeSound: NSSound?

    typealias VerificationRouteFactory = @Sendable (OutputDevice, StereoOutputChannels?, @escaping StereoRender) throws -> SystemAudioRoute

    init(
        store: ProfileStore = ProfileStore(), defaults: UserDefaults = .standard,
        presetLibrary: PresetMigrationStore? = nil,
        migrationWarning: String? = nil,
        currentOutput: @escaping () throws -> OutputDevice = SystemAudioRoute.currentOutput,
        availableOutputs: @escaping () -> [OutputDevice] = SystemAudioRoute.availableOutputs,
        chain: RenderChain = RenderChain(),
        effectCatalog: EffectCatalog = EffectCatalog(),
        makeVerificationRoute: @escaping VerificationRouteFactory = { output, channels, render in
            try SystemAudioRoute(output: output, verification: true, outputChannels: channels, render: render)
        }
    ) {
        self.store = store
        self.defaults = defaults
        self.presetLibrary = presetLibrary
        self.migrationWarning = migrationWarning
        self.currentOutput = currentOutput
        self.availableOutputs = availableOutputs
        self.chain = chain
        self.effectCatalog = effectCatalog
        self.makeVerificationRoute = makeVerificationRoute
        mixer = AppMixer(defaults: defaults)
        super.init()
        isEnabled = defaults.object(forKey: "ProcessingEnabled") == nil || defaults.bool(forKey: "ProcessingEnabled")
        do {
            let saved = try store.load()
            profiles = saved.mapValues { profile in
                var profile = profile
                profile.slots = profile.slots.map { $0.updatingManufacturer().adoptingSpatialBypass() }
                return profile
            }
            if profiles != saved { persistProfiles() }
        } catch {
            storageReadOnly = true
            storageError = "Saved chains could not be read. Their file is preserved."
        }
        rescan()
        refreshMixerRows()
        refreshOutput()
        refreshDevices()
        audioApplications.startWatching { [weak self] in
            guard let self, !self.suspendedForSleep else { return }
            self.scanAudioApplications()
        }
        heartbeat = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
    }

    func rescan() {
        components = effectCatalog.list()
        startPresetUpgrade()
        offlineIssues.removeAll()
        for slot in slots where effects[slot.id] == nil { prepare(slot) }
        if case .failed = playback {
            setPlayback(.native)
            captureVerified = false
            recoveryAttempted = false
            updatePlayback()
        }
    }

    private func startPresetUpgrade() {
        guard let presetLibrary, presetUpgrade == nil else { return }
        presetUpgrade = Task { [weak self, defaults, instantiate = effectCatalog.instantiate] in
            do {
                try await AudioUnitPresetUpgrade.migrate(from: presetLibrary, defaults: defaults, instantiate: instantiate)
                self?.presetUpgradeWarning = nil
            } catch where !Task.isCancelled {
                self?.presetUpgradeWarning = "Saved presets could not be imported. \(error.localizedDescription) Rescan Audio Units to retry."
            } catch {}
            self?.presetUpgrade = nil
        }
    }

    var editingDevices: [HostDeviceTarget] {
        Set(connected.keys).union(profiles.keys).union(currentDeviceUID.map { [$0] } ?? [])
            .map { uid in
                HostDeviceTarget(
                    id: uid,
                    name: connected[uid]?.name ?? (uid == currentDeviceUID ? outputName : profiles[uid]?.name) ?? uid,
                    isCurrent: uid == currentDeviceUID,
                    isConnected: connected[uid] != nil || uid == currentDeviceUID,
                    hasProfile: profiles[uid] != nil,
                    outputChannels: profiles[uid]?.outputChannels,
                    outputChannelCount: connected[uid]?.routing?.outputChannelCount ?? 0,
                    preferredOutputChannels: connected[uid]?.routing?.preferredStereoChannels
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }

    var editingSlots: [EffectSlot] {
        guard let uid = editingDeviceUID else { return [] }
        return uid == currentDeviceUID ? slots : profiles[uid]?.slots ?? []
    }

    func effectSlot(_ id: UUID, for deviceUID: String) -> EffectSlot? {
        let deviceSlots = deviceUID == currentDeviceUID ? slots : profiles[deviceUID]?.slots ?? []
        return deviceSlots.first { $0.id == id }
    }

    var editingSlotIssues: [UUID: String] {
        let active = editingDeviceUID == currentDeviceUID
        var issues = active ? slotIssues : offlineIssues
        for slot in editingSlots {
            if let issue = slot.migrationIssue {
                issues[slot.id] = issues[slot.id].map { "\(issue) \($0)" } ?? issue
            } else if !active, issues[slot.id] == nil, !components.contains(where: { $0.id == slot.component }) {
                issues[slot.id] = "Audio Unit unavailable. Install it and rescan."
            }
        }
        return issues
    }

    func selectEditingDevice(_ uid: String) {
        guard editingDevices.contains(where: { $0.id == uid }) else { return }
        editingDeviceUID = uid
    }

    func configureOutput(for uid: String, channels: StereoOutputChannels?) throws {
        let saved = profiles[uid]?.outputChannels
        guard saved != channels else { return }
        if let channels {
            guard let output = connected[uid]?.routing else {
                throw SystemAudioRouteError.unsupportedOutput("Connect this output to configure its channels.")
            }
            if case .unsupported(let reason) = OutputRoutingResolver.resolve(output: output, channels: channels) {
                throw SystemAudioRouteError.unsupportedOutput(reason)
            }
        }
        var profile = profiles[uid] ?? DeviceProfile(name: connected[uid]?.name ?? uid,
                                                     sampleRate: connected[uid]?.sampleRate, slots: [])
        profile.outputChannels = channels
        var updated = profiles
        updated[uid] = profile
        guard !storageReadOnly else {
            throw SystemAudioRouteError.unsupportedOutput(storageError ?? "Saved chains cannot be written.")
        }
        try store.save(updated)
        profiles = updated
        storageError = nil
        if uid == currentDeviceUID {
            recoveryAttempted = false
            setPlayback(.native)
            updatePlayback()
        }
    }

    func selectCurrentOutputForEditing() {
        if let currentDeviceUID { selectEditingDevice(currentDeviceUID) }
    }

    func addEditing(_ component: EffectComponent) {
        guard let uid = editingDeviceUID else { return }
        if uid == currentDeviceUID { add(component) }
        else { editProfile(uid) { $0.append(EffectSlot(component)) } }
    }

    func removeEditing(_ id: UUID) {
        guard let uid = editingDeviceUID, editingSlots.contains(where: { $0.id == id }) else { return }
        if uid == currentDeviceUID { remove(id) }
        else {
            editors[id]?.window.close()
            offlineIssues[id] = nil
            editProfile(uid) { $0.removeAll { $0.id == id } }
        }
    }

    func moveEditing(from indices: IndexSet, to destination: Int) {
        guard let uid = editingDeviceUID, destination >= 0, destination <= editingSlots.count,
              indices.allSatisfy({ editingSlots.indices.contains($0) }) else { return }
        if uid == currentDeviceUID { move(from: indices, to: destination) }
        else { editProfile(uid) { $0.move(fromOffsets: indices, toOffset: destination) } }
    }

    func setEditingBypass(_ id: UUID, _ bypassed: Bool) {
        guard let uid = editingDeviceUID else { return }
        setBypass(id, bypassed, for: uid)
    }

    func setBypass(_ id: UUID, _ bypassed: Bool, for deviceUID: String) {
        if deviceUID == currentDeviceUID {
            setBypass(id, bypassed)
        } else if let deviceSlots = profiles[deviceUID]?.slots,
                  let index = deviceSlots.firstIndex(where: { $0.id == id }),
                  deviceSlots[index].migrationIssue == nil {
            editProfile(deviceUID) { $0[index].isBypassed = bypassed }
        }
    }

    func resetEffects(for uid: String) {
        guard uid == currentDeviceUID || connected[uid] != nil,
              let profile = profiles[uid], !profile.slots.isEmpty else { return }
        closeEditors(for: [uid])
        for slot in profile.slots { offlineIssues[slot.id] = nil }
        if uid == currentDeviceUID {
            loadTasks.values.forEach { $0.cancel() }
            loadTasks.removeAll()
            effects.removeAll()
            spatialLayouts.removeAll()
            slotIssues.removeAll()
            slots.removeAll()
            saveProfile()
            updatePlayback()
        } else {
            editProfile(uid) { $0.removeAll() }
        }
    }

    func removeSavedProfile(for uid: String) {
        guard uid != currentDeviceUID, connected[uid] == nil,
              let profile = profiles[uid] else { return }
        closeEditors(for: [uid])
        for slot in profile.slots { offlineIssues[slot.id] = nil }
        profiles[uid] = nil
        repairEditingDevice()
        persistProfiles()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: "ProcessingEnabled")
        if !enabled, case .failed = captureCheck { captureCheck = .idle }
        recoveryAttempted = false
        setPlayback(.native)
        updatePlayback()
    }

    func setAppVolume(_ volume: Double, for id: String) {
        mixer.setVolume(volume, for: id)
        refreshMixerRows()
    }

    func setAppMuted(_ isMuted: Bool, for id: String) {
        mixer.setMuted(isMuted, for: id)
        refreshMixerRows()
    }

    func resetAppVolume(for id: String) {
        mixer.reset(id)
        refreshMixerRows()
    }

    var processingNotice: HostProcessingNotice? {
        if pendingCleanup != nil { return .information(status) }
        if case .failed(let reason) = captureCheck { return .captureFailure(reason) }
        if let storageError { return .warning(storageError) }
        if let migrationWarning { return .warning(migrationWarning) }
        if let presetUpgradeWarning { return .warning(presetUpgradeWarning) }
        if rejectedMixerSources != nil { return .warning(status) }
        switch playback {
        case .startingCheck, .checking: return .information(status)
        default: return nil
        }
    }

    func add(_ component: EffectComponent) {
        guard output != nil else { return }
        let slot = EffectSlot(component)
        slots.append(slot)
        saveProfile()
        prepare(slot)
        updatePlayback()
    }

    func remove(_ id: UUID) {
        guard slots.contains(where: { $0.id == id }) else { return }
        editors[id]?.window.close()
        loadTasks.removeValue(forKey: id)?.cancel()
        effects.removeValue(forKey: id)
        spatialLayouts.removeValue(forKey: id)
        slotIssues[id] = nil
        slots.removeAll { $0.id == id }
        saveProfile()
        updatePlayback()
    }

    func move(from indices: IndexSet, to destination: Int) {
        guard destination >= 0, destination <= slots.count,
              indices.allSatisfy({ slots.indices.contains($0) }) else { return }
        slots.move(fromOffsets: indices, toOffset: destination)
        saveProfile()
        updatePlayback()
    }

    func setBypass(_ id: UUID, _ bypassed: Bool) {
        guard let index = slots.firstIndex(where: { $0.id == id }), slots[index].migrationIssue == nil else { return }
        slots[index].isBypassed = bypassed
        if !bypassed, let effect = effects[id], effect.stage.failure.load(ordering: .relaxed) != noErr {
            editors[id]?.window.close()
            effects[id] = nil
            prepare(slots[index])
        }
        saveProfile()
        updatePlayback()
    }

    func openEditingEditor(_ id: UUID) {
        guard let uid = editingDeviceUID, let slot = editingSlots.first(where: { $0.id == id }) else { return }
        if let editor = editors[id] {
            editor.window.makeKeyAndOrderFront(nil)
            return
        }
        guard openingEditors[id] == nil else { return }
        let active = uid == currentDeviceUID
        let choosingReplacement = slot.migrationIssue != nil
        if active && effects[id] == nil && !choosingReplacement { return }

        let token = UUID()
        openingEditors[id] = token
        let device = connected[uid]
        let rate = device?.sampleRate ?? profiles[uid]?.sampleRate ?? 48_000
        let name = device?.name ?? profiles[uid]?.name ?? uid
        Task { [weak self] in
            guard let self else { return }
            defer { if self.openingEditors[id] == token { self.openingEditors[id] = nil } }
            if PresetMigrationStore.supports(slot.component) { await self.presetUpgrade?.value }
            guard self.openingEditors[id] == token else { return }
            do {
                let effect: LiveEffect
                let layout: InputLayout?
                if let live = self.effects[id], active {
                    effect = live
                    layout = self.spatialLayouts[id]
                } else {
                    var preview = slot
                    if choosingReplacement {
                        preview.isBypassed = false
                        preview.state = try PropertyListSerialization.data(
                            fromPropertyList: PresetDocument.emptyState(for: slot.component), format: .binary, options: 0
                        )
                    }
                    layout = active ? self.preferredSpatialLayout(for: preview) : nil
                    effect = try await LiveEffect.load(
                        preview, sampleRate: rate, maximumFrames: SystemAudioRoute.maximumFrames, spatialLayout: layout,
                        equalizerOutput: (uid: uid, name: name, channelCount: device?.capturedChannelCount),
                        instantiate: self.effectCatalog.instantiate
                    )
                    if choosingReplacement {
                        guard let state = effect.unit.fullStateForDocument,
                              !PresetDocument.hasSelection(state, for: slot.component) else { throw EffectError.invalidState }
                    }
                }
                let custom = await effect.unit.requestViewController()
                guard self.openingEditors[id] == token,
                      self.profiles[uid]?.slots.contains(where: { $0.id == id }) == true,
                      (uid == self.currentDeviceUID) == active else { return }
                if active && !choosingReplacement && self.effects[id] !== effect { return }
                let controller = custom ?? NSHostingController(rootView: ParameterEditor(unit: effect.unit))
                let window = self.makeEditorWindow(controller, slot: slot, deviceUID: uid)
                window.delegate = self
                window.center()
                self.editors[id] = Editor(deviceUID: uid, effect: effect, spatialLayout: layout, window: window)
                self.offlineIssues[id] = nil
                window.makeKeyAndOrderFront(nil)
            } catch {
                if self.openingEditors[id] == token,
                   self.profiles[uid]?.slots.contains(where: { $0.id == id }) == true {
                    if active { self.slotIssues[id] = error.localizedDescription }
                    else { self.offlineIssues[id] = error.localizedDescription }
                }
            }
        }
    }

    private func makeEditorWindow(_ editor: NSViewController, slot: EffectSlot, deviceUID: String) -> NSWindow {
        let content = editor.view
        let editorSize = [editor.preferredContentSize, content.frame.size].first {
            $0.width >= 240 && $0.height >= 120
        } ?? NSSize(width: 420, height: 300)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: editorSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = slot.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(HostAppearance.canvas)
        window.isReleasedWhenClosed = false

        let container = NSViewController()
        container.view = NSView()
        container.addChild(editor)
        window.contentViewController = container

        let header = NSHostingView(rootView: HostEditorHeader(host: self, slot: slot, deviceUID: deviceUID))
        header.appearance = NSAppearance(named: .darkAqua)
        header.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = container.view
        root.addSubview(header)
        root.addSubview(content)

        let nativeTitlebarHeight = root.bounds.height - window.contentLayoutRect.height
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: HostEditorHeader.height),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.setContentSize(NSSize(width: editorSize.width, height: editorSize.height + HostEditorHeader.height + nativeTitlebarHeight))
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = editors.first(where: { $0.value.window === window })?.key else { return }
        stashEditorState(for: [id])
        editors[id] = nil
    }

    func checkCapturePermission() {
        guard let output else {
            captureCheck = .failed("Connect an audio output to test system audio capture.")
            return
        }
        if case .processing = playback {
            captureCheck = .verified
            return
        }
        recoveryAttempted = false
        startCheck(output, explicit: true)
    }

    func openCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func suspendForSleep() {
        guard !suspendedForSleep else { return }
        suspendedForSleep = true
        captureVerified = false
        captureCheck = .idle
        setPlayback(.native)
    }

    func resumeAfterWake() {
        guard suspendedForSleep else { return }
        suspendedForSleep = false
        recoveryAttempted = false
        refreshOutput()
        refreshDevices()
        updatePlayback()
    }

    func shutdown() {
        suspendedForSleep = true
        presetUpgrade?.cancel()
        audioApplications.stopWatching()
        stashEditorState(for: Array(editors.keys))
        heartbeat?.invalidate()
        heartbeat = nil
        loadTasks.values.forEach { $0.cancel() }
        chain.replace(with: [])
        setPlayback(.native)
        _ = pendingCleanup?.stop()
    }

    private func tick() {
        guard !suspendedForSleep else { return }
        refreshOutput()
        scanAudioApplications()
        if Date().timeIntervalSince(lastDeviceScan) >= 2 { refreshDevices() }
        stashEditorState(for: Array(editors.keys))
        chain.reclaim()
        if let pendingCleanup, pendingCleanup.stop() {
            self.pendingCleanup = nil
            if case .failed(let reason) = playback { status = reason }
            updatePlayback()
        }
        var effectFailed = false
        for (id, effect) in effects {
            let status = effect.stage.failure.load(ordering: .relaxed)
            if status != noErr, !effect.reportedRenderFailure {
                effect.reportedRenderFailure = true
                slotIssues[id] = "Render failed (\(status)). Toggle bypass to retry."
                effectFailed = true
            }
        }
        if effectFailed { updatePlayback() }

        switch playback {
        case .checking(let route, let signal, let explicit, let started):
            if route.hasIOFailure {
                setPlayback(.failed("Core Audio changed the capture format."))
            } else if signal.received.load(ordering: .relaxed) {
                captureVerified = true
                captureCheck = .verified
                setPlayback(.native)
                updatePlayback()
                if explicit, case .native = playback, storageError == nil {
                    status = "System audio capture is working"
                }
            } else if explicit, Date().timeIntervalSince(started) > 5 {
                setPlayback(.failed("No audio captured. Play something or check System Audio Recording permission."))
            } else if Date().timeIntervalSince(started) > 15 {
                status = storageError ?? "Waiting for system audio. Check permission if audio is playing."
            }
        case .processing(let route):
            if route.hasIOFailure {
                restartInterruptedRoute()
                return
            }
            let callbacks = chain.callbacks.load(ordering: .relaxed)
            if callbacks != lastCallbacks {
                lastCallbacks = callbacks
                lastCallbackTime = Date()
            } else if Date().timeIntervalSince(lastCallbackTime) > 3 {
                restartInterruptedRoute()
            }
        case .native, .startingCheck, .failed:
            break
        }
    }

    private func refreshOutput() {
        let next = try? currentOutput()
        guard next != output else { return }
        let previousUID = currentDeviceUID
        let followsOutput = editingDeviceUID == nil || editingDeviceUID == previousUID
        closeEditors(for: Set([previousUID, next?.uid].compactMap { $0 }))
        setPlayback(.native)
        loadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll()
        effects.removeAll()
        spatialLayouts.removeAll()
        slotIssues.removeAll()
        chain.replace(with: [])
        output = next
        currentDeviceUID = next?.uid
        outputName = next?.name ?? "No audio output"
        scanAudioApplications(updateRoute: false)
        slots = next.flatMap { profiles[$0.uid]?.slots } ?? []
        if followsOutput { editingDeviceUID = next?.uid }
        repairEditingDevice()
        switch captureCheck {
        case .checking, .failed: captureCheck = .idle
        case .idle, .verified: break
        }
        recoveryAttempted = false
        for slot in slots { prepare(slot) }
        updatePlayback()
    }

    private var surroundLayout: InputLayout? {
        guard let layout = output?.captureLayout, layout.channels.count > 2 else { return nil }
        return layout
    }

    private func runnableEffect(for slot: EffectSlot) -> LiveEffect? {
        guard !slot.isBypassed, let effect = effects[slot.id],
              effect.stage.failure.load(ordering: .relaxed) == noErr else { return nil }
        return effect
    }

    private func reconcileEffects() -> [LiveEffect] {
        let surround = surroundLayout
        var active: [LiveEffect] = []
        for index in slots.indices {
            let slot = slots[index]
            guard !slot.isBypassed, slot.migrationIssue == nil else { continue }
            if slot.component == .airwaveSpatial {
                let layout = active.isEmpty ? surround : nil
                if spatialLayouts[slot.id] != layout {
                    reloadSpatial(at: index, layout: layout)
                    continue
                }
            }
            if let effect = runnableEffect(for: slot) { active.append(effect) }
        }
        return active
    }

    private func reloadSpatial(at index: Int, layout: InputLayout?) {
        let id = slots[index].id
        if let effect = effects[id] {
            do {
                let state = try effect.saveState(previous: slots[index].state)
                if state != slots[index].state {
                    slots[index].state = state
                    saveProfile()
                }
            } catch {
                slotIssues[id] = "Audio Unit settings could not be saved."
                return
            }
        }
        editors[id]?.window.close()
        openingEditors[id] = nil
        effects[id] = nil
        loadTasks.removeValue(forKey: id)?.cancel()
        prepare(slots[index], spatialLayout: layout)
    }

    private func preferredSpatialLayout(for slot: EffectSlot) -> InputLayout? {
        guard slot.component == .airwaveSpatial, !slot.isBypassed,
              !slots.prefix(while: { $0.id != slot.id }).contains(where: { runnableEffect(for: $0) != nil }) else { return nil }
        return surroundLayout
    }

    private func prepare(_ slot: EffectSlot) {
        prepare(slot, spatialLayout: preferredSpatialLayout(for: slot))
    }

    private func prepare(_ slot: EffectSlot, spatialLayout layout: InputLayout?) {
        guard let output, loadTasks[slot.id] == nil, slot.migrationIssue == nil else { return }
        spatialLayouts[slot.id] = layout
        if !components.contains(where: { $0.id == slot.component }) {
            slotIssues[slot.id] = "Audio Unit unavailable. Install it and rescan."
            return
        }
        slotIssues[slot.id] = nil
        loadTasks[slot.id] = Task { [weak self, instantiate = effectCatalog.instantiate] in
            do {
                let effect = try await LiveEffect.load(
                    slot, sampleRate: output.sampleRate, maximumFrames: SystemAudioRoute.maximumFrames,
                    spatialLayout: layout, equalizerOutput: (
                        uid: output.uid, name: output.name, channelCount: output.capturedChannelCount
                    ), instantiate: instantiate
                )
                guard let self, !Task.isCancelled else { return }
                self.effects[slot.id] = effect
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.slotIssues[slot.id] = error.localizedDescription
            }
            self?.loadTasks[slot.id] = nil
            self?.updatePlayback()
        }
    }

    private func scanAudioApplications(updateRoute: Bool = true) {
        if let apps = audioApplications.scan(output: output) { mixer.update(apps) }
        refreshMixerRows(updateRoute: updateRoute)
    }

    private func refreshMixerRows(updateRoute: Bool = true) {
        let rows = mixer.rows
        if rows != mixerRows { mixerRows = rows }
        let sources = mixer.sources
        let requiresRouting = mixer.requiresRouting
        guard sources != mixerSources || requiresRouting != mixerRequiresRouting else { return }
        mixerSources = sources
        mixerRequiresRouting = requiresRouting
        if updateRoute { updatePlayback() }
    }

    private func updatePlayback() {
        guard !suspendedForSleep, pendingCleanup == nil else { return }
        let active = reconcileEffects()
        chain.replace(with: active)
        guard let output else {
            setPlayback(.native)
            status = storageError ?? "Connect an audio output"
            return
        }
        let outputChannels = profiles[output.uid]?.outputChannels
        let processingStatus = active.isEmpty && !mixerRequiresRouting ? "Routing audio" : "Processing system audio"
        guard isEnabled, !active.isEmpty || mixerRequiresRouting || outputChannels != nil else {
            switch playback {
            case .startingCheck(true), .checking(_, _, true, _): return
            default: break
            }
            setPlayback(.native)
            status = storageError ?? (isEnabled && !loadTasks.isEmpty ? "Loading Audio Units…" : "Normal macOS playback")
            return
        }
        guard verificationStartup == nil else { return }
        switch playback {
        case .processing(let route):
            if mixerSources == routedMixerSources {
                status = storageError ?? processingStatus
                rejectedMixerSources = nil
                return
            }
            guard mixerSources != rejectedMixerSources else { return }
            do {
                if try route.retarget(to: mixerSources) {
                    routedMixerSources = mixerSources
                    rejectedMixerSources = nil
                    status = storageError ?? processingStatus
                    return
                }
            } catch {
                setPlayback(.native)
                guard pendingCleanup == nil else { return }
            }
        case .native:
            break
        case .startingCheck, .checking, .failed:
            return
        }
        if captureVerified {
            do {
                let route = try SystemAudioRoute(
                    output: output, appSources: mixerSources, outputChannels: outputChannels,
                    capturedRender: chain.renderCaptured, render: chain.render
                )
                setPlayback(.native)
                guard pendingCleanup == nil else { return }
                try start(route)
                playback = .processing(route)
                routedMixerSources = mixerSources
                lastCallbacks = chain.callbacks.load(ordering: .relaxed)
                lastCallbackTime = Date()
                captureCheck = .verified
                status = storageError ?? processingStatus
            } catch {
                if case .processing = playback {
                    rejectedMixerSources = mixerSources
                    status = "App Mixer couldn’t update. \(error.localizedDescription)"
                } else {
                    setPlayback(.failed(error.localizedDescription))
                }
            }
        } else {
            startCheck(output, explicit: false)
        }
    }

    private func startCheck(_ output: OutputDevice, explicit: Bool) {
        if case .startingCheck = playback {
            if explicit {
                playback = .startingCheck(explicit: true)
                captureCheck = .checking
                status = "Checking system audio capture…"
            }
            return
        }
        guard verificationStartup == nil else {
            if explicit { captureCheck = .failed("Wait for the audio route to recover, then test again.") }
            return
        }
        setPlayback(.native)
        guard pendingCleanup == nil else {
            if explicit { captureCheck = .failed("Wait for the audio route to recover, then test again.") }
            return
        }
        if explicit { captureCheck = .checking }
        playback = .startingCheck(explicit: explicit)
        status = explicit ? "Checking system audio capture…" : "Starting system audio capture…"

        let signal = CaptureSignal()
        let channels = profiles[output.uid]?.outputChannels
        let worker = Task.detached(priority: .userInitiated) { [makeVerificationRoute] () -> VerificationStart in
            var route: SystemAudioRoute?
            do {
                try Task.checkCancellation()
                let created = try makeVerificationRoute(output, channels, signal.inspect)
                route = created
                try Task.checkCancellation()
                try created.start()
                try Task.checkCancellation()
                return .started(created)
            } catch {
                let cleanup = route.flatMap { $0.stop() ? nil : $0 }
                return .failed(error.localizedDescription, cleanup: cleanup)
            }
        }
        verificationStartup = worker
        Task { [weak self] in
            let result = await worker.value
            guard let self, case .startingCheck(let explicit) = self.playback else {
                if result.route != nil {
                    let released = await Task.detached { result.route?.stop() ?? true }.value
                    if !released { self?.pendingCleanup = result.route }
                }
                self?.verificationStartup = nil
                self?.updatePlayback()
                return
            }
            self.verificationStartup = nil
            switch result {
            case .started(let route):
                self.playback = .checking(route, signal, explicit: explicit, started: Date())
                self.status = explicit ? "Checking system audio capture…" : "Play audio to enable processing"
                if explicit {
                    self.probeSound = NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true)
                    self.probeSound?.volume = 0.18
                    self.probeSound?.play()
                }
            case .failed(let reason, let cleanup):
                self.pendingCleanup = cleanup
                self.setPlayback(.failed(reason))
            }
        }
    }

    private func restartInterruptedRoute() {
        let message = "System audio stopped reaching the host."
        if recoveryAttempted {
            setPlayback(.failed(message))
            return
        }
        recoveryAttempted = true
        captureVerified = false
        setPlayback(.native)
        updatePlayback()
    }

    private func start(_ route: SystemAudioRoute) throws {
        do {
            try route.start()
        } catch {
            if !route.stop() { pendingCleanup = route }
            throw error
        }
    }

    private func setPlayback(_ next: Playback) {
        if case .startingCheck = playback { verificationStartup?.cancel() }
        if case .failed(let reason) = next {
            captureCheck = .failed(reason)
        } else if captureCheck == .checking {
            switch playback {
            case .startingCheck(true), .checking(_, _, true, _): captureCheck = .idle
            default: break
            }
        }
        if let route = playback.route, !route.stop() { pendingCleanup = route }
        probeSound?.stop()
        probeSound = nil
        playback = next
        routedMixerSources = []
        rejectedMixerSources = nil
        if pendingCleanup != nil {
            chain.replace(with: [])
            status = "Recovering the system audio route…"
        } else if case .failed(let reason) = next {
            status = reason
        }
    }

    private func refreshDevices() {
        lastDeviceScan = Date()
        var devices: [String: OutputDevice] = [:]
        for device in availableOutputs() { devices[device.uid] = device }
        if let output { devices[output.uid] = output }
        if connected != devices { connected = devices }

        var updated = profiles
        for (uid, device) in devices where updated[uid] != nil {
            updated[uid]?.name = device.name
            updated[uid]?.sampleRate = device.sampleRate
        }
        if updated != profiles {
            profiles = updated
            persistProfiles()
        }
        repairEditingDevice()
    }

    private func repairEditingDevice() {
        if let uid = editingDeviceUID, connected[uid] != nil || profiles[uid] != nil || uid == currentDeviceUID { return }
        editingDeviceUID = currentDeviceUID ?? editingDevices.first?.id
    }

    private func editProfile(_ uid: String, _ changes: (inout [EffectSlot]) -> Void) {
        let device = connected[uid]
        var profile = profiles[uid] ?? DeviceProfile(name: device?.name ?? uid, sampleRate: device?.sampleRate, slots: [])
        changes(&profile.slots)
        profiles[uid] = profile
        persistProfiles()
    }

    private func closeEditors(for devices: Set<String>) {
        editors.values.filter { devices.contains($0.deviceUID) }.forEach { $0.window.close() }
        for uid in devices {
            for slot in profiles[uid]?.slots ?? [] { openingEditors[slot.id] = nil }
        }
    }

    private func stashEditorState(for ids: [UUID]) {
        var updated = profiles
        var recoveredActiveEffect = false
        for id in ids {
            guard let editor = editors[id], let index = updated[editor.deviceUID]?.slots.firstIndex(where: { $0.id == id }),
                  let previousSlot = updated[editor.deviceUID]?.slots[index] else { continue }
            do {
                let state = try editor.effect.saveState(previous: previousSlot.state)
                guard state != previousSlot.state else { continue }
                var slot = previousSlot
                if slot.migrationIssue != nil {
                    guard let state,
                          let document = try PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any],
                          PresetDocument.hasSelection(document, for: slot.component) else { continue }
                    slot.migrationIssue = nil
                    slot.isBypassed = false
                    if editor.deviceUID == currentDeviceUID {
                        effects[id] = editor.effect
                        spatialLayouts[id] = editor.spatialLayout
                        slotIssues[id] = nil
                        recoveredActiveEffect = true
                    }
                }
                slot.state = state
                updated[editor.deviceUID]?.slots[index] = slot
                if editor.deviceUID == currentDeviceUID,
                   let liveIndex = slots.firstIndex(where: { $0.id == id }) {
                    slots[liveIndex] = slot
                }
            } catch {
                let issue = "Audio Unit settings could not be saved."
                if editor.deviceUID == currentDeviceUID { slotIssues[id] = issue }
                else { offlineIssues[id] = issue }
            }
        }
        if updated != profiles {
            profiles = updated
            persistProfiles()
        }
        if recoveredActiveEffect { Task { [weak self] in self?.updatePlayback() } }
    }

    private func saveProfile() {
        guard let output else { return }
        var profile = profiles[output.uid] ?? DeviceProfile(name: output.name, sampleRate: output.sampleRate, slots: [])
        profile.name = output.name
        profile.sampleRate = output.sampleRate
        profile.slots = slots
        profiles[output.uid] = profile
        persistProfiles()
    }

    private func persistProfiles() {
        guard !storageReadOnly else { status = storageError ?? status; return }
        do {
            try store.save(profiles)
            storageError = nil
        } catch {
            storageError = "The effect chains could not be saved."
            status = storageError ?? status
        }
    }

}

private final class CaptureSignal: Sendable {
    let received = Atomic<Bool>(false)

    func inspect(
        _ time: UnsafePointer<AudioTimeStamp>, _ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>,
        _ outputLeft: UnsafeMutablePointer<Float>, _ outputRight: UnsafeMutablePointer<Float>, _ frames: UInt32
    ) {
        if !received.load(ordering: .relaxed) {
            for index in 0..<Int(frames) where abs(left[index]) > 0.0001 || abs(right[index]) > 0.0001 {
                received.store(true, ordering: .relaxed)
                break
            }
        }
        let bytes = Int(frames) * MemoryLayout<Float>.size
        memset(outputLeft, 0, bytes)
        memset(outputRight, 0, bytes)
    }
}

private struct ParameterEditor: View {
    let unit: AUAudioUnit

    var body: some View {
        let parameters = unit.parameterTree?.allParameters ?? []
        if parameters.isEmpty {
            Text("This Audio Unit has no editable controls.")
                .padding(24)
        } else {
            Form {
                ForEach(parameters, id: \.address) { parameter in
                    ParameterControl(parameter: parameter)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 350, minHeight: 230)
        }
    }
}

private struct ParameterControl: View {
    let parameter: AUParameter
    @State private var value: AUValue

    init(parameter: AUParameter) {
        self.parameter = parameter
        _value = State(initialValue: parameter.value)
    }

    var body: some View {
        if let strings = parameter.valueStrings, !strings.isEmpty {
            Picker(parameter.displayName, selection: $value) {
                ForEach(Array(strings.enumerated()), id: \.offset) { index, title in
                    Text(title).tag(parameter.minValue + AUValue(index))
                }
            }
            .onChange(of: value) { _, newValue in parameter.value = newValue }
        } else if parameter.minValue < parameter.maxValue {
            LabeledContent(parameter.displayName) {
                HStack {
                    Slider(value: $value, in: parameter.minValue...parameter.maxValue) {
                        Text(parameter.displayName)
                    }
                    Text(formattedValue)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
                .onChange(of: value) { _, newValue in parameter.value = newValue }
            }
        } else {
            LabeledContent(parameter.displayName, value: formattedValue)
        }
    }

    private var formattedValue: String {
        var displayed = value
        return parameter.string(fromValue: &displayed)
    }
}
