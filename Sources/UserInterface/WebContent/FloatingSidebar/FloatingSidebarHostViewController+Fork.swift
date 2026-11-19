// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

extension FloatingSidebarHostViewController {
    /// Fork: whether something opened from the hover-revealed sidebar is up
    /// beside it, so the sidebar stays while the pointer is over that
    /// instead: a pinned tab's live card, or a window of this browser
    /// window's own that has the keyboard, such as an extension's popup or
    /// the address bar's suggestions (Chromium attaches those as child
    /// windows). The history panel is the exception: it belongs to the page.
    var forkKeepsFloatingSidebarOpen: Bool {
        guard let window = view.window else { return false }
        if ForkPinnedLivePreview.isShowingCard(over: window) { return true }
        guard let key = NSApp.keyWindow, key !== window,
              !ForkHistoryPanelController.isHistoryPanel(key) else { return false }
        var ancestor = key.parent
        while let current = ancestor {
            if current === window { return true }
            ancestor = current.parent
        }
        return false
    }
}
