//
//  CavernSeerUITests.swift
//  CavernSeerUITests
//
//  Created by Samuel Grush on 6/27/20.
//  Copyright © 2020 Samuel K. Grush. All rights reserved.
//

import XCTest

class CavernSeerUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use recording to get started writing UI tests.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTOSSignpostMetric.applicationLaunch]) {
                XCUIApplication().launch()
            }
        }
    }
}

extension CavernSeerUITests {
    private func seededRow(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["scan-row-" + id].firstMatch
    }

    func testSeededScanRenderAndBackup() throws {
        let app = XCUIApplication()
        app.launch()
        let row = seededRow("review_alpha", in: app)
        guard row.waitForExistence(timeout: 5) else {
            throw XCTSkip("Requires the isolated Simulator fixture seeded by scripts/simulator-smoke.sh.")
        }
        row.tap()
        for name in ["3D Render", "Plan Projected Render", "Elevation Projected Render", "Cross Section Render"] {
            let link = app.staticTexts[name]
            XCTAssertTrue(link.waitForExistence(timeout: 10), name)
            if !link.isHittable { app.swipeUp() }
            link.tap()
            XCTAssertEqual(app.state, .runningForeground, name)
            let nav = app.navigationBars.firstMatch
            XCTAssertTrue(nav.waitForExistence(timeout: 10), name)
            let back = nav.buttons.firstMatch
            XCTAssertTrue(back.isHittable, name)
            back.tap()
        }
        let menu = app.buttons["Export scan"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let zip = app.buttons["Backup ZIP (original + mesh)"]
        XCTAssertTrue(zip.waitForExistence(timeout: 5))
        zip.tap()
        // iOS 26 represents sharing actions as cells, not buttons.
        let files = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Save to Files")
        ).firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 20))
    }

    func testSeededFilteredDeleteAndRestore() throws {
        let app = XCUIApplication()
        app.launch()
        let alpha = seededRow("review_alpha", in: app)
        let beta = seededRow("review_beta", in: app)
        guard alpha.waitForExistence(timeout: 5), beta.exists else {
            throw XCTSkip("Requires the isolated Simulator fixtures seeded by scripts/simulator-smoke.sh.")
        }
        let firstIsAlpha = alpha.frame.minY < beta.frame.minY
        let first = firstIsAlpha ? alpha : beta
        let filtered = firstIsAlpha ? beta : alpha
        let filteredID = firstIsAlpha ? "review_beta" : "review_alpha"
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.isHittable)
        search.tap()
        search.typeText(filteredID)
        XCTAssertTrue(filtered.waitForExistence(timeout: 5))
        XCTAssertFalse(first.exists)
        filtered.swipeLeft()
        let move = app.buttons["move-scan-to-trash"]
        let namedMove = app.buttons["Move to Trash"]
        if move.waitForExistence(timeout: 2) { move.tap() }
        else if namedMove.waitForExistence(timeout: 2) { namedMove.tap() }
        else { XCTFail("Move to Trash was not offered"); return }
        XCTAssertTrue(filtered.waitForNonExistence(timeout: 5))
        // A recovery operation must still be available after a full launch,
        // independent of platform-specific search dismissal controls.
        app.terminate()
        app.launch()
        XCTAssertTrue(first.waitForExistence(timeout: 5), "The other scan must still exist.")
        let trash = app.buttons["scan-trash"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.tap()
        let restore = app.buttons["restore-scan-" + filteredID]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        XCTAssertTrue(beta.exists)
    }
}
