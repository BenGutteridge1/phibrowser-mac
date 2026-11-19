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
    private static let sites: [(host: String, url: String, css: String, name: String, signedInPath: String)] = [
        ("mail.google.com", "https://mail.google.com/mail/", gmailCSS, "Gmail", "/mail/mu/mp/"),
        ("ticktick.com", "https://ticktick.com/webapp/", "", "TickTick", "/webapp")
    ]

    /// A signed-in page lives under the site's app path; anything else (a
    /// sign-in page, Google's "better on the app" page) means signed out.
    /// Signing in can't happen in the card (Google refuses the mobile
    /// identity it uses), so the card offers a real tab instead.
    private func isSignedIn(_ page: Page, url: String) -> Bool {
        guard let site = Self.sites.first(where: { $0.url == url }),
              let current = page.wrapper.urlString.flatMap(URL.init(string:)) else { return true }
        return current.path.hasPrefix(site.signedInPath)
    }

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

    /// Whether a live card is up over `window`.
    static func isShowingCard(over window: NSWindow) -> Bool {
        controllers.values.contains { $0.panel?.isVisible == true && $0.panel?.parent === window }
    }

    static func controller(for state: BrowserState) -> ForkPinnedLivePreview {
        if let existing = controllers[state.windowId] { return existing }
        let controller = ForkPinnedLivePreview(state: state)
        controllers[state.windowId] = controller
        return controller
    }

    private static let cardSize = NSSize(width: 340, height: 400)
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
        /// Set while the card showed the sign-in prompt, so the next showing
        /// reloads the site (the user may have signed in in a tab since).
        var needsReload = false
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
    private var scrollMonitor: Any?

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
            signInPrompt = nil
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
        installScrollMonitor()
        if let page = pages[url] {
            if page.needsReload {
                page.needsReload = false
                page.wrapper.navigate(toURL: url)
            }
            updateSignInPrompt(for: page, url: url)
        }
        panel.invalidateShadow()
    }

    private func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        removeScrollMonitor()
        pointerOverCard = false
        if let url = shownURL { scheduleRelease(url) }
    }

    /// The card never becomes key and sits in a child panel, so the wheel
    /// doesn't reach its page on its own. While the card is up, scrolling
    /// over it goes straight to the view under the pointer.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible,
                      let content = panel.contentView else { return event }
                let pointer = NSEvent.mouseLocation
                guard panel.frame.contains(pointer) else { return event }
                let point = panel.convertPoint(fromScreen: pointer)
                guard let target = content.hitTest(content.convert(point, from: nil)) else { return event }
                if event.window === panel {
                    target.scrollWheel(with: event)
                    return nil
                }
                // An event addressed to another window carries that window's
                // coordinates: rebuild it at the pointer's spot in the card.
                // (Without a window, an event's location is read as the
                // card's own coordinates.)
                guard let copy = event.cgEvent?.copy(),
                      let primaryHeight = NSScreen.screens.first?.frame.height else { return event }
                copy.location = CGPoint(x: point.x, y: primaryHeight - point.y)
                guard let redirected = NSEvent(cgEvent: copy) else { return event }
                target.scrollWheel(with: redirected)
                return nil
            }
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
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

    // MARK: Sign-in prompt

    private var signInPrompt: NSView?

    /// Shows the native sign-in prompt over the card while the site is
    /// signed out; looks again once the page has had time to load.
    private func updateSignInPrompt(for page: Page, url: String, recheck: Bool = true) {
        let signedOut = !page.wrapper.isLoading && !isSignedIn(page, url: url)
        if signedOut, signInPrompt == nil, let content, let site = Self.sites.first(where: { $0.url == url }) {
            let prompt = NSVisualEffectView()
            prompt.material = .popover
            prompt.blendingMode = .withinWindow
            let title = NSTextField(labelWithString: String(format: NSLocalizedString(
                "pinnedPreview.signIn.title", value: "Not signed in to %@",
                comment: "Live pinned-tab card - shown when the site in the card is signed out; %@ is the site, such as Gmail"), site.name))
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString: NSLocalizedString(
                "pinnedPreview.signIn.detail", value: "Sign in in a tab. The card shows it here afterwards.",
                comment: "Live pinned-tab card - explains that signing in happens in a normal tab"))
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.alignment = .center
            let button = NSButton(title: NSLocalizedString("pinnedPreview.signIn.button", value: "Sign In",
                comment: "Live pinned-tab card - opens the site in a tab to sign in"), target: self, action: #selector(signInPressed))
            button.bezelStyle = .push
            let stack = NSStackView(views: [title, detail, button])
            stack.orientation = .vertical
            stack.spacing = 10
            prompt.addSubview(stack)
            stack.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.leading.trailing.equalToSuperview().inset(24)
            }
            content.addSubview(prompt)
            prompt.snp.makeConstraints { make in make.edges.equalToSuperview() }
            signInPrompt = prompt
            page.needsReload = true
        } else if !signedOut, !page.wrapper.isLoading {
            signInPrompt?.removeFromSuperview()
            signInPrompt = nil
        }
        guard recheck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak page] in
            MainActor.assumeIsolated {
                guard let self, let page, self.shownURL == url, self.panel?.isVisible == true else { return }
                self.updateSignInPrompt(for: page, url: url, recheck: false)
            }
        }
    }

    @objc private func signInPressed() {
        guard let url = shownURL, let state else { return }
        hide()
        state.createTab(url)
    }

    private func page(for url: String, state: BrowserState) -> Page? {
        if let page = pages[url] { return page }
        guard let wrapper = ChromiumLauncher.sharedInstance().bridge?
            .newWebContents(forUrl: "about:blank", windowId: Int64(state.windowId)) else { return nil }
        let page = Page(wrapper: wrapper)
        pages[url] = page
        Task { @MainActor [weak self] in await self?.load(url, into: page) }
        return page
    }

    /// Mobile sites scroll some views by touch alone: Gmail's open email sits
    /// in an `overflow: hidden` box it moves on swipes. When the wheel would
    /// scroll nothing natively, this scrolls the nearest such box that has
    /// room to move.
    private static let wheelScrollScript = """
    (()=>{addEventListener('wheel',e=>{if(e.ctrlKey||e.defaultPrevented)return;\
    const dy=e.deltaMode===1?e.deltaY*16:e.deltaMode===2?e.deltaY*innerHeight:e.deltaY;if(!dy)return;\
    for(let el=e.target instanceof Element?e.target:null;el&&el!==document.documentElement&&el!==document.body;el=el.parentElement){\
    if(el.scrollHeight<=el.clientHeight+1)continue;\
    const room=dy>0?el.scrollTop+el.clientHeight<el.scrollHeight-1:el.scrollTop>0;if(!room)continue;\
    const oy=getComputedStyle(el).overflowY;\
    if(oy==='hidden'){el.scrollTop+=dy;e.preventDefault();return}\
    if(/auto|scroll|overlay/.test(oy))return}},{passive:false,capture:true})})();
    """

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
            // Scripts injected into every page the card loads only run with
            // the Page domain on.
            _ = try? await session.command("Page.enable")
            _ = try? await session.command("Page.addScriptToEvaluateOnNewDocument",
                                           params: ["source": Self.wheelScrollScript])
            let css = Self.css(forPageURL: url)
            if !css.isEmpty, let literal = String(data: (try? JSONSerialization.data(withJSONObject: [css])) ?? Data(), encoding: .utf8) {
                // Every page the card loads gets the style from its start. A
                // constructed (adopted) stylesheet, not a <style> element:
                // sites' content security policies block inline styles.
                let script = """
                (()=>{try{const s=new CSSStyleSheet();s.replaceSync(\(literal)[0]);\
                document.adoptedStyleSheets=[...document.adoptedStyleSheets,s];}catch(e){}})();
                """
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
