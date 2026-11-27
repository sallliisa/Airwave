import AppKit
import CoreAudio

struct AppMixerRow: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage?
    let volume: Double
    let isMuted: Bool
    let isRecent: Bool
    let isAdjusted: Bool
}

struct AppMixerApplication {
    let id: String
    let name: String
    let icon: NSImage?
    let bundleID: String?
    var processIDs: [AudioObjectID]
    var hasActiveOutput: Bool
}

@MainActor
final class AppMixer {
    private struct Adjustment: Codable, Equatable {
        var name: String
        let bundleID: String?
        var volume: Double = 100
        var isMuted = false

        var gain: Float { isMuted ? 0 : Float(volume / 100) }
        var isAdjusted: Bool { volume != 100 || isMuted }
    }

    private struct Recent {
        let application: AppMixerApplication
        let lastActive: Date
    }

    private struct TapSlot {
        var applicationID: String?
        let gain = AppMixerGain(1)
    }

    private static let key = "Host.AppMixer.Adjustments"
    private static let tapBatchSize = 4
    private let defaults: UserDefaults
    private var adjustments: [String: Adjustment] = [:]
    private var tapSlots: [TapSlot] = []
    private var applications: [String: AppMixerApplication] = [:]
    private var recent: [String: Recent] = [:]
    private var savedIcons: [String: NSImage] = [:]
    private var searchedIcons: Set<String> = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.object(forKey: Self.key) as? Data,
           let saved = try? PropertyListDecoder().decode([String: Adjustment].self, from: data) {
            adjustments = saved.filter { $0.value.volume.isFinite && (0...100).contains($0.value.volume) && $0.value.isAdjusted }
        }
        updateTapAssignments()
    }

    func update(_ discovered: [AppMixerApplication], now: Date = .now) {
        applications = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        recent = recent.filter { now.timeIntervalSince($0.value.lastActive) < 45 }
        for app in discovered where app.hasActiveOutput {
            recent[app.id] = Recent(application: app, lastActive: now)
        }
        updateTapAssignments()
    }

    private var trackedAppIDs: Set<String> { Set(recent.keys).union(adjustments.keys) }

    var rows: [AppMixerRow] {
        trackedAppIDs.map { id in
            let saved = adjustments[id]
            let app = applications[id] ?? recent[id]?.application
            let icon = app?.icon ?? saved.flatMap { savedIcon(for: id, bundleID: $0.bundleID) }
            return AppMixerRow(id: id, name: app?.name ?? saved?.name ?? id,
                               icon: icon, volume: saved?.volume ?? 100, isMuted: saved?.isMuted ?? false,
                               isRecent: recent[id] != nil, isAdjusted: saved != nil)
        }.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    var requiresRouting: Bool { !recent.isEmpty || !adjustments.isEmpty }

    var sources: [AppMixerSource] {
        tapSlots.enumerated().map { index, slot in
            let processes = slot.applicationID.flatMap { applications[$0] }?.processIDs.sorted() ?? []
            return AppMixerSource(id: "Mixer slot \(index + 1)", processIDs: processes, gain: slot.gain)
        }
    }

    func setVolume(_ volume: Double, for id: String) {
        guard volume.isFinite else { return }
        change(id) { $0.volume = max(0, min(volume.rounded(), 100)) }
    }

    func setMuted(_ isMuted: Bool, for id: String) {
        change(id) { $0.isMuted = isMuted }
    }

    func reset(_ id: String) {
        change(id) {
            $0.volume = 100
            $0.isMuted = false
        }
    }

    private func change(_ id: String, _ change: (inout Adjustment) -> Void) {
        let app = applications[id] ?? recent[id]?.application
        guard var adjustment = adjustments[id] ?? app.map({ Adjustment(name: $0.name, bundleID: $0.bundleID) }) else {
            return
        }
        change(&adjustment)
        let saved = adjustment.isAdjusted ? adjustment : nil
        guard adjustments[id] != saved else { return }
        tapSlots.first { $0.applicationID == id }?.gain.set(adjustment.gain)
        adjustments[id] = saved
        updateTapAssignments()
        save()
    }

    private func updateTapAssignments() {
        var unassigned = trackedAppIDs
        while tapSlots.count < max(Self.tapBatchSize, unassigned.count) {
            tapSlots.append(contentsOf: (0..<Self.tapBatchSize).map { _ in TapSlot() })
        }
        for index in tapSlots.indices {
            guard let appID = tapSlots[index].applicationID, unassigned.remove(appID) == nil else { continue }
            tapSlots[index].applicationID = nil
            tapSlots[index].gain.set(1)
        }
        let available = tapSlots.indices.filter { tapSlots[$0].applicationID == nil }
        for (index, appID) in zip(available, unassigned.sorted()) {
            tapSlots[index].applicationID = appID
            tapSlots[index].gain.set(adjustments[appID]?.gain ?? 1)
        }
    }

    private func savedIcon(for id: String, bundleID: String?) -> NSImage? {
        if let bundleID, searchedIcons.insert(id).inserted,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            savedIcons[id] = NSWorkspace.shared.icon(forFile: url.path)
        }
        return savedIcons[id]
    }

    private func save() {
        if let data = try? PropertyListEncoder().encode(adjustments) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

@MainActor
final class AudioApplicationCatalog {
    private typealias ResponsibleProcess = @convention(c) (pid_t) -> pid_t
    private static let responsibleProcess = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleProcess.self) }
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private struct Identity {
        let id: String
        let name: String
        let icon: NSImage?
        let bundleID: String?
    }

    private struct Client {
        let pid: pid_t
        let identity: Identity
    }

    private var clients: [AudioObjectID: Client] = [:]
    private var processListListener: AudioObjectPropertyListenerBlock?

    func startWatching(_ refresh: @escaping @MainActor () -> Void) {
        guard processListListener == nil else { return }
        var address = HAL.address(kAudioHardwarePropertyProcessObjectList)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(Self.system, &address, .main, listener) == noErr {
            processListListener = listener
        }
    }

    func stopWatching() {
        guard let processListListener else { return }
        var address = HAL.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(Self.system, &address, .main, processListListener)
        self.processListListener = nil
    }

    func scan(output: OutputDevice?) -> [AppMixerApplication]? {
        guard let ids = try? HAL.readIDs(kAudioHardwarePropertyProcessObjectList, of: Self.system,
                                         scope: kAudioObjectPropertyScopeGlobal) else { return nil }
        var current: [AudioObjectID: Client] = [:]
        var apps: [String: AppMixerApplication] = [:]
        let hostPID = getpid()
        for id in ids {
            guard let pid = try? HAL.read(kAudioProcessPropertyPID, of: id, as: pid_t.self),
                  pid > 1, pid != hostPID else { continue }
            let client: Client
            if let cached = clients[id], cached.pid == pid {
                client = cached
            } else {
                let raw = try? HAL.read(kAudioProcessPropertyBundleID, of: id, as: Unmanaged<CFString>?.self)
                let bundleID = raw.map { $0.takeRetainedValue() as String }.flatMap { $0.isEmpty ? nil : $0 }
                guard let identity = Self.identify(pid: pid, bundleID: bundleID) else { continue }
                client = Client(pid: pid, identity: identity)
            }
            current[id] = client
            let identity = client.identity
            let devices = try? HAL.readIDs(kAudioProcessPropertyDevices, of: id, scope: kAudioObjectPropertyScopeOutput)
            if let output, let devices, !devices.isEmpty, !devices.contains(output.id) { continue }
            let running = (try? HAL.read(kAudioProcessPropertyIsRunningOutput, of: id, as: UInt32.self)) == 1
            var app = apps[identity.id] ?? AppMixerApplication(id: identity.id, name: identity.name, icon: identity.icon,
                                                              bundleID: identity.bundleID, processIDs: [], hasActiveOutput: false)
            app.processIDs.append(id)
            app.hasActiveOutput = app.hasActiveOutput || running
            apps[app.id] = app
        }
        clients = current
        return Array(apps.values)
    }

    private static func identify(pid: pid_t, bundleID: String?) -> Identity? {
        let running = NSRunningApplication(processIdentifier: pid)
        let executable = running?.executableURL ?? executableURL(pid)
        if let path = executable?.path, let end = path.range(of: ".app/"),
           let bundle = Bundle(url: URL(filePath: String(path[..<end.upperBound]), directoryHint: .isDirectory)),
           let ownerID = bundle.bundleIdentifier {
            let owner = NSRunningApplication.runningApplications(withBundleIdentifier: ownerID).first
            let name = owner?.localizedName ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
            return Identity(id: ownerID, name: name, icon: owner?.icon ?? NSWorkspace.shared.icon(forFile: bundle.bundlePath),
                            bundleID: ownerID)
        }
        if let running, let ownerID = running.bundleIdentifier, running.bundleURL?.pathExtension == "app" {
            return Identity(id: ownerID, name: running.localizedName ?? ownerID,
                            icon: running.icon, bundleID: ownerID)
        }
        if executable?.path.contains(".xpc/") == true || bundleID?.hasPrefix("com.apple.WebKit.") == true {
            guard let ownerPID = responsibleProcess?(pid), ownerPID > 1, ownerPID != pid, ownerPID != getpid(),
                  let owner = NSRunningApplication(processIdentifier: ownerPID), owner.bundleURL?.pathExtension == "app",
                  let ownerID = owner.bundleIdentifier else { return nil }
            return Identity(id: ownerID, name: owner.localizedName ?? ownerID, icon: owner.icon, bundleID: ownerID)
        }
        guard let id = bundleID ?? executable?.path, let name = running?.localizedName ?? executable?.lastPathComponent ?? bundleID else {
            return nil
        }
        return Identity(id: id, name: name, icon: running?.icon, bundleID: bundleID)
    }

    private static func executableURL(_ pid: pid_t) -> URL? {
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return URL(filePath: String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))
    }
}
