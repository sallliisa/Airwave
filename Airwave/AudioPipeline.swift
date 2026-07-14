import Foundation

nonisolated protocol StereoAudioProcessing: AnyObject {
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    )
}

extension RealtimeAudioProcessor: StereoAudioProcessing {
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        process(
            inputLeft: inputLeft,
            inputRight: inputRight,
            leftOutput: outputLeft,
            rightOutput: outputRight,
            frameCount: frameCount
        )
    }
}

/// Owns one strict tap -> private aggregate -> I/O lifecycle.
nonisolated final class AudioPipeline {
    private let platform: AudioPlatformClient
    private let processor: StereoAudioProcessing

    private var tap: AudioTapHandle?
    private var aggregate: PrivateAggregateHandle?
    private var io: AudioIOHandle?
    private var ioStarted = false

    init(platform: AudioPlatformClient, processor: StereoAudioProcessing) {
        self.platform = platform
        self.processor = processor
    }

    convenience init(processor: StereoAudioProcessing) {
        self.init(platform: CoreAudioPlatformClient(), processor: processor)
    }

    deinit {
        try? stop()
    }

    func start() throws {
        guard tap == nil, aggregate == nil, io == nil else { return }

        do {
            let output = try platform.defaultOutputDevice()
            guard output.outputChannelCount == 2, !output.isVirtual, !output.isAggregate else {
                throw AudioRuntimeError.unsupportedOutput(output.name)
            }

            let process = try platform.resolveOwnProcess()
            let request = GlobalStereoTapRequest(excludedProcess: process)
            let createdTap = try platform.createGlobalStereoTap(request)
            tap = createdTap

            let tapFormat = try platform.streamFormat(for: createdTap)
            let expectedFormat = AudioStreamFormat.stereo(sampleRate: output.nominalSampleRate)
            guard tapFormat == expectedFormat else {
                throw AudioRuntimeError.formatMismatch(expected: expectedFormat, actual: tapFormat)
            }

            let createdAggregate = try platform.createPrivateAggregate(tap: createdTap, output: output)
            aggregate = createdAggregate

            let aggregateFormat = try platform.streamFormat(for: createdAggregate)
            guard aggregateFormat == tapFormat else {
                throw AudioRuntimeError.formatMismatch(expected: tapFormat, actual: aggregateFormat)
            }

            let createdIO = try platform.createIO(aggregate: createdAggregate) { [processor] inLeft, inRight, outLeft, outRight, frames in
                processor.process(
                    inputLeft: inLeft,
                    inputRight: inRight,
                    outputLeft: outLeft,
                    outputRight: outRight,
                    frameCount: frames
                )
            }
            io = createdIO
            try platform.startIO(createdIO)
            ioStarted = true
        } catch {
            try? stop()
            throw error
        }
    }

    func stop() throws {
        if let io {
            if ioStarted {
                // Never destroy a running I/O object or its dependencies. A failed stop
                // preserves the complete chain so a later stop() can retry safely.
                try platform.stopIO(io)
                ioStarted = false
            }
            try platform.destroyIO(io)
            self.io = nil
        }
        if let aggregate {
            try platform.destroyPrivateAggregate(aggregate)
            self.aggregate = nil
        }
        if let tap {
            try platform.destroyTap(tap)
            self.tap = nil
        }
    }
}
