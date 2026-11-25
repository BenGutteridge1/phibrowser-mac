// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Fork: with "double-click to close tabs" on, the first click of a
/// double-click on another tab switched to it before the second click closed
/// it. A plain click on a tab other than the current one now waits briefly
/// before switching; if a second click starts in that time, the switch is
/// dropped (the second click then closes the tab). The current tab, pinned
/// tabs and modified clicks are not delayed, and nothing is with the setting
/// off.
///
/// The wait only has to cover the gap until the second press begins, not
/// the whole system double-click interval (0.5 s by default): the second
/// press is caught on mouse down, so the wait is short.
@MainActor
enum ForkTabClickDeferral {
    /// Long enough for the second press of a double-click to begin.
    private static let wait: TimeInterval = 0.3
    private static var pending: DispatchWorkItem?
    private static var mouseDownMonitor: Any?

    /// Whether a click on `tab` should wait for a possible second click.
    static func shouldDefer(_ tab: Tab, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        PhiPreferences.GeneralSettings.doubleClickToCloseTabs.loadValue()
            && !tab.isPinned && !tab.isActive
            && modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
    }

    /// Runs `switchToTab` after a short wait unless a second click begins
    /// (or another click comes) first.
    static func deferSwitch(_ switchToTab: @escaping () -> Void) {
        cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                finish()
                switchToTab()
            }
        }
        pending = work
        // The second press of a double-click drops the switch as it begins.
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if event.clickCount >= 2 { MainActor.assumeIsolated { cancel() } }
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + min(wait, NSEvent.doubleClickInterval), execute: work)
    }

    /// A second click (or a click elsewhere) drops a waiting switch.
    static func cancel() {
        pending?.cancel()
        finish()
    }

    private static func finish() {
        pending = nil
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
    }
}
