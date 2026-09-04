import Foundation
import os

nonisolated protocol StereoAudioProcessing: AnyObject {
    func process(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    )
}

nonisolated protocol AudioPipelineControlling: AnyObject {
    func start(
        on output: OutputDeviceDescriptor,
        muteBehavior: AudioTapMuteBehavior,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws
    func start(
        on output: OutputDeviceDescriptor,
        purpose: AudioPipelinePurpose,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws
    func stop() throws
    /// True while a passthrough-hold teardown is scheduled but not yet done;
    /// no replacement pipeline may be created while this is set.
    var isDeferredTeardownPending: Bool { get }
    /// See `AudioPipeline.stop(holdingPassthroughFade:onTeardownComplete:)`.
    func stop(
        holdingPassthroughFade hold: Bool,
        onTeardownComplete: ((Error?) -> Void)?
    ) throws
}

extension AudioPipelineControlling {
    /// Default for lightweight fakes: no deferred teardown.
    var isDeferredTeardownPending: Bool { false }

    /// Default for lightweight fakes: no hold window, immediate teardown.
    func stop(
        holdingPassthroughFade hold: Bool,
        onTeardownComplete: ((Error?) -> Void)?
    ) throws {
        try stop()
        onTeardownComplete?(nil)
    }
}

extension AudioPipelineControlling {
    func start(
        on output: OutputDeviceDescriptor,
        purpose: AudioPipelinePurpose,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws {
        switch purpose {
        case .verification:
            try start(on: output, muteBehavior: .unmuted, verificationHandler: verificationHandler)
        case .processing:
            try start(on: output, muteBehavior: .mutedWhenTapped, verificationHandler: verificationHandler)
        }
    }

    func start(
        on output: OutputDeviceDescriptor,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws {
        try start(
            on: output,
            muteBehavior: .mutedWhenTapped,
            verificationHandler: verificationHandler
        )
    }

    func start(on output: OutputDeviceDescriptor) throws {
        try start(on: output, muteBehavior: .mutedWhenTapped, verificationHandler: { _ in })
    }
}

/// Owns one strict tap -> private aggregate -> I/O lifecycle.
nonisolated final class AudioPipeline: AudioPipelineControlling {
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
        try start(on: platform.defaultOutputDevice(), muteBehavior: .mutedWhenTapped, verificationHandler: { _ in })
    }

    func start(on output: OutputDeviceDescriptor) throws {
        try start(on: output, muteBehavior: .mutedWhenTapped, verificationHandler: { _ in })
    }

    func start(
        on output: OutputDeviceDescriptor,
        muteBehavior: AudioTapMuteBehavior,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws {
        try start(
            on: output,
            purpose: muteBehavior == .unmuted ? .verification(includeOwnProcess: true) : .processing,
            verificationHandler: verificationHandler
        )
    }

    func start(
        on output: OutputDeviceDescriptor,
        purpose: AudioPipelinePurpose,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws {
        guard tap == nil, aggregate == nil, io == nil else { return }
        let pipelineID = ObjectIdentifier(self)
        AirwaveLog.audio.info("Pipeline start: stage=defaultOutput (\(String(describing: pipelineID))).")
        do {
            guard output.isSupportedProfileOutput else {
                throw AudioRuntimeError.unsupportedOutput(output.name)
            }

            let excludedProcesses: [AudioProcessHandle]
            switch purpose {
            case .verification(let includeOwnProcess):
                excludedProcesses = includeOwnProcess ? [] : [try platform.resolveOwnProcess()]
            case .processing:
                excludedProcesses = [try platform.resolveOwnProcess()]
            }
            // The support policy requires one output stream, so CATap stream 0
            // carries the complete supported device output.
            let request = GlobalStereoTapRequest(
                excludedProcesses: excludedProcesses,
                output: output,
                muteBehavior: purpose == .processing ? .mutedWhenTapped : .unmuted
            )
            let createdTap = try platform.createGlobalStereoTap(request)
            tap = createdTap
            AirwaveLog.audio.info("Pipeline start: created tap \(createdTap.value) (\(String(describing: pipelineID))).")

            let tapFormat = try platform.streamFormat(for: createdTap)
            let expectedCapture = AudioStreamFormat.capturing(channels: output.outputChannelCount, sampleRate: output.nominalSampleRate)
            guard tapFormat.isFloat32CaptureCompatible(with: expectedCapture) else {
                throw AudioRuntimeError.formatMismatch(expected: expectedCapture, actual: tapFormat)
            }

            let createdAggregate = try platform.createPrivateAggregate(tap: createdTap, output: output)
            aggregate = createdAggregate
            AirwaveLog.audio.info("Pipeline start: created aggregate \(createdAggregate.value) (\(String(describing: pipelineID))).")

            let aggregateFormat = try platform.streamFormat(for: createdAggregate)
            guard aggregateFormat.isFloat32CaptureCompatible(with: expectedCapture) else {
                throw AudioRuntimeError.formatMismatch(expected: tapFormat, actual: aggregateFormat)
            }

            let createdIO = try platform.createIO(
                aggregate: createdAggregate,
                callback: { [processor] inputChannels, inputChannelCount, outLeft, outRight, frames in
                    switch purpose {
                    case .processing:
                        processor.process(
                            inputChannels: inputChannels,
                            inputChannelCount: inputChannelCount,
                            outputLeft: outLeft,
                            outputRight: outRight,
                            frameCount: frames
                        )
                    case .verification:
                        StereoCallbackBridge.zero(left: outLeft, right: outRight, frameCount: frames)
                    }
                },
                verificationHandler: verificationHandler
            )
            io = createdIO
            AirwaveLog.audio.info("Pipeline start: created IO \(createdIO.value) (\(String(describing: pipelineID))).")
            try platform.startIO(createdIO)
            ioStarted = true
            AirwaveLog.audio.info("Pipeline start complete (pipeline \(String(describing: pipelineID)), IO \(createdIO.value), aggregate \(createdAggregate.value), tap \(createdTap.value)).")
        } catch {
            AirwaveLog.audio.error("Pipeline start failed: \(String(describing: error), privacy: .public) (\(String(describing: pipelineID))); unwinding.")
            try? stop()
            throw error
        }
    }

    /// Tears the chain down in strict IO → aggregate → tap order. Each stage is
    /// idempotent-tolerant (the platform treats already-destroyed objects as
    /// success) and throws only for genuinely unrecoverable statuses; a failed
    /// stage preserves the rest of the chain so a later `stop()` can safely
    /// retry THE SAME pipeline object.
    func stop() throws {
        guard !isDeferredTeardownPending else {
            // Destruction is already scheduled by a passthrough-hold stop;
            // reporting success here would let a replacement pipeline be
            // created while these resources are still registered.
            throw AudioRuntimeError.cleanupFailed("Pipeline teardown already scheduled")
        }
        let pipelineID = ObjectIdentifier(self)
        if let io {
            if ioStarted {
                // Never destroy a running I/O object or its dependencies. A failed stop
                // preserves the complete chain so a later stop() can retry safely.
                try platform.stopIO(io)
                ioStarted = false
                AirwaveLog.audio.info("Pipeline stop: stopped IO \(io.value) (\(String(describing: pipelineID))).")
            }
            try platform.destroyIO(io)
            AirwaveLog.audio.info("Pipeline stop: destroyed IO \(io.value) (\(String(describing: pipelineID))).")
            self.io = nil
        }
        if let aggregate {
            try platform.destroyPrivateAggregate(aggregate)
            AirwaveLog.audio.info("Pipeline stop: destroyed aggregate \(aggregate.value) (\(String(describing: pipelineID))).")
            self.aggregate = nil
        }
        if let tap {
            try platform.destroyTap(tap)
            AirwaveLog.audio.info("Pipeline stop: destroyed tap \(tap.value) (\(String(describing: pipelineID))).")
            self.tap = nil
        }
    }

    /// Length of time the tap and aggregate stay registered after program
    /// audio has stopped, keeping the native output muted while the renderer's
    /// fade to passthrough completes. Injectable for regression tests.
    nonisolated(unsafe) static var passthroughHoldInterval: TimeInterval = 0.5

    private var isDeferredTeardownPendingStorage = false

    /// True while a passthrough-hold teardown is scheduled but not yet done;
    /// no replacement pipeline may be created while this is set.
    var isDeferredTeardownPending: Bool { isDeferredTeardownPendingStorage }

    /// Plan 021 Step 2: never unmute into program audio.
    ///
    /// With `hold` set, the I/O loop halts synchronously (program audio stops
    /// flowing through Airwave immediately) while the tap and aggregate stay
    /// registered for `passthroughHoldInterval` — the native device therefore
    /// remains muted while the renderer's fade to passthrough finishes. Only
    /// after the window elapses are IO, aggregate, and tap destroyed on the
    /// main queue, so destroying the tap can never unmute native audio into
    /// still-flowing program audio.
    ///
    /// The claimed handles have a single owner from the moment this returns:
    /// either the deferred teardown block, or — if that destruction fails —
    /// they are handed back to this pipeline so a later `stop()` retry of THE
    /// SAME object can finish releasing them. While a teardown is pending,
    /// every further `stop()` throws instead of reporting success, preserving
    /// exclusive pipeline ownership (no replacement may be created while these
    /// handles are still registered).
    func stop(
        holdingPassthroughFade hold: Bool,
        onTeardownComplete: ((Error?) -> Void)?
    ) throws {
        guard hold else {
            try stop()
            onTeardownComplete?(nil)
            return
        }
        guard !isDeferredTeardownPending else {
            throw AudioRuntimeError.cleanupFailed("Pipeline teardown already scheduled")
        }

        // Synchronous stage: stop the I/O loop so program audio stops flowing
        // through Airwave. A failure here preserves the complete chain; the
        // caller retries THE SAME pipeline object.
        if let io, ioStarted {
            try platform.stopIO(io)
            ioStarted = false
        }
        guard tap != nil || aggregate != nil || io != nil else {
            onTeardownComplete?(nil)
            return
        }

        // Claim every handle: from here they belong solely to the deferred
        // teardown block, so neither a concurrent stop nor deinit can
        // double-destroy them.
        let teardownBox = DeferredTeardownBox(
            pipeline: self,
            platform: platform,
            io: io,
            aggregate: aggregate,
            tap: tap
        )
        io = nil
        aggregate = nil
        tap = nil
        isDeferredTeardownPendingStorage = true

        // The hold timer fires exclusively on the main queue — the same queue
        // on which the controller performs every pipeline mutation.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.passthroughHoldInterval) {
            teardownBox.run(onTeardownComplete: onTeardownComplete)
        }
    }

    /// `@unchecked Sendable`: the box is confined to the main queue — armed on
    /// it and fired exclusively by its `asyncAfter` handler — so the captured
    /// non-Sendable pipeline/platform references never cross threads.
    private final class DeferredTeardownBox: @unchecked Sendable {
        let pipeline: AudioPipeline
        let platform: AudioPlatformClient
        let io: AudioIOHandle?
        let aggregate: PrivateAggregateHandle?
        let tap: AudioTapHandle?

        init(
            pipeline: AudioPipeline,
            platform: AudioPlatformClient,
            io: AudioIOHandle?,
            aggregate: PrivateAggregateHandle?,
            tap: AudioTapHandle?
        ) {
            self.pipeline = pipeline
            self.platform = platform
            self.io = io
            self.aggregate = aggregate
            self.tap = tap
        }

        func run(onTeardownComplete: ((Error?) -> Void)?) {
            // Every outcome hands ownership back: fully destroyed, or the
            // surviving handles returned to this object so a later `stop()`
            // retry of THE SAME pipeline can finish releasing them.
            pipeline.isDeferredTeardownPendingStorage = false
            // The I/O loop was already stopped synchronously before the hold.
            pipeline.ioStarted = false
            AirwaveLog.audioRuntime.info("Passthrough hold elapsed; destroying IO, aggregate, tap.")
            do {
                if let io { try platform.destroyIO(io) }
            } catch {
                pipeline.io = io
                pipeline.aggregate = aggregate
                pipeline.tap = tap
                AirwaveLog.audioRuntime.error(
                    "Deferred pipeline teardown failed at destroyIO; chain preserved for retry: \(String(describing: error), privacy: .public)"
                )
                onTeardownComplete?(error)
                return
            }
            do {
                if let aggregate { try platform.destroyPrivateAggregate(aggregate) }
            } catch {
                pipeline.aggregate = aggregate
                pipeline.tap = tap
                AirwaveLog.audioRuntime.error(
                    "Deferred pipeline teardown failed at destroyAggregate; aggregate+tap preserved for retry: \(String(describing: error), privacy: .public)"
                )
                onTeardownComplete?(error)
                return
            }
            do {
                if let tap { try platform.destroyTap(tap) }
            } catch {
                pipeline.tap = tap
                AirwaveLog.audioRuntime.error(
                    "Deferred pipeline teardown failed at destroyTap; tap preserved for retry: \(String(describing: error), privacy: .public)"
                )
                onTeardownComplete?(error)
                return
            }
            onTeardownComplete?(nil)
            AirwaveLog.audio.info(
                "Pipeline stop: deferred teardown complete (pipeline \(String(describing: ObjectIdentifier(self.pipeline)))."
            )
        }
    }
}
