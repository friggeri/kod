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
        XCTAssertTrue(app.staticTexts["workspace.root"].exists)

        let trustButton = app.buttons["workspace.trust"]
        XCTAssertTrue(trustButton.exists)
        trustButton.click()
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
        XCTAssertTrue(firstCloseButton.waitForExistence(timeout: 5))

        app.staticTexts["Second.swift"].click()
        XCTAssertTrue(app.buttons["tab.close.Second.swift"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab.close.First.swift"].exists)
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
                app.buttons.matching(identifier: "editorGroup.back").count == expectedCount
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

        let tabCloseButton = app.buttons["tab.close.Sources/Pane.swift"]
        XCTAssertTrue(tabCloseButton.waitForExistence(timeout: 5))

        app.buttons["editorGroup.splitRight"].firstMatch.click()
        waitForGroupCount(2)

        tabCloseButton.click()
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "exists == false"),
                        object: tabCloseButton
                    )
                ],
                timeout: 5
            ),
            .completed
        )

        let splitDownButtons = app.buttons.matching(identifier: "editorGroup.splitDown")
        splitDownButtons.element(boundBy: splitDownButtons.count - 1).click()
        waitForGroupCount(3)

        let closeGroupButtons = app.buttons.matching(identifier: "editorGroup.closeGroup")
        closeGroupButtons.element(boundBy: closeGroupButtons.count - 1).click()
        waitForGroupCount(2)

        closeGroupButtons.element(boundBy: closeGroupButtons.count - 1).click()
        waitForGroupCount(1)

        app.terminate()
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
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

        // Back should return to Alpha, Forward should return to Beta.
        let backButton = app.buttons["editorGroup.back"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        XCTAssertTrue(backButton.isEnabled)
        backButton.click()
        waitForDocumentPath(containing: "Alpha.swift")

        let forwardButton = app.buttons["editorGroup.forward"].firstMatch
        XCTAssertTrue(forwardButton.isEnabled)
        forwardButton.click()
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
        let splitRightButton = app.buttons["editorGroup.splitRight"].firstMatch
        XCTAssertTrue(splitRightButton.waitForExistence(timeout: 5))
        splitRightButton.click()
        XCTAssertEqual(app.buttons.matching(identifier: "editorGroup.back").count, 2)

        // The new group starts empty; open Alpha into it too, so both groups
        // have live tabs to restore across relaunch.
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
        XCTAssertEqual(relaunched.buttons.matching(identifier: "editorGroup.back").count, 2)
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
