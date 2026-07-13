import CoreAudio

struct AudioDeviceRefreshResult {
    let devices: [AudioDevice]
    let defaultInputID: AudioDeviceID?
    let defaultOutputID: AudioDeviceID?
}

protocol AudioDeviceQuerying {
    func refresh() -> AudioDeviceRefreshResult
}

/// CoreAudio metadata reader. One refresh creates one immutable snapshot per device.
final class CoreAudioDeviceQueryService: AudioDeviceQuerying {
    func refresh() -> AudioDeviceRefreshResult {
        let devices = AudioDeviceManager.getAllDeviceIDs().compactMap {
            AudioDeviceManager.makeDeviceSnapshot(deviceID: $0)
        }
        return AudioDeviceRefreshResult(
            devices: devices,
            defaultInputID: AudioDeviceManager.queryDefaultDeviceID(
                selector: kAudioHardwarePropertyDefaultInputDevice
            ),
            defaultOutputID: AudioDeviceManager.queryDefaultDeviceID(
                selector: kAudioHardwarePropertyDefaultOutputDevice
            )
        )
    }
}
