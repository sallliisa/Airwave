import Combine
import ServiceManagement

@MainActor
protocol LoginItemAdapting: AnyObject {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

@MainActor
private final class SystemLoginItemAdapter: LoginItemAdapting {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LaunchAtLoginManager: ObservableObject, LaunchAtLoginResetting {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool {
        didSet {
            guard !isSynchronizing else { return }
            updateLoginItem()
        }
    }

    private let adapter: LoginItemAdapting
    private var isSynchronizing = false

    init(adapter: LoginItemAdapting? = nil) {
        let resolvedAdapter = adapter ?? SystemLoginItemAdapter()
        self.adapter = resolvedAdapter
        isEnabled = resolvedAdapter.isEnabled
    }

    func enableForFirstRun() throws {
        if !adapter.isEnabled { try adapter.register() }
        setPublishedValue(true)
    }

    private func updateLoginItem() {
        do {
            if isEnabled, !adapter.isEnabled {
                try adapter.register()
            } else if !isEnabled, adapter.isEnabled {
                try adapter.unregister()
            }
        } catch {
            Logger.log("[LaunchAtLogin] Failed to update login item: \(error)")
            setPublishedValue(adapter.isEnabled)
        }
    }

    private func setPublishedValue(_ value: Bool) {
        guard isEnabled != value else { return }
        isSynchronizing = true
        isEnabled = value
        isSynchronizing = false
    }
}
