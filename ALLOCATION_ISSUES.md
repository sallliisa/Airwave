# Allocation Issues Analysis - AudioGraphManager.swift

## Primary Issue: UnsafeMutableAudioBufferListPointer Usage in Callbacks

**Location**: Lines 499 and 550

**Problem**: You're using `UnsafeMutableAudioBufferListPointer`, which is a Swift standard library wrapper that provides convenient Collection semantics. However, this wrapper **allocates memory** when constructed in the audio callbacks.

### Input Callback (Line 499)
```swift
let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

for i in 0..<channelCount {
    buffers[i].mNumberChannels = 1
    buffers[i].mDataByteSize = UInt32(bytesPerChannel)
    buffers[i].mData = inputBuffers[i]
}
```

### Output Callback (Line 550)
```swift
let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
let outputChannelCount = Int(bufferList.pointee.mNumberBuffers)

// Later used in loops:
for i in 0..<buffers.count { ... }
for i in 0..<min(outputChannelCount, 2) { ... }
```

## Why This Allocates

`UnsafeMutableAudioBufferListPointer` is a Swift struct that:
1. Wraps the raw pointer in a Swift collection type
2. Provides bounds checking
3. Implements Collection protocol methods
4. Creates Swift runtime metadata for iteration

Each time you create this wrapper in a callback (running thousands of times per second), Swift allocates temporary storage for the collection semantics.

## Solution: Use Raw Pointer Arithmetic

Replace the Swift wrapper with direct C-style pointer access:

### For Input Callback (Lines 499-508)
```swift
// REMOVE:
// let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

// REPLACE WITH:
let bufferPtr = UnsafeMutableRawPointer(&audioBufferList.pointee.mBuffers)
    .assumingMemoryBound(to: AudioBuffer.self)

if let inputBuffers = manager.inputAudioBuffersPtr {
    for i in 0..<channelCount {
        let buffer = bufferPtr.advanced(by: i)
        buffer.pointee.mNumberChannels = 1
        buffer.pointee.mDataByteSize = UInt32(bytesPerChannel)
        buffer.pointee.mData = inputBuffers[i]
    }
}
```

### For Output Callback (Lines 550, 557, 576, 589, 650)
```swift
// REMOVE:
// let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
// let outputChannelCount = Int(bufferList.pointee.mNumberBuffers)

// REPLACE WITH:
let outputChannelCount = Int(bufferList.pointee.mNumberBuffers)
let bufferPtr = UnsafeMutableRawPointer(&bufferList.pointee.mBuffers)
    .assumingMemoryBound(to: AudioBuffer.self)

// Then replace all buffers[i] with:
// let buffer = bufferPtr.advanced(by: i)
// buffer.pointee.mData, buffer.pointee.mDataByteSize, etc.
```

## Specific Replacements Needed

### Line 557-562 (silence fill in output callback)
```swift
for i in 0..<outputChannelCount {
    let buffer = bufferPtr.advanced(by: i)
    if let data = buffer.pointee.mData {
        memset(data, 0, Int(buffer.pointee.mDataByteSize))
    }
}
```

### Line 576-580 (buffering silence)
```swift
for i in 0..<outputChannelCount {
    let buffer = bufferPtr.advanced(by: i)
    if let data = buffer.pointee.mData {
        memset(data, 0, Int(buffer.pointee.mDataByteSize))
    }
}
```

### Line 589-594 (underrun silence)
```swift
for i in 0..<outputChannelCount {
    let buffer = bufferPtr.advanced(by: i)
    if let data = buffer.pointee.mData {
        memset(data, 0, Int(buffer.pointee.mDataByteSize))
    }
}
```

### Line 650-658 (writing output)
```swift
for i in 0..<min(outputChannelCount, 2) {
    let buffer = bufferPtr.advanced(by: i)
    if let data = buffer.pointee.mData {
        let samples = data.assumingMemoryBound(to: Float.self)
        let sourcePtr = (i == 0) ? manager.outputStereoLeftPtr : manager.outputStereoRightPtr

        let byteCount = frameCount * MemoryLayout<Float>.size
        memcpy(samples, sourcePtr, byteCount)
    }
}
```

## Expected Result

Eliminating `UnsafeMutableAudioBufferListPointer` from both callbacks should eliminate the 12k mallocs/sec you're seeing. This is because:
- The wrapper is created once per callback invocation
- At 48kHz with 512 sample blocks = ~94 calls/sec per callback
- Input callback: ~94 allocs/sec
- Output callback: ~94 allocs/sec
- Total base: ~188 allocs/sec

But wait - you're seeing 12k/sec, which suggests the callbacks are being called much more frequently OR there are other allocations happening elsewhere (possibly in HRIRManager or ConvolutionEngine).

## Secondary Considerations

1. **Check HRIRManager.processAudio()** - If that method or any ConvolutionEngine methods are allocating, you'll see it multiply by the callback frequency.

2. **Swift runtime overhead** - Even accessing Swift properties in callbacks can cause allocations if they involve copy-on-write types or retain/release operations.

3. **Profile with Instruments** - Use Allocations instrument with "Record reference counts" to see the exact allocation stack traces.

## Testing the Fix

1. Replace all `UnsafeMutableAudioBufferListPointer` usage with raw pointer arithmetic
2. Build and run
3. Use Instruments Allocations template
4. Filter for "Persistent" = false (transient allocations)
5. Look for remaining allocation sources

The allocation count should drop dramatically after this change.
