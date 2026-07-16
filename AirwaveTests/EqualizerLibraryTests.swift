import Foundation
import XCTest
@testable import Airwave

@MainActor
final class EqualizerLibraryTests: XCTestCase {
    func testEmptyLibraryDefaultsToNone() throws {
        let context = try TestContext()

        XCTAssertTrue(context.manager.presets.isEmpty)
        XCTAssertEqual(context.manager.selection, .none)
        XCTAssertNil(context.manager.selectedDefinition)
        XCTAssertNil(context.manager.libraryError)
    }

    func testImportPersistsStableIDsAndSelectionAcrossRelaunch() throws {
        let context = try TestContext()
        let alpha = try context.writePreset(named: "Alpha.TXT", preamp: 1)
        let zulu = try context.writePreset(named: "Zulu.txt", preamp: 2)

        let result = context.manager.importPresets([zulu, alpha], collisionPolicy: .reject)
        XCTAssertEqual(result.imported.map(\.displayName), ["Zulu", "Alpha"])
        XCTAssertEqual(context.manager.presets.map(\.displayName), ["Alpha", "Zulu"])
        let selected = try XCTUnwrap(result.imported.last)
        context.manager.select(.preset(selected.id))
        let selectedDefinition = context.manager.selectedDefinition

        let relaunched = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope
        )

        XCTAssertEqual(relaunched.presets.map(\.id), context.manager.presets.map(\.id))
        XCTAssertEqual(relaunched.selection, .preset(selected.id))
        XCTAssertEqual(relaunched.selectedDefinition, selectedDefinition)
    }

    func testInvalidManagedFileIsSkippedAndReported() throws {
        let context = try TestContext()
        let invalid = context.managed.appendingPathComponent("broken.txt")
        try Data("Include: other.txt\n".utf8).write(to: invalid)

        let manager = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope
        )

        XCTAssertTrue(manager.presets.isEmpty)
        XCTAssertEqual(manager.libraryError?.filename, "broken.txt")
    }

    func testMissingSelectedFileFallsBackToNoneAndClearsStaleKey() throws {
        let context = try TestContext()
        let source = try context.writePreset(named: "Selected.txt", preamp: 1)
        let imported = try XCTUnwrap(context.manager.importPresets([source], collisionPolicy: .reject).imported.first)
        context.manager.select(.preset(imported.id))
        try FileManager.default.removeItem(at: imported.fileURL)

        let relaunched = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope
        )

        XCTAssertEqual(relaunched.selection, .none)
        XCTAssertNil(relaunched.selectedDefinition)
        XCTAssertNil(context.defaults.string(forKey: EqualizerManager.selectedPresetDefaultsKey))
        XCTAssertEqual(relaunched.libraryError?.filename, "Selected.txt")
    }

    func testPreflightAndBatchImportCopySourceAndBalanceSecurityScope() throws {
        let context = try TestContext()
        let valid = try context.writePreset(named: "Valid.txt", preamp: 1)
        let invalid = context.sourceDirectory.appendingPathComponent("invalid.txt")
        try Data("not an equalizer\n".utf8).write(to: invalid)

        let preflight = context.manager.preflightImport([invalid, valid])
        XCTAssertEqual(preflight.acceptable, [valid])
        XCTAssertEqual(preflight.rejected.count, 1)

        let sourceBytes = try Data(contentsOf: valid)
        let result = context.manager.importPresets([invalid, valid], collisionPolicy: .reject)
        XCTAssertEqual(result.imported.map(\.displayName), ["Valid"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: valid), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: context.managed.appendingPathComponent("Valid.txt")), sourceBytes)
        XCTAssertEqual(context.securityScope.startCount, 4)
        XCTAssertEqual(context.securityScope.stopCount, 4)
    }

    func testCollisionRejectAndReplacementPreserveIDAndReplaceAtomically() throws {
        let context = try TestContext()
        let source = try context.writePreset(named: "Curve.txt", preamp: 1)
        let first = try XCTUnwrap(context.manager.importPresets([source], collisionPolicy: .reject).imported.first)
        context.manager.select(.preset(first.id))
        let originalBytes = try Data(contentsOf: first.fileURL)

        let replacementSource = try context.writePreset(named: "Curve.txt", preamp: 2)
        let preflight = context.manager.preflightImport([replacementSource])
        XCTAssertEqual(preflight.conflicts, [replacementSource])
        let rejected = context.manager.importPresets([replacementSource], collisionPolicy: .reject)
        XCTAssertEqual(rejected.skipped, ["Curve.txt"])
        XCTAssertEqual(try Data(contentsOf: first.fileURL), originalBytes)
        XCTAssertEqual(context.manager.selectedDefinition?.preampDB, 1)

        let replaced = context.manager.importPresets([replacementSource], collisionPolicy: .replace)
        XCTAssertEqual(replaced.imported.first?.id, first.id)
        XCTAssertEqual(context.manager.selection, .preset(first.id))
        XCTAssertEqual(context.manager.selectedDefinition?.preampDB, 2)
        XCTAssertEqual(try Data(contentsOf: first.fileURL), try Data(contentsOf: replacementSource))
        XCTAssertEqual(try Data(contentsOf: replacementSource), Data("Preamp: 2.0 dB\n".utf8))
    }

    func testFailedReplacementPreservesOldBytesAndDefinition() throws {
        let context = try TestContext()
        let source = try context.writePreset(named: "Curve.txt", preamp: 1)
        let first = try XCTUnwrap(context.manager.importPresets([source], collisionPolicy: .reject).imported.first)
        context.manager.select(.preset(first.id))
        let originalBytes = try Data(contentsOf: first.fileURL)

        let invalidReplacement = try context.writePreset(named: "Curve.txt", preamp: nil)
        let result = context.manager.importPresets([invalidReplacement], collisionPolicy: .replace)

        XCTAssertTrue(result.imported.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: first.fileURL), originalBytes)
        XCTAssertEqual(context.manager.selection, .preset(first.id))
        XCTAssertEqual(context.manager.selectedDefinition?.preampDB, 1)
    }

    func testTraversalResistantBasenameAndSelectedDeletionLeaveSourceUntouched() throws {
        let context = try TestContext()
        let nested = context.sourceDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = try context.writePreset(named: "Nested.txt", preamp: 1, directory: nested)
        let sourceBytes = try Data(contentsOf: source)
        let traversalURL = nested.appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("Nested.txt")

        let imported = try XCTUnwrap(context.manager.importPresets([traversalURL], collisionPolicy: .reject).imported.first)
        XCTAssertEqual(imported.fileURL.deletingLastPathComponent().standardizedFileURL, context.managed.standardizedFileURL)
        context.manager.select(.preset(imported.id))
        XCTAssertTrue(context.manager.delete(imported))
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(context.manager.selection, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.fileURL.path))
    }

    func testSymbolicLinkImportIsRejectedAndDoesNotEnterManagedLibrary() throws {
        let context = try TestContext()
        let target = try context.writePreset(named: "Target.txt", preamp: 1)
        let link = context.sourceDirectory.appendingPathComponent("Link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = context.manager.importPresets([link], collisionPolicy: .reject)

        XCTAssertTrue(result.imported.isEmpty)
        XCTAssertEqual(result.failures.first?.filename, "Link.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.managed.appendingPathComponent("Link.txt").path))
    }

    func testCorruptManifestErrorIsPreservedAlongsideValidPresetRows() throws {
        let context = try TestContext()
        let valid = context.managed.appendingPathComponent("Valid.txt")
        try Data("Preamp: 1 dB\n".utf8).write(to: valid)
        try Data("{not-json".utf8).write(to: context.managed.appendingPathComponent("manifest.json"))

        let reloaded = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope
        )

        XCTAssertEqual(reloaded.presets.map(\.displayName), ["Valid"])
        XCTAssertEqual(reloaded.libraryError?.filename, "manifest.json")
    }

    func testManifestWriteFailureRollsBackImportAndDeletion() throws {
        let writer = EqualizerManifestWriterFake()
        let context = try TestContext(manifestWriter: writer)
        let source = try context.writePreset(named: "Curve.txt", preamp: 1)

        writer.shouldFail = true
        let failedImport = context.manager.importPresets([source], collisionPolicy: .reject)
        XCTAssertTrue(failedImport.imported.isEmpty)
        XCTAssertTrue(context.manager.presets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.managed.appendingPathComponent("Curve.txt").path))

        writer.shouldFail = false
        let imported = try XCTUnwrap(
            context.manager.importPresets([source], collisionPolicy: .reject).imported.first
        )
        context.manager.select(.preset(imported.id))
        let originalBytes = try Data(contentsOf: imported.fileURL)

        writer.shouldFail = true
        XCTAssertFalse(context.manager.delete(imported))
        XCTAssertTrue(context.manager.presets.contains(imported))
        XCTAssertEqual(context.manager.selection, .preset(imported.id))
        XCTAssertEqual(try Data(contentsOf: imported.fileURL), originalBytes)
    }
}

@MainActor
private final class TestContext {
    let root: URL
    let managed: URL
    let sourceDirectory: URL
    let defaults: UserDefaults
    let securityScope = EqualizerSecurityScopeFake()
    let manager: EqualizerManager
    private let defaultsSuiteName: String

    init(manifestWriter: EqualizerManifestWriting = DefaultEqualizerManifestWriter()) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        managed = root.appendingPathComponent("Equalizer Presets", isDirectory: true)
        sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "EqualizerLibraryTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        manager = EqualizerManager(
            managedDirectory: managed,
            fileManager: .default,
            defaults: defaults,
            securityScope: securityScope,
            manifestWriter: manifestWriter
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    func writePreset(named name: String, preamp: Double?, directory: URL? = nil) throws -> URL {
        let directory = directory ?? sourceDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let contents = preamp.map { "Preamp: \($0) dB\n" } ?? "Include: invalid\n"
        try Data(contents.utf8).write(to: url)
        return url
    }
}

private final class EqualizerManifestWriterFake: EqualizerManifestWriting {
    var shouldFail = false

    func write(_ data: Data, to url: URL) throws {
        if shouldFail {
            throw NSError(domain: "EqualizerLibraryTests", code: 1)
        }
        try data.write(to: url, options: .atomic)
    }
}

private final class EqualizerSecurityScopeFake: EqualizerSecurityScopeAccessing {
    var startCount = 0
    var stopCount = 0

    func startAccessingSecurityScopedResource(for url: URL) -> Bool {
        startCount += 1
        return true
    }

    func stopAccessingSecurityScopedResource(for url: URL) {
        stopCount += 1
    }
}
