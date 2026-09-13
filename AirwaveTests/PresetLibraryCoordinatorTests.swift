import XCTest
@testable import Airwave

@MainActor
final class PresetLibraryCoordinatorTests: XCTestCase {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/preset-library-tests/\(name)")
    }

    private func makeCoordinator(
        _ manager: PresetLibraryManagerFake
    ) -> PresetLibraryCoordinator {
        PresetLibraryCoordinator(manager: manager, configuration: .equalizer)
    }

    func testRejectedFilesSurfaceAsOneMessageAndNothingImports() async {
        let manager = PresetLibraryManagerFake()
        let broken = url("broken.txt")
        manager.preflight = .init(acceptable: [], conflicts: [], rejected: [
            .init(filename: "broken.txt", reason: "unsupported directive")
        ])
        let coordinator = makeCoordinator(manager)

        coordinator.receive([broken])
        await coordinator.waitForIdle()

        XCTAssertEqual(coordinator.message?.text, "broken.txt: unsupported directive")
        XCTAssertEqual(manager.importCalls.count, 1)
        XCTAssertEqual(manager.importCalls.first?.urls, [])
        XCTAssertTrue(coordinator.conflicts.isEmpty)
    }

    func testConflictReplaceImportsWithReplacement() async {
        let manager = PresetLibraryManagerFake()
        let existing = url("Curve.txt")
        manager.preflight = .init(acceptable: [], conflicts: [existing], rejected: [])
        let coordinator = makeCoordinator(manager)

        coordinator.receive([existing])
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.conflicts, [existing])
        XCTAssertTrue(manager.importCalls.isEmpty)

        coordinator.resolveConflicts(.replace)
        await coordinator.waitForIdle()

        XCTAssertEqual(manager.importCalls.count, 1)
        XCTAssertEqual(manager.importCalls.first?.urls, [existing])
        XCTAssertEqual(manager.importCalls.first?.replacing, true)
        XCTAssertTrue(coordinator.conflicts.isEmpty)
        XCTAssertNil(coordinator.message)
    }

    func testConflictKeepExistingImportsWithoutReplacement() async {
        let manager = PresetLibraryManagerFake()
        let existing = url("Curve.txt")
        manager.preflight = .init(acceptable: [], conflicts: [existing], rejected: [])
        let coordinator = makeCoordinator(manager)

        coordinator.receive([existing])
        await coordinator.waitForIdle()
        coordinator.resolveConflicts(.keepExisting)
        await coordinator.waitForIdle()

        XCTAssertEqual(manager.importCalls.first?.replacing, false)
    }

    func testCancellingConflictsImportsNothingButKeepsPreflightFailures() async {
        let manager = PresetLibraryManagerFake()
        let existing = url("Curve.txt")
        manager.preflight = .init(
            acceptable: [],
            conflicts: [existing],
            rejected: [.init(filename: "broken.txt", reason: "unsupported directive")]
        )
        let coordinator = makeCoordinator(manager)

        coordinator.receive([existing, url("broken.txt")])
        await coordinator.waitForIdle()
        coordinator.resolveConflicts(.cancel)

        XCTAssertTrue(manager.importCalls.isEmpty)
        XCTAssertEqual(coordinator.message?.text, "broken.txt: unsupported directive")
        XCTAssertTrue(coordinator.conflicts.isEmpty)
    }

    func testDeleteConfirmDeletesAndClearsMessage() {
        let manager = PresetLibraryManagerFake()
        let coordinator = makeCoordinator(manager)
        let preset = FakePreset(id: "Curve", name: "Curve")

        XCTAssertTrue(coordinator.delete(manager.libraryDeletion(for: preset), decision: .confirm))

        XCTAssertEqual(manager.deleted, [preset])
        XCTAssertNil(coordinator.message)
    }

    func testDeleteCancelLeavesTheLibraryUntouched() {
        let manager = PresetLibraryManagerFake()
        let coordinator = makeCoordinator(manager)
        let preset = FakePreset(id: "Curve", name: "Curve")

        XCTAssertFalse(coordinator.delete(manager.libraryDeletion(for: preset), decision: .cancel))

        XCTAssertTrue(manager.deleted.isEmpty)
        XCTAssertNil(coordinator.message)
    }

    func testFailedDeleteReportsManagerDetailThenFallback() {
        let manager = PresetLibraryManagerFake()
        manager.deleteSucceeds = false
        manager.failureDetail = "Curve.txt: the managed file could not be read"
        let coordinator = makeCoordinator(manager)
        let preset = FakePreset(id: "Curve", name: "Curve")

        XCTAssertFalse(coordinator.delete(manager.libraryDeletion(for: preset), decision: .confirm))
        XCTAssertEqual(
            coordinator.message?.text,
            "Could not delete Curve.txt: the managed file could not be read"
        )

        manager.failureDetail = nil
        XCTAssertFalse(coordinator.delete(manager.libraryDeletion(for: preset), decision: .confirm))
        XCTAssertEqual(coordinator.message?.text, "Could not delete the managed preset.")
    }

    func testRowsPlaceNoneFirstAndSortOnlyWhenAsked() {
        let presets = [
            FakePreset(id: "b", name: "Zulu"),
            FakePreset(id: "a", name: "Alpha")
        ]

        let unsorted = PresetLibraryRowModel.rows(
            presets: presets, selectedID: "a", name: \.name, sortedByName: false
        )
        XCTAssertEqual(unsorted.map(\.name), ["None", "Zulu", "Alpha"])
        XCTAssertEqual(unsorted.map(\.isSelected), [false, false, true])

        let sorted = PresetLibraryRowModel.rows(
            presets: presets, selectedID: nil, name: \.name, sortedByName: true
        )
        XCTAssertEqual(sorted.map(\.name), ["None", "Alpha", "Zulu"])
        XCTAssertTrue(try XCTUnwrap(sorted.first).isSelected)
        XCTAssertTrue(PresetLibraryRowModel.rows(
            presets: [FakePreset](), selectedID: nil, name: \.name, sortedByName: true
        ).isEmpty)
    }

    func testNewRequestRejectsStalePreflightAndMainActorRemainsResponsive() async {
        let manager = PresetLibraryManagerFake()
        manager.suspendPreflight = true
        let old = url("Old.txt")
        let new = url("New.txt")
        manager.preflightsByURL[old] = .init(acceptable: [], conflicts: [old], rejected: [])
        manager.preflightsByURL[new] = .init(acceptable: [], conflicts: [new], rejected: [])
        let coordinator = makeCoordinator(manager)

        coordinator.receive([old])
        await Task.yield()
        coordinator.dismissMessage()
        coordinator.receive([new])
        await Task.yield()
        XCTAssertEqual(manager.preflightWaiters.count, 2)

        manager.resumePreflight(at: 1)
        await coordinator.waitForIdle()
        manager.resumePreflight(at: 0)
        await Task.yield()

        XCTAssertEqual(coordinator.conflicts, [new])
    }
}

private struct FakePreset: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
private final class PresetLibraryManagerFake: PresetLibraryManaging {
    var preflight = PresetLibraryPreflight(acceptable: [], conflicts: [], rejected: [])
    var preflightsByURL: [URL: PresetLibraryPreflight] = [:]
    var suspendPreflight = false
    var preflightWaiters: [CheckedContinuation<Void, Never>] = []
    var importFailures: [PresetLibraryFailure] = []
    var deleteSucceeds = true
    var failureDetail: String?
    private(set) var importCalls: [(urls: [URL], replacing: Bool)] = []
    private(set) var deleted: [FakePreset] = []
    private(set) var revealCount = 0

    func preflightLibraryImport(_ urls: [URL]) async -> PresetLibraryPreflight {
        if suspendPreflight {
            await withCheckedContinuation { preflightWaiters.append($0) }
        }
        return urls.first.flatMap { preflightsByURL[$0] } ?? preflight
    }

    func resumePreflight(at index: Int) {
        preflightWaiters[index].resume()
    }

    func importLibraryPresets(_ urls: [URL], replacingConflicts: Bool) async -> [PresetLibraryFailure] {
        importCalls.append((urls, replacingConflicts))
        return importFailures
    }

    func deleteLibraryPreset(_ preset: FakePreset) -> Bool {
        guard deleteSucceeds else { return false }
        deleted.append(preset)
        return true
    }

    func deletionFailureDetail(for preset: FakePreset) -> String? { failureDetail }

    func revealLibraryDirectory() { revealCount += 1 }
}
