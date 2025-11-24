### 🔴 Issue 1: Incomplete UID Migration

**Evidence**: Lines 36, 365, 395, 510, 514, 728 vs Lines 571-572

```swift
// TRACKING by UID in memory ✅
private var lastUserSelectedOutputUID: String?  // Line 36
lastUserSelectedOutputUID = firstOutput.uid     // Lines 365, 395, 510, etc.

// But SAVING by device ID to disk ❌
let settings = AppSettings(
    aggregateDeviceID: audioManager.aggregateDevice?.id,        // Line 571
    selectedOutputDeviceID: selectedOutputDevice?.device.id,    // Line 572
    // ...
)
```

**Impact**:

- UID tracking is lost on app restart
- Device reconnection only works within a single session
- Defeats the entire purpose of UID tracking

**Why This Happened**:
The refactoring was started (added `lastUserSelectedOutputUID`) but not completed (settings schema not updated).

**Fix**:
Implement Phase 2 of `DEVICE_PERSISTENCE_AND_RECONNECTION_REFACTOR.md` to update settings schema.

### 🔴 Issue 2: Duplicate Device Restoration Logic

**Two nearly identical functions** that restore user's preferred device:

#### Function A: `refreshAvailableOutputsIfNeeded()` (Lines 646-742)

- Triggered by: System device list changes (`deviceManager.$aggregateDevices`)
- Uses: `setupAudioUnit()` for restoration (stops/restarts audio)
- Lines of code: 96

#### Function B: `handleAggregateConfigurationChange()` (Lines 744-803)

- Triggered by: CoreAudio aggregate config change listener
- Uses: `setOutputChannels()` for restoration (no stop/restart)
- Lines of code: 59

**Key Differences**:

```swift
// Function A (Line 692)
try audioManager.setupAudioUnit(...)  // Reinitializes audio unit

// Function B (Line 778)
audioManager.setOutputChannels(channelRange)  // Just updates channels
```

**Why This is Confusing**:

1. Both functions do UID-based device restoration
2. But use different approaches (setupAudioUnit vs setOutputChannels)
3. Comments on Line 397 say "NO NEED TO STOP AUDIO!" but Function A does stop audio
4. Unclear which one is correct

**Root Cause**:
Two separate attempts to solve device reconnection, neither removed after the other was added.

**Impact**:

- Maintenance burden (bug fixes needed in 2 places)
- Inconsistent behavior depending on which listener fires first
- Race conditions possible

### 🟡 Issue 3: Massive Code Duplication (Virtual Loopback Filtering)

**Duplicated 5 times** across the file:

1. **Lines 352-355** (selectAggregateDevice):

```swift
availableOutputs = allOutputs.filter { output in
    let name = output.name.lowercased()
    return !name.contains("blackhole") && !name.contains("soundflower")
}
```

2. **Lines 496-499** (loadSettings):

```swift
availableOutputs = allOutputs.filter { output in
    let name = output.name.lowercased()
    return !name.contains("blackhole") && !name.contains("soundflower")
}
```

3. **Lines 654-657** (refreshAvailableOutputsIfNeeded)
4. **Lines 756-759** (handleAggregateConfigurationChange)
5. **Lines 814-817** (refreshOutputChannelMapping)

**Plus empty-check fallback duplicated 5 times**:

```swift
if availableOutputs.isEmpty && !allOutputs.isEmpty {
    print("[MenuBarManager] Warning: All outputs were virtual loopback devices, showing all")
    availableOutputs = allOutputs
}
```

**Impact**:

- 30+ lines of duplicated code
- If filter logic changes (e.g., add "Loopback" to filter), must update 5 places
- Easy to miss updates, leading to inconsistencies

**Fix**: Extract to helper method.

### 🟡 Issue 4: Hardcoded Stereo Channel Range

**Repeated 11 times** throughout the file:

```swift
output.startChannel..<(output.startChannel + 2)
```

**Locations**: Lines 323, 370, 399, 521, 694, 730, 777, 825, 851

**Problems**:

- Magic number `2` assumes stereo output
- If future feature adds multi-channel output, must update 11 places
- Not clear what `+ 2` means without context

**Fix**: Extract to computed property or helper method:

```swift
extension SubDeviceInfo {
    var stereoChannelRange: Range<Int> {
        return startChannel..<(startChannel + 2)
    }
}
```

### 🟡 Issue 5: Validation Filters, Then Selection Filters Again

**Validation (Lines 282-288)**:

```swift
private func validateAggregateDevice(_ device: AudioDevice) -> (valid: Bool, reason: String?) {
    do {
        let inputs = try inspector.getInputDevices(aggregate: device)
        let allOutputs = try inspector.getOutputDevices(aggregate: device)

        // Filter out virtual loopback devices for validation
        let outputs = allOutputs.filter { output in
            let name = output.name.lowercased()
            return !name.contains("blackhole") && !name.contains("soundflower")
        }
```

**Then Selection (Lines 348-355)**:

```swift
let allOutputs = try inspector.getOutputDevices(aggregate: device)

// Filter out virtual loopback devices (BlackHole, Soundflower, etc.)
availableOutputs = allOutputs.filter { output in
    let name = output.name.lowercased()
    return !name.contains("blackhole") && !name.contains("soundflower")
}
```

**Issue**:

- Filtering happens twice
- If validation passes but selection filters everything, inconsistency
- Code assumes both use same filter (but they're duplicated, so could diverge)

**Fix**: Extract filter, apply once before validation.

### 🟡 Issue 6: Two Listeners for Overlapping Events

**Listener 1**: Combine publisher (Lines 74-80)

```swift
deviceManager.$aggregateDevices
    .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
    .sink { [weak self] _ in
        self?.refreshAvailableOutputsIfNeeded()  // Calls Function A
        self?.updateMenu()
    }
```

**Listener 2**: CoreAudio property listener (Lines 595-619, 871-889)

```swift
AudioObjectAddPropertyListener(
    device.id,
    &propertyAddress,  // kAudioAggregateDevicePropertyFullSubDeviceList
    aggregateDeviceChangeCallback,
    // ...
)

// Callback invokes:
manager.handleAggregateConfigurationChange()  // Calls Function B
```

**Problem**:

- Both fire when aggregate device configuration changes
- Can fire at different times (~100ms apart based on LESSONS.md)
- Each calls a different restoration function
- Potential for race conditions or double-processing

**Questions**:

1. Why have both?
2. Which one is more reliable?
3. Can they conflict with each other?

**Likely Answer**:

- Publisher fires when system device list changes (device added/removed from system)
- Listener fires when aggregate config changes (sub-device added/removed from aggregate)
- These are related but distinct events

**Recommendation**: Document the distinction clearly, or consolidate.
