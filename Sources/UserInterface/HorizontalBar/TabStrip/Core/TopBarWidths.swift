// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CoreGraphics

/// How the Comfortable top bar gives ground when the window narrows.
///
/// The bar is one row: the fixed controls, the pinned tiles, the Space pins,
/// the address field, the tab run and the trailing buttons. The tabs absorb
/// every change first (the strip shrinks them from their ideal width down to
/// their favicons and then scrolls, keeping the active tab in view).
/// When the tabs would drop under `tabsTitledWidth` each, the rest of the row
/// folds in this order, each step only once the one before it is spent:
///
/// 1. Space pins drop their titles and keep their favicons.
/// 2. Memory, Feedback, Chat and the cards bulb fold into one menu.
/// 3. The mini player keeps its site icon and play/pause.
///
/// The address field keeps one width, the sidebar's address bar's
/// (`TopBarController.addressFieldWidth`).
///
/// A pure function of the room and the measured parts, so every step is
/// unit tested apart from any view.
enum TopBarWidths {
    /// Below this each, a tab loses its title.
    static let tabsTitledWidth: CGFloat = 110
    /// A tab's narrowest: its favicon.
    static let tabsMinWidth: CGFloat = 36

    /// The measured widths of everything in the row but the tabs.
    struct Parts: Equatable {
        /// Lights, navigation buttons, the Space row, separators, fixed gaps
        /// and the address field.
        var fixed: CGFloat
        /// Pinned extension and pinned tab tiles.
        var pinnedTiles: CGFloat
        var spacePinsTitled: CGFloat
        var spacePinsIconOnly: CGFloat
        var trailingFull: CGFloat
        var trailingFolded: CGFloat
        /// Zero while nothing plays.
        var playerFull: CGFloat
        var playerCompact: CGFloat
        /// Tabs in the strip.
        var tabCount: Int
    }

    struct Fit: Equatable {
        var spacePinTitles = true
        var foldsTrailingButtons = false
        var compactPlayer = false
    }

    static func solve(room: CGFloat, parts: Parts) -> Fit {
        var fit = Fit()

        func tabRoom(_ fit: Fit) -> CGFloat {
            room - parts.fixed - parts.pinnedTiles
                - (fit.spacePinTitles ? parts.spacePinsTitled : parts.spacePinsIconOnly)
                - (fit.foldsTrailingButtons ? parts.trailingFolded : parts.trailingFull)
                - (fit.compactPlayer ? parts.playerCompact : parts.playerFull)
        }
        /// Every tab gets at least `perTab`.
        func fits(_ fit: Fit, perTab: CGFloat) -> Bool {
            tabRoom(fit) >= CGFloat(parts.tabCount) * perTab
        }

        let steps: [(inout Fit) -> Void] = [
            { $0.spacePinTitles = false },
            { $0.foldsTrailingButtons = true },
            { $0.compactPlayer = true },
        ]
        for step in steps where !fits(fit, perTab: tabsTitledWidth) {
            step(&fit)
        }
        return fit
    }
}
