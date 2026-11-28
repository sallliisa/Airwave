import AudioToolbox
import AVFoundation
import CoreAudio
import Synchronization
@testable import Airwave3
import XCTest

final class SystemAudioHostTests: XCTestCase {
    private static let airwaveID = ComponentID(AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x41777370,
        componentManufacturer: 0x41777665,
        componentFlags: 0,
        componentFlagsMask: 0
    ))

    func testProfilesKeepOrderedDuplicateInstancesAndSeparateDevices() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(url: root.appending(path: "profiles.plist"))

        let airwave = EffectComponent(id: Self.airwaveID, name: "Spatial", manufacturer: "Airwave")
        var first = EffectSlot(airwave)
        first.state = Data([7, 12])
        var second = EffectSlot(airwave)
        second.isBypassed = true
        let speaker = EffectSlot(airwave)

        XCTAssertEqual(try store.load(), [:])
        try store.save([
            "Headphones": DeviceProfile(name: "Headphones", sampleRate: 44_100, slots: [second, first]),
            "Speakers": DeviceProfile(name: "Speakers", sampleRate: 48_000, slots: [speaker]),
        ])
        let restored = try store.load()
        XCTAssertEqual(restored["Headphones"]?.slots, [second, first])
        XCTAssertEqual(restored["Speakers"]?.slots, [speaker])
        XCTAssertNotEqual(restored["Headphones"]?.slots[0].id, restored["Headphones"]?.slots[1].id)
    }

    func testLegacyProfilesKeepTheirOrderAndPluginState() throws {
        let location = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: location) }
        let airwave = EffectComponent(id: Self.airwaveID, name: "Spatial", manufacturer: "Airwave")
        var first = EffectSlot(airwave)
        first.state = Data([1, 3, 5])
        var second = EffectSlot(airwave)
        second.isBypassed = true
        try PropertyListEncoder().encode(["legacy": [second, first]]).write(to: location)
        let store = ProfileStore(url: location)
        let restored = try store.load()
        XCTAssertEqual(restored["legacy"]?.slots, [second, first])
        XCTAssertEqual(restored["legacy"]?.name, "legacy")
        XCTAssertNil(restored["legacy"]?.sampleRate)
        try store.save(restored)
        XCTAssertEqual(try store.load(), restored)
    }

    @MainActor
    func testSavedEqualizerGetsAirwaveAuthorAndKeepsItsPreset() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(url: root.appending(path: "profiles.plist"))
        var slot = EffectSlot(EffectComponent(id: .airwaveEqualizer, name: "Equalizer", manufacturer: "South Neuhof"))
        slot.state = Data([7, 12])
        slot.isBypassed = true
        try store.save(["headphones": DeviceProfile(name: "Headphones", slots: [slot])])

        let host = HostController(store: store, currentOutput: { throw CocoaError(.fileNoSuchFile) },
                                  availableOutputs: { [] })
        defer { host.shutdown() }

        XCTAssertEqual(host.effectSlot(slot.id, for: "headphones")?.manufacturer, "Airwave")
        let saved = try XCTUnwrap(store.load()["headphones"]?.slots.first)
        XCTAssertEqual(saved.id, slot.id)
        XCTAssertEqual(saved.component, slot.component)
        XCTAssertEqual(saved.manufacturer, "Airwave")
        XCTAssertEqual(saved.state, slot.state)
        XCTAssertTrue(saved.isBypassed)
    }

    @MainActor
    func testSavedSpatialCheckboxBecomesHostBypassWithoutChangingThePreset() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(url: root.appending(path: "profiles.plist"))
        var slot = EffectSlot(EffectComponent(id: .airwaveSpatial, name: "Spatial", manufacturer: "Airwave"))
        slot.state = try PropertyListSerialization.data(fromPropertyList: [
            "AirwaveSpatial.bypass": true,
            "AirwaveSpatial.bundledPreset": "room",
        ], format: .binary, options: 0)
        try store.save(["headphones": DeviceProfile(name: "Headphones", slots: [slot])])

        let host = HostController(store: store, currentOutput: { throw CocoaError(.fileNoSuchFile) },
                                  availableOutputs: { [] })
        defer { host.shutdown() }
        XCTAssertEqual(host.effectSlot(slot.id, for: "headphones")?.isBypassed, true)
        host.setBypass(slot.id, false, for: "headphones")

        let saved = try XCTUnwrap(store.load()["headphones"]?.slots.first)
        let state = try XCTUnwrap(saved.state)
        let document = try XCTUnwrap(PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any])
        XCTAssertFalse(saved.isBypassed)
        XCTAssertEqual(document["AirwaveSpatial.bypass"] as? Bool, false)
        XCTAssertEqual(document["AirwaveSpatial.bundledPreset"] as? String, "room")
    }

    func testUpdateConfigurationRequiresAHostFeedAndEd25519Key() {
        let key = Data(repeating: 11, count: 32).base64EncodedString()
        XCTAssertNil(HostUpdateConfiguration(feed: nil, publicKey: key))
        XCTAssertNil(HostUpdateConfiguration(feed: "http://example.org/appcast.xml", publicKey: key))
        XCTAssertNil(HostUpdateConfiguration(feed: "https://example.org/appcast.xml", publicKey: "placeholder"))
        XCTAssertEqual(
            HostUpdateConfiguration(feed: "https://example.org/appcast.xml", publicKey: key)?.feed.path,
            "/appcast.xml"
        )
    }

    @MainActor
    func testChangingTheOutputSelectsItsOwnSavedChain() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = ProfileStore(url: scratch.appending(path: "profiles.plist"))
        let first = OutputDevice(id: 1, uid: "speakers", name: "Speakers", sampleRate: 48_000)
        let second = OutputDevice(id: 2, uid: "headphones", name: "Headphones", sampleRate: 44_100)
        let unavailable = ComponentID(AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: 0x0000FFAA,
            componentManufacturer: 0x00000123, componentFlags: 0, componentFlagsMask: 0
        ))
        let example = EffectComponent(id: unavailable, name: "Uninstalled Audio Unit", manufacturer: "Test")
        let firstSlot = EffectSlot(example)
        let secondSlot = EffectSlot(example)
        try store.save([
            first.uid: DeviceProfile(name: first.name, sampleRate: first.sampleRate, slots: [firstSlot]),
            second.uid: DeviceProfile(name: second.name, sampleRate: second.sampleRate, slots: [secondSlot]),
        ])
        var output = first
        let host = HostController(store: store, currentOutput: { output }, availableOutputs: { [first] })
        defer { host.shutdown() }

        XCTAssertEqual(host.slots, [firstSlot])
        XCTAssertNotNil(host.slotIssues[firstSlot.id])
        host.selectEditingDevice(second.uid)
        XCTAssertEqual(host.editingDevices.first(where: { $0.id == second.uid })?.isConnected, false)
        XCTAssertEqual(host.editingSlots, [secondSlot])
        host.setEditingBypass(secondSlot.id, true)
        XCTAssertEqual(host.slots, [firstSlot])
        XCTAssertEqual(host.outputName, first.name)

        output = second
        try await waitForOutput(host, named: second.name)
        XCTAssertEqual(host.slots.first?.id, secondSlot.id)
        XCTAssertEqual(host.slots.first?.isBypassed, true)
        XCTAssertNotNil(host.slotIssues[secondSlot.id])
        XCTAssertNil(host.slotIssues[firstSlot.id])

        output = first
        try await waitForOutput(host, named: first.name)
        XCTAssertEqual(host.slots, [firstSlot])
        XCTAssertEqual(try store.load()[second.uid]?.slots.first?.isBypassed, true)
    }

    @MainActor
    private func waitForOutput(_ host: HostController, named name: String) async throws {
        for _ in 0..<25 {
            if host.outputName == name { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(host.outputName, name)
    }

    @MainActor
    func testAirwaveSpatialRendersAndCanBeInstantiatedTwice() async throws {
        let component = try XCTUnwrap(
            EffectCatalog.discover().first { $0.id == Self.airwaveID },
            "Install Airwave 2.2.0 or later and open it once to register Airwave Spatial."
        )
        let first = try await LiveEffect.load(EffectSlot(component), sampleRate: 48_000, maximumFrames: 4_096)
        let second = try await LiveEffect.load(EffectSlot(component), sampleRate: 48_000, maximumFrames: 4_096)
        XCTAssertNotEqual(first.slotID, second.slotID)
        XCTAssertFalse(first.unit === second.unit)

        let chain = RenderChain()
        let dry = render(chain)
        chain.replace(with: [first])
        let single = render(chain)
        chain.replace(with: [first, second])
        first.unit.reset()
        let doubled = render(chain)
        chain.replace(with: [])
        let bypassed = render(chain)

        XCTAssertEqual(first.stage.failure.load(ordering: .relaxed), noErr)
        XCTAssertEqual(second.stage.failure.load(ordering: .relaxed), noErr)
        XCTAssertTrue(single.allSatisfy(\.isFinite))
        XCTAssertTrue(doubled.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(distance(dry, single), 0.5)
        XCTAssertGreaterThan(distance(single, doubled), 0.5)
        XCTAssertEqual(dry, bypassed)
        first.unit.shouldBypassEffect = true
        var saved = EffectSlot(component)
        saved.state = try XCTUnwrap(first.saveState(previous: nil))
        let restored = try await LiveEffect.load(saved, sampleRate: 48_000, maximumFrames: 4_096)
        XCTAssertTrue(restored.unit.shouldBypassEffect)
        XCTAssertFalse(second.unit.shouldBypassEffect)

        chain.replace(with: [second])
        let peak = render(chain, amplitude: 10).map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.9)
        XCTAssertLessThanOrEqual(peak, 0.98)
        chain.replace(with: [])
        XCTAssertEqual(render(chain), dry)
    }

    @MainActor
    func testAppleAudioUnitCanShareTheChain() async throws {
        let lowpass = ComponentID(AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_LowPassFilter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        ))
        let components = EffectCatalog.discover()
        let apple = try XCTUnwrap(components.first { $0.id == lowpass })
        let airwave = try XCTUnwrap(components.first { $0.id == Self.airwaveID })
        let filter = try await LiveEffect.load(EffectSlot(apple), sampleRate: 48_000, maximumFrames: 4_096)
        let spatial = try await LiveEffect.load(EffectSlot(airwave), sampleRate: 48_000, maximumFrames: 4_096)
        let chain = RenderChain()
        let dry = render(chain)
        chain.replace(with: [filter, spatial])
        let processed = render(chain)

        XCTAssertEqual(filter.stage.failure.load(ordering: .relaxed), noErr)
        XCTAssertEqual(spatial.stage.failure.load(ordering: .relaxed), noErr)
        XCTAssertTrue(processed.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(distance(dry, processed), 0.5)
    }

    @MainActor
    func testAppMixerKeepsVolumeWhenMutedAndRestoresItAfterRelaunch() throws {
        let suite = "SystemAudioHostTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = "test.browser"
        let app = AppMixerApplication(id: id, name: "Browser", icon: nil, bundleID: id,
                                      processIDs: [123], hasActiveOutput: true)
        let mixer = AppMixer(defaults: defaults)
        let now = Date()
        mixer.update([app], now: now)
        XCTAssertEqual(mixer.rows.first?.volume, 100)
        mixer.setVolume(25, for: id)
        mixer.setMuted(true, for: id)
        mixer.update([], now: now.addingTimeInterval(15))
        XCTAssertEqual(mixer.rows.first?.isRecent, true)
        mixer.update([], now: now.addingTimeInterval(60))
        XCTAssertEqual(mixer.rows.first?.isRecent, false)

        let reopened = AppMixer(defaults: defaults)
        XCTAssertEqual(reopened.rows.first?.volume, 25)
        XCTAssertEqual(reopened.rows.first?.isMuted, true)
        reopened.setMuted(false, for: id)
        XCTAssertEqual(reopened.rows.first?.volume, 25)
        XCTAssertEqual(reopened.rows.first?.isMuted, false)
        reopened.reset(id)
        XCTAssertTrue(AppMixer(defaults: defaults).rows.isEmpty)
    }

    @MainActor
    func testSystemSoundsKeepTheirAdjustmentWithTheFriendlyLabel() throws {
        let suite = "SystemAudioHostTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for id in ["systemsoundserverd", "/usr/sbin/systemsoundserverd"] {
            let mixer = AppMixer(defaults: defaults)
            mixer.update([AppMixerApplication(id: id, name: "systemsoundserverd", icon: nil, bundleID: nil,
                                              processIDs: [123], hasActiveOutput: true)])
            XCTAssertEqual(mixer.rows.first?.name, "System Sounds")
            XCTAssertNotNil(mixer.rows.first?.icon)
            mixer.setVolume(40, for: id)

            let reopened = AppMixer(defaults: defaults)
            let saved = try XCTUnwrap(reopened.rows.first)
            XCTAssertEqual(saved.id, id)
            XCTAssertEqual(saved.name, "System Sounds")
            XCTAssertEqual(saved.volume, 40)
            XCTAssertFalse(saved.isRecent)
            reopened.reset(id)
        }
    }

    @MainActor
    func testAppMixerKeepsPlaybackRouteAcrossUnityGain() throws {
        let suite = "SystemAudioHostTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppMixerApplication(id: "test.browser", name: "Browser", icon: nil, bundleID: nil,
                                      processIDs: [123], hasActiveOutput: true)
        let mixer = AppMixer(defaults: defaults)
        let idle = mixer.sources
        let now = Date()
        XCTAssertFalse(mixer.requiresRouting)
        mixer.update([app], now: now)
        XCTAssertTrue(mixer.requiresRouting, "The mixer needs a route even with every app at 100%.")
        let route = mixer.sources
        XCTAssertTrue(route.contains { $0.processIDs == app.processIDs }, "Prepare the app tap while its volume is 100%.")
        mixer.setVolume(70, for: app.id)
        XCTAssertEqual(mixer.rows.first?.volume, 70)
        let reducedRoute = mixer.sources
        XCTAssertEqual(reducedRoute, route, "Lowering 100% must not change the live tap plan.")
        mixer.setVolume(100, for: app.id)
        XCTAssertEqual(mixer.rows.first?.isAdjusted, false)
        XCTAssertEqual(mixer.sources, reducedRoute, "Returning to 100% must not change the live tap plan.")
        XCTAssertTrue(AppMixer(defaults: defaults).rows.isEmpty, "Unity gain is not a saved adjustment.")

        let other = AppMixerApplication(id: "test.music", name: "Music", icon: nil, bundleID: nil,
                                        processIDs: [456], hasActiveOutput: true)
        mixer.update([app, other], now: now)
        XCTAssertEqual(mixer.sources.count, route.count)
        XCTAssertTrue(zip(mixer.sources, route).allSatisfy { $0.sharesTap(with: $1) },
                      "A newly playing app can take a spare tap on the existing route.")
        mixer.update([], now: now.addingTimeInterval(60))
        XCTAssertFalse(mixer.requiresRouting)
        XCTAssertEqual(mixer.sources, idle, "Idle taps are reusable and the mixer can return to native playback.")
    }

    func testGainRampFinishesBetweenSamplesOfAnOddSizedBlock() {
        let frames = 7
        let gain = AppMixerGain(0)
        for stride in [1, 2] {
            gain.set(0)
            let left = BufferChannel(buffer: 0, offset: 0, stride: stride)
            let right = BufferChannel(buffer: stride == 1 ? 1 : 0, offset: stride - 1, stride: stride)
            let tap = StereoTapInput(left: left, right: right, gain: gain)
            let list = AudioBufferList.allocate(maximumBuffers: 2)
            defer { list.unsafeMutablePointer.deallocate() }
            list.count = 2 / stride
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            defer { data.deallocate() }
            for index in 0..<list.count {
                list[index] = AudioBuffer(mNumberChannels: UInt32(stride), mDataByteSize: UInt32(frames * stride * 4),
                                          mData: data.advanced(by: index * frames * stride))
            }
            for frame in 0..<frames {
                data[frame * stride] = 1
                data[(stride == 1 ? frames : 1) + frame * stride] = -2
            }
            let blocks: [(target: Float, levels: [Float])] = [
                (1, [0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875]),
                (1, [1, 1, 1, 1, 1, 1, 1]),
                (0.5, [0.875, 0.75, 0.625, 0.5, 0.5, 0.5, 0.5])
            ]
            for (target, expected) in blocks {
                gain.set(target)
                var mixedL = [Float](repeating: 0.5, count: frames)
                var mixedR = mixedL
                XCTAssertTrue(tap.mix(from: list, into: &mixedL, &mixedR, frames: frames, gainStep: 0.125))
                XCTAssertEqual(mixedL, expected.map { 0.5 + $0 })
                XCTAssertEqual(mixedR, expected.map { 0.5 - 2 * $0 })
            }
        }
    }

    @MainActor
    func testCaptureCheckKeepsHostResponsiveWhileCoreAudioWaits() async throws {
        let id = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defaults.set(false, forKey: "ProcessingEnabled")
        defer { defaults.removePersistentDomain(forName: id) }
        let output = OutputDevice(id: 42, uid: "speakers", name: "Speakers", sampleRate: 48_000)
        let host = HostController(
            store: ProfileStore(url: FileManager.default.temporaryDirectory.appending(path: id)),
            defaults: defaults, currentOutput: { output }, availableOutputs: { [output] },
            makeVerificationRoute: { _, _, _ in
                XCTAssertFalse(Thread.isMainThread, "The HAL can wait for permission or a device on this call.")
                Thread.sleep(forTimeInterval: 0.25)
                throw SystemAudioRouteError.permissionDenied
            }
        )
        defer { host.shutdown() }

        host.checkCapturePermission()
        XCTAssertEqual(host.captureCheck, .checking, "Starting the audio test must return before Core Audio answers.")
        let deadline = Date().addingTimeInterval(2)
        while host.captureCheck == .checking, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(host.captureCheck, .failed(SystemAudioRouteError.permissionDenied.localizedDescription))
    }

    @MainActor
    func testLiveAirwaveRoute() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SYSTEM_AUDIO_HOST_LIVE"] == "1",
                          "Run Scripts/verify live to test the current output with quiet playback.")
        let output = try SystemAudioRoute.currentOutput()
        let component = try XCTUnwrap(EffectCatalog.discover().first { $0.id == Self.airwaveID })
        let effect = try await LiveEffect.load(
            EffectSlot(component), sampleRate: output.sampleRate, maximumFrames: SystemAudioRoute.maximumFrames
        )
        let chain = RenderChain()
        chain.replace(with: [effect])

        let detector = LiveRouteDetector(chain: nil)
        let verification = try SystemAudioRoute(output: output, verification: true, render: detector.render)
        try verification.start()
        defer { verification.stop() }
        await playUntil { detector.captured.load(ordering: .relaxed) }
        XCTAssertTrue(detector.captured.load(ordering: .relaxed), "The unmuted tap did not capture afplay.")
        XCTAssertTrue(verification.stop())
        try XCTSkipUnless(detector.captured.load(ordering: .relaxed), "Capture access is required to test the muted route.")

        let processed = LiveRouteDetector(chain: chain)
        let route = try SystemAudioRoute(output: output, render: processed.render)
        try route.start()
        defer { route.stop() }
        await playUntil(timeout: 8) { processed.changed.load(ordering: .relaxed) }
        if let frames = try? HAL.read(kAudioDevicePropertyBufferFrameSize, of: output.id, as: UInt32.self) {
            print(String(format: "%@ at %.0f Hz, device buffer %u frames (%.2f ms), AU reports %.2f ms latency",
                         output.name, output.sampleRate, frames, 1000 * Double(frames) / output.sampleRate,
                         1000 * effect.unit.latency))
        }
        XCTAssertTrue(processed.captured.load(ordering: .relaxed))
        XCTAssertTrue(processed.changed.load(ordering: .relaxed), "Airwave must change the signal written to the output.")
        XCTAssertEqual(effect.stage.failure.load(ordering: .relaxed), noErr)
        XCTAssertFalse(route.hasIOFailure)
        XCTAssertTrue(route.stop())
        XCTAssertEqual(try SystemAudioRoute.currentOutput(), output)
    }

    @MainActor
    func testLiveMixerSeparatesTwoSourcesBeforeAirwave() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SYSTEM_AUDIO_HOST_LIVE"] == "1",
                          "Run Scripts/verify live to test the mixer with quiet playback.")
        let output = try SystemAudioRoute.currentOutput()
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let firstTone = 1_125.0
        let secondTone = 3_000.0
        let firstFile = try tone(firstTone, to: scratch.appending(path: "first.wav"))
        let secondFile = try tone(secondTone, to: scratch.appending(path: "second.wav"))
        let fixtureBundleID = "com.southneuhof.SystemAudioHost.LiveTone"
        let executable = try toneApplication(in: scratch, bundleID: fixtureBundleID)
        var first: Process?
        defer { if let first { stop(first) } }
        let second = try play(secondFile)
        defer { stop(second) }

        let component = try XCTUnwrap(EffectCatalog.discover().first { $0.id == Self.airwaveID })
        let effect = try await LiveEffect.load(
            EffectSlot(component), sampleRate: output.sampleRate, maximumFrames: SystemAudioRoute.maximumFrames
        )
        let chain = RenderChain()
        chain.replace(with: [effect])
        let detector = MixerToneDetector(firstTone, secondTone, sampleRate: output.sampleRate, chain: chain)
        let suite = "SystemAudioHostTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mixer = AppMixer(defaults: defaults)
        mixer.update([AppMixerApplication(id: fixtureBundleID, name: "Live Tone", icon: nil,
                                          bundleID: fixtureBundleID, processIDs: [], hasActiveOutput: true)])
        let route = try SystemAudioRoute(output: output, appSources: mixer.sources, render: detector.render)
        try route.start()
        defer { route.stop() }
        let catalog = AudioApplicationCatalog()
        var lastIDs: [AudioObjectID] = []
        var retargetError: Error?
        catalog.startWatching {
            guard let apps = catalog.scan(output: output) else { return }
            let fixture = apps.filter { $0.id == fixtureBundleID }
            let ids = fixture.first?.processIDs.sorted() ?? []
            guard ids != lastIDs else { return }
            do {
                mixer.update(fixture)
                let keptRoute = try route.retarget(to: mixer.sources)
                XCTAssertTrue(keptRoute)
                lastIDs = ids
            } catch {
                retargetError = error
            }
        }
        defer { catalog.stopWatching() }
        _ = try await waitForTones(detector, phase: "before the adjusted app starts") { $0 < 0.001 && $1 > 0.002 }
        let initialProcess = try play(firstFile, executable: executable)
        first = initialProcess
        let initialID = try await waitForPlayback(initialProcess)
        for _ in 0..<50 where !lastIDs.contains(initialID) {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertTrue(lastIDs.contains(initialID), "The fixture must be on its own tap before changing its gain.")
        _ = try await waitForTones(detector, phase: "both apps at full gain") { $0 > 0.0045 && $1 > 0.0045 }
        var baselineFirst: [Double] = []
        var baselineSecond: [Double] = []
        for _ in 0..<9 {
            try await Task.sleep(for: .milliseconds(60))
            baselineFirst.append(detector.first.load(ordering: .relaxed))
            baselineSecond.append(detector.second.load(ordering: .relaxed))
        }
        let initial = (baselineFirst.sorted()[4], baselineSecond.sorted()[4])
        let liveSources = mixer.sources
        mixer.setVolume(25, for: fixtureBundleID)
        XCTAssertEqual(mixer.sources, liveSources)
        _ = try await waitForTones(detector, phase: "25% of \(initial.0)") {
            abs($0 / initial.0 - 0.25) < 0.09 && abs($1 / initial.1 - 1) < 0.22
        }
        mixer.setVolume(100, for: fixtureBundleID)
        XCTAssertEqual(mixer.sources, liveSources)
        _ = try await waitForTones(detector, phase: "return to 100% of \(initial)") {
            abs($0 / initial.0 - 1) < 0.22 && abs($1 / initial.1 - 1) < 0.22
        }
        mixer.setMuted(true, for: fixtureBundleID)
        _ = try await waitForTones(detector, phase: "mute") { $0 < initial.0 * 0.1 && abs($1 / initial.1 - 1) < 0.22 }
        stop(try XCTUnwrap(first))
        detector.watchFirstPeak.store(true, ordering: .relaxed)
        let replacement = try play(firstFile, executable: executable)
        first = replacement
        let replacementID = try await waitForPlayback(replacement)
        try await Task.sleep(for: .milliseconds(600))
        detector.watchFirstPeak.store(false, ordering: .relaxed)
        XCTAssertNil(retargetError)
        XCTAssertTrue(lastIDs.contains(replacementID), "The relaunched app should rejoin its existing mixer channel.")
        XCTAssertLessThan(detector.firstPeak.load(ordering: .relaxed), initial.0 * 0.2,
                          "A new process in the muted app must stay muted from its first buffer.")
        mixer.setMuted(false, for: fixtureBundleID)
        _ = try await waitForTones(detector, phase: "unmute") {
            abs($0 / initial.0 - 1) < 0.22 && abs($1 / initial.1 - 1) < 0.22
        }
        XCTAssertTrue(detector.effectChanged.load(ordering: .relaxed))
        XCTAssertEqual(effect.stage.failure.load(ordering: .relaxed), noErr)
        XCTAssertFalse(route.hasIOFailure)
        XCTAssertTrue(route.stop())
        XCTAssertEqual(try SystemAudioRoute.currentOutput(), output)
    }

    private func tone(_ frequency: Double, to url: URL) throws -> URL {
        let rate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(buffer.frameLength) { channel[i] = 0.008 * Float(sin(2 * .pi * frequency * Double(i) / rate)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for _ in 0..<24 { try file.write(from: buffer) }
        return url
    }

    private func toneApplication(in root: URL, bundleID: String) throws -> URL {
        let app = root.appending(path: "Live Tone.app")
        let executable = app.appending(path: "Contents/MacOS/Tone")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/afplay"), to: executable)
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": bundleID, "CFBundleName": "Live Tone", "CFBundleExecutable": "Tone",
            "CFBundlePackageType": "APPL", "LSUIElement": true,
        ], format: .xml, options: 0)
        try info.write(to: app.appending(path: "Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(filePath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        return executable
    }

    private func play(_ file: URL, executable: URL = URL(filePath: "/usr/bin/afplay")) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = [file.path]
        try process.run()
        return process
    }

    private func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private func waitForPlayback(_ process: Process) async throws -> AudioObjectID {
        for _ in 0..<50 {
            if let id = try? HAL.processID(process.processIdentifier),
               (try? HAL.read(kAudioProcessPropertyIsRunningOutput, of: id, as: UInt32.self)) == 1 { return id }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw XCTSkip("The test sound could not start playing.")
    }

    private func waitForTones(_ detector: MixerToneDetector, phase: String,
                              matching: (Double, Double) -> Bool) async throws -> (Double, Double) {
        var levels = (0.0, 0.0)
        var consecutive = 0
        for _ in 0..<125 {
            try await Task.sleep(for: .milliseconds(40))
            levels = (detector.first.load(ordering: .relaxed), detector.second.load(ordering: .relaxed))
            consecutive = matching(levels.0, levels.1) ? consecutive + 1 : 0
            if consecutive == 3 { return levels }
        }
        XCTFail("Expected app gains were not rendered at \(phase). Last tone levels: \(levels)")
        throw CocoaError(.fileReadUnknown)
    }

    @MainActor
    private func playUntil(timeout: TimeInterval = 24, condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            let playback = Process()
            playback.executableURL = URL(filePath: "/usr/bin/afplay")
            playback.arguments = ["-v", "0.025", "/System/Library/Sounds/Glass.aiff"]
            guard (try? playback.run()) != nil else { return }
            while playback.isRunning, !condition(), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if playback.isRunning { playback.terminate() }
            playback.waitUntilExit()
            if !condition() { try? await Task.sleep(for: .milliseconds(200)) }
        }
    }

    private func render(_ chain: RenderChain, amplitude: Float = 0.15) -> [Float] {
        let frames = 256
        let blocks = 42
        let input = (0..<frames).map { sin(Float($0) * 0.32) * amplitude }
        let opposite = input.map { $0 * -0.6 }
        var left = [Float](repeating: 0, count: frames)
        var right = left
        var result: [Float] = []
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        for block in 0..<blocks {
            time.mSampleTime = Double(block * frames)
            chain.render(&time, input, opposite, &left, &right, UInt32(frames))
            result.append(contentsOf: left)
            result.append(contentsOf: right)
        }
        return result
    }

    private func distance(_ first: [Float], _ second: [Float]) -> Float {
        zip(first, second).reduce(0) { $0 + abs($1.0 - $1.1) }
    }
}

private final class MixerToneDetector {
    let first = Atomic(0.0)
    let second = Atomic(0.0)
    let firstPeak = Atomic(0.0)
    let watchFirstPeak = Atomic(false)
    let effectChanged = Atomic(false)
    private var firstTone: Tone
    private var secondTone: Tone
    private var position = 0
    private let chain: RenderChain

    init(_ firstFrequency: Double, _ secondFrequency: Double, sampleRate: Double, chain: RenderChain) {
        firstTone = Tone(coefficient: 2 * cos(2 * .pi * firstFrequency / sampleRate))
        secondTone = Tone(coefficient: 2 * cos(2 * .pi * secondFrequency / sampleRate))
        self.chain = chain
    }

    func render(_ time: UnsafePointer<AudioTimeStamp>, _ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>,
                _ outLeft: UnsafeMutablePointer<Float>, _ outRight: UnsafeMutablePointer<Float>, _ frames: UInt32) {
        let window = 2_048
        for index in 0..<Int(frames) {
            let sample = Double(left[index])
            firstTone.add(sample)
            secondTone.add(sample)
            position += 1
            if position == window {
                let level = firstTone.finish(window)
                first.store(level, ordering: .relaxed)
                second.store(secondTone.finish(window), ordering: .relaxed)
                if watchFirstPeak.load(ordering: .relaxed), level > firstPeak.load(ordering: .relaxed) {
                    firstPeak.store(level, ordering: .relaxed)
                }
                position = 0
            }
        }
        chain.render(time, left, right, outLeft, outRight, frames)
        if !effectChanged.load(ordering: .relaxed), (0..<Int(frames)).contains(where: { abs(left[$0] - outLeft[$0]) > 0.001 }) {
            effectChanged.store(true, ordering: .relaxed)
        }
    }

    private struct Tone {
        let coefficient: Double
        var previous = 0.0
        var beforePrevious = 0.0

        mutating func add(_ sample: Double) {
            let current = sample + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }

        mutating func finish(_ frames: Int) -> Double {
            let energy = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
            previous = 0
            beforePrevious = 0
            return 2 * sqrt(max(0, energy)) / Double(frames)
        }
    }
}

private final class LiveRouteDetector {
    let captured = Atomic(false)
    let changed = Atomic(false)
    private let chain: RenderChain?

    init(chain: RenderChain?) { self.chain = chain }

    func render(
        _ time: UnsafePointer<AudioTimeStamp>, _ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>,
        _ outputLeft: UnsafeMutablePointer<Float>, _ outputRight: UnsafeMutablePointer<Float>, _ frames: UInt32
    ) {
        chain?.render(time, left, right, outputLeft, outputRight, frames)
        var heardInput = false
        var heardChange = false
        for index in 0..<Int(frames) {
            heardInput = heardInput || abs(left[index]) > 0.00001 || abs(right[index]) > 0.00001
            if chain != nil {
                heardChange = heardChange || abs(outputLeft[index] - left[index]) > 0.00001
            }
        }
        if heardInput { captured.store(true, ordering: .relaxed) }
        if heardChange { changed.store(true, ordering: .relaxed) }
    }
}
