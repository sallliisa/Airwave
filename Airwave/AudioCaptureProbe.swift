import AVFoundation
import Foundation

@MainActor
protocol AudioProbeStimulusPlaying: AnyObject {
    func play() throws
    func stop()
}

@MainActor
final class AVAudioProbeStimulusPlayer: NSObject, AudioProbeStimulusPlaying {
    private var player: AVAudioPlayer?

    func play() throws {
        guard let url = Bundle.main.url(forResource: "AudioCaptureProbe", withExtension: "wav") else {
            throw AudioRuntimeError.ioCreationFailed("Bundled capture probe is missing")
        }
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.play() else {
            throw AudioRuntimeError.ioStartFailed("Bundled capture probe could not start")
        }
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
