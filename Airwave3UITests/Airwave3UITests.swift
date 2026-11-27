import XCTest

final class Airwave3UITests: XCTestCase {
    @MainActor
    func testFirstRunHidesMainControlsAndResumesSetup() throws {
        try withApp(setupPending: true) { app, _ in
            let capture = app.buttons["test-capture"]
            XCTAssertTrue(app.staticTexts["Welcome"].waitForExistence(timeout: 8))
            XCTAssertFalse(app.buttons["global-bypass"].exists)
            XCTAssertFalse(app.buttons["quit-host"].exists)
            XCTAssertFalse(app.buttons["exit-setup"].exists)

            app.buttons["setup-next"].click()
            XCTAssertTrue(capture.waitForExistence(timeout: 4))
            XCTAssertFalse(app.buttons["global-bypass"].exists)
            XCTAssertFalse(app.buttons["quit-host"].exists)

            app.terminate()
            app.launch()
            XCTAssertTrue(capture.waitForExistence(timeout: 8))
            XCTAssertFalse(app.buttons["quit-host"].exists)
        }
    }

    @MainActor
    func testTabFramesStayFixedAndTroubleshootingReturnsToSettings() throws {
        try withApp { app, _ in
            let tabIDs = ["effects", "app-mixer", "application-settings"]
            let tabs = tabIDs.map { app.buttons[$0] }
            let effectsHeading = app.staticTexts["Effect Chain"]
            let setup = app.buttons["setup-troubleshooting"]
            XCTAssertTrue(effectsHeading.waitForExistence(timeout: 8))
            let frames = tabs.map(\.frame)
            XCTAssertTrue(frames.allSatisfy { !$0.isEmpty })
            let globalPower = app.buttons["global-bypass"]
            XCTAssertTrue(globalPower.exists)
            XCTAssertLessThan(frames[2].maxX, globalPower.frame.minX)

            tabs[1].click()
            XCTAssertTrue(app.staticTexts["App Mixer"].waitForExistence(timeout: 4))
            XCTAssertEqual(tabs.map(\.frame), frames)

            tabs[2].click()
            XCTAssertTrue(setup.waitForExistence(timeout: 4))
            XCTAssertEqual(tabs.map(\.frame), frames)
            setup.click()
            let exitSetup = app.buttons["exit-setup"]
            XCTAssertTrue(exitSetup.waitForExistence(timeout: 4))
            XCTAssertEqual(app.buttons.matching(identifier: "quit-host").count, 1)
            exitSetup.click()
            XCTAssertTrue(setup.waitForExistence(timeout: 4))
            XCTAssertEqual(tabs.map(\.frame), frames)

            tabs[0].click()
            XCTAssertTrue(effectsHeading.waitForExistence(timeout: 4))
            XCTAssertEqual(tabs.map(\.frame), frames)
        }
    }

    @MainActor
    func testManageDevicesCanReturnWithoutChangingTheSelectedProfile() throws {
        try withApp(profiles: offlineProfile) { app, _ in
            let picker = app.descendants(matching: .any).matching(identifier: "current-output").firstMatch
            let liveOutput = app.buttons["live-output"]
            let manage = app.buttons["registered-devices"]
            let offline = app.buttons["edit-device.\(offlineDeviceID)"]
            XCTAssertTrue(picker.waitForExistence(timeout: 8))
            let previousDevice = try XCTUnwrap(picker.value as? String)

            manage.click()
            XCTAssertTrue(offline.waitForExistence(timeout: 4))
            app.buttons["back-to-effects"].click()
            XCTAssertTrue(picker.waitForExistence(timeout: 4))
            XCTAssertEqual(picker.value as? String, previousDevice)

            selectOfflineDevice(in: app)
            XCTAssertEqual(picker.value as? String, "Test Headphones")
            XCTAssertEqual(app.buttons["global-bypass"].value as? String, "Off")

            if previousDevice.hasSuffix(", live output") {
                XCTAssertTrue(liveOutput.exists)
                liveOutput.click()
                XCTAssertEqual(picker.value as? String, previousDevice)
            }
        }
    }

    @MainActor
    func testMixerEditsAndClearsSavedAdjustmentsWithMenuBarHidden() throws {
        let id = "test.mixer.browser"
        let adjustments = try plist([id: [
            "name": "Test Browser", "volume": 25.0, "isMuted": true, "bundleID": id,
        ]])
        try withApp(preferences: ["Host.AppMixer.Adjustments": adjustments]) { app, _ in
            let nav = app.buttons["app-mixer"]
            XCTAssertTrue(nav.waitForExistence(timeout: 8))
            nav.click()

            let mute = app.buttons["app-mixer-mute.\(id)"]
            let slider = app.sliders["app-mixer-volume.\(id)"]
            XCTAssertTrue(mute.waitForExistence(timeout: 5))
            XCTAssertEqual(mute.label, "Unmute Test Browser")
            XCTAssertEqual(app.buttons["global-bypass"].value as? String, "Off")
            let originalValue = String(describing: try XCTUnwrap(slider.value))
            slider.adjust(toNormalizedSliderPosition: 0.4)
            XCTAssertNotEqual(String(describing: try XCTUnwrap(slider.value)), originalValue)
            mute.click()
            XCTAssertEqual(mute.label, "Mute Test Browser")
            let savedValue = String(describing: try XCTUnwrap(slider.value))

            app.terminate()
            app.launch()
            XCTAssertTrue(nav.waitForExistence(timeout: 8))
            nav.click()
            XCTAssertTrue(mute.waitForExistence(timeout: 5))
            XCTAssertEqual(mute.label, "Mute Test Browser")
            XCTAssertEqual(String(describing: try XCTUnwrap(slider.value)), savedValue)
            app.staticTexts["app-mixer-name.\(id)"].rightClick()
            app.menuItems["Clear Saved Adjustment"].click()
            XCTAssertTrue(slider.waitForNonExistence(timeout: 4))
        }
    }

    @MainActor
    func testMenuBarReopensTheMainWindowAfterClosingIt() throws {
        try withApp(preferences: ["Host.Application.ShowInMenuBar": true]) { app, _ in
            let effectsHeading = app.staticTexts["Effect Chain"]
            XCTAssertTrue(effectsHeading.waitForExistence(timeout: 8))
            let close = app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow]
            XCTAssertTrue(close.exists)
            close.click()
            XCTAssertTrue(effectsHeading.waitForNonExistence(timeout: 4))
            XCTAssertNotEqual(app.state, .notRunning)

            let menu = app.statusItems.matching(NSPredicate(
                format: "identifier == %@ OR label == %@", "hostMenu", "Airwave"
            )).firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            menu.click()
            let open = app.buttons["Open Airwave"]
            XCTAssertTrue(open.waitForExistence(timeout: 4))
            XCTAssertFalse(app.buttons["Bypass Processing"].exists)
            open.click()
            XCTAssertTrue(effectsHeading.waitForExistence(timeout: 4))
        }
    }

    @MainActor
    func testAudioIssueOpensWithoutMovingTheEffectsControls() throws {
        try withApp(profiles: Data("Invalid profile data".utf8)) { app, profile in
            let effectsHeading = app.staticTexts["Effect Chain"]
            XCTAssertTrue(effectsHeading.waitForExistence(timeout: 8))
            let addEffect = app.buttons["add-effect"]
            let content = addEffect.exists ? addEffect : effectsHeading
            let contentFrame = content.frame
            let tabFrame = app.buttons["effects"].frame

            let issue = app.buttons["route-status"]
            XCTAssertEqual(issue.label, "Audio Issue")
            issue.click()
            XCTAssertTrue(app.staticTexts["notice-details"].waitForExistence(timeout: 4))
            XCTAssertEqual(content.frame, contentFrame)

            app.terminate()
            try plist([:]).write(to: profile)
            app.launch()
            XCTAssertTrue(content.waitForExistence(timeout: 8))
            XCTAssertFalse(issue.exists)
            XCTAssertEqual(content.frame, contentFrame)
            XCTAssertEqual(app.buttons["effects"].frame, tabFrame)
        }
    }

    @MainActor
    func testEmptyEffectSearchCanReturnToAudioUnits() throws {
        try withApp(profiles: offlineProfile) { app, _ in
            selectOfflineDevice(in: app)
            XCTAssertTrue(app.staticTexts["No effects yet"].waitForExistence(timeout: 4))

            app.buttons["add-effect"].click()
            let search = app.textFields["effect-search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.click()
            search.typeText("Nonexistent effect 7071")
            XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 4))

            app.buttons["Clear Search"].click()
            XCTAssertTrue(app.staticTexts["No matches"].waitForNonExistence(timeout: 4))
            app.typeText("AULowpass")
            XCTAssertEqual(search.value as? String, "AULowpass")
            app.buttons["Add AULowpass"].click()
            XCTAssertTrue(app.buttons["open-editor"].waitForExistence(timeout: 4))
            XCTAssertFalse(app.staticTexts["No effects yet"].exists)
        }
    }

    @MainActor
    func testDuplicateAudioUnitsCanBeDraggedByTheCardAndRestored() throws {
        try withApp(profiles: offlineProfile) { app, _ in
            selectOfflineDevice(in: app)
            addLowpass(to: app)
            addLowpass(to: app)
            let cards = app.buttons.matching(identifier: "open-editor")
            XCTAssertTrue(cards.element(boundBy: 1).waitForExistence(timeout: 5))
            XCTAssertEqual(cards.count, 2)
            XCTAssertEqual(cards.element(boundBy: 0).label, cards.element(boundBy: 1).label)

            let bypasses = app.buttons.matching(identifier: "bypass-effect")
            bypasses.element(boundBy: 0).click()
            XCTAssertTrue(bypasses.element(boundBy: 0).label.hasPrefix("Enable "))
            XCTAssertTrue(bypasses.element(boundBy: 1).label.hasPrefix("Bypass "))
            XCTAssertFalse(app.windows["AULowpass"].exists)

            let more = app.descendants(matching: .any).matching(identifier: "effect-actions").firstMatch
            more.click()
            XCTAssertTrue(app.menuItems["Move Down"].waitForExistence(timeout: 4))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertFalse(app.windows["AULowpass"].exists)

            let source = cards.element(boundBy: 0)
                .coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.4))
            let target = cards.element(boundBy: 1)
                .coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.7))
            let outsideChain = app.buttons["effects"]
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            source.click(forDuration: 0.25, thenDragTo: outsideChain, withVelocity: .slow, thenHoldForDuration: 0.25)
            XCTAssertTrue(bypasses.element(boundBy: 0).label.hasPrefix("Enable "))
            XCTAssertFalse(app.windows["AULowpass"].exists)

            source.click(forDuration: 0.25, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.4)
            let moved = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label BEGINSWITH %@", "Enable "),
                object: bypasses.element(boundBy: 1)
            )
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 4), .completed)
            XCTAssertTrue(bypasses.element(boundBy: 0).label.hasPrefix("Bypass "))
            XCTAssertFalse(app.windows["AULowpass"].exists)

            cards.element(boundBy: 1).click()
            let editor = app.windows["AULowpass"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            XCTAssertEqual(editor.buttons["editor-bypass-effect"].value as? String, "Off")

            app.terminate()
            app.launch()
            selectOfflineDevice(in: app)
            XCTAssertTrue(bypasses.element(boundBy: 1).waitForExistence(timeout: 4))
            XCTAssertTrue(bypasses.element(boundBy: 1).label.hasPrefix("Enable "))
            XCTAssertTrue(bypasses.element(boundBy: 0).label.hasPrefix("Bypass "))
        }
    }

    @MainActor
    func testEffectCardAndControlsShareTheSamePowerState() throws {
        try withApp(profiles: offlineProfile) { app, _ in
            selectOfflineDevice(in: app)
            addLowpass(to: app)
            let mainWindow = app.windows["Airwave"]
            let cardPower = mainWindow.buttons["bypass-effect"]
            XCTAssertTrue(cardPower.waitForExistence(timeout: 5))
            mainWindow.buttons["open-editor"].click()

            let editor = app.windows["AULowpass"]
            let editorPower = editor.buttons["editor-bypass-effect"]
            let editorTitle = editor.staticTexts["editor-effect-title"]
            XCTAssertTrue(editorPower.waitForExistence(timeout: 8))
            XCTAssertEqual(editorTitle.label, "AULowpass")
            let titleFrame = editorTitle.frame
            let powerFrame = editorPower.frame
            XCTAssertLessThan(titleFrame.maxX, powerFrame.minX)
            editorPower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            XCTAssertEqual(editorTitle.frame, titleFrame)
            XCTAssertEqual(editorPower.frame, powerFrame)

            XCTAssertEqual(editorPower.value as? String, "On")
            editorPower.click()
            XCTAssertEqual(editorPower.value as? String, "Off")
            XCTAssertEqual(cardPower.value as? String, "Off")
            XCTAssertEqual(editorTitle.frame, titleFrame)
            XCTAssertEqual(editorPower.frame, powerFrame)

            mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.03)).click()
            cardPower.click()
            XCTAssertEqual(cardPower.value as? String, "On")
            XCTAssertEqual(editorPower.value as? String, "On")
        }
    }

    @MainActor
    func testMissingEqualizerPresetCanBeRestoredFromTheAudioUnitControls() throws {
        let component = ["type": 0x61756678, "subtype": 0x45714150, "manufacturer": 0x536E6866]
        let profiles = try plist([offlineDeviceID: ["name": "Test Headphones", "slots": [[
            "id": UUID().uuidString, "component": component, "name": "Equalizer", "manufacturer": "Airwave",
            "isBypassed": true, "migrationIssue": "The Airwave 2 preset is unavailable.",
        ]]]])
        try withApp(profiles: profiles) { app, profile in
            selectOfflineDevice(in: app)
            let issue = app.buttons["effect-issue"]
            let controls = app.buttons["open-editor"]
            XCTAssertTrue(issue.waitForExistence(timeout: 4))
            XCTAssertTrue(controls.exists)
            XCTAssertFalse(app.buttons["open-presets"].exists)

            controls.click()
            let editor = app.windows["Equalizer"]
            XCTAssertTrue(editor.waitForExistence(timeout: 8))
            let power = editor.buttons["editor-bypass-effect"]
            XCTAssertTrue(power.exists)
            XCTAssertFalse(power.isEnabled)
            let picker = editor.descendants(matching: .any).matching(identifier: "eq-presets").firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            picker.click()
            let replacement = editor.descendants(matching: .any).matching(identifier: "Bass Booster").firstMatch
            XCTAssertTrue(replacement.waitForExistence(timeout: 4))
            replacement.click()
            XCTAssertTrue(issue.waitForNonExistence(timeout: 5))
            XCTAssertTrue(power.isEnabled)
            XCTAssertEqual(power.value as? String, "On")

            let bytes = try Data(contentsOf: profile)
            let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
            let device = try XCTUnwrap(saved[offlineDeviceID] as? [String: Any])
            let slots = try XCTUnwrap(device["slots"] as? [[String: Any]])
            let state = try XCTUnwrap(slots.first?["state"] as? Data)
            let preset = try XCTUnwrap(PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any])
            XCTAssertEqual(preset["Equalizer.presetName"] as? String, "Bass Booster")
            XCTAssertEqual(slots.first?["isBypassed"] as? Bool, false)
            XCTAssertNil(slots.first?["migrationIssue"])
        }
    }

    private let offlineDeviceID = "test.offline.headphones"

    private var offlineProfile: Data {
        get throws {
            try plist([offlineDeviceID: ["name": "Test Headphones", "slots": [] as [String]]])
        }
    }

    @MainActor
    private func selectOfflineDevice(in app: XCUIApplication) {
        let picker = app.descendants(matching: .any).matching(identifier: "current-output").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        if picker.value as? String != "Test Headphones" {
            app.buttons["registered-devices"].click()
            let offline = app.buttons["edit-device.\(offlineDeviceID)"]
            XCTAssertTrue(offline.waitForExistence(timeout: 4))
            offline.click()
            XCTAssertTrue(picker.waitForExistence(timeout: 4))
        }
        XCTAssertEqual(picker.value as? String, "Test Headphones")
    }

    @MainActor
    private func addLowpass(to app: XCUIApplication) {
        app.buttons["add-effect"].click()
        let search = app.textFields["effect-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("AULowpass")
        let component = app.buttons["Add AULowpass"]
        XCTAssertTrue(component.waitForExistence(timeout: 5), "The Apple AULowpass effect should be available.")
        component.click()
    }

    @MainActor
    private func withApp(
        setupPending: Bool = false,
        preferences: [String: Any] = [:],
        profiles: Data? = nil,
        run: (XCUIApplication, URL) throws -> Void
    ) throws {
        continueAfterFailure = false
        let scratch = FileManager.default.temporaryDirectory.appending(path: "airwave-ui-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let profile = scratch.appending(path: "profiles.plist")
        try profiles?.write(to: profile)
        var values = preferences
        values["ProcessingEnabled"] = false
        try plist(values).write(to: profile.appendingPathExtension("preferences"))

        let app = XCUIApplication()
        app.launchEnvironment["SYSTEM_AUDIO_HOST_TEST_PROFILE"] = profile.path
        if setupPending {
            app.launchEnvironment["SYSTEM_AUDIO_HOST_TEST_SETUP"] = "pending"
        }
        app.launch()
        defer { app.terminate() }
        try run(app, profile)
    }

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
}
