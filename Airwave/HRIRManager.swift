//
//  HRIRManager.swift
//  Airwave
//
//  Manages HRIR presets and multi-channel convolution processing
//

import Accelerate
import Foundation
import Combine

/// Represents an HRIR preset
nonisolated struct HRIRPreset: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let name: String
    let fileURL: URL
    let channelCount: Int
    let sampleRate: Double

    static func == (lhs: HRIRPreset, rhs: HRIRPreset) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum HRIRImportCollisionPolicy { case reject, replace }

struct HRIRImportFailure: Equatable {
    let filename: String
    let reason: String
}

struct HRIRImportPreflight {
    let acceptable: [URL]
    let conflicts: [URL]
    let rejected: [HRIRImportFailure]
}

struct HRIRImportResult {
    let imported: [HRIRPreset]
    let skipped: [String]
    let failures: [HRIRImportFailure]
}

enum HRIRActivationResult: Equatable {
    case success
    case failure(String)
}

struct PresetActivationKey: Hashable {
    let presetID: UUID
    let fileURL: URL
    let sampleRate: Double
    let inputChannels: [VirtualSpeaker]

    init(preset: HRIRPreset, targetSampleRate: Double, inputLayout: InputLayout) {
        self.presetID = preset.id
        self.fileURL = preset.fileURL.standardizedFileURL
        self.sampleRate = targetSampleRate
        self.inputChannels = inputLayout.channels
    }
}

final class ActivationCancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Renders a single virtual speaker to binaural output
nonisolated struct VirtualSpeakerRenderer {
    let speaker: VirtualSpeaker
    let convolver: StereoConvolutionEngine
}

/// Manages HRIR presets and multi-channel convolution processing
import AppKit

import os

/// Fixed-capacity hand-off slots. The render thread never releases a renderer
/// state; it parks it here and the control thread drains it.
nonisolated struct SpatialRetirementSlots {
    private var first: HRIRManager.RendererState?
    private var second: HRIRManager.RendererState?
    private var third: HRIRManager.RendererState?
    private var fourth: HRIRManager.RendererState?

    var isEmpty: Bool { first == nil && second == nil && third == nil && fourth == nil }

    var count: Int {
        var total = 0
        if first != nil { total += 1 }
        if second != nil { total += 1 }
        if third != nil { total += 1 }
        if fourth != nil { total += 1 }
        return total
    }

    mutating func insert(_ state: HRIRManager.RendererState) -> Bool {
        if first == nil { first = state; return true }
        if second == nil { second = state; return true }
        if third == nil { third = state; return true }
        if fourth == nil { fourth = state; return true }
        return false
    }

    /// Moves everything it can into `other`, keeping whatever does not fit.
    /// Allocation-free so the render thread can call it.
    mutating func moveAll(into other: inout SpatialRetirementSlots) -> Bool {
        var moved = true
        if let value = first {
            if other.insert(value) { first = nil } else { moved = false }
        }
        if let value = second {
            if other.insert(value) { second = nil } else { moved = false }
        }
        if let value = third {
            if other.insert(value) { third = nil } else { moved = false }
        }
        if let value = fourth {
            if other.insert(value) { fourth = nil } else { moved = false }
        }
        return moved
    }

    mutating func clear() {
        first = nil
        second = nil
        third = nil
        fourth = nil
    }
}

/// Blends the outgoing and incoming renderer states on the render thread so a
/// preset change never has to tear down the Core Audio chain.
///
/// The incoming state is fed input for `primeLength` frames before it is blended
/// in: `RealtimeAudioProcessor` emits silence until it holds one full DSP block,
/// and blending that silence would click. Only after the priming window does the
/// equal-power ramp run.
nonisolated final class SpatialRendererCrossfader {
    typealias RendererState = HRIRManager.RendererState

    let primeLength: Int
    let fadeLength: Int
    let maxFramesPerCallback: Int

    private let fadeOutGain: UnsafeMutablePointer<Float>
    private let fadeInGain: UnsafeMutablePointer<Float>
    private let fromLeftScratch: UnsafeMutablePointer<Float>
    private let fromRightScratch: UnsafeMutablePointer<Float>
    private let toLeftScratch: UnsafeMutablePointer<Float>
    private let toRightScratch: UnsafeMutablePointer<Float>

    private let retirementLock = OSAllocatedUnfairLock<SpatialRetirementSlots>(initialState: SpatialRetirementSlots())
    private let resetLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    // Render-thread-only state.
    private var activeState: RendererState?
    private var observedState: RendererState?
    private var fadeFrom: RendererState?
    private var fadeTo: RendererState?
    private var pendingTarget: RendererState?
    private var hasPendingTarget = false
    private var isFading = false
    private var fadeFrame = 0
    private var primeFrames = 0
    private var pendingRetirement = SpatialRetirementSlots()

    init(primeLength: Int, fadeLength: Int = 1_024, maxFramesPerCallback: Int = 4_096) {
        precondition(primeLength >= 0)
        precondition(fadeLength > 0)
        precondition(maxFramesPerCallback > 0)
        self.primeLength = primeLength
        self.fadeLength = fadeLength
        self.maxFramesPerCallback = maxFramesPerCallback

        fadeOutGain = UnsafeMutablePointer<Float>.allocate(capacity: fadeLength)
        fadeInGain = UnsafeMutablePointer<Float>.allocate(capacity: fadeLength)
        for index in 0..<fadeLength {
            let theta = (Double(index + 1) / Double(fadeLength)) * (.pi / 2)
            fadeOutGain[index] = Float(cos(theta))
            fadeInGain[index] = Float(sin(theta))
        }

        fromLeftScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        fromRightScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        toLeftScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        toRightScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
    }

    deinit {
        fadeOutGain.deallocate()
        fadeInGain.deallocate()
        fromLeftScratch.deallocate()
        fromRightScratch.deallocate()
        toLeftScratch.deallocate()
        toRightScratch.deallocate()
    }

    #if DEBUG
    var retiredStateCountForTesting: Int { retirementLock.withLock { $0.count } }
    var isFadingForTesting: Bool { isFading }
    var activeStateForTesting: RendererState? { activeState }
    #endif

    /// Releases states retired by the render thread. Call from the control thread.
    func drainRetiredStates() {
        retirementLock.withLock { slots in
            slots.clear()
        }
    }

    /// Call only after the I/O callback has stopped.
    func cleanupAfterIOStopped() {
        retirementLock.withLock { $0.clear() }
        pendingRetirement.clear()
        activeState = nil
        observedState = nil
        fadeFrom = nil
        fadeTo = nil
        pendingTarget = nil
        hasPendingTarget = false
        isFading = false
        fadeFrame = 0
        primeFrames = 0
    }

    /// Drops the render-thread state without fading. Used when the pipeline is
    /// torn down, so a rebuilt pipeline never resumes a stale preset.
    func requestReset() {
        resetLock.withLock { requested in
            requested = true
        }
    }

    // BEGIN REALTIME CALLBACK
    func observe(_ published: RendererState?) {
        guard published !== observedState else { return }
        if isFading, let pendingTarget, pendingTarget !== published {
            guard retire(pendingTarget) else { return }
            self.pendingTarget = nil
        }
        observedState = published
        if isFading {
            if published !== fadeTo {
                pendingTarget = published
                hasPendingTarget = true
            } else {
                pendingTarget = nil
                hasPendingTarget = false
            }
        } else if !pendingRetirement.isEmpty {
            pendingTarget = published
            hasPendingTarget = true
        } else if published !== activeState {
            beginFade(to: published)
        }
    }

    func processIfNeeded(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Bool {
        precondition(frameCount <= maxFramesPerCallback)
        applyPendingReset()
        flushPendingRetirement()
        guard frameCount > 0 else { return false }
        guard isFading || activeState != nil else { return false }

        var passthroughSpeakers: [VirtualSpeaker]?
        var offset = 0
        while offset < frameCount {
            guard isFading else {
                render(
                    activeState,
                    inputChannels: inputChannels,
                    inputChannelCount: inputChannelCount,
                    inputOffset: offset,
                    leftOutput: leftOutput.advanced(by: offset),
                    rightOutput: rightOutput.advanced(by: offset),
                    frameCount: frameCount - offset,
                    fallbackSpeakers: passthroughSpeakers
                )
                return true
            }

            let boundary = fadeFrame < primeFrames ? primeFrames : primeFrames + fadeLength
            let segment = min(boundary - fadeFrame, frameCount - offset)

            if fadeFrame < primeFrames {
                render(
                    fadeFrom,
                    inputChannels: inputChannels,
                    inputChannelCount: inputChannelCount,
                    inputOffset: offset,
                    leftOutput: leftOutput.advanced(by: offset),
                    rightOutput: rightOutput.advanced(by: offset),
                    frameCount: segment
                )
                // Warm the incoming adapter; its output is still silence-padded.
                render(
                    fadeTo,
                    inputChannels: inputChannels,
                    inputChannelCount: inputChannelCount,
                    inputOffset: offset,
                    leftOutput: toLeftScratch,
                    rightOutput: toRightScratch,
                    frameCount: segment
                )
            } else {
                render(
                    fadeFrom,
                    inputChannels: inputChannels,
                    inputChannelCount: inputChannelCount,
                    inputOffset: offset,
                    leftOutput: fromLeftScratch,
                    rightOutput: fromRightScratch,
                    frameCount: segment
                )
                render(
                    fadeTo,
                    inputChannels: inputChannels,
                    inputChannelCount: inputChannelCount,
                    inputOffset: offset,
                    leftOutput: toLeftScratch,
                    rightOutput: toRightScratch,
                    frameCount: segment
                )
                let base = fadeFrame - primeFrames
                for index in 0..<segment {
                    let outGain = fadeOutGain[base + index]
                    let inGain = fadeInGain[base + index]
                    leftOutput[offset + index] = fromLeftScratch[index] * outGain + toLeftScratch[index] * inGain
                    rightOutput[offset + index] = fromRightScratch[index] * outGain + toRightScratch[index] * inGain
                }
            }

            fadeFrame += segment
            offset += segment
            if fadeFrame == primeFrames + fadeLength {
                if fadeTo == nil {
                    passthroughSpeakers = fadeFrom?.fallbackSpeakers
                }
                finishFade()
            }
        }
        return true
    }
    // END REALTIME CALLBACK

    @inline(__always)
    private func render(
        _ state: RendererState?,
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        inputOffset: Int,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int,
        fallbackSpeakers: [VirtualSpeaker]? = nil
    ) {
        guard let state, !state.renderers.isEmpty else {
            let speakers = state?.fallbackSpeakers
                ?? fadeTo?.fallbackSpeakers
                ?? fadeFrom?.fallbackSpeakers
                ?? fallbackSpeakers
            guard let speakers else { return }
            StereoDownmixGains.downmix(
                inputChannels: inputChannels,
                inputChannelCount: inputChannelCount,
                inputOffset: inputOffset,
                inputSpeakers: speakers,
                outputLeft: leftOutput,
                outputRight: rightOutput,
                frameCount: frameCount
            )
            return
        }
        state.processor.process(
            inputChannels: inputChannels,
            inputChannelCount: inputChannelCount,
            inputOffset: inputOffset,
            leftOutput: leftOutput,
            rightOutput: rightOutput,
            frameCount: frameCount
        )
    }

    private func beginFade(to target: RendererState?) {
        guard target !== activeState else { return }
        fadeFrom = activeState
        fadeTo = target
        fadeFrame = 0
        primeFrames = target == nil ? 0 : primeLength
        isFading = true
    }

    private func finishFade() {
        let outgoing = fadeFrom
        activeState = fadeTo
        fadeFrom = nil
        fadeTo = nil
        fadeFrame = 0
        primeFrames = 0
        isFading = false
        if let outgoing, !retire(outgoing) { return }
        startPendingFadeIfNeeded()
    }

    private func startPendingFadeIfNeeded() {
        guard hasPendingTarget, pendingRetirement.isEmpty else { return }
        let pending = pendingTarget
        pendingTarget = nil
        hasPendingTarget = false
        if pending !== activeState { beginFade(to: pending) }
    }

    private func applyPendingReset() {
        guard let requested = resetLock.withLockIfAvailable({ requested -> Bool in
            let value = requested
            requested = false
            return value
        }), requested else {
            return
        }
        if let state = activeState { _ = retire(state) }
        if let state = fadeTo, state !== activeState { _ = retire(state) }
        if let state = pendingTarget, state !== activeState, state !== fadeTo { _ = retire(state) }
        activeState = nil
        observedState = nil
        fadeFrom = nil
        fadeTo = nil
        pendingTarget = nil
        hasPendingTarget = false
        isFading = false
        fadeFrame = 0
        primeFrames = 0
    }

    @discardableResult
    private func retire(_ state: RendererState) -> Bool {
        if pendingRetirement.isEmpty,
           retirementLock.withLockIfAvailable({ slots in slots.insert(state) }) == true {
            return true
        }
        return pendingRetirement.insert(state)
    }

    private func flushPendingRetirement() {
        guard !pendingRetirement.isEmpty else { return }
        guard retirementLock.withLockIfAvailable({ slots in
            pendingRetirement.moveAll(into: &slots)
        }) == true else {
            return
        }
        startPendingFadeIfNeeded()
    }
}

/// Manages HRIR presets and multi-channel convolution processing
class HRIRManager: ObservableObject {
    
    // MARK: - Singleton
    static let shared = HRIRManager()

    // MARK: - Published Properties

    @Published var presets: [HRIRPreset] = []
    @Published var activePreset: HRIRPreset?
    
    @Published var errorMessage: String?
    @Published private(set) var initialLibrarySyncReady = false
    
    // Internal state
    private(set) var currentInputLayout: InputLayout?
    private(set) var currentHRIRMap: HRIRChannelMap?
    
    // Convolution is active when a preset is loaded and renderer state is ready
    var isConvolutionActive: Bool {
        return activePreset != nil && rendererState != nil
    }
    
    // MARK: - Private Properties
    
    // Multi-channel rendering: one renderer per input channel
    // Protected by a concurrent queue for thread-safe access
    // Immutable state container for lock-free access
    nonisolated class RendererState {
        let renderers: [VirtualSpeakerRenderer]
        let processor: RealtimeAudioProcessor
        let fallbackSpeakers: [VirtualSpeaker]

        init(renderers: [VirtualSpeakerRenderer], inputChannelCount: Int, fallbackSpeakers: [VirtualSpeaker], blockSize: Int) {
            self.renderers = renderers
            self.fallbackSpeakers = fallbackSpeakers
            self.processor = RealtimeAudioProcessor(
                renderers: renderers,
                inputChannelCount: inputChannelCount,
                fallbackSpeakers: fallbackSpeakers,
                blockSize: blockSize
            )
        }
    }
    
    // Writers publish immutable state under one lock. Render thread makes one non-blocking snapshot attempt.
    nonisolated private let stateLock = OSAllocatedUnfairLock<RendererState?>(initialState: nil)
    // Render-thread blend between the outgoing and incoming state. A preset
    // change never stops the pipeline; it publishes a new state and fades.
    nonisolated private let crossfader = SpatialRendererCrossfader(
        primeLength: HRIRManager.processingBlockSize
    )

    private var activationTask: DispatchWorkItem?
    private var activationGeneration = 0
    private var currentActivationKey: PresetActivationKey?
    private var inFlightActivationKey: PresetActivationKey?
    private var activationCancellationToken: ActivationCancellationToken?
    private var activationCompletion: ((HRIRActivationResult) -> Void)?

    // Serialized off-main import work: validation and copy run on one queue,
    // commits land on the main actor in request order. Newer requests cancel
    // older ones before any publish step.
    private let importWorkQueue = DispatchQueue(label: "com.airwave.hrir.import", qos: .userInitiated)
    private var importGeneration = 0
    
    private var rendererState: RendererState? {
        get { stateLock.withLock { $0 } }
        set { stateLock.withLock { $0 = newValue } }
    }
    
    nonisolated static let processingBlockSize: Int = 512  // Balance between latency (~10.7ms @ 48kHz) and CPU efficiency

    private let presetsDirectory: URL
    private let fileManager: FileManager
    private let bundledPresetCatalog: BundledPresetCatalog
    private var eventStream: FSEventStreamRef?
    private var directoryDebounceTask: DispatchWorkItem?

    // MARK: - Initialization

    init(
        presetsDirectory: URL? = nil,
        fileManager: FileManager = .default,
        startWatcher: Bool = true,
        bundledPresetCatalog: BundledPresetCatalog? = nil
    ) {
        self.fileManager = fileManager
        self.bundledPresetCatalog = bundledPresetCatalog ?? BundledPresetCatalog.fromMainBundle()
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.presetsDirectory = presetsDirectory ?? appSupport.appendingPathComponent("Airwave/presets", isDirectory: true)

        // Create directory if it doesn't exist
        try? fileManager.createDirectory(at: self.presetsDirectory, withIntermediateDirectories: true)

        seedBundledPresets()

        // Load existing presets and sync with directory
        loadAndSyncPresets()
        
        // Start watching for changes
        if startWatcher { startDirectoryWatcher() }
    }
    
    deinit {
        stopDirectoryWatcher()
    }

    // MARK: - Public Methods

    private func seedBundledPresets() {
        BundledPresetSeeder.seed(
            files: bundledPresetCatalog.hrirFiles,
            into: presetsDirectory,
            markerURL: presetsDirectory.appendingPathComponent(".bundled-presets.json"),
            fileManager: fileManager
        ) { source in
            _ = try WAVLoader.load(from: source)
        }
    }

    /// Opens the presets directory in Finder
    func openPresetsDirectory() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: presetsDirectory.path)
    }

    func preflightImport(_ urls: [URL]) -> HRIRImportPreflight {
        var acceptable: [URL] = []
        var conflicts: [URL] = []
        var rejected: [HRIRImportFailure] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                rejected.append(.init(filename: url.lastPathComponent, reason: "Choose a WAV file, not a folder.")); continue
            }
            guard url.pathExtension.lowercased() == "wav" else {
                rejected.append(.init(filename: url.lastPathComponent, reason: "Only WAV files can be imported.")); continue
            }
            guard fileManager.isReadableFile(atPath: url.path) else {
                rejected.append(.init(filename: url.lastPathComponent, reason: "The file could not be read.")); continue
            }
            do {
                let header = try WAVLoader.headerInfo(from: url)
                guard header.channelCount >= 2 else { throw HRIRError.invalidChannelCount(header.channelCount) }
                let destination = presetsDirectory.appendingPathComponent(url.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) { conflicts.append(url) }
                else { acceptable.append(url) }
            } catch {
                rejected.append(.init(filename: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return .init(acceptable: acceptable, conflicts: conflicts, rejected: rejected)
    }

    private struct ValidatedHRIRImport: Sendable {
        let source: URL
        let filename: String
        let destination: URL
        let channelCount: Int
        let sampleRate: Double
        let securityScoped: Bool
        /// Support closure runs on the worker and can suspend an import with
        /// no managed-side effects, for the cancellation test path only.
        /// Production passes nil.
        let workerGate: (@Sendable () -> Bool)?
    }

    private func validateImportURL(_ url: URL, workerGate: (@Sendable () -> Bool)? = nil) throws -> ValidatedHRIRImport {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw HRIRError.batchImportFailed("Choose a WAV file, not a folder.")
        }
        guard url.pathExtension.lowercased() == "wav" else {
            throw HRIRError.batchImportFailed("Only WAV files can be imported.")
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw HRIRError.batchImportFailed("The file could not be read.")
        }
        // Bounded header check on the caller thread; full sample validation
        // runs on the worker before any managed file changes. Security-scoped
        // access starts here and ends when the worker finishes the copy, so
        // the worker can read panel URLs after this function returns.
        let accessed = url.startAccessingSecurityScopedResource()
        let header: WAVHeaderInfo
        do {
            header = try WAVLoader.headerInfo(from: url)
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        guard header.channelCount >= 2 else {
            if accessed { url.stopAccessingSecurityScopedResource() }
            throw HRIRError.invalidChannelCount(header.channelCount)
        }
        let filename = url.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            if accessed { url.stopAccessingSecurityScopedResource() }
            throw HRIRError.batchImportFailed("Invalid filename.")
        }
        let destination = presetsDirectory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard destination.deletingLastPathComponent() == presetsDirectory.standardizedFileURL else {
            if accessed { url.stopAccessingSecurityScopedResource() }
            throw HRIRError.batchImportFailed("Invalid filename.")
        }
        return ValidatedHRIRImport(
            source: url,
            filename: filename,
            destination: destination,
            channelCount: header.channelCount,
            sampleRate: header.sampleRate,
            securityScoped: accessed,
            workerGate: workerGate
        )
    }

    private func copyValidatedImportToTemporary(_ input: ValidatedHRIRImport) throws -> CommittedHRIRFile {
        // Full finite-sample validation before the managed copy. Security
        // scope ends here: all source reads for this file complete below.
        defer {
            if input.securityScoped { input.source.stopAccessingSecurityScopedResource() }
        }
        // Test hook: while the gate holds, an outer cancellation request that
        // arrives mid-worker must discard this import with no managed effect.
        if let gate = input.workerGate {
            while gate() { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        // Full finite-sample validation before the managed copy.
        let wav = try WAVLoader.load(from: input.source)
        guard wav.channelCount >= 2 else { throw HRIRError.invalidChannelCount(wav.channelCount) }
        let temporary = presetsDirectory.appendingPathComponent(".\(UUID().uuidString).wav")
        try fileManager.copyItem(at: input.source, to: temporary)
        return CommittedHRIRFile(
            temporary: temporary,
            filename: input.filename,
            destination: input.destination,
            channelCount: wav.channelCount,
            sampleRate: wav.sampleRate
        )
    }

    private struct CommittedHRIRFile: Sendable {
        let temporary: URL
        let filename: String
        let destination: URL
        let channelCount: Int
        let sampleRate: Double
    }

    private enum CommittedHRIRImport: Sendable {
        case committed(CommittedHRIRFile)
        case skipped(String)
        case failure(HRIRImportFailure)
    }

    private func commitValidatedImport(_ file: CommittedHRIRFile, collisionPolicy: HRIRImportCollisionPolicy) -> CommittedHRIRImport {
        // Commits run serialized on the main actor in request order.
        dispatchPrecondition(condition: .onQueue(.main))
        let existing = presets.first { $0.fileURL.lastPathComponent == file.destination.lastPathComponent }
        if fileManager.fileExists(atPath: file.destination.path), collisionPolicy == .reject {
            try? fileManager.removeItem(at: file.temporary)
            return .skipped(file.filename)
        }
        do {
            if fileManager.fileExists(atPath: file.destination.path) {
                _ = try fileManager.replaceItemAt(file.destination, withItemAt: file.temporary)
            } else {
                try fileManager.moveItem(at: file.temporary, to: file.destination)
            }
        } catch {
            try? fileManager.removeItem(at: file.temporary)
            return .failure(.init(filename: file.filename, reason: error.localizedDescription))
        }
        let preset = HRIRPreset(
            id: existing?.id ?? UUID(), name: file.destination.deletingPathExtension().lastPathComponent,
            fileURL: file.destination, channelCount: file.channelCount, sampleRate: file.sampleRate
        )
        if let index = presets.firstIndex(where: { $0.id == preset.id }) { presets[index] = preset }
        else { presets.append(preset) }
        if activePreset?.id == preset.id { activePreset = preset }
        return .committed(file)
    }

    private func publishCommittedImport(_ file: CommittedHRIRFile) -> HRIRPreset? {
        presets.first { $0.fileURL.lastPathComponent == file.destination.lastPathComponent }
    }

    func importPresets(_ urls: [URL], collisionPolicy: HRIRImportCollisionPolicy) -> HRIRImportResult {
        dispatchPrecondition(condition: .onQueue(.main))
        var staged: [ValidatedHRIRImport] = []
        staged.reserveCapacity(urls.count)
        var failures: [HRIRImportFailure] = []
        for url in urls {
            do {
                staged.append(try validateImportURL(url))
            } catch {
                failures.append(.init(filename: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        guard !staged.isEmpty else {
            savePresets()
            return .init(imported: [], skipped: [], failures: failures)
        }
        return importPresetsStaged(staged, collisionPolicy: collisionPolicy, priorFailures: failures)
    }

    private func importPresetsStaged(
        _ staged: [ValidatedHRIRImport],
        collisionPolicy: HRIRImportCollisionPolicy,
        priorFailures: [HRIRImportFailure]
    ) -> HRIRImportResult {
        dispatchPrecondition(condition: .onQueue(.main))
        // Synchronous entry (tests, init paths): run worker validation inline
        // on the caller, then commit in order on the main actor.
        var failures = priorFailures
        var files: [CommittedHRIRFile] = []
        for input in staged {
            do {
                files.append(try copyValidatedImportToTemporary(input))
            } catch {
                failures.append(.init(filename: input.filename, reason: error.localizedDescription))
            }
        }
        var imported: [HRIRPreset] = []
        var skipped: [String] = []
        files.sort { $0.filename < $1.filename }
        for file in files {
            switch commitValidatedImport(file, collisionPolicy: collisionPolicy) {
            case .committed(let committed):
                if let preset = publishCommittedImport(committed) { imported.append(preset) }
            case .skipped(let name):
                skipped.append(name)
            case .failure(let failure):
                failures.append(failure)
            }
        }
        savePresets()
        return HRIRImportResult(imported: imported, skipped: skipped, failures: failures)
    }

    private struct StagedAsyncImport {
        let published: HRIRImportResult
        let committedFilesForDiscard: [CommittedHRIRFile]
    }

    private func importPresetsStagedAsync(
        _ staged: [ValidatedHRIRImport],
        collisionPolicy: HRIRImportCollisionPolicy,
        priorFailures: [HRIRImportFailure],
        cancellation: ActivationCancellationToken?
    ) async -> StagedAsyncImport {
        // Worker stage: full WAV decode + finite-sample check + copy to a
        // managed temporary. Runs serialized on importWorkQueue.
        let policy = collisionPolicy
        struct WorkerOutcome: Sendable {
            var files: [CommittedHRIRFile] = []
            var failures: [HRIRImportFailure] = []
        }
        let workerOutcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                importWorkQueue.async { [weak self] in
                    var outcome = WorkerOutcome()
                    guard let self else {
                        continuation.resume(returning: outcome)
                        return
                    }
                    for input in staged {
                        if let cancellation, cancellation.isCancelled { break }
                        do {
                            outcome.files.append(try self.copyValidatedImportToTemporary(input))
                        } catch is CancellationError {
                            break
                        } catch {
                            outcome.failures.append(.init(filename: input.filename, reason: error.localizedDescription))
                        }
                    }
                    continuation.resume(returning: outcome)
                }
            }
        } onCancel: {
            cancellation?.cancel()
        }
        guard !(cancellation?.isCancelled ?? false) else {
            for file in workerOutcome.files {
                try? FileManager.default.removeItem(at: file.temporary)
            }
            return StagedAsyncImport(
                published: HRIRImportResult(imported: [], skipped: [], failures: []),
                committedFilesForDiscard: []
            )
        }
        // Commit stage on the main actor, in filename order. The caller
        // checks generation and cancellation before this runs, and again
        // before it keeps the commit, so a stale request never touches
        // managed files or the preset array.
        return await MainActor.run { [weak self] in
            guard let self else {
                return StagedAsyncImport(
                    published: HRIRImportResult(imported: [], skipped: [], failures: priorFailures + workerOutcome.failures),
                    committedFilesForDiscard: []
                )
            }
            var failures = priorFailures + workerOutcome.failures
            var imported: [HRIRPreset] = []
            var skipped: [String] = []
            let files = workerOutcome.files.sorted { $0.filename < $1.filename }
            var committedFiles: [CommittedHRIRFile] = []
            for file in files {
                switch self.commitValidatedImport(file, collisionPolicy: policy) {
                case .committed(let committed):
                    committedFiles.append(file)
                    if let preset = self.publishCommittedImport(committed) { imported.append(preset) }
                case .skipped(let name):
                    skipped.append(name)
                case .failure(let failure):
                    failures.append(failure)
                }
            }
            self.savePresets()
            return StagedAsyncImport(
                published: HRIRImportResult(imported: imported, skipped: skipped, failures: failures),
                committedFilesForDiscard: committedFiles
            )
        }
    }

    func importPresetsAsync(_ urls: [URL], collisionPolicy: HRIRImportCollisionPolicy) async -> HRIRImportResult {
        // Newest-wins across overlapping requests. The generation orders
        // callers; each request runs validation on main, then worker decode on
        // the serial queue, then commit on main. A request that lost the race
        // before its commit publishes nothing; its temporaries are removed and
        // its security-scoped access is balanced.
        let generation: Int = await MainActor.run { [weak self] in
            guard let self else { return 0 }
            self.importGeneration += 1
            return self.importGeneration
        }
        return await importPresetsAsyncWithGeneration(urls, collisionPolicy: collisionPolicy, generation: generation)
    }

    private func importPresetsAsyncWithGeneration(
        _ urls: [URL],
        collisionPolicy: HRIRImportCollisionPolicy,
        generation: Int
    ) async -> HRIRImportResult {
        var staged: [ValidatedHRIRImport] = []
        var failures: [HRIRImportFailure] = []
        await MainActor.run { [weak self] in
            guard let self else { return }
            for url in urls {
                do {
                    staged.append(try self.validateImportURL(url))
                } catch {
                    failures.append(.init(filename: url.lastPathComponent, reason: error.localizedDescription))
                }
            }
        }
        guard !staged.isEmpty else {
            await MainActor.run { [weak self] in self?.savePresets() }
            return HRIRImportResult(imported: [], skipped: [], failures: failures)
        }
        // Check generation and task cancellation before the worker commit:
        // after the worker decodes a file, a commit that replaces the
        // managed file or publishes a preset is irreversible.
        let stillCurrent = await MainActor.run { [weak self] in
            guard let self else { return false }
            return generation == self.importGeneration
        }
        guard stillCurrent, !Task.isCancelled else {
            return HRIRImportResult(imported: [], skipped: [], failures: [])
        }
        let importCancellation = ActivationCancellationToken()
        let result = await importPresetsStagedAsync(
            staged,
            collisionPolicy: collisionPolicy,
            priorFailures: failures,
            cancellation: importCancellation
        )
        // A stale or cancelled request publishes nothing: its managed
        // temporaries are removed and the working preset set is untouched.
        // No rollback reads or deletes managed files by preset ID.
        let isNewest = await MainActor.run { [weak self] () -> (Bool, Bool) in
            guard let self else { return (false, false) }
            let newest = generation == self.importGeneration
            return (newest, Task.isCancelled)
        }
        guard isNewest.0, !importCancellation.isCancelled, !isNewest.1 else {
            await MainActor.run { [weak self] in
                guard let self else { return }
                for file in result.committedFilesForDiscard {
                    try? self.fileManager.removeItem(at: file.temporary)
                }
                self.savePresets()
            }
            return HRIRImportResult(imported: [], skipped: [], failures: [])
        }
        return result.published
    }

#if DEBUG
    var presetsDirectoryForTesting: URL { presetsDirectory }

    func takeImportTicketForTesting() async -> Int {
        await MainActor.run { [weak self] in
            guard let self else { return 0 }
            self.importGeneration += 1
            return self.importGeneration
        }
    }

    func importPresetsStagedForTesting(
        _ urls: [URL],
        collisionPolicy: HRIRImportCollisionPolicy,
        ticketTaker: @escaping () async -> Int
    ) async -> HRIRImportResult {
        let generation = await ticketTaker()
        return await importPresetsAsyncWithGeneration(urls, collisionPolicy: collisionPolicy, generation: generation)
    }

    /// Same-file stale-replacement test path: holds one import inside worker
    /// validation while the caller supersedes its generation, then checks
    /// that the stale commit never runs. Production passes workerGate nil.
    func importPresetsStagedForTesting(
        _ urls: [URL],
        collisionPolicy: HRIRImportCollisionPolicy,
        generation: Int,
        workerGate: (@Sendable () -> Bool)?,
        onWorkerEntry: (@Sendable () -> Void)? = nil
    ) async -> HRIRImportResult {
        var staged: [ValidatedHRIRImport] = []
        var failures: [HRIRImportFailure] = []
        await MainActor.run { [weak self] in
            guard let self else { return }
            for url in urls {
                do {
                    staged.append(try self.validateImportURL(url, workerGate: workerGate))
                } catch {
                    failures.append(.init(filename: url.lastPathComponent, reason: error.localizedDescription))
                }
            }
            onWorkerEntry?()
        }
        guard !staged.isEmpty else {
            return HRIRImportResult(imported: [], skipped: [], failures: failures)
        }
        let stillCurrent = await MainActor.run { [weak self] in
            guard let self else { return false }
            return generation == self.importGeneration
        }
        guard stillCurrent, !Task.isCancelled else {
            return HRIRImportResult(imported: [], skipped: [], failures: [])
        }
        let importCancellation = ActivationCancellationToken()
        let result = await importPresetsStagedAsync(
            staged,
            collisionPolicy: collisionPolicy,
            priorFailures: failures,
            cancellation: importCancellation
        )
        let verdict = await MainActor.run { [weak self] () -> (Bool, Bool) in
            guard let self else { return (false, false) }
            return (generation == self.importGeneration, Task.isCancelled)
        }
        guard verdict.0, !importCancellation.isCancelled, !verdict.1 else {
            await MainActor.run { [weak self] in
                guard let self else { return }
                for file in result.committedFilesForDiscard {
                    try? self.fileManager.removeItem(at: file.temporary)
                }
                self.savePresets()
            }
            return HRIRImportResult(imported: [], skipped: [], failures: [])
        }
        return result.published
    }
#endif

    /// Remove a preset
    /// - Parameter preset: The preset to remove
    func removePreset(_ preset: HRIRPreset) {
        _ = deletePreset(preset)
    }

    @discardableResult
    func deletePreset(_ preset: HRIRPreset) -> Bool {
        guard let stored = presets.first(where: { $0.id == preset.id }),
              stored.fileURL.standardizedFileURL == preset.fileURL.standardizedFileURL else {
            return false
        }

        do {
            try fileManager.removeItem(at: stored.fileURL)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        presets.removeAll { $0.id == stored.id }
        if activePreset?.id == stored.id {
            deactivatePreset()
        }
        savePresets()
        return true
    }

    /// Select and load a preset for convolution with specified input layout
    /// - Parameters:
    ///   - preset: The preset to activate
    ///   - targetSampleRate: The sample rate to resample to
    ///   - inputLayout: The layout of input channels (detected from device)
    ///   - hrirMap: Optional custom HRIR channel mapping (defaults to interleaved pairs)
    func activatePreset(
        _ preset: HRIRPreset,
        targetSampleRate: Double,
        inputLayout: InputLayout,
        hrirMap: HRIRChannelMap? = nil,
        completion: ((HRIRActivationResult) -> Void)? = nil
    ) {
        let activationKey = hrirMap == nil
            ? PresetActivationKey(preset: preset, targetSampleRate: targetSampleRate, inputLayout: inputLayout)
            : nil

        if let activationKey,
           activationKey == currentActivationKey,
           rendererState != nil {
            if inFlightActivationKey != nil && inFlightActivationKey != activationKey {
                activationTask?.cancel()
                activationTask = nil
                activationCancellationToken?.cancel()
                activationCancellationToken = nil
                activationCompletion = nil
                inFlightActivationKey = nil
                activationGeneration += 1
            }
            completion?(.success)
            return
        }
        if let activationKey, activationKey == inFlightActivationKey {
            if let completion {
                let prior = activationCompletion
                activationCompletion = { result in
                    prior?(result)
                    completion(result)
                }
            }
            return
        }

        activationTask?.cancel()
        activationCancellationToken?.cancel()
        activationGeneration += 1
        let generation = activationGeneration
        inFlightActivationKey = activationKey
        let blockSize = Self.processingBlockSize
        let cancellationToken = ActivationCancellationToken()
        activationCancellationToken = cancellationToken
        activationCompletion = completion

        let log2n = vDSP_Length(log2(Double(blockSize * 2)))
        let sharedFFTSetup = FFTSetupManager.shared.getSetup(log2n: log2n)

        let task = DispatchWorkItem { [weak self] in
            do {
                let wavData = try WAVLoader.load(from: preset.fileURL)
                guard !cancellationToken.isCancelled else { return }

                let speakers = inputLayout.channels
                let channelMap: HRIRChannelMap
                
                if wavData.channelCount == 7 {
                    channelMap = HRIRChannelMap.hesuvi7Channel(speakers: Array(speakers))
                } else {
                    // Default to HeSuVi 14-channel mapping
                    channelMap = HRIRChannelMap.hesuvi14Channel(speakers: Array(speakers))
                }

                // Build renderers for each input channel
                var newRenderers: [VirtualSpeakerRenderer] = []
                newRenderers.reserveCapacity(speakers.count)
                
                for (_, speaker) in inputLayout.channels.enumerated() {
                    guard !cancellationToken.isCancelled else { return }

                    // Look up HRIR indices for this speaker
                    guard let (leftEarIdx, rightEarIdx) = channelMap.getIndices(for: speaker) else {
                        continue
                    }
                    
                    // Validate indices
                    guard leftEarIdx < wavData.channelCount && rightEarIdx < wavData.channelCount else {
                        throw HRIRError.invalidChannelMapping(
                            "HRIR indices (\(leftEarIdx), \(rightEarIdx)) out of range for \(wavData.channelCount) channels"
                        )
                    }
                    
                    // Get HRIR data
                    let leftEarIR = wavData.audioData[leftEarIdx]
                    let rightEarIR = wavData.audioData[rightEarIdx]
                    
                    // Resample if needed
                    let resampledLeft: [Float]
                    let resampledRight: [Float]
                    
                    if abs(wavData.sampleRate - targetSampleRate) > 0.01 {
                        resampledLeft = try Resampler.resampleHighQuality(
                            input: leftEarIR,
                            fromRate: wavData.sampleRate,
                            toRate: targetSampleRate
                        )
                        resampledRight = try Resampler.resampleHighQuality(
                            input: rightEarIR,
                            fromRate: wavData.sampleRate,
                            toRate: targetSampleRate
                        )
                    } else {
                        resampledLeft = leftEarIR
                        resampledRight = rightEarIR
                    }
                    
                    // Create convolution engines off the render thread. Both ears
                    // share one input FFT, one FDL, and one cached FFT setup.
                    guard let engine = StereoConvolutionEngine(
                        leftEarHRIR: resampledLeft,
                        rightEarHRIR: resampledRight,
                        blockSize: blockSize,
                        sharedFFTSetup: sharedFFTSetup
                    ) else {
                        throw HRIRError.convolutionSetupFailed("Failed to create engines for \(speaker.displayName)")
                    }

                    let renderer = VirtualSpeakerRenderer(speaker: speaker, convolver: engine)
                    
                    newRenderers.append(renderer)
                }
                
                guard !newRenderers.isEmpty else {
                    throw HRIRError.convolutionSetupFailed("No valid renderers created")
                }

                guard !cancellationToken.isCancelled else { return }
                DispatchQueue.main.async {
                    self?.publishActivation(
                        generation: generation,
                        key: activationKey,
                        preset: preset,
                        inputLayout: inputLayout,
                        channelMap: channelMap,
                        renderers: newRenderers,
                        completion: self?.activationCompletion
                    )
                }
            } catch {
                guard !cancellationToken.isCancelled else { return }
                DispatchQueue.main.async {
                    self?.publishActivationFailure(
                        generation: generation,
                        message: "Failed to activate preset: \(error.localizedDescription)",
                        completion: self?.activationCompletion
                    )
                }
            }
        }
        activationTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }

    /// Reuse matching renderer state; rebuild only when device configuration changed.
    func ensurePresetConfiguration(targetSampleRate: Double, inputLayout: InputLayout) {
        guard let preset = activePreset else { return }
        let key = PresetActivationKey(preset: preset, targetSampleRate: targetSampleRate, inputLayout: inputLayout)
        if key != currentActivationKey {
            // Device configuration changed; the old convolvers no longer match.
            crossfader.requestReset()
            crossfader.drainRetiredStates()
            rendererState = nil
            currentActivationKey = nil
        }
        activatePreset(preset, targetSampleRate: targetSampleRate, inputLayout: inputLayout)
    }

    /// Cancel activation and atomically publish passthrough state.
    /// - Parameter immediate: drop render-thread state instead of fading out.
    ///   Pipeline teardown uses this so a rebuilt pipeline never resumes a stale
    ///   preset; user-facing preset removal fades.
    func deactivatePreset(immediate: Bool = false) {
        if immediate { crossfader.requestReset() }
        crossfader.drainRetiredStates()
        activationTask?.cancel()
        activationTask = nil
        activationCancellationToken?.cancel()
        activationCancellationToken = nil
        activationCompletion = nil
        activationGeneration += 1
        inFlightActivationKey = nil
        currentActivationKey = nil
        // Dropping immutable state also drops its pending FIFO; render thread observes this via try-lock.
        rendererState = nil
        activePreset = nil
        currentInputLayout = nil
        currentHRIRMap = nil
        errorMessage = nil
    }

    private func publishActivation(
        generation: Int,
        key: PresetActivationKey?,
        preset: HRIRPreset,
        inputLayout: InputLayout,
        channelMap: HRIRChannelMap,
        renderers: [VirtualSpeakerRenderer],
        completion: ((HRIRActivationResult) -> Void)?
    ) {
        guard generation == activationGeneration else { return }
        crossfader.drainRetiredStates()
        rendererState = RendererState(
            renderers: renderers,
            inputChannelCount: inputLayout.channels.count,
            fallbackSpeakers: inputLayout.channels,
            blockSize: Self.processingBlockSize
        )
        currentActivationKey = key
        inFlightActivationKey = nil
        activationTask = nil
        activationCancellationToken = nil
        activePreset = preset
        currentInputLayout = inputLayout
        currentHRIRMap = channelMap
        errorMessage = nil
        activationCompletion = nil
        completion?(.success)
    }

    private func publishActivationFailure(
        generation: Int,
        message: String,
        completion: ((HRIRActivationResult) -> Void)?
    ) {
        guard generation == activationGeneration else { return }
        inFlightActivationKey = nil
        activationTask = nil
        activationCancellationToken = nil
        errorMessage = message
        activationCompletion = nil
        completion?(.failure(message))
    }

    /// Control-only read of the published renderer state. Render-thread
    /// crossfader state is not part of readiness.
    nonisolated func hasPublishedRendererForControl() -> Bool {
        stateLock.withLock { $0?.renderers.isEmpty == false }
    }

    nonisolated func processAudio(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Bool {
        // A writer can never stall the render thread. A failed attempt keeps prior immutable state.
        if let publishedState = stateLock.withLockIfAvailable({ $0 }) {
            crossfader.observe(publishedState)
        }

        return crossfader.processIfNeeded(
            inputChannels: inputChannels,
            inputChannelCount: inputChannelCount,
            leftOutput: leftOutput,
            rightOutput: rightOutput,
            frameCount: frameCount
        )
    }

    /// Releases renderer states handed back by the render thread.
    func drainRetiredStates() {
        crossfader.drainRetiredStates()
    }

    nonisolated func cleanupAfterIOStopped() {
        crossfader.cleanupAfterIOStopped()
    }


    /// Reset the internal state of all convolution engines
    /// Useful when changing presets or seeking to clear old audio buffers
    func resetConvolutionState() {
        guard let state = rendererState else { return }
        state.processor.reset()
    }

    // MARK: - Private Methods

    private func startDirectoryWatcher() {
        let pathsToWatch = [presetsDirectory.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let callback: FSEventStreamCallback = { (
            streamRef,
            clientCallBackInfo,
            numEvents,
            eventPaths,
            eventFlags,
            eventIds
        ) in
            guard let info = clientCallBackInfo else { return }
            let manager = Unmanaged<HRIRManager>.fromOpaque(info).takeUnretainedValue()
            
            // Cancel any pending reload
            manager.directoryDebounceTask?.cancel()
            
            // Schedule new reload with debouncing (reduced to 0.2s for faster updates)
            let task = DispatchWorkItem { [weak manager] in
                manager?.loadAndSyncPresets()
            }
            manager.directoryDebounceTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
        }
        
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // Latency in seconds
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
        
        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(stream)
            self.eventStream = stream
        }
    }
    
    private func stopDirectoryWatcher() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }

    func waitForLibrarySync() async {
        // Drain pending import work, then publish the directory scan on main.
        await withCheckedContinuation { continuation in
            importWorkQueue.async {
                continuation.resume()
            }
        }
        loadAndSyncPresets()
    }

    private func loadAndSyncPresets() {
        dispatchPrecondition(condition: .onQueue(.main))
        // 1. Load known presets from JSON
        var knownPresets: [HRIRPreset] = []
        let metadataURL = presetsDirectory.appendingPathComponent("presets.json")

        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder().decode([HRIRPreset].self, from: data) {
            knownPresets = decoded
        }

        // 2. Scan directory for WAV files
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: presetsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            self.initialLibrarySyncReady = true
            return
        }

        let wavFiles = fileURLs.filter { $0.pathExtension.lowercased() == "wav" }

        var updatedPresets: [HRIRPreset] = []
        var hasChanges = false

        // 3. Reconcile. The scan uses the bounded header read only; a corrupt
        // file that passes the header still fails at activation/import time.
        let existingFilenames = Set(wavFiles.map { $0.lastPathComponent })

        for fileURL in wavFiles {
            // Check if we already have this file
            if let existing = knownPresets.first(where: { $0.fileURL.lastPathComponent == fileURL.lastPathComponent }) {
                // Update path in case it moved (though unlikely if filename matches)
                // But mostly just keep it
                let updated = HRIRPreset(
                    id: existing.id,
                    name: existing.name,
                    fileURL: fileURL,
                    channelCount: existing.channelCount,
                    sampleRate: existing.sampleRate
                )
                updatedPresets.append(updated)
            } else {
                // New file found!
                if let newPreset = try? createPresetHeaderOnly(from: fileURL) {
                    updatedPresets.append(newPreset)
                    hasChanges = true
                }
            }
        }

        // Check if any were removed (orphaned)
        // We use the filename set to explicitly identify presets whose files are gone
        let orphanedPresets = knownPresets.filter { preset in
            !existingFilenames.contains(preset.fileURL.lastPathComponent)
        }

        if !orphanedPresets.isEmpty {
            Logger.log("[HRIRManager] Removing \(orphanedPresets.count) orphaned presets")
            hasChanges = true
        }

        // 4. Update State. The caller holds the main actor.
        if hasChanges || self.presets != updatedPresets {
            self.presets = updatedPresets
            self.savePresets()
        }

        // Check if active preset is still valid
        if let active = self.activePreset, !updatedPresets.contains(where: { $0.id == active.id }) {
            self.deactivatePreset()
        }
        self.initialLibrarySyncReady = true
    }

    private func createPresetHeaderOnly(from fileURL: URL) throws -> HRIRPreset {
        let header = try WAVLoader.headerInfo(from: fileURL)

        return HRIRPreset(
            id: UUID(),
            name: fileURL.deletingPathExtension().lastPathComponent,
            fileURL: fileURL,
            channelCount: header.channelCount,
            sampleRate: header.sampleRate
        )
    }

    private func createPreset(from fileURL: URL) throws -> HRIRPreset {
        let wavData = try WAVLoader.load(from: fileURL)

        return HRIRPreset(
            id: UUID(),
            name: fileURL.deletingPathExtension().lastPathComponent,
            fileURL: fileURL,
            channelCount: wavData.channelCount,
            sampleRate: wavData.sampleRate
        )
    }

    private func savePresets() {
        let metadataURL = presetsDirectory.appendingPathComponent("presets.json")

        guard let data = try? JSONEncoder().encode(presets) else {
            Logger.log("Failed to encode presets")
            return
        }

        try? data.write(to: metadataURL)
    }
}

// MARK: - Error Types

enum HRIRError: LocalizedError {
    case invalidChannelCount(Int)
    case emptyFile
    case convolutionSetupFailed(String)
    case invalidChannelMapping(String)
    case batchImportFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidChannelCount(let count):
            return "Invalid HRIR channel count: \(count). Must have at least 2 channels."
        case .emptyFile:
            return "HRIR file is empty"
        case .convolutionSetupFailed(let detail):
            return "Failed to set up convolution: \(detail)"
        case .invalidChannelMapping(let detail):
            return "Invalid channel mapping: \(detail)"
        case .batchImportFailed(let detail):
            return "Batch import failed: \(detail)"
        }
    }
}
