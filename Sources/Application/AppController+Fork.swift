// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

extension AppController {
    /// Fork: "Open Address Bar from Any App". Brings Phi forward and does
    /// what New Tab (⌘T) does in the front window, so the New tab behavior
    /// setting decides between the omnibox and a new tab page. With no
    /// window open, opens one first, the way clicking the Dock icon does.
    @MainActor
    func forkOpenAddressBarFromAnywhere() {
        NSApp.activate(ignoringOtherApps: true)
        let manager = SpaceSessionControllersManager.shared
        if let controller = manager.activeWindowController, let window = controller.window,
           window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            controller.newBrowserTab(nil)
            return
        }
        _ = ChromiumLauncher.sharedInstance().bridge?
            .applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        // A window that opens empty (the fork's empty state) still owes the
        // address bar; one that opens on a new tab already shows it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                guard let controller = SpaceSessionControllersManager.shared.activeWindowController,
                      controller.browserState.isInPlaceholderMode else { return }
                controller.newBrowserTab(nil)
            }
        }
    }
}
