// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Fork: keeps the Dock icon the one macOS draws.
///
/// With a download in progress, Chromium's `DockIcon` sets the Dock tile's
/// content view to its own view, which draws `NSApp.applicationIconImage` (the
/// flat light icon) plus a progress bar. That replaced the icon macOS renders
/// from the app's icon (dark, tinted or clear, as the user chose), and it
/// stayed so until a relaunch: the Dock icon "randomly" went light and
/// translucent. Phi+ shows download progress in its own ring, so after each
/// download event (once Chromium has handled it) the tile's content view is
/// cleared and macOS draws the icon again. Chromium then messages a nil view,
/// which does nothing.
@MainActor
enum ForkDockIcon {
    static func restoreSystemIcon() {
        DispatchQueue.main.async {
            let tile = NSApp.dockTile
            guard tile.contentView != nil else { return }
            tile.contentView = nil
            tile.display()
        }
    }
}
