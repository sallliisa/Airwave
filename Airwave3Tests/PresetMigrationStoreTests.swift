import Foundation
import XCTest
@testable import Airwave3

final class PresetMigrationStoreTests: XCTestCase {
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

        let library = PresetMigrationStore(url: folder.appending(path: "Presets.plist"))
        let installed = PresetMigrationStore.legacyEntries(at: legacy)
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

    }

    func testOneMalformedLibraryItemDoesNotHideTheRest() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Presets.plist")
        let library = PresetMigrationStore(url: url)
        let state = try PropertyListSerialization.data(
            fromPropertyList: ["AirwaveSpatial.bundledPreset": "neutral"], format: .binary, options: 0
        )
        let saved = PresetMigrationStore.Entry(id: UUID(), component: .airwaveSpatial, name: "Neutral", state: state)
        try library.mergeLegacy([saved])

        var onDisk = try document(Data(contentsOf: url))
        var entries = try XCTUnwrap(onDisk["entries"] as? [[String: Any]])
        entries.insert(["name": "Broken"], at: 0)
        onDisk["entries"] = entries
        let damaged = try PropertyListSerialization.data(fromPropertyList: onDisk, format: .binary, options: 0)
        try damaged.write(to: url)

        XCTAssertEqual(try library.load(for: .airwaveSpatial), [saved])
        let added = PresetMigrationStore.Entry(id: UUID(), component: .airwaveSpatial, name: "Another", state: state)
        try library.mergeLegacy([added])
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
