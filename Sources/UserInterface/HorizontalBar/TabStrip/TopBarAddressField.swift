// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine

/// The Comfortable top bar's address field: the window's one address bar,
/// in a slot of its own ahead of the tabs, as wide as the sidebar's.
///
/// It is the vertical sidebar's own address bar (`SideAddressBar`), with the
/// same buttons and the same settings: Reader, Memory, Autoplay and Copy
/// Link, which the sidebar's right-click menu turns on and off, and the
/// extensions menu. Pinned extensions stay out of it; the top bar shows them
/// as tiles. It shows the
/// focused tab, whichever zone that tab is in. A click on it opens the
/// Omnibox over it; ⌘L opens it centred, as ⌘T does.
final class TopBarAddressField: NSView, TitlebarAwareHitTestable {
    static let height: CGFloat = 28

    private let browserState: BrowserState
    private let addressBar: SideAddressBar
    private var cancellables = Set<AnyCancellable>()

    /// What the Omnibox lays itself over.
    var anchorView: NSView { addressBar }

    init(browserState: BrowserState) {
        self.browserState = browserState
        addressBar = SideAddressBar(browserState: browserState, isInTopBar: true)
        super.init(frame: .zero)
        wantsLayer = true

        // The sidebar address bar's own wash, as it looks in the sidebar.
        addressBar.showBackgroundWhenInactive = true
        // The bar is always in view, so its buttons always show, where the
        // sidebar's appear when the pointer is over the sidebar.
        addressBar.setAccessoryButtonsVisible(true, animated: false)
        addressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addressBar)
        NSLayoutConstraint.activate([
            addressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            addressBar.topAnchor.constraint(equalTo: topAnchor),
            addressBar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        browserState.$focusingTab
            .compactMap { $0 }
            .removeDuplicates { $0 === $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in self?.addressBar.currentTab = tab }
            .store(in: &cancellables)
        if let tab = browserState.focusingTab {
            addressBar.currentTab = tab
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hit testing

    /// The field takes its clicks inside titlebar space: it is a control,
    /// not a window drag handle.
    func shouldConsumeHitTest(at point: NSPoint) -> Bool { true }

    /// Presses on the field's text, icon and background go to the address
    /// bar, which declines to move the window; its buttons keep their own.
    /// AppKit asks the view it hit-tests whether a press in titlebar space
    /// moves the window, and a double press on one that says yes zooms it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let candidate = view, candidate !== self {
            if candidate is NSControl || candidate is HoverableButtonNSView
                || candidate === addressBar.extensionMenuView { return hit }
            view = candidate.superview
        }
        return addressBar
    }
}
