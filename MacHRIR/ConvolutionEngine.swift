//
//  ConvolutionEngine.swift
//  MacHRIR
//
//  Fast convolution using Accelerate framework's FFT (Overlap-Save method)
//

import Foundation
import Accelerate

/// Real-time convolution engine using Accelerate's FFT (Overlap-Save)
class ConvolutionEngine {

    // MARK: - Properties

    private let log2n: vDSP_Length
    private let fftSize: Int
    private let fftSizeHalf: Int
    private let blockSize: Int
    
    private let fftSetup: FFTSetup
    
    // Buffers (Manual Memory Management)
    private let inputBuffer: UnsafeMutablePointer<Float>
    private let outputBuffer: UnsafeMutablePointer<Float>
    
    // Split Complex Buffers
    private let splitComplexReal: UnsafeMutablePointer<Float>
    private let splitComplexImag: UnsafeMutablePointer<Float>
    private var splitComplex: DSPSplitComplex
    
    // HRIR Frequency Domain Representation
    private let hrirReal: UnsafeMutablePointer<Float>
    private let hrirImag: UnsafeMutablePointer<Float>
    private var hrirSplitComplex: DSPSplitComplex
    
    private var debugCounter: Int = 0

    // MARK: - Initialization

    /// Initialize convolution engine
    /// - Parameters:
    ///   - hrirSamples: Impulse response samples
    ///   - blockSize: Processing block size (typically 512)
    init?(hrirSamples: [Float], blockSize: Int = 512) {
        self.blockSize = blockSize
        
        // 1. Determine FFT size
        let minSize = blockSize + hrirSamples.count - 1
        let log2n = vDSP_Length(ceil(log2(Double(minSize))))
        self.log2n = log2n
        self.fftSize = 1 << Int(log2n)
        self.fftSizeHalf = fftSize / 2
        
        print("[Convolution] Init: BlockSize=\(blockSize), HRIR=\(hrirSamples.count), FFTSize=\(fftSize)")
        
        // 2. Create FFT Setup
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            print("[Convolution] Failed to create FFT setup")
            return nil
        }
        self.fftSetup = setup
        
        // 3. Allocate Buffers
        self.inputBuffer = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        self.inputBuffer.initialize(repeating: 0, count: fftSize)
        
        self.outputBuffer = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        self.outputBuffer.initialize(repeating: 0, count: fftSize)
        
        self.splitComplexReal = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        self.splitComplexImag = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        self.splitComplex = DSPSplitComplex(realp: splitComplexReal, imagp: splitComplexImag)
        
        self.hrirReal = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        self.hrirImag = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        self.hrirSplitComplex = DSPSplitComplex(realp: hrirReal, imagp: hrirImag)
        
        // 4. Prepare HRIR (Filter Kernel)
        var tempHrir = [Float](repeating: 0, count: fftSize)
        for i in 0..<min(hrirSamples.count, fftSize) {
            tempHrir[i] = hrirSamples[i]
        }
        
        // Pack real data into split complex format
        tempHrir.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complexPtr in
                vDSP_ctoz(complexPtr, 2, &hrirSplitComplex, 1, vDSP_Length(fftSizeHalf))
            }
        }
        
        // Compute FFT of HRIR
        vDSP_fft_zrip(fftSetup, &hrirSplitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }
    
    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        
        inputBuffer.deallocate()
        outputBuffer.deallocate()
        splitComplexReal.deallocate()
        splitComplexImag.deallocate()
        hrirReal.deallocate()
        hrirImag.deallocate()
    }

    // MARK: - Public Methods

    /// Process a block of audio samples using Overlap-Save FFT convolution
    /// - Parameters:
    ///   - input: Input samples buffer (must be size `blockSize`)
    ///   - output: Output buffer (must be size `blockSize`)
    ///   - frameCount: Number of frames to process (must match `blockSize`)
    func process(input: [Float], output: inout [Float], frameCount: Int? = nil) {
        let count = frameCount ?? blockSize
        
        guard count == blockSize else {
            return
        }
        
        // 1. Prepare Input Buffer (Overlap-Save)
        let overlapSize = fftSize - blockSize
        
        // Shift buffer left by blockSize using memmove (fastest)
        // inputBuffer[0...overlapSize] = inputBuffer[blockSize...fftSize]
        memmove(inputBuffer, inputBuffer.advanced(by: blockSize), overlapSize * MemoryLayout<Float>.size)
        
        // Copy new input to tail
        // We need to copy from the Swift Array 'input' to the UnsafeMutablePointer 'inputBuffer'
        // Using withUnsafeBufferPointer is the safe way to get the array's pointer
        input.withUnsafeBufferPointer { inputPtr in
            guard let baseAddr = inputPtr.baseAddress else { return }
            // Copy min(count, input.count)
            let copyCount = min(count, input.count)
            memcpy(inputBuffer.advanced(by: overlapSize), baseAddr, copyCount * MemoryLayout<Float>.size)
            
            // Zero pad if needed (though we expect full blocks)
            if copyCount < blockSize {
                memset(inputBuffer.advanced(by: overlapSize + copyCount), 0, (blockSize - copyCount) * MemoryLayout<Float>.size)
            }
        }
        
        // 2. Forward FFT
        // Cast inputBuffer (Float*) to DSPComplex* for vDSP_ctoz
        inputBuffer.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complexPtr in
            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSizeHalf))
        }
        
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
        
        // 3. Complex Multiplication
        vDSP_zvmul(&splitComplex, 1, &hrirSplitComplex, 1, &splitComplex, 1, vDSP_Length(fftSizeHalf), 1)
        
        // 4. Inverse FFT
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        
        // 5. Unpack and Scale
        let scaleFactor = 0.5 / Float(fftSize)
        vDSP_vsmul(splitComplex.realp, 1, [scaleFactor], splitComplex.realp, 1, vDSP_Length(fftSizeHalf))
        vDSP_vsmul(splitComplex.imagp, 1, [scaleFactor], splitComplex.imagp, 1, vDSP_Length(fftSizeHalf))
        
        outputBuffer.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complexPtr in
            vDSP_ztoc(&splitComplex, 1, complexPtr, 2, vDSP_Length(fftSizeHalf))
        }
        
        // 6. Overlap-Save Output Extraction
        // Copy valid part to output array
        let validStartIndex = fftSize - blockSize
        
        // We need to copy FROM outputBuffer TO output (Swift Array)
        // output is inout [Float]
        // We can use output.withUnsafeMutableBufferPointer
        
        output.withUnsafeMutableBufferPointer { outPtr in
            guard let baseAddr = outPtr.baseAddress else { return }
            memcpy(baseAddr, outputBuffer.advanced(by: validStartIndex), blockSize * MemoryLayout<Float>.size)
        }
        
        if debugCounter < 2 {
            print("[Convolution] Processed block")
            debugCounter += 1
        }
    }
    
    /// Reset the engine state
    func reset() {
        memset(inputBuffer, 0, fftSize * MemoryLayout<Float>.size)
        memset(outputBuffer, 0, fftSize * MemoryLayout<Float>.size)
    }
}

