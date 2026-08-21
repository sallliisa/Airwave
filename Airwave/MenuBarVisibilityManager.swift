import SwiftUI
import Combine

@MainActor
final class MenuBarVisibilityManager: ObservableObject {
    static let shared = MenuBarVisibilityManager()
    static let defaultsKey = "Airwave.Application.ShowInMenuBar"

    @Published var isVisible: Bool {
        didSet {
            defaults.set(isVisible, forKey: Self.defaultsKey)
            visibilityDidChange()
        }
    }

    private let defaults: UserDefaults
    private let visibilityDidChange: () -> Void

    init(
        defaults: UserDefaults = .standard,
        visibilityDidChange: (() -> Void)? = nil
    ) {
        self.defaults = defaults
        self.visibilityDidChange = visibilityDidChange ?? {
            ApplicationLifecycleCoordinator.shared.updateActivationPolicy()
        }
        isVisible = defaults.object(forKey: Self.defaultsKey) == nil ? false : defaults.bool(forKey: Self.defaultsKey)
    }

    func setVisible(_ value: Bool) {
        guard value != isVisible else { return }
        isVisible = value
    }

    /// The one binding every toggle uses. The async hop keeps the activation
    /// policy change out of the SwiftUI update that flipped the switch.
    var visibilityBinding: Binding<Bool> {
        Binding(
            get: { self.isVisible },
            set: { value in
                guard value != self.isVisible else { return }
                DispatchQueue.main.async { self.setVisible(value) }
            }
        )
    }

    func applyActivationPolicy() {
        ApplicationLifecycleCoordinator.shared.updateActivationPolicy()
    }
}
