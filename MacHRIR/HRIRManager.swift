//
//  HRIRManager.swift
//  MacHRIR
//
//  Manages HRIR presets and multi-channel convolution processing
//

import Foundation
import Combine
import Accelerate

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

/// Renders a single virtual speaker to binaural output
struct VirtualSpeakerRenderer {
    let speaker: VirtualSpeaker
    let convolverLeftEar: ConvolutionEngine
    let convolverRightEar: ConvolutionEngine
}

/// Manages HRIR presets and multi-channel convolution processing
import AppKit

/// Manages HRIR presets and multi-channel convolution processing
class HRIRManager: ObservableObject {

    // MARK: - Published Properties

    @Published var presets: [HRIRPreset] = []
    @Published var activePreset: HRIRPreset?
    @Published var convolutionEnabled: Bool = false
    @Published var errorMessage: String?
    @Published var currentInputLayout: InputLayout = .stereo
    @Published var currentHRIRMap: HRIRChannelMap?
    
    // MARK: - Private Properties
    
    // Multi-channel rendering: one renderer per input channel
    private var renderers: [VirtualSpeakerRenderer] = []
    
    private let processingBlockSize: Int = 512

    private let presetsDirectory: URL
    private var directorySource: DispatchSourceFileSystemObject?

    // MARK: - Initialization

    init() {
        // Set up presets directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        presetsDirectory = appSupport.appendingPathComponent("MacHRIR/presets", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)

        // Load existing presets and sync with directory
        loadAndSyncPresets()
        
        // Start watching for changes
        startDirectoryWatcher()
    }
    
    deinit {
        directorySource?.cancel()
    }

    // MARK: - Public Methods

    /// Opens the presets directory in Finder
    func openPresetsDirectory() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: presetsDirectory.path)
    }

    /// Remove a preset
    /// - Parameter preset: The preset to remove
    func removePreset(_ preset: HRIRPreset) {
        // Remove file
        try? FileManager.default.removeItem(at: preset.fileURL)
        // The directory watcher will handle the update, but we can update immediately for responsiveness
        // However, to avoid race conditions with the watcher, it's often safer to let the watcher handle it,
        // or update local state and let the watcher confirm.
        // For simplicity and responsiveness, we'll update local state and let sync handle any discrepancies.
        
        presets.removeAll { $0.id == preset.id }

        // Clear active preset if it was removed
        if activePreset?.id == preset.id {
            activePreset = nil
            renderers.removeAll()
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
        hrirMap: HRIRChannelMap? = nil
    ) {
        do {
            // Load WAV file
            let wavData = try WAVLoader.load(from: preset.fileURL)

            // Determine HRIR mapping
            // Always use HeSuVi 14-channel mapping as requested
            let speakers = inputLayout.channels
            let channelMap = HRIRChannelMap.hesuvi14Channel(speakers: Array(speakers))

            // Build renderers for each input channel
            var newRenderers: [VirtualSpeakerRenderer] = []
            
            for (_, speaker) in inputLayout.channels.enumerated() {
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
                
                // Create convolution engines
                guard let leftEngine = ConvolutionEngine(hrirSamples: resampledLeft, blockSize: processingBlockSize),
                      let rightEngine = ConvolutionEngine(hrirSamples: resampledRight, blockSize: processingBlockSize) else {
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

            // Activate
            renderers = newRenderers
            
            DispatchQueue.main.async {
                self.activePreset = preset
                self.currentInputLayout = inputLayout
                self.currentHRIRMap = channelMap
                self.errorMessage = nil
            }

        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to activate preset: \(error.localizedDescription)"
            }
        }
    }

    /// Process multi-channel audio through convolution
    /// - Parameters:
    ///   - inputs: Array of input channel buffers
    ///   - leftOutput: Left ear output buffer
    ///   - rightOutput: Right ear output buffer
    ///   - frameCount: Number of frames to process
    func processAudio(
        inputs: [[Float]],
        leftOutput: inout [Float],
        rightOutput: inout [Float],
        frameCount: Int
    ) {
        guard convolutionEnabled, !renderers.isEmpty else {
            // Passthrough mode - mix all inputs to stereo
            for i in 0..<frameCount {
                leftOutput[i] = 0
                rightOutput[i] = 0
            }
            
            // Simple downmix: take first two channels if available
            if inputs.count >= 1 {
                for i in 0..<frameCount {
                    leftOutput[i] = inputs[0][i]
                }
            }
            if inputs.count >= 2 {
                for i in 0..<frameCount {
                    rightOutput[i] = inputs[1][i]
                }
            }
            return
        }

        // Process in chunks of processingBlockSize
        var offset = 0
        
        while offset + processingBlockSize <= frameCount {
            // Clear output accumulators for this block
            leftOutput.withUnsafeMutableBufferPointer { leftPtr in
                rightOutput.withUnsafeMutableBufferPointer { rightPtr in
                    guard let leftBase = leftPtr.baseAddress,
                          let rightBase = rightPtr.baseAddress else { return }
                    
                    let currentLeftOut = leftBase.advanced(by: offset)
                    let currentRightOut = rightBase.advanced(by: offset)
                    
                    // Zero the output for this block
                    memset(currentLeftOut, 0, processingBlockSize * MemoryLayout<Float>.size)
                    memset(currentRightOut, 0, processingBlockSize * MemoryLayout<Float>.size)
                    
                    // Accumulate contributions from each virtual speaker
                    for (channelIndex, renderer) in renderers.enumerated() {
                        guard channelIndex < inputs.count else { continue }
                        
                        inputs[channelIndex].withUnsafeBufferPointer { inputPtr in
                            guard let inputBase = inputPtr.baseAddress else { return }
                            let currentInput = inputBase.advanced(by: offset)
                            
                            // Convolve and accumulate to left ear
                            renderer.convolverLeftEar.processAndAccumulate(
                                input: currentInput,
                                outputAccumulator: currentLeftOut
                            )
                            
                            // Convolve and accumulate to right ear
                            renderer.convolverRightEar.processAndAccumulate(
                                input: currentInput,
                                outputAccumulator: currentRightOut
                            )
                        }
                    }
                }
            }
            
            offset += processingBlockSize
        }
    }


    // MARK: - Private Methods

    private func startDirectoryWatcher() {
        let fileDescriptor = open(presetsDirectory.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )
        
        source.setEventHandler { [weak self] in
            // Debounce slightly or just reload
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.loadAndSyncPresets()
            }
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        directorySource = source
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
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: presetsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        
        let wavFiles = fileURLs.filter { $0.pathExtension.lowercased() == "wav" }
        
        var updatedPresets: [HRIRPreset] = []
        var hasChanges = false
        
        // 3. Reconcile
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
        
        // Check if any were removed
        if updatedPresets.count != knownPresets.count {
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
                self.activePreset = nil
                self.renderers.removeAll()
            }
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
            print("Failed to encode presets")
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
