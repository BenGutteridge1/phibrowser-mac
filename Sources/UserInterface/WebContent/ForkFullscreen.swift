// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Fork: two fixes around a page's (HTML5) fullscreen.
///
/// 1. The page is told when fullscreen ends. Chromium tells the renderer
///    through the resize that comes with leaving fullscreen. With
///    edge-to-edge content in a window that fills the screen, the page area
///    is the same size in and out of fullscreen, so no resize happens and
///    the page keeps believing it is fullscreen (YouTube stays in its
///    fullscreen layout, a "fullscreen theatre mode", and can toggle back
///    in). After the window has left fullscreen, a page that still reports
///    a fullscreen element is asked to exit, over the app's in-process
///    DevTools session.
/// 2. Chromium's "Press Esc to exit full screen" bubble is hidden when
///    `ForkSettings.hidesFullscreenExitHint` is on. The bubble is a small
///    Chromium widget window attached to the shell, centered at its top.
@MainActor
enum ForkFullscreen {
    /// Windows whose page is in fullscreen, by Chromium window id.
    private static var fullscreenWindows: Set<Int> = []
    private static var hintTasks: [Int: Task<Void, Never>] = [:]
    private static var occlusionObserver: NSObjectProtocol?

    /// Called from `PhiChromiumCoordinator.tabContentFullscreenChanged`.
    static func pageFullscreenChanged(tabId: Int, windowId: Int, isFullscreen: Bool) {
        hintTasks.removeValue(forKey: windowId)?.cancel()
        if isFullscreen {
            fullscreenWindows.insert(windowId)
            if ForkSettings.hidesFullscreenExitHint { startHidingExitHint(windowId: windowId) }
        } else {
            fullscreenWindows.remove(windowId)
            releasePageIfStillFullscreen(tabId: tabId, windowId: windowId)
        }
    }

    // MARK: The page's own fullscreen state

    private static func releasePageIfStillFullscreen(tabId: Int, windowId: Int) {
        Task { @MainActor in
            // After the window's exit transition, as the resize would come.
            try? await Task.sleep(for: .milliseconds(900))
            guard !fullscreenWindows.contains(windowId),
                  let tab = SpaceSessionControllersManager.shared.controller(for: windowId)?
                    .browserState.resolveTab(tabId),
                  !tab.isInContentFullscreen,
                  let targetId = tab.webContentWrapper?.devToolsTargetId,
                  let session = try? await AppDevToolsPageSession.open(targetId: targetId) else { return }
            defer { session.close() }
            let reply = try? await session.command("Runtime.evaluate", params: [
                "expression": "document.fullscreenElement ? (document.exitFullscreen().catch(() => {}), 'released') : 'clear'",
                "returnByValue": true
            ])
            if ((reply?["result"] as? [String: Any])?["value"] as? String) == "released" {
                AppLogInfo("[ForkFullscreen] tab \(tabId) still reported fullscreen after leaving it; released")
            }
        }
    }

    // MARK: "Press Esc to exit full screen"

    private static func startHidingExitHint(windowId: Int) {
        // The moment the bubble is ordered in (its visibility changes),
        // before it has faded in; the polling below is the fallback.
        if occlusionObserver == nil {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { note in
                MainActor.assumeIsolated {
                    guard !fullscreenWindows.isEmpty, ForkSettings.hidesFullscreenExitHint,
                          let window = note.object as? NSWindow, window.isVisible,
                          window.contentView?.isHidden == false,
                          let shell = window.parent, isExitHint(window, in: shell) else { return }
                    hide(window)
                }
            }
        }
        hintTasks[windowId] = Task { @MainActor in
            // Closely while the bubble first appears, then now and then in
            // case Chromium shows it again, for as long as the page is
            // fullscreen.
            for step in 0..<120 {
                guard !Task.isCancelled, fullscreenWindows.contains(windowId) else { return }
                if let shell = SpaceSessionControllersManager.shared.controller(for: windowId)?.window {
                    for child in shell.childWindows ?? [] where child.isVisible && child.contentView?.isHidden == false
                        && isExitHint(child, in: shell) {
                        hide(child)
                    }
                }
                try? await Task.sleep(for: step < 40 ? .milliseconds(100) : .seconds(1))
            }
        }
    }

    /// Hides what the bubble draws rather than the window: Chromium keeps
    /// ordering the window in and fading it (in, and out again), which a
    /// hidden window loses to. With its content view hidden there is
    /// nothing to fade. Chromium makes a new bubble widget for each
    /// fullscreen, so this does not outlive the setting being turned off.
    private static func hide(_ window: NSWindow) {
        window.contentView?.isHidden = true
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    /// The bubble: a Chromium widget window about 400×50 points, centered
    /// horizontally at the top of the shell.
    private static func isExitHint(_ window: NSWindow, in shell: NSWindow) -> Bool {
        String(describing: type(of: window)) == "NativeWidgetMacNSWindow"
            && (200...800).contains(window.frame.width)
            && (30...90).contains(window.frame.height)
            && abs(window.frame.midX - shell.frame.midX) <= 4
            && shell.frame.maxY - window.frame.maxY <= 140
    }
}
