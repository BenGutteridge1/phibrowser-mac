// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The Comfortable top bar's width ladder: what folds, in which order, as
/// the room for the tabs runs out.
final class TopBarWidthsTests: XCTestCase {
    private func parts(tabs: Int, player: Bool = false) -> TopBarWidths.Parts {
        TopBarWidths.Parts(
            fixed: 220,
            pinnedTiles: 120,
            spacePinsTitled: 260,
            spacePinsFoldersCompressed: 200,
            spacePinsIconOnly: 90,
            trailingFull: 200,
            trailingFolded: 92,
            playerFull: player ? 138 : 0,
            playerCompact: player ? 62 : 0,
            tabCount: tabs
        )
    }

    /// Everything shown, the address field included in `fixed`.
    private func fullWidth(_ parts: TopBarWidths.Parts) -> CGFloat {
        parts.fixed + parts.pinnedTiles + parts.spacePinsTitled
            + parts.trailingFull + parts.playerFull
    }

    func testRoomyRowFoldsNothing() {
        let parts = parts(tabs: 5)
        let fit = TopBarWidths.solve(room: fullWidth(parts) + 5 * TopBarWidths.tabsTitledWidth, parts: parts)
        XCTAssertEqual(fit, TopBarWidths.Fit())
    }

    func testFoldersCompressFirst() {
        let parts = parts(tabs: 5)
        let room = fullWidth(parts) + 5 * TopBarWidths.tabsTitledWidth - 10
        let fit = TopBarWidths.solve(room: room, parts: parts)
        XCTAssertFalse(fit.folderTitles)
        XCTAssertTrue(fit.spacePinTitles)
        XCTAssertFalse(fit.foldsTrailingButtons)
    }

    func testSpacePinsDropTitlesAfterFolders() {
        let parts = parts(tabs: 5)
        let foldersSaving = parts.spacePinsTitled - parts.spacePinsFoldersCompressed
        let room = fullWidth(parts) + 5 * TopBarWidths.tabsTitledWidth - foldersSaving - 10
        let fit = TopBarWidths.solve(room: room, parts: parts)
        XCTAssertFalse(fit.folderTitles)
        XCTAssertFalse(fit.spacePinTitles)
        XCTAssertFalse(fit.foldsTrailingButtons)
    }

    func testStepsFoldInOrder() {
        let parts = parts(tabs: 5, player: true)
        let base = fullWidth(parts) + 5 * TopBarWidths.tabsTitledWidth
        // Past the Space pins' and the trailing buttons' savings.
        let pinsSaving = parts.spacePinsTitled - parts.spacePinsIconOnly
        let trailingSaving = parts.trailingFull - parts.trailingFolded
        let fit = TopBarWidths.solve(room: base - pinsSaving - trailingSaving - 1, parts: parts)
        XCTAssertFalse(fit.folderTitles)
        XCTAssertFalse(fit.spacePinTitles)
        XCTAssertTrue(fit.foldsTrailingButtons)
        XCTAssertTrue(fit.compactPlayer)
    }

    func testEverythingFoldsWhenTabsHaveNoRoom() {
        let fit = TopBarWidths.solve(room: 1200, parts: parts(tabs: 30, player: true))
        XCTAssertFalse(fit.folderTitles)
        XCTAssertFalse(fit.spacePinTitles)
        XCTAssertTrue(fit.foldsTrailingButtons)
        XCTAssertTrue(fit.compactPlayer)
    }
}
