// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// A favicon-only tab under the pointer grows to its titled width, from its
/// own leading edge, and the tabs after it move along to make the room.
final class TabStripHoverExpansionTests: XCTestCase {
    private func layout(containerWidth: CGFloat, tabCount: Int, hovered: Int?) -> TabStripLayoutOutput {
        TabStripLayoutEngine.layoutNormal(input: TabStripLayoutInput(
            containerWidth: containerWidth,
            tabCount: tabCount,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 180,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 28,
            hoverExpandedIndex: hovered,
            hoverExpandedWidth: 180
        ))
    }

    func testCompressedHoveredTabGrowsAndPushesTheRest() {
        let resting = layout(containerWidth: 600, tabCount: 20, hovered: nil)
        let hovered = layout(containerWidth: 600, tabCount: 20, hovered: 5)
        XCTAssertLessThan(resting.tabFrames[5].width, TabStripMetrics.Content.compactModeThreshold)
        XCTAssertEqual(hovered.tabFrames[5].width, 180)
        // It grows from its own leading edge, so it stays under the pointer.
        XCTAssertEqual(hovered.tabFrames[5].minX, resting.tabFrames[5].minX, accuracy: 0.01)
        // Tabs before it don't move; tabs after it move by the growth.
        XCTAssertEqual(hovered.tabFrames[4], resting.tabFrames[4])
        let growth = hovered.tabFrames[5].width - resting.tabFrames[5].width
        XCTAssertEqual(hovered.tabFrames[6].minX, resting.tabFrames[6].minX + growth, accuracy: 0.01)
    }

    func testTitledTabsDoNotGrow() {
        let resting = layout(containerWidth: 2000, tabCount: 4, hovered: nil)
        let hovered = layout(containerWidth: 2000, tabCount: 4, hovered: 2)
        XCTAssertEqual(hovered.tabFrames, resting.tabFrames)
    }
}
