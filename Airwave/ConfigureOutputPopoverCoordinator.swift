import Combine
import Foundation

/// Holds unsaved output assignments for one Registered Devices surface.
/// Transient native popover dismissal only unpresents the current editor;
/// explicit Cancel, successful Save, row removal, and parent teardown discard it.
@MainActor
final class ConfigureOutputPopoverCoordinator: ObservableObject {
    typealias EditorFactory = (String, String) -> ConfigureOutputCoordinator

    @Published private(set) var presentedDeviceUID: String?

    private let profiles: DeviceProfileManager
    private let makeEditor: EditorFactory
    private var drafts: [String: ConfigureOutputCoordinator] = [:]

    init(
        profiles: DeviceProfileManager,
        makeEditor: EditorFactory? = nil
    ) {
        self.profiles = profiles
        self.makeEditor = makeEditor ?? { uid, name in
            ConfigureOutputCoordinator(deviceUID: uid, deviceName: name, profiles: profiles)
        }
    }

    var presentedEditor: ConfigureOutputCoordinator? {
        guard let presentedDeviceUID else { return nil }
        return drafts[presentedDeviceUID]
    }

    /// Presents or resumes this UID only when no other editor is currently
    /// presented. A different UID gets its own draft after transient dismissal.
    func present(deviceUID: String, deviceName: String) {
        guard presentedDeviceUID == nil || presentedDeviceUID == deviceUID else { return }
        guard profiles.availableOutputs.contains(where: {
            $0.uid == deviceUID && $0.isConfigurationEligible
        }) else { return }

        if drafts[deviceUID] == nil {
            drafts[deviceUID] = makeEditor(deviceUID, deviceName)
        }
        presentedDeviceUID = deviceUID
    }

    /// SwiftUI calls this when the native popover closes from Escape or an
    /// outside click. Keep the editor in `drafts` for a later reopen.
    func dismissTransiently() {
        presentedDeviceUID = nil
    }

    @discardableResult
    func savePresentedDraft(for deviceUID: String) -> Bool {
        guard presentedDeviceUID == deviceUID,
              let editor = drafts[deviceUID],
              editor.save() else { return false }
        drafts.removeValue(forKey: deviceUID)
        presentedDeviceUID = nil
        return true
    }

    func cancelPresentedDraft(for deviceUID: String) {
        guard presentedDeviceUID == deviceUID else { return }
        discardDraft(for: deviceUID)
    }

    /// Confirmed Reset Profile or Forget Device invalidates that UID's draft.
    /// Calling this for a failed or cancelled action is intentionally avoided.
    func discardDraft(for deviceUID: String) {
        drafts.removeValue(forKey: deviceUID)?.cancel()
        if presentedDeviceUID == deviceUID {
            presentedDeviceUID = nil
        }
    }

    /// Remove drafts for devices that no longer have a Registered Devices row.
    func pruneDrafts(retaining deviceUIDs: Set<String>) {
        let removedUIDs = drafts.keys.filter { !deviceUIDs.contains($0) }
        for uid in removedUIDs {
            drafts.removeValue(forKey: uid)?.cancel()
        }
        if let presentedDeviceUID, !deviceUIDs.contains(presentedDeviceUID) {
            self.presentedDeviceUID = nil
        }
    }

    /// A parent navigation/settings teardown bounds draft lifetime to this surface.
    func discardAllDrafts() {
        drafts.values.forEach { $0.cancel() }
        drafts.removeAll()
        presentedDeviceUID = nil
    }
}
