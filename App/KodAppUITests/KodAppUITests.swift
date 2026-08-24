import XCTest

@MainActor
final class KodAppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testWelcomeWindowLaunchesWithVisibleCommands() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows["Kod"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["welcome.title"].exists)
        XCTAssertTrue(app.staticTexts["welcome.buildInfo"].exists)

        let openFolder = app.buttons["welcome.openFolder"]
        let openFile = app.buttons["welcome.openFile"]
        let openRecent = app.buttons["welcome.openRecent"]

        XCTAssertTrue(openFolder.exists)
        XCTAssertTrue(openFile.exists)
        XCTAssertTrue(openRecent.exists)
        XCTAssertTrue(openFolder.isEnabled)
        XCTAssertTrue(openFile.isEnabled)
    }

    func testSettingsSidebarNavigatesBetweenFontAndLanguages() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows["Kod"].waitForExistence(timeout: 5))

        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["settings.window"]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 5),
            app.debugDescription
        )

        XCTAssertFalse(
            settingsWindow.searchFields[
                "settings.languageSupport.search"
            ].exists
        )
        let cRow = settingsWindow.descendants(matching: .any)[
            "settings.languageSupport.c.row"
        ]
        XCTAssertTrue(cRow.waitForExistence(timeout: 5))
        cRow.click()
        XCTAssertTrue(
            settingsWindow.staticTexts["Status"]
                .waitForExistence(timeout: 5),
            settingsWindow.debugDescription
        )
        XCTAssertFalse(settingsWindow.buttons["Toggle Sidebar"].exists)

        let fontRow = settingsWindow.descendants(matching: .any)[
            "settings.font.row"
        ]
        XCTAssertTrue(fontRow.waitForExistence(timeout: 5))
        fontRow.click()
        XCTAssertTrue(
            settingsWindow.descendants(matching: .any)["settings.ligatures"]
                .waitForExistence(timeout: 5),
            settingsWindow.debugDescription
        )
        let fontSizeStepper = settingsWindow.steppers["Font size"]
        XCTAssertTrue(fontSizeStepper.waitForExistence(timeout: 5))
        let initialFontSize = String(describing: fontSizeStepper.value)
        let increment = fontSizeStepper.descendants(
            matching: .incrementArrow
        ).firstMatch
        let decrement = fontSizeStepper.descendants(
            matching: .decrementArrow
        ).firstMatch
        XCTAssertTrue(increment.exists)
        XCTAssertTrue(decrement.exists)
        let changingArrow = increment.isEnabled ? increment : decrement
        let restoringArrow = increment.isEnabled ? decrement : increment
        changingArrow.click()
        let fontSizeChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                String(describing: fontSizeStepper.value) != initialFontSize
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [fontSizeChanged], timeout: 2),
            .completed
        )
        restoringArrow.click()
        XCTAssertFalse(settingsWindow.radioButtons["Font"].exists)
        XCTAssertFalse(settingsWindow.radioButtons["Languages"].exists)
        XCTAssertFalse(settingsWindow.radioButtons["Diagnostics"].exists)
    }

    func testLanguageSidebarShowsStatusAndSelectionWithoutSearch() {
        let app = XCUIApplication()
        app.launch()
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["settings.window"]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 5),
            app.debugDescription
        )

        XCTAssertFalse(
            settingsWindow.searchFields[
                "settings.languageSupport.search"
            ].exists
        )
        let cRow = settingsWindow.descendants(matching: .any)[
            "settings.languageSupport.c.row"
        ]
        XCTAssertTrue(cRow.waitForExistence(timeout: 5))
        cRow.click()
        XCTAssertTrue(
            settingsWindow.staticTexts["Status"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            settingsWindow.descendants(matching: .any)[
                "settings.languageSupport.css.row"
            ].waitForExistence(timeout: 5)
        )
    }

    func testLanguageDetailContainsOnlyServerConfiguration() {
        let app = XCUIApplication()
        app.launch()
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["settings.window"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        let cRow = settingsWindow.descendants(matching: .any)[
            "settings.languageSupport.c.row"
        ]
        XCTAssertTrue(cRow.waitForExistence(timeout: 5))
        cRow.click()

        XCTAssertTrue(
            settingsWindow.staticTexts["Status"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            settingsWindow.buttons[
                "settings.languageSupport.editFileTypes"
            ].exists
        )
        XCTAssertFalse(
            settingsWindow.checkBoxes[
                "settings.languageSupport.serverEnabled"
            ].exists
        )
        let command = settingsWindow.textFields[
            "settings.languageSupport.command"
        ]
        XCTAssertTrue(command.exists, settingsWindow.debugDescription)
        XCTAssertEqual(command.label, "Command")
    }

    func testOpeningAndTypingNeverChangesSourceFile() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Fixtures/SmallWorkspace/Sources/Hello.swift")
        let originalData = try Data(contentsOf: sourceURL)

        let app = XCUIApplication()
        app.launchArguments = ["--open-file", sourceURL.path]
        app.launch()

        let viewport = app.textViews["code.viewport"]
        XCTAssertTrue(
            viewport.waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCTAssertTrue(app.staticTexts["document.path"].exists)

        viewport.click()
        viewport.typeText("this must never be inserted")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        app.terminate()

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
    }

    func testWorkspaceQuickOpenAndTrustNeverChangeFiles() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )
        let sourceURL = sources.appendingPathComponent("Hello.swift")
        let originalData = Data("let message = \"hello\"\n".utf8)
        try originalData.write(to: sourceURL)
        addTeardownBlock {
            try FileManager.default.removeItem(at: workspace)
        }

        let app = XCUIApplication()
        app.launchArguments = ["--open-folder", workspace.path]
        app.launch()

        XCTAssertTrue(app.outlines["workspace.explorer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.firstMatch.title, workspace.lastPathComponent)

        let trustButton = app.buttons["workspace.trust"]
        XCTAssertTrue(trustButton.exists)
        trustButton.click()
        let dismissTrustButton = app.buttons["workspace.trustDismiss"]
        XCTAssertTrue(dismissTrustButton.exists)
        dismissTrustButton.click()
        XCTAssertFalse(trustButton.exists)

        app.typeKey("p", modifierFlags: .command)
        let search = app.searchFields["quickOpen.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Hello")

        let result = app.staticTexts["Sources/Hello.swift"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textViews["code.viewport"].waitForExistence(timeout: 5))
        app.terminate()

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
    }

    func testExplorerClicksOpenPersistentTabs() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let firstURL = workspace.appendingPathComponent("First.swift")
        let secondURL = workspace.appendingPathComponent("Second.swift")
        let firstData = Data("struct First {}\n".utf8)
        let secondData = Data("struct Second {}\n".utf8)
        try firstData.write(to: firstURL)
        try secondData.write(to: secondURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workspace)
        }

        let app = XCUIApplication()
        app.launchArguments = ["--open-folder", workspace.path]
        app.launch()

        XCTAssertTrue(app.outlines["workspace.explorer"].waitForExistence(timeout: 5))
        let firstFile = app.staticTexts["First.swift"]
        firstFile.click()
        let firstTabTitle = app.buttons["tab.title.First.swift"]
        XCTAssertTrue(firstTabTitle.waitForExistence(timeout: 5))
        firstTabTitle.hover()
        let firstCloseButton = app.buttons["tab.close.First.swift"]
        XCTAssertTrue(firstCloseButton.waitForExistence(timeout: 5))

        firstCloseButton.click()
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "exists == false"),
                        object: firstCloseButton
                    )
                ],
                timeout: 5
            ),
            .completed
        )
        firstFile.click()
        XCTAssertTrue(firstTabTitle.waitForExistence(timeout: 5))

        app.staticTexts["Second.swift"].click()
        let secondTabTitle = app.buttons["tab.title.Second.swift"]
        XCTAssertTrue(secondTabTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(firstTabTitle.exists)
        secondTabTitle.hover()
        XCTAssertTrue(app.buttons["tab.close.Second.swift"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tab.pin.First.swift"].exists)
        XCTAssertFalse(app.buttons["tab.pin.Second.swift"].exists)

        app.terminate()
        XCTAssertEqual(try Data(contentsOf: firstURL), firstData)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondData)
    }

    func testSplitPaneControlsRemainClickableAndCanUnsplit() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let sourceURL = sources.appendingPathComponent("Pane.swift")
        let originalData = Data("struct Pane {}\n".utf8)
        try originalData.write(to: sourceURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workspace)
        }

        let app = XCUIApplication()
        app.launchArguments = ["--open-folder", workspace.path]
        app.launch()

        func waitForGroupCount(_ expectedCount: Int) {
            let predicate = NSPredicate { _, _ in
                app.groups.matching(identifier: "editorGroup.container").count == expectedCount
            }
            XCTAssertEqual(
                XCTWaiter().wait(
                    for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)],
                    timeout: 5
                ),
                .completed
            )
        }

        XCTAssertTrue(app.outlines["workspace.explorer"].waitForExistence(timeout: 5))
        app.typeKey("p", modifierFlags: .command)
        let search = app.searchFields["quickOpen.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Pane")
        search.typeKey(.return, modifierFlags: [])

        let tabTitle = app.buttons["tab.title.Sources/Pane.swift"]
        XCTAssertTrue(tabTitle.waitForExistence(timeout: 5))
        tabTitle.hover()
        let tabCloseButton = app.buttons["tab.close.Sources/Pane.swift"]
        XCTAssertTrue(tabCloseButton.waitForExistence(timeout: 5))

        app.buttons["Split Right"].click()
        waitForGroupCount(2)
        XCTAssertEqual(
            app.buttons.matching(identifier: "tab.title.Sources/Pane.swift").count,
            2,
            "Splitting should open the current file in both panes"
        )

        let duplicatedTitles = app.buttons.matching(
            identifier: "tab.title.Sources/Pane.swift"
        ).allElementsBoundByIndex
        let rightTabTitle = try XCTUnwrap(
            duplicatedTitles.max { $0.frame.minX < $1.frame.minX }
        )
        rightTabTitle.hover()
        let closeButtons = app.buttons.matching(
            identifier: "tab.close.Sources/Pane.swift"
        )
        XCTAssertTrue(closeButtons.firstMatch.waitForExistence(timeout: 5))
        let rightCloseButton = try XCTUnwrap(
            closeButtons.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX }
        )
        rightCloseButton.click()
        waitForGroupCount(1)

        app.buttons["Split Down"].click()
        waitForGroupCount(2)
        XCTAssertEqual(
            app.buttons.matching(identifier: "tab.title.Sources/Pane.swift").count,
            2
        )

        app.menuItems["Close Editor Group"].click()
        waitForGroupCount(1)

        app.terminate()
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
    }

    func testTabDragReordersFromTheTitleAcrossTheRail() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for name in ["First.swift", "Second.swift", "Third.swift"] {
            try Data("struct \(name.dropLast(6)) {}\n".utf8).write(
                to: workspace.appendingPathComponent(name)
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workspace)
        }

        let app = XCUIApplication()
        app.launchArguments = ["--open-folder", workspace.path]
        app.launch()
        XCTAssertTrue(app.outlines["workspace.explorer"].waitForExistence(timeout: 5))

        for name in ["First", "Second", "Third"] {
            app.typeKey("p", modifierFlags: .command)
            let search = app.searchFields["quickOpen.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.typeText(name)
            search.typeKey(.return, modifierFlags: [])
        }

        let first = app.buttons["tab.title.First.swift"]
        let second = app.buttons["tab.title.Second.swift"]
        let third = app.buttons["tab.title.Third.swift"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        XCTAssertTrue(third.exists)
        XCTAssertLessThan(first.frame.minX, second.frame.minX)
        XCTAssertLessThan(second.frame.minX, third.frame.minX)

        first.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).press(
            forDuration: 0.1,
            thenDragTo: third.coordinate(
                withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)
            )
        )
        let reordered = NSPredicate { _, _ in
            second.frame.minX < third.frame.minX && third.frame.minX < first.frame.minX
        }
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(predicate: reordered, object: nil)],
                timeout: 5
            ),
            .completed,
            "Expected First to settle after Third; frames: \(first.frame), \(second.frame), \(third.frame)"
        )
        XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 1)
        XCTAssertEqual(second.frame.midY, third.frame.midY, accuracy: 1)

        app.terminate()
    }

    func testTabDragMovesBetweenPanesAndEmptyPanesCollapse() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for name in ["First.swift", "Second.swift"] {
            try Data("struct \(name.dropLast(6)) {}\n".utf8).write(
                to: workspace.appendingPathComponent(name)
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workspace)
        }

        let app = XCUIApplication()
        app.launchArguments = ["--open-folder", workspace.path]
        app.launch()
        XCTAssertTrue(app.outlines["workspace.explorer"].waitForExistence(timeout: 5))

        func openViaQuickOpen(_ query: String) {
            app.typeKey("p", modifierFlags: .command)
            let search = app.searchFields["quickOpen.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.typeText(query)
            search.typeKey(.return, modifierFlags: [])
        }

        func waitForGroupCount(_ expectedCount: Int) {
            let predicate = NSPredicate { _, _ in
                app.groups.matching(identifier: "editorGroup.container").count == expectedCount
            }
            XCTAssertEqual(
                XCTWaiter().wait(
                    for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)],
                    timeout: 5
                ),
                .completed
            )
        }

        func groupFrames() -> [CGRect] {
            app.groups.matching(identifier: "editorGroup.container")
                .allElementsBoundByIndex
                .map(\.frame)
                .sorted { $0.minX < $1.minX }
        }

        func assertGroupFrames(
            _ actual: [CGRect],
            equal expected: [CGRect],
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(actual.count, expected.count, file: file, line: line)
            for (actualFrame, expectedFrame) in zip(actual, expected) {
                XCTAssertEqual(actualFrame.minX, expectedFrame.minX, accuracy: 1, file: file, line: line)
                XCTAssertEqual(actualFrame.width, expectedFrame.width, accuracy: 1, file: file, line: line)
            }
        }

        openViaQuickOpen("First")
        XCTAssertTrue(app.buttons["tab.title.First.swift"].waitForExistence(timeout: 5))
        app.buttons["Split Right"].click()
        waitForGroupCount(2)
        let splitFrames = groupFrames()

        let firstTabs = app.buttons.matching(identifier: "tab.title.First.swift")
        XCTAssertEqual(firstTabs.count, 2)
        let leftFirst = try XCTUnwrap(
            firstTabs.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }
        )
        leftFirst.click()
        openViaQuickOpen("Second")

        let second = app.buttons["tab.title.Second.swift"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        assertGroupFrames(groupFrames(), equal: splitFrames)
        let rightFirst = try XCTUnwrap(
            firstTabs.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX }
        )
        second.click(forDuration: 0.1, thenDragTo: rightFirst)

        let movedToRight = NSPredicate { _, _ in
            second.exists && second.frame.midX > app.windows.firstMatch.frame.midX
        }
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(predicate: movedToRight, object: nil)],
                timeout: 5
            ),
            .completed
        )
        waitForGroupCount(2)
        assertGroupFrames(groupFrames(), equal: splitFrames)

        second.hover()
        let secondClose = app.buttons["tab.close.Second.swift"]
        XCTAssertTrue(secondClose.waitForExistence(timeout: 5))
        secondClose.click()

        let currentFirstTabs = app.buttons.matching(identifier: "tab.title.First.swift")
        let rightRemainingFirst = try XCTUnwrap(
            currentFirstTabs.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX }
        )
        rightRemainingFirst.hover()
        let firstCloseButtons = app.buttons.matching(identifier: "tab.close.First.swift")
        XCTAssertTrue(firstCloseButtons.firstMatch.waitForExistence(timeout: 5))
        let rightClose = try XCTUnwrap(
            firstCloseButtons.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX }
        )
        rightClose.click()
        waitForGroupCount(1)

        let lastFirst = app.buttons["tab.title.First.swift"]
        XCTAssertTrue(lastFirst.waitForExistence(timeout: 5))
        lastFirst.hover()
        let lastClose = app.buttons["tab.close.First.swift"]
        XCTAssertTrue(lastClose.waitForExistence(timeout: 5))
        lastClose.click()
        waitForGroupCount(1)
        XCTAssertFalse(app.buttons["tab.title.First.swift"].exists)

        app.terminate()
    }

    func testWorkspaceWindowChromeAndSidebarToggle() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("Chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("struct Chrome {}\n".utf8).write(
            to: workspace.appendingPathComponent("Chrome.swift")
        )
        try Data("# Chrome\n".utf8).write(
            to: workspace.appendingPathComponent("README.md")
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workspace)
        }

        let app = XCUIApplication()
        app.launchArguments = ["--open-folder", workspace.path]
        app.launch()

        let outline = app.outlines["workspace.explorer"]
        let directoryName = app.staticTexts["workspace.directoryName"]
        let sidebarToggle = app.buttons["Toggle Sidebar"]
        let splitRightButton = app.buttons["Split Right"]
        let splitDownButton = app.buttons["Split Down"]
        let window = app.windows.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 5))
        XCTAssertTrue(directoryName.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(splitRightButton.waitForExistence(timeout: 5))
        XCTAssertTrue(splitDownButton.waitForExistence(timeout: 5))
        XCTAssertEqual(directoryName.label, workspace.lastPathComponent)
        XCTAssertEqual(directoryName.frame.midX, window.frame.midX, accuracy: 3)
        XCTAssertGreaterThan(splitRightButton.frame.minX, directoryName.frame.maxX)
        XCTAssertEqual(splitRightButton.frame.midY, splitDownButton.frame.midY, accuracy: 1)
        XCTAssertFalse(app.buttons["editorGroup.previewSourceToggle"].exists)

        let readme = outline.staticTexts["README.md"]
        XCTAssertTrue(readme.waitForExistence(timeout: 5))
        readme.doubleClick()
        let previewSourceToggle = app.buttons["View Source"]
        XCTAssertTrue(
            previewSourceToggle.waitForExistence(timeout: 5),
            app.toolbars.debugDescription
        )
        XCTAssertEqual(previewSourceToggle.label, "View Source")
        XCTAssertLessThan(previewSourceToggle.frame.minX, splitRightButton.frame.minX)
        XCTAssertEqual(previewSourceToggle.frame.midY, splitRightButton.frame.midY, accuracy: 1)
        previewSourceToggle.click()
        XCTAssertTrue(app.buttons["View Preview"].waitForExistence(timeout: 5))

        sidebarToggle.click()
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "exists == false"),
                        object: outline
                    )
                ],
                timeout: 5
            ),
            .completed
        )
        XCTAssertTrue(directoryName.exists)
        XCTAssertEqual(directoryName.frame.midX, window.frame.midX, accuracy: 3)

        sidebarToggle.click()
        XCTAssertTrue(outline.waitForExistence(timeout: 5))
        app.terminate()
    }

    /// End-to-end Phase 3 vertical slice: opening two files as tabs, Back/
    /// Forward navigation between them, Find in File, Go to Line, splitting
    /// the editor into two groups, and relaunching to confirm the tab/split
    /// layout was restored from external metadata — all while proving the
    /// on-disk fixture bytes never change.
    func testOpenFindSplitNavigateAndRelaunchPreservesLayoutWithoutMutatingFixtures() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )

        let alphaURL = sources.appendingPathComponent("Alpha.swift")
        let alphaData = Data(
            """
            // Alpha fixture
            struct Alpha {
                let alphaMark = "ALPHAMARK one"
                let other = "ALPHAMARK two"
            }

            """.utf8
        )
        try alphaData.write(to: alphaURL)

        let betaURL = sources.appendingPathComponent("Beta.swift")
        let betaData = Data(
            """
            // Beta fixture
            struct Beta {
                let betaMark = "BETAMARK one"
                let another = "BETAMARK two"
                let third = "BETAMARK three"
            }

            """.utf8
        )
        try betaData.write(to: betaURL)

        addTeardownBlock {
            try? FileManager.default.removeItem(at: workspace)
        }

        func assertFixtureBytesUnchanged() throws {
            XCTAssertEqual(try Data(contentsOf: alphaURL), alphaData)
            XCTAssertEqual(try Data(contentsOf: betaURL), betaData)
        }

        let app = XCUIApplication()
        app.launchArguments = ["--open-folder", workspace.path]
        app.launch()

        XCTAssertTrue(app.outlines["workspace.explorer"].waitForExistence(timeout: 5))
        let trustButton = app.buttons["workspace.trust"]
        if trustButton.exists {
            trustButton.click()
        }

        func openViaQuickOpen(_ query: String) {
            app.typeKey("p", modifierFlags: .command)
            let search = app.searchFields["quickOpen.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.typeText(query)
            search.typeKey(.return, modifierFlags: [])
        }

        func waitForDocumentPath(containing substring: String, file: StaticString = #filePath, line: UInt = #line) {
            let predicate = NSPredicate { _, _ in
                (app.staticTexts["document.path"].firstMatch.value as? String)?.contains(substring) == true
            }
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
            let result = XCTWaiter().wait(for: [expectation], timeout: 5)
            let actual = app.staticTexts["document.path"].firstMatch.value as? String ?? "<none>"
            XCTAssertEqual(
                result,
                .completed,
                "Expected document.path to contain \(substring), actual: \(actual)",
                file: file,
                line: line
            )
        }

        // Open both files as pinned tabs in the (single, initial) group.
        openViaQuickOpen("Alpha")
        XCTAssertTrue(app.buttons["Alpha.swift"].waitForExistence(timeout: 5))
        waitForDocumentPath(containing: "Alpha.swift")

        openViaQuickOpen("Beta")
        XCTAssertTrue(app.buttons["Beta.swift"].waitForExistence(timeout: 5))
        waitForDocumentPath(containing: "Beta.swift")

        // Navigation remains available from its standard keyboard commands
        // even though the redundant header buttons are intentionally absent.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        waitForDocumentPath(containing: "Alpha.swift")

        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        waitForDocumentPath(containing: "Beta.swift")

        // Find in File on Beta.swift: default (case-insensitive) plain-text
        // search for "BETAMARK" also matches the lowercase "betaMark"
        // identifier, for four total occurrences.
        app.typeKey("f", modifierFlags: .command)
        let findField = app.searchFields["find.query"]
        XCTAssertTrue(findField.waitForExistence(timeout: 5))
        findField.typeText("BETAMARK")
        let matchCount = app.staticTexts["find.matchCount"]
        XCTAssertTrue(matchCount.waitForExistence(timeout: 5))
        let matchCountValue = try XCTUnwrap(matchCount.value as? String)
        XCTAssertEqual(matchCountValue, "1 of 4")

        // Toggling case-sensitive mode narrows the match to the three
        // uppercase "BETAMARK" string-literal occurrences only.
        app.checkBoxes["find.matchCase"].click()
        let caseSensitiveMatchCountValue = try XCTUnwrap(matchCount.value as? String)
        XCTAssertEqual(caseSensitiveMatchCountValue, "1 of 3")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.searchFields["find.query"].exists)

        // Go to Line: opens and dismisses without disturbing the document.
        app.typeKey("g", modifierFlags: .control)
        let lineField = app.textFields["goToLine.field"]
        XCTAssertTrue(lineField.waitForExistence(timeout: 5))
        lineField.typeText("3")
        app.buttons["goToLine.submit"].click()
        XCTAssertFalse(app.textFields["goToLine.field"].exists)

        // Split Right: a second, independently navigable editor group appears.
        let splitRightButton = app.buttons["Split Right"]
        XCTAssertTrue(splitRightButton.waitForExistence(timeout: 5))
        splitRightButton.click()
        XCTAssertEqual(app.groups.matching(identifier: "editorGroup.container").count, 2)

        // The new group starts with Beta, the current file. Open Alpha there
        // too, so both groups have that tab to restore across relaunch.
        openViaQuickOpen("Alpha")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "title == 'Alpha.swift'")).count, 2)

        // Word Wrap toggles via the View menu without crashing or mutating files.
        app.menuItems["Word Wrap"].click()

        try assertFixtureBytesUnchanged()

        // Quit (triggering windowWillClose persistence) and relaunch: tabs
        // and the split layout must be restored from external metadata.
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["--open-folder", workspace.path]
        relaunched.launch()

        XCTAssertTrue(relaunched.outlines["workspace.explorer"].waitForExistence(timeout: 5))
        XCTAssertEqual(relaunched.groups.matching(identifier: "editorGroup.container").count, 2)
        XCTAssertTrue(
            relaunched.buttons["Beta.swift"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            relaunched.buttons.matching(NSPredicate(format: "title == 'Alpha.swift'")).count,
            2
        )
        relaunched.terminate()

        try assertFixtureBytesUnchanged()
    }
}
