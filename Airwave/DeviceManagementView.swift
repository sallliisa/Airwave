import Combine
import SwiftUI

nonisolated enum DeviceManagementAction: Equatable {
    case reset
    case forget
}

nonisolated struct DeviceManagementRow: Equatable, Identifiable {
    let id: String
    let deviceName: String
    let transport: String
    let status: String
    let hrirName: String
    let equalizerName: String
    let canReset: Bool
    let canForget: Bool
}

nonisolated struct DeviceManagementConfirmation: Equatable {
    let action: DeviceManagementAction
    let deviceUID: String
    let deviceName: String
    let title: String
    let message: String
    let destructiveButtonTitle: String
}

nonisolated struct DeviceManagementResult: Equatable {
    let text: String
}

@MainActor
final class DeviceManagementCoordinator: ObservableObject {
    @Published private(set) var pendingConfirmation: DeviceManagementConfirmation?
    @Published private(set) var result: DeviceManagementResult?

    private let profileManager: DeviceProfileManager
    private let hrirManager: HRIRManager
    private let equalizerManager: EqualizerManager
    private let resetOperation: (String) -> Bool
    private let forgetOperation: (String) -> Bool

    init(
        profileManager: DeviceProfileManager,
        hrirManager: HRIRManager,
        equalizerManager: EqualizerManager,
        resetOperation: ((String) -> Bool)? = nil,
        forgetOperation: ((String) -> Bool)? = nil
    ) {
        self.profileManager = profileManager
        self.hrirManager = hrirManager
        self.equalizerManager = equalizerManager
        self.resetOperation = resetOperation ?? { [weak profileManager] uid in
            profileManager?.resetProfile(deviceUID: uid) ?? false
        }
        self.forgetOperation = forgetOperation ?? { [weak profileManager] uid in
            profileManager?.forgetProfile(deviceUID: uid) ?? false
        }
    }

    var rows: [DeviceManagementRow] {
        profileManager.sortedProfiles.map { profile in
            let hrirName = profile.hrirPresetID.flatMap { id in
                hrirManager.presets.first { $0.id == id }?.name
            } ?? "None"
            let equalizerName = profile.equalizerPresetID.flatMap { id in
                equalizerManager.presets.first { $0.id == id }?.displayName
            } ?? "None"
            return DeviceManagementRow(
                id: profile.deviceUID,
                deviceName: profile.deviceName,
                transport: profile.transport.isEmpty ? "Unknown transport" : profile.transport,
                status: profile.deviceUID == profileManager.currentDeviceUID ? "Current" : "Not Current",
                hrirName: hrirName,
                equalizerName: equalizerName,
                canReset: profile.hrirPresetID != nil || profile.equalizerPresetID != nil,
                canForget: profile.deviceUID != profileManager.currentDeviceUID
            )
        }
    }

    func requestReset(deviceUID: String) {
        guard let row = rows.first(where: { $0.id == deviceUID }), row.canReset else { return }
        pendingConfirmation = DeviceManagementConfirmation(
            action: .reset,
            deviceUID: row.id,
            deviceName: row.deviceName,
            title: "Reset " + row.deviceName + " profile?",
            message: "Both HRIR and EQ will become None.",
            destructiveButtonTitle: "Reset Profile"
        )
    }

    func requestForget(deviceUID: String) {
        guard let row = rows.first(where: { $0.id == deviceUID }), row.canForget else { return }
        pendingConfirmation = DeviceManagementConfirmation(
            action: .forget,
            deviceUID: row.id,
            deviceName: row.deviceName,
            title: "Forget " + row.deviceName + "?",
            message: "If this device is encountered again, Airwave will recreate a blank profile.",
            destructiveButtonTitle: "Forget Device"
        )
    }

    func cancelConfirmation() {
        pendingConfirmation = nil
    }

    @discardableResult
    func confirmPendingAction() -> Bool {
        guard let confirmation = pendingConfirmation else { return false }
        pendingConfirmation = nil

        let changed: Bool
        switch confirmation.action {
        case .reset:
            changed = resetOperation(confirmation.deviceUID)
            result = DeviceManagementResult(
                text: changed
                    ? "Reset " + confirmation.deviceName + " profile. HRIR and EQ are now None."
                    : "No changes were made to " + confirmation.deviceName + " profile."
            )
        case .forget:
            changed = forgetOperation(confirmation.deviceUID)
            result = DeviceManagementResult(
                text: changed
                    ? "Forgot " + confirmation.deviceName + ". If it appears again, Airwave will recreate a blank profile."
                    : "No changes were made for " + confirmation.deviceName + "."
            )
        }
        return changed
    }

    func dismissResult() {
        result = nil
    }
}

struct DeviceManagementView: View {
    @StateObject private var coordinator: DeviceManagementCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        profileManager: DeviceProfileManager = .shared,
        hrirManager: HRIRManager = .shared,
        equalizerManager: EqualizerManager = .shared
    ) {
        _coordinator = StateObject(wrappedValue: DeviceManagementCoordinator(
            profileManager: profileManager,
            hrirManager: hrirManager,
            equalizerManager: equalizerManager
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            AirwaveSectionHeader(
                title: "Remembered Devices",
                subtitle: "Inspect and manage the HRIR and EQ profile saved for each output."
            )

            if let result = coordinator.result {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(result.text).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Dismiss", action: coordinator.dismissResult)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
                .padding(.vertical, AirwaveLayout.rowVerticalPadding)
                .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Result: \(result.text)")
                .transition(.opacity)
            }

            ScrollView {
                if coordinator.rows.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(coordinator.rows) { row in
                            deviceRow(row)
                            if row.id != coordinator.rows.last?.id {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: coordinator.result)
        .confirmationDialog(
            coordinator.pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { coordinator.pendingConfirmation != nil },
                set: { isPresented in
                    if !isPresented { coordinator.cancelConfirmation() }
                }
            )
        ) {
            if let confirmation = coordinator.pendingConfirmation {
                Button(confirmation.destructiveButtonTitle, role: .destructive) {
                    coordinator.confirmPendingAction()
                }
            }
            Button("Cancel", role: .cancel, action: coordinator.cancelConfirmation)
        } message: {
            if let confirmation = coordinator.pendingConfirmation {
                Text(confirmation.message)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("No remembered devices")
                .font(.system(size: 13, weight: .semibold))
            Text("Supported stereo outputs will appear here after Airwave sees them.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AirwaveLayout.cardPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No remembered devices. Supported stereo outputs will appear here after Airwave sees them.")
    }

    private func deviceRow(_ row: DeviceManagementRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.deviceName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(row.transport) · \(row.status)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("HRIR: \(row.hrirName)")
                    Text("EQ: \(row.equalizerName)")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Reset Profile") { coordinator.requestReset(deviceUID: row.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!row.canReset)
                    .accessibilityLabel("Reset Profile for \(row.deviceName)")
                Button("Forget Device") { coordinator.requestForget(deviceUID: row.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!row.canForget)
                    .accessibilityLabel("Forget \(row.deviceName)")
            }
        }
        .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }
}
