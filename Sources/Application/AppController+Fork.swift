// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Fork: the floating address bar of "Open Address Bar from Any App".
@MainActor
private enum ForkAddressBarPanel {
    static var current: KioskLaunchOmniBoxPanelController?
}

extension AppController {
    /// Fork: "Open Address Bar from Any App". Shows Phi's own omnibox,
    /// unchanged, in the floating, non-activating panel Kiosk's global
    /// shortcut uses (`KioskLaunchOmniBoxPanelController`): it appears over
    /// whatever app is in front, on the screen the pointer is on, without
    /// bringing Phi forward. Picking a result activates Phi and opens it in a
    /// new tab of the browser window; Escape, or the shortcut again, leaves
    /// the user where they were.
    @MainActor
    func forkOpenAddressBarFromAnywhere() {
        if let panel = ForkAddressBarPanel.current, !panel.isFinished {
            panel.dismiss()
            return
        }
        ForkAddressBarPanel.current = nil
        let manager = SpaceSessionControllersManager.shared
        // The omnibox takes its suggestions from a browser window; with no
        // window open the shortcut does nothing.
        guard let host = manager.activeWindowController, !host.isDormant,
              host.window?.isVisible == true || host.window?.isMiniaturized == true else { return }
        // One omnibox at a time: an omnibox already up in the window ends.
        if let container = host.omniBoxContainerViewController, container.hasShown {
            container.hideOmniBox()
        }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        // One turn later, like Kiosk: the hide above hands key back first.
        DispatchQueue.main.async {
            guard ForkAddressBarPanel.current == nil else { return }
            let panel = KioskLaunchOmniBoxPanelController(
                browserState: host.browserState,
                hostWindow: host.lifecycleWindow
            ) { url in
                ForkAddressBarPanel.current = nil
                guard let url else { return }
                KioskLaunchActivation().perform {
                    if let window = host.window {
                        if window.isMiniaturized { window.deminiaturize(nil) }
                        window.makeKeyAndOrderFront(nil)
                    }
                    host.browserState.createTab(url)
                }
            }
            ForkAddressBarPanel.current = panel
            panel.present(on: screen)
        }
    }
}
