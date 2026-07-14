import Foundation

enum DeviceOutputEligibility {
    static func isSelectablePhysicalOutput(_ output: AggregateDeviceInspector.SubDeviceInfo) -> Bool {
        guard let range = output.outputChannelRange, range.count >= 2 else { return false }
        return !VirtualAudioDriver.isVirtualDriver(deviceName: output.name)
    }

    static func filter(_ outputs: [AggregateDeviceInspector.SubDeviceInfo]) -> [AggregateDeviceInspector.SubDeviceInfo] {
        outputs.filter(isSelectablePhysicalOutput)
    }
}
