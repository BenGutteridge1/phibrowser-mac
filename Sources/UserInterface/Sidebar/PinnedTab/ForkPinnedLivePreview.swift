// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Fork: an interactive live card for chosen pinned tabs (Gmail, TickTick),
/// shown on hover beside the sidebar, like Arc's calendar preview. It shows
/// the signed-in site itself, in the site's mobile layout, in a small panel
/// the user can scroll, read and click in. Other pinned tabs keep Phi's own
/// snapshot preview.
///
/// Each site's page is a detached WebContents (never in a tab strip) kept
/// warm for `idleRelease` after its card was last shown, so a card appears at
/// once. The mobile layout is requested over the app's in-process CDP session
/// (`AppDevToolsPageSession`), which stays open while the page lives because
/// the user-agent override lasts only as long as the session.
@MainActor
final class ForkPinnedLivePreview: NSObject {
    // MARK: Eligibility

    /// Hosts that get a live card, and the page the card opens on.
    private static let sites: [(host: String, url: String)] = [
        ("mail.google.com", "https://mail.google.com/mail/"),
        ("ticktick.com", "https://ticktick.com/webapp/")
    ]

    /// The card's page for `tab`, or nil when the tab gets Phi's own preview.
    static func previewURL(for tab: Tab) -> String? {
        guard ForkSettings.pinnedTabLivePreviewsEnabled,
              let raw = tab.pinnedUrl ?? tab.url,
              let host = URL(string: raw)?.host?.lowercased() else { return nil }
        return sites.first { host == $0.host || host.hasSuffix("." + $0.host) }?.url
    }

    // MARK: Per-window controllers

    private static var controllers: [Int: ForkPinnedLivePreview] = [:]

    static func controller(for state: BrowserState) -> ForkPinnedLivePreview {
        if let existing = controllers[state.windowId] { return existing }
        let controller = ForkPinnedLivePreview(state: state)
        controllers[state.windowId] = controller
        return controller
    }

    private static let cardSize = NSSize(width: 390, height: 600)
    private static let gap: CGFloat = 8
    private static let showDelay: TimeInterval = 0.35
    private static let hideDelay: TimeInterval = 0.3
    private static let idleRelease: TimeInterval = 600
    /// A mobile Chrome user agent, so sites serve their small-screen layout.
    private static let mobileUserAgent =
        "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Mobile Safari/537.36"

    private final class Page {
        let wrapper: any WebContentWrapper
        var session: AppDevToolsPageSession?
        var releaseWork: DispatchWorkItem?
        init(wrapper: any WebContentWrapper) { self.wrapper = wrapper }
        func close() {
            releaseWork?.cancel()
            session?.close()
            wrapper.close()
        }
    }

    private final class CardPanel: NSPanel {
        var onPointerInside: ((Bool) -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { onPointerInside?(false) }
    }

    /// Tracks the pointer over the card so the card stays while it is used.
    private final class CardContentView: NSView {
        var onPointerInside: ((Bool) -> Void)?
        private var area: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let new = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                     owner: self, userInfo: nil)
            addTrackingArea(new)
            area = new
        }
        override func mouseEntered(with event: NSEvent) { onPointerInside?(true) }
        override func mouseExited(with event: NSEvent) { onPointerInside?(false) }
    }

    private weak var state: BrowserState?
    private var pages: [String: Page] = [:]
    private var panel: CardPanel?
    private var content: CardContentView?
    private var shownURL: String?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var pointerOverTab = false
    private var pointerOverCard = false

    private init(state: BrowserState) {
        self.state = state
        super.init()
    }

    // MARK: Hover

    /// Called from the pinned tab's hover changes. Returns true when the tab
    /// gets a live card (the caller then skips Phi's snapshot preview).
    @discardableResult
    func hoverChanged(_ hovering: Bool, tab: Tab, anchor: NSView) -> Bool {
        guard let url = Self.previewURL(for: tab) else { return false }
        pointerOverTab = hovering
        if hovering {
            hideWork?.cancel()
            showWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak anchor] in
                MainActor.assumeIsolated {
                    guard let self, let anchor, self.pointerOverTab else { return }
                    self.show(url: url, beside: anchor)
                }
            }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (panel?.isVisible == true ? 0 : Self.showDelay), execute: work)
        } else {
            showWork?.cancel()
            scheduleHide()
        }
        return true
    }

    /// A click on the pinned tab opens it for real; the card goes.
    func dismissForInteraction() {
        showWork?.cancel()
        hide()
    }

    private func pointerOverCardChanged(_ inside: Bool) {
        pointerOverCard = inside
        if inside { hideWork?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.pointerOverTab, !self.pointerOverCard else { return }
                self.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
    }

    // MARK: Card

    private func show(url: String, beside anchor: NSView) {
        guard let state, let parent = anchor.window else { return }
        let panel = self.panel ?? makePanel()
        if shownURL != url {
            content?.subviews.forEach { $0.removeFromSuperview() }
            shownURL = url
            mount(page(for: url, state: state))
        }
        pages[url]?.releaseWork?.cancel()
        // Beside the sidebar, top-aligned with the pinned tab, kept on screen.
        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        // The pinned grid spans the sidebar, so its edge is the sidebar's.
        let grid = anchor.enclosingScrollView ?? anchor
        let sidebarEdge = parent.convertToScreen(grid.convert(grid.bounds, to: nil)).maxX
        var origin = NSPoint(x: max(sidebarEdge, anchorRect.maxX) + Self.gap,
                             y: anchorRect.maxY - Self.cardSize.height)
        origin.y = min(max(origin.y, visible.minY + Self.gap), visible.maxY - Self.cardSize.height - Self.gap)
        panel.setFrame(NSRect(origin: origin, size: Self.cardSize), display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    private func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        pointerOverCard = false
        if let url = shownURL { scheduleRelease(url) }
    }

    private func makePanel() -> CardPanel {
        let panel = CardPanel(contentRect: NSRect(origin: .zero, size: Self.cardSize),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let content = CardContentView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(white: 0.5, alpha: 0.25).cgColor
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.onPointerInside = { [weak self] inside in self?.pointerOverCardChanged(inside) }
        panel.onPointerInside = { [weak self] _ in self?.hide() }
        panel.contentView = content
        self.panel = panel
        self.content = content
        return panel
    }

    /// Mounts the page's view the way the placeholder shell does: add first,
    /// then constrain, which out-of-band WebContents need in order to render.
    private func mount(_ page: Page?) {
        guard let content, let view = page?.wrapper.nativeView else { return }
        view.removeFromSuperview()
        content.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.snp.remakeConstraints { make in make.edges.equalToSuperview() }
    }

    // MARK: Pages

    private func page(for url: String, state: BrowserState) -> Page? {
        if let page = pages[url] { return page }
        guard let wrapper = ChromiumLauncher.sharedInstance().bridge?
            .newWebContents(forUrl: "about:blank", windowId: Int64(state.windowId)) else { return nil }
        let page = Page(wrapper: wrapper)
        pages[url] = page
        Task { @MainActor [weak self] in await self?.load(url, into: page) }
        return page
    }

    /// Switches the page to the site's mobile layout, then loads the site.
    private func load(_ url: String, into page: Page) async {
        for _ in 0..<60 where page.wrapper.devToolsTargetId == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let targetId = page.wrapper.devToolsTargetId,
           let session = try? await AppDevToolsPageSession.open(targetId: targetId) {
            page.session = session
            _ = try? await session.command("Emulation.setUserAgentOverride",
                                           params: ["userAgent": Self.mobileUserAgent])
            _ = try? await session.command("Emulation.setDeviceMetricsOverride", params: [
                "width": 0, "height": 0, "deviceScaleFactor": 0, "mobile": true
            ])
        }
        page.wrapper.navigate(toURL: url)
    }

    private func scheduleRelease(_ url: String) {
        guard let page = pages[url] else { return }
        page.releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shownURL != url || self.panel?.isVisible != true else { return }
                if self.shownURL == url {
                    self.content?.subviews.forEach { $0.removeFromSuperview() }
                    self.shownURL = nil
                }
                self.pages.removeValue(forKey: url)?.close()
            }
        }
        page.releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleRelease, execute: work)
    }

    /// Releases every page (the window closed).
    static func release(windowId: Int) {
        guard let controller = controllers.removeValue(forKey: windowId) else { return }
        controller.hide()
        controller.pages.values.forEach { $0.close() }
        controller.pages.removeAll()
    }
}
