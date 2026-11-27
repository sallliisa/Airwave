import Foundation
import XCTest
@testable import Airwave3

final class HostPresetLibraryTests: XCTestCase {
    func testImportsAvailableLegacyPresetsAndKeepsStableIDs() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = folder.appending(path: "Airwave 2")
        let spatial = legacy.appending(path: "presets")
        let equalizer = legacy.appending(path: "Equalizer Presets")
        try FileManager.default.createDirectory(at: spatial, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: equalizer, withIntermediateDirectories: true)

        let spatialID = UUID()
        let equalizerID = UUID()
        let unassignedID = UUID()
        let wav = makeWAV()
        let desk = Data("Preamp: -4 dB".utf8)
        try wav.write(to: spatial.appending(path: "Personal.wav"))
        try Data("RIFF".utf8).write(to: spatial.appending(path: "Corrupt.wav"))
        try desk.write(to: equalizer.appending(path: "Desk.txt"))
        try Data("Filter: ON PK Fc 200 Hz Gain -3 dB Q 0.9".utf8)
            .write(to: equalizer.appending(path: "Unassigned.txt"))
        try Data("Filter: malformed".utf8).write(to: equalizer.appending(path: "Broken.txt"))
        try FileManager.default.createSymbolicLink(
            at: equalizer.appending(path: "Link.txt"), withDestinationURL: equalizer.appending(path: "Desk.txt")
        )
        try writeJSON([
            ["id": spatialID.uuidString, "name": "Personal", "fileURL": "file:///old/location/Personal.wav"],
            ["id": "bad", "name": "Bad metadata"],
            ["id": UUID().uuidString, "name": "Corrupt WAV", "fileURL": "file:///old/location/Corrupt.wav"]
        ], to: spatial.appending(path: "presets.json"))
        try writeJSON(["presets": [
            ["id": equalizerID.uuidString, "displayName": "Desk", "filename": "Desk.txt"],
            ["id": "bad", "filename": "Unassigned.txt"],
            ["id": unassignedID.uuidString, "displayName": "Unassigned", "filename": "Unassigned.txt"],
            ["id": UUID().uuidString, "displayName": "Missing", "filename": "Missing.txt"],
            ["id": UUID().uuidString, "displayName": "Corrupt", "filename": "Broken.txt"],
            ["id": UUID().uuidString, "displayName": "Link", "filename": "Link.txt"],
            ["id": UUID().uuidString, "displayName": "Traversal", "filename": "../Desk.txt"]
        ]], to: equalizer.appending(path: "manifest.json"))

        let library = HostPresetLibrary(url: folder.appending(path: "Presets.plist"))
        let installed = HostPresetLibrary.legacyEntries(at: legacy)
        XCTAssertEqual(Set(installed.map(\.id)), [spatialID, equalizerID, unassignedID])
        try library.mergeLegacy(installed)
        try library.mergeLegacy(installed)
        try FileManager.default.removeItem(at: legacy)

        let restoredSpatial = try XCTUnwrap(library.load(for: .airwaveSpatial).first)
        XCTAssertEqual(restoredSpatial.id, spatialID)
        XCTAssertEqual(try document(restoredSpatial.state)["AirwaveSpatial.impulseResponse"] as? Data, wav)
        let restoredEqualizers = try library.load(for: .airwaveEqualizer)
        XCTAssertEqual(restoredEqualizers.map(\.id), [equalizerID, unassignedID])
        XCTAssertEqual(try EqualizerAUState(document(restoredEqualizers[0].state)).preset?.data, desk)

        try library.rename(restoredEqualizers[0], to: "Desk speakers")
        try library.delete(restoredEqualizers[1])
        try library.mergeLegacy(installed)
        let remaining = try library.load(for: .airwaveEqualizer)
        XCTAssertEqual(remaining.map(\.id), [equalizerID])
        XCTAssertEqual(remaining.map(\.name), ["Desk speakers"])
    }

    func testSavingStateDetachesEqualizerPresetFromOriginalRouteAndBypass() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let libraryURL = folder.appending(path: "Presets.plist")
        let library = HostPresetLibrary(url: libraryURL)
        let preset = EqualizerAUState.Preset(name: "Current", filename: "Desk.txt", data: Data("Preamp: -4 dB".utf8))
        let context = EqualizerAUState.OutputContext(deviceName: "Original", deviceUID: "original", inputChannelCount: 6)
        let state = EqualizerAUState.document(preset: preset, context: context, bypass: true)
        let data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        let saved = try library.save(name: "  Reusable  ", component: .airwaveEqualizer, state: data)

        let reopened = HostPresetLibrary(url: libraryURL)
        let stored = try XCTUnwrap(reopened.load(for: .airwaveEqualizer).first)
        XCTAssertEqual(saved.id, stored.id)
        XCTAssertEqual(stored.name, "Reusable")
        XCTAssertTrue(try reopened.load(for: .airwaveSpatial).isEmpty)
        let portable = try EqualizerAUState(document(stored.state))
        XCTAssertEqual(portable.preset?.data, preset.data)
        XCTAssertNil(portable.context)
        XCTAssertFalse(portable.bypass)
        XCTAssertThrowsError(try library.save(name: "New", component: .airwaveEqualizer, state: Data("bad state".utf8)))
        XCTAssertEqual(try reopened.load(for: .airwaveEqualizer), [stored])
    }

    func testImportKeepsAnEqualizerConfigFolderSelfContained() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = HostPresetLibrary(url: folder.appending(path: "Presets.plist"))
        let source = folder.appending(path: "Home speakers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("Include: filters.txt".utf8).write(to: source.appending(path: "config.txt"))
        try Data("Preamp: -2 dB".utf8).write(to: source.appending(path: "filters.txt"))
        let saved = try library.importPreset(from: source, component: .airwaveEqualizer)
        try FileManager.default.removeItem(at: source)

        let entry = try XCTUnwrap(library.load(for: .airwaveEqualizer).first)
        XCTAssertEqual(entry, saved)
        XCTAssertEqual(entry.name, "Home speakers")
        let restored = try XCTUnwrap(EqualizerAUState(document(entry.state)).preset)
        let definition = try EqualizerConfigFiles.parseManagedDefinition(data: restored.data, filename: restored.filename)
        XCTAssertEqual(definition.directives.filter { $0 == .preamp(-2) }, [.preamp(-2)])
    }

    func testOneMalformedLibraryItemDoesNotHideTheRest() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Presets.plist")
        let library = HostPresetLibrary(url: url)
        let state = try PropertyListSerialization.data(
            fromPropertyList: ["AirwaveSpatial.bundledPreset": "neutral"], format: .binary, options: 0
        )
        let saved = try library.save(name: "Neutral", component: .airwaveSpatial, state: state)

        var onDisk = try document(Data(contentsOf: url))
        var entries = try XCTUnwrap(onDisk["entries"] as? [[String: Any]])
        entries.insert(["name": "Broken"], at: 0)
        onDisk["entries"] = entries
        let damaged = try PropertyListSerialization.data(fromPropertyList: onDisk, format: .binary, options: 0)
        try damaged.write(to: url)

        XCTAssertEqual(try library.load(for: .airwaveSpatial), [saved])
        let added = try library.save(name: "Another", component: .airwaveSpatial, state: state)
        XCTAssertEqual(try library.load(for: .airwaveSpatial), [added, saved])
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func document(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func makeWAV() -> Data {
        let channels: UInt16 = 7
        let sampleRate: UInt32 = 48_000
        let blockSize = channels * 2
        let size = UInt32(blockSize) * 16
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        append(36 + size)
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(channels)
        append(sampleRate)
        append(sampleRate * UInt32(blockSize))
        append(blockSize)
        append(UInt16(16))
        wav.append(contentsOf: "data".utf8)
        append(size)
        wav.append(Data(repeating: 0, count: Int(size)))
        return wav
    }
}
