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

    /// Hosts that get a live card, the page the card opens on, and the
    /// card-only styling injected into that site's pages.
    private static let sites: [(host: String, url: String, css: String)] = [
        ("mail.google.com", "https://mail.google.com/mail/", gmailCSS),
        ("ticktick.com", "https://ticktick.com/webapp/", "")
    ]

    /// Gmail's mobile site: drop the "Gmail is better on the app" banner, and
    /// in dark mode (the card follows the browser) give the page a dark look
    /// with the usual invert-and-rotate, flipping pictures back.
    private static let gmailCSS = """
    #speedbump { display: none !important; }
    @media (prefers-color-scheme: dark) {
      html { filter: invert(0.9) hue-rotate(180deg); background: #fff; }
      img, video, picture, [style*="background-image"] { filter: invert(1) hue-rotate(180deg); }
    }
    """

    /// The card's page for `tab`, or nil when the tab gets Phi's own preview.
    static func previewURL(for tab: Tab) -> String? {
        guard ForkSettings.pinnedTabLivePreviewsEnabled,
              let raw = tab.pinnedUrl ?? tab.url,
              let host = URL(string: raw)?.host?.lowercased() else { return nil }
        return sites.first { host == $0.host || host.hasSuffix("." + $0.host) }?.url
    }

    private static func css(forPageURL url: String) -> String {
        sites.first { $0.url == url }?.css ?? ""
    }

    // MARK: Per-window controllers

    private static var controllers: [Int: ForkPinnedLivePreview] = [:]

    static func controller(for state: BrowserState) -> ForkPinnedLivePreview {
        if let existing = controllers[state.windowId] { return existing }
        let controller = ForkPinnedLivePreview(state: state)
        controllers[state.windowId] = controller
        return controller
    }

    private static let cardSize = NSSize(width: 340, height: 500)
    /// The page lays out this much wider than the card, then is drawn scaled
    /// down to fit, so more of the inbox or task list fits.
    private static let contentScale = 0.85
    private static let gap: CGFloat = 8
    private static let showDelay: TimeInterval = 0.35
    private static let hideDelay: TimeInterval = 0.3
    private static let idleRelease: TimeInterval = 600
    /// A mobile Chrome user agent, so sites serve their small-screen layout.
    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    private final class Page {
        let wrapper: any WebContentWrapper
        var session: AppDevToolsPageSession?
        /// The color scheme last requested from the site, nil before any.
        var isDark: Bool?
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
        // Follow the browser's light or dark appearance.
        let isDark = state.themeContext.currentAppearance.isDark
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if let page = pages[url], page.session != nil, page.isDark != isDark {
            Task { @MainActor [weak self] in await self?.applyColorScheme(isDark: isDark, to: page) }
        }
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
                "width": Int(Self.cardSize.width / Self.contentScale),
                "height": Int(Self.cardSize.height / Self.contentScale),
                "deviceScaleFactor": 0, "mobile": true, "scale": Self.contentScale
            ])
            await applyColorScheme(isDark: state?.themeContext.currentAppearance.isDark ?? false, to: page)
            let css = Self.css(forPageURL: url)
            if !css.isEmpty, let literal = String(data: (try? JSONSerialization.data(withJSONObject: [css])) ?? Data(), encoding: .utf8) {
                // Every page the card loads gets the style from its start. A
                // constructed (adopted) stylesheet, not a <style> element:
                // sites' content security policies block inline styles.
                let script = """
                (()=>{try{const s=new CSSStyleSheet();s.replaceSync(\(literal)[0]);\
                document.adoptedStyleSheets=[...document.adoptedStyleSheets,s];}catch(e){}})();
                """
                // The injected script only runs with the Page domain on.
                _ = try? await session.command("Page.enable")
                _ = try? await session.command("Page.addScriptToEvaluateOnNewDocument", params: ["source": script])
            }
        }
        page.wrapper.navigate(toURL: url)
    }

    /// Asks the site for its dark or light look (`prefers-color-scheme`).
    private func applyColorScheme(isDark: Bool, to page: Page) async {
        guard let session = page.session else { return }
        page.isDark = isDark
        _ = try? await session.command("Emulation.setEmulatedMedia", params: [
            "features": [["name": "prefers-color-scheme", "value": isDark ? "dark" : "light"]]
        ])
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
