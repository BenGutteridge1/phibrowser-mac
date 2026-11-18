// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Fork: which tabs the tab switcher (Ctrl-Tab) and ⌘1–⌘9 skip
/// (`ForkSettings`, Settings → Spaces).
extension BrowserState {
    /// Whether `tab` sits in a closed folder: a collapsed tab group, or a
    /// sidebar bookmark folder that is collapsed (the bookmark is then not
    /// among the sidebar's visible bookmarks).
    func forkIsInClosedFolder(_ tab: Tab) -> Bool {
        if let token = tab.groupToken, groups[token]?.isCollapsed == true { return true }
        guard !tab.isPinned, let guid = tab.guidInLocalDB, !guid.isEmpty,
              bookmarkManager.bookmark(withGuid: guid) != nil else { return false }
        return !visibleBookmarkTabs.contains { $0.guid == guid }
    }

    /// Whether the tab switcher (Ctrl-Tab) leaves `tab` out.
    func forkTabSwitcherExcludes(_ tab: Tab) -> Bool {
        (ForkSettings.tabSwitcherExcludesPinnedTabs && tab.isPinned)
            || (ForkSettings.tabSelectionExcludesClosedFolders && forkIsInClosedFolder(tab))
    }
}
