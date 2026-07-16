//
//  HRIRManager.swift
//  Airwave
//
//  Manages HRIR presets and multi-channel convolution processing
//

import Foundation
import Combine

/// Represents an HRIR preset
struct HRIRPreset: Identifiable, Codable, Equatable, Hashable {
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
    let convolverLeftEar: ConvolutionEngine
    let convolverRightEar: ConvolutionEngine
}

/// Manages HRIR presets and multi-channel convolution processing
import AppKit

import os

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
        
        init(renderers: [VirtualSpeakerRenderer], blockSize: Int) {
            self.renderers = renderers
            self.processor = RealtimeAudioProcessor(renderers: renderers, blockSize: blockSize)
        }
    }
    
    // Writers publish immutable state under one lock. Render thread makes one non-blocking snapshot attempt.
    nonisolated private let stateLock = OSAllocatedUnfairLock<RendererState?>(initialState: nil)
    nonisolated(unsafe) private var audioThreadState: RendererState?

    private var activationTask: DispatchWorkItem?
    private var activationGeneration = 0
    private var currentActivationKey: PresetActivationKey?
    private var inFlightActivationKey: PresetActivationKey?
    private var activationCancellationToken: ActivationCancellationToken?
    private var activationCompletion: ((HRIRActivationResult) -> Void)?
    
    private var rendererState: RendererState? {
        get { stateLock.withLock { $0 } }
        set { stateLock.withLock { $0 = newValue } }
    }
    
    private let processingBlockSize: Int = 512  // Balance between latency (~10.7ms @ 48kHz) and CPU efficiency

    private let presetsDirectory: URL
    private let fileManager: FileManager
    private var eventStream: FSEventStreamRef?
    private var directoryDebounceTask: DispatchWorkItem?

    // MARK: - Initialization

    init(presetsDirectory: URL? = nil, fileManager: FileManager = .default, startWatcher: Bool = true) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.presetsDirectory = presetsDirectory ?? appSupport.appendingPathComponent("Airwave/presets", isDirectory: true)

        // Create directory if it doesn't exist
        try? fileManager.createDirectory(at: self.presetsDirectory, withIntermediateDirectories: true)

        // Load existing presets and sync with directory
        loadAndSyncPresets()
        
        // Start watching for changes
        if startWatcher { startDirectoryWatcher() }
    }
    
    deinit {
        stopDirectoryWatcher()
    }

    // MARK: - Public Methods

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
                let wav = try WAVLoader.load(from: url)
                guard wav.channelCount >= 2 else { throw HRIRError.invalidChannelCount(wav.channelCount) }
                let destination = presetsDirectory.appendingPathComponent(url.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) { conflicts.append(url) }
                else { acceptable.append(url) }
            } catch {
                rejected.append(.init(filename: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return .init(acceptable: acceptable, conflicts: conflicts, rejected: rejected)
    }

    @discardableResult
    func importPresets(_ urls: [URL], collisionPolicy: HRIRImportCollisionPolicy) -> HRIRImportResult {
        var imported: [HRIRPreset] = []
        var skipped: [String] = []
        var failures: [HRIRImportFailure] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                guard url.pathExtension.lowercased() == "wav" else { throw HRIRError.batchImportFailed("Only WAV files can be imported.") }
                let wav = try WAVLoader.load(from: url)
                guard wav.channelCount >= 2 else { throw HRIRError.invalidChannelCount(wav.channelCount) }
                let destination = presetsDirectory.appendingPathComponent(url.lastPathComponent).standardizedFileURL
                guard destination.deletingLastPathComponent() == presetsDirectory.standardizedFileURL else {
                    throw HRIRError.batchImportFailed("Invalid filename.")
                }
                let existing = presets.first { $0.fileURL.lastPathComponent == destination.lastPathComponent }
                if fileManager.fileExists(atPath: destination.path), collisionPolicy == .reject {
                    skipped.append(url.lastPathComponent); continue
                }
                let temporary = presetsDirectory.appendingPathComponent(".\(UUID().uuidString).wav")
                try fileManager.copyItem(at: url, to: temporary)
                do {
                    if fileManager.fileExists(atPath: destination.path) {
                        _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
                    } else {
                        try fileManager.moveItem(at: temporary, to: destination)
                    }
                } catch {
                    try? fileManager.removeItem(at: temporary)
                    throw error
                }
                let preset = HRIRPreset(
                    id: existing?.id ?? UUID(), name: destination.deletingPathExtension().lastPathComponent,
                    fileURL: destination, channelCount: wav.channelCount, sampleRate: wav.sampleRate
                )
                if let index = presets.firstIndex(where: { $0.id == preset.id }) { presets[index] = preset }
                else { presets.append(preset) }
                if activePreset?.id == preset.id { activePreset = preset }
                imported.append(preset)
            } catch {
                failures.append(.init(filename: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        savePresets()
        return .init(imported: imported, skipped: skipped, failures: failures)
    }

    /// Remove a preset
    /// - Parameter preset: The preset to remove
    func removePreset(_ preset: HRIRPreset) {
        // Remove file
        try? fileManager.removeItem(at: preset.fileURL)
        // The directory watcher will handle the update, but we can update immediately for responsiveness
        // However, to avoid race conditions with the watcher, it's often safer to let the watcher handle it,
        // or update local state and let the watcher confirm.
        // For simplicity and responsiveness, we'll update local state and let sync handle any discrepancies.
        
        presets.removeAll { $0.id == preset.id }

        // Clear active preset if it was removed
        if activePreset?.id == preset.id {
            deactivatePreset()
        }

        savePresets()
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
            completion?(.success)
            return
        }
        if let activationKey, activationKey == inFlightActivationKey {
            return
        }

        activationTask?.cancel()
        activationCancellationToken?.cancel()
        activationGeneration += 1
        let generation = activationGeneration
        inFlightActivationKey = activationKey
        let blockSize = processingBlockSize
        let cancellationToken = ActivationCancellationToken()
        activationCancellationToken = cancellationToken
        activationCompletion = completion

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
                        resampledLeft = Resampler.resampleHighQuality(
                            input: leftEarIR,
                            fromRate: wavData.sampleRate,
                            toRate: targetSampleRate
                        )
                        resampledRight = Resampler.resampleHighQuality(
                            input: rightEarIR,
                            fromRate: wavData.sampleRate,
                            toRate: targetSampleRate
                        )
                    } else {
                        resampledLeft = leftEarIR
                        resampledRight = rightEarIR
                    }
                    
                    // Create convolution engines off the render thread.
                    guard let leftEngine = ConvolutionEngine(hrirSamples: resampledLeft, blockSize: blockSize),
                          let rightEngine = ConvolutionEngine(hrirSamples: resampledRight, blockSize: blockSize) else {
                        throw HRIRError.convolutionSetupFailed("Failed to create engines for \(speaker.displayName)")
                    }
                    
                    let renderer = VirtualSpeakerRenderer(
                        speaker: speaker,
                        convolverLeftEar: leftEngine,
                        convolverRightEar: rightEngine
                    )
                    
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
                        completion: completion
                    )
                }
            } catch {
                guard !cancellationToken.isCancelled else { return }
                DispatchQueue.main.async {
                    self?.publishActivationFailure(
                        generation: generation,
                        message: "Failed to activate preset: \(error.localizedDescription)",
                        completion: completion
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
            rendererState = nil
            currentActivationKey = nil
        }
        activatePreset(preset, targetSampleRate: targetSampleRate, inputLayout: inputLayout)
    }

    /// Cancel activation and atomically publish passthrough state.
    func deactivatePreset() {
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
        rendererState = RendererState(renderers: renderers, blockSize: processingBlockSize)
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

    /// Process selected stereo input through convolution without render-thread allocation.
    nonisolated func hasPublishedRendererForAudioCallback() -> Bool {
        var state = audioThreadState
        enum StateRead {
            case available(RendererState?)
        }
        if let read = stateLock.withLockIfAvailable({ StateRead.available($0) }),
           case .available(let publishedState) = read {
            state = publishedState
            audioThreadState = publishedState
        }
        return state?.renderers.isEmpty == false
    }

    nonisolated func processAudio(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        // A writer can never stall the render thread. A failed attempt keeps prior immutable state.
        var state = audioThreadState
        enum StateRead {
            case available(RendererState?)
        }
        if let read = stateLock.withLockIfAvailable({ StateRead.available($0) }) {
            if case .available(let publishedState) = read {
                state = publishedState
                audioThreadState = publishedState
            }
        }

        guard let state, !state.renderers.isEmpty else {
            // Passthrough mode - simple copy
            memcpy(leftOutput, inputLeft, frameCount * MemoryLayout<Float>.size)
            if let inputRight {
                memcpy(rightOutput, inputRight, frameCount * MemoryLayout<Float>.size)
            } else {
                memcpy(rightOutput, inputLeft, frameCount * MemoryLayout<Float>.size)
            }
            return
        }

        state.processor.process(
            inputLeft: inputLeft,
            inputRight: inputRight,
            leftOutput: leftOutput,
            rightOutput: rightOutput,
            frameCount: frameCount
        )
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

    private func loadAndSyncPresets() {
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
            DispatchQueue.main.async { self.initialLibrarySyncReady = true }
            return
        }
        
        let wavFiles = fileURLs.filter { $0.pathExtension.lowercased() == "wav" }
        
        var updatedPresets: [HRIRPreset] = []
        var hasChanges = false
        
        // 3. Reconcile
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
                if let newPreset = try? createPreset(from: fileURL) {
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
        
        // 4. Update State
        DispatchQueue.main.async {
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
