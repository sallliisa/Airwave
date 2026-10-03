import SwiftUI

struct ConfigureOutputView: View {
    @ObservedObject var coordinator: ConfigureOutputCoordinator
    let onCancel: () -> Void
    let onSave: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(coordinator.deviceName)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            Text("Choose the device channels for Airwave's stereo output.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(spacing: AirwaveLayout.sectionContentSpacing) {
                channelPicker(
                    title: "Left output",
                    selection: coordinator.leftChannel,
                    options: coordinator.leftChannelOptions,
                    setSelection: coordinator.selectLeftChannel
                )
                channelPicker(
                    title: "Right output",
                    selection: coordinator.rightChannel,
                    options: coordinator.rightChannelOptions,
                    setSelection: coordinator.selectRightChannel
                )
            }
            .padding(.top, AirwaveLayout.sectionSpacing)

            Group {
                if let message = coordinator.validationMessage {
                    Text(message)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Output assignment status: \(message)")
                } else {
                    Text("Left and right output use distinct device channels.")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Output assignment is valid")
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, AirwaveLayout.sectionSpacing)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .accessibilityLabel("Cancel output configuration for \(coordinator.deviceName)")

                Button("Save") {
                    _ = onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!coordinator.canSave)
                .accessibilityLabel("Save output configuration for \(coordinator.deviceName)")
            }
            .padding(.top, AirwaveLayout.sectionSpacing)
        }
        .padding(AirwaveLayout.cardPadding)
        .frame(width: 360, alignment: .leading)
        .preferredColorScheme(.dark)
    }

    private func channelPicker(
        title: String,
        selection: Int,
        options: [Int],
        setSelection: @escaping (Int) -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 100, alignment: .leading)

            Picker(title, selection: Binding(
                get: { selection },
                set: setSelection
            )) {
                ForEach(options, id: \.self) { channel in
                    Text(coordinator.channelOptionLabel(channel)).tag(channel)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!coordinator.isAvailable)
            .accessibilityLabel("\(title) for \(coordinator.deviceName)")
            .accessibilityValue(coordinator.channelOptionLabel(selection))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
