// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Brings the Comfortable top bar back while it is hidden (⌘S): the pointer
/// resting on the window's top edge slides the bar down over the page as a
/// floating glass panel, and it slides away again once the pointer leaves.
///
/// The panel covers the page rather than pushing it down, so a reveal never
/// resizes the page. It stays while the pointer is on it and while anything
/// opened from it is up: the Omnibox, a menu, a popover or a hover card
/// (child windows of the browser window). Menus are followed from the menu
/// tracking notifications. Nothing runs while the bar is
/// docked or the pointer is elsewhere: the trigger is a tracking area, and
/// the only timers are the reveal dwell and the hide delay.
///
/// The sidebar's floating panel has the same job for the left edge, but its
/// trigger is bound up with docking and resizing the column; this keeps the
/// bar's to the few rules a row needs.
final class TopBarRevealController: NSObject {
    /// The panel's inset from the window's top and side edges.
    static let panelInset: CGFloat = 6
    static let panelCornerRadius: CGFloat = 14
    /// How long the pointer stays at the window's very top edge
    /// (`edgeBand`) before the bar comes.
    static let revealDelay: TimeInterval = 0.12
    /// How long it stays in the rest of the trigger band, which reaches a
    /// few points into the page: long enough that passing over the page's
    /// own controls at the top doesn't bring the bar over them.
    static let bandRevealDelay: TimeInterval = 0.35
    /// The top edge proper, where the bar comes quickest.
    static let edgeBand: CGFloat = 5
    /// The trigger band's height: the page's 8pt margin and 12pt of the
    /// page, or with the page meeting the edge (edge to edge), 12pt of the
    /// page. Below `edgeBand` the pointer has to rest `bandRevealDelay`, so
    /// the page's own controls up there stay usable.
    static let triggerHeight: CGFloat = 20
    static let edgeToEdgeTriggerHeight: CGFloat = 12
    /// How long after the pointer leaves the bar goes.
    static let hideDelay: TimeInterval = 0.4
    static let showDuration: TimeInterval = 0.22
    static let hideDuration: TimeInterval = 0.18
    /// ⌘S docking or hiding the bar: a little longer than the sidebar
    /// toggle's 0.11s, which covers a column's width in one beat; the bar
    /// also travels its own height out of or into the window.
    static let dockDuration: TimeInterval = 0.18

    /// Called with `true` to show the panel and `false` to put it away,
    /// animated or not. The container moves the bar.
    var onRevealChange: ((_ revealed: Bool, _ animated: Bool) -> Void)?
    /// Whether something opened from the bar is still up (the Omnibox).
    var isHeldOpen: (() -> Bool)?

    private(set) var isRevealed = false
    private(set) var isEnabled = false

    private let triggerView = TopBarRevealTriggerView()
    /// The panel's surface, laid behind the bar: the floating sidebar's glass
    /// and the Space's themed fill.
    let glassView: NSView
    private let themedFill = ColoredVisualEffectView()
    private weak var barView: NSView?
    private var barTrackingArea: NSTrackingArea?
    private var revealWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    /// Whether a menu is open (a context menu, the More menu, a Space menu).
    /// A menu is a window of the system's, neither a child window nor a
    /// popover, so it is followed from the menu tracking notifications.
    private var isMenuOpen = false
    private var menuObservers: [NSObjectProtocol] = []

    override init() {
        themedFill.themedBackgroundColor = .windowOverlayBackground
        themedFill.usesThemePalette = true
        themedFill.runsPaletteHorizontally = true
        // The sidebar's own material: blended behind the window, as the
        // docked sidebar and the floating sidebar's panel are, so the Space's
        // transparency shows the desktop through the bar as it does through
        // the sidebar.
        themedFill.material = .fullScreenUI
        themedFill.blendingMode = .behindWindow
        themedFill.state = .active
        themedFill.wantsLayer = true
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.wantsLayer = true
            glass.cornerRadius = Self.panelCornerRadius
            glass.style = .regular
            themedFill.layer?.cornerRadius = Self.panelCornerRadius
            themedFill.layer?.cornerCurve = .continuous
            themedFill.layer?.masksToBounds = true
            glass.contentView = themedFill
            glassView = glass
        } else {
            themedFill.layer?.cornerRadius = Self.panelCornerRadius
            themedFill.layer?.cornerCurve = .continuous
            themedFill.layer?.masksToBounds = true
            themedFill.layer?.borderWidth = 1
            themedFill.phiLayer?.setBorderColor(.border)
            glassView = themedFill
        }
        glassView.isHidden = true
        super.init()
        triggerView.onEnter = { [weak self] in self?.pointerReachedEdge() }
        triggerView.onExit = { [weak self] in self?.pointerLeftEdge() }
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.isMenuOpen = true
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.isMenuOpen = false
            },
        ]
    }

    deinit {
        menuObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Mounts the trigger along the top of `container` and the glass behind
    /// `bar`.
    func install(in container: NSView, bar: NSView) {
        barView = bar
        container.addSubview(glassView, positioned: .below, relativeTo: bar)
        glassView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            glassView.topAnchor.constraint(equalTo: bar.topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        container.addSubview(triggerView)
        triggerView.translatesAutoresizingMaskIntoConstraints = false
        triggerHeight = triggerView.heightAnchor.constraint(equalToConstant: Self.triggerHeight)
        NSLayoutConstraint.activate([
            triggerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            triggerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            triggerView.topAnchor.constraint(equalTo: container.topAnchor),
            triggerHeight!,
        ])
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        bar.addTrackingArea(area)
        barTrackingArea = area
        triggerView.isHidden = true
    }

    private var triggerHeight: NSLayoutConstraint?

    /// Turns the reveal on while the bar is hidden. The trigger is a band
    /// along the top edge (`triggerHeight`), narrower when the page meets
    /// the edge. It never takes a click.
    func setEnabled(_ enabled: Bool, edgeToEdge: Bool) {
        triggerHeight?.constant = edgeToEdge ? Self.edgeToEdgeTriggerHeight : Self.triggerHeight
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        triggerView.isHidden = !enabled
        if enabled { glassView.isHidden = false }
        cancelTimers()
        if !enabled, isRevealed {
            isRevealed = false
        }
    }

    // MARK: - Pointer

    private func pointerReachedEdge() {
        guard isEnabled else { return }
        hideWork?.cancel()
        guard !isRevealed, revealWork == nil else { return }
        scheduleRevealCheck(after: Self.revealDelay, enteredAt: Date())
    }

    /// Reveals once the pointer has rested: briefly at the window's very top
    /// edge, longer lower in the band, and never while a mouse button is held
    /// (a drag or a text selection running up to the top).
    private func scheduleRevealCheck(after delay: TimeInterval, enteredAt: Date) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.revealWork = nil
            guard self.isEnabled, !self.isRevealed,
                  let distance = self.pointerDistanceFromTop,
                  distance <= self.triggerView.bounds.height else { return }
            let rested = Date().timeIntervalSince(enteredAt)
            let needed = distance <= Self.edgeBand ? Self.revealDelay : Self.bandRevealDelay
            guard NSEvent.pressedMouseButtons == 0, rested >= needed else {
                self.scheduleRevealCheck(after: max(0.05, needed - rested), enteredAt: enteredAt)
                return
            }
            self.setRevealed(true, animated: true)
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The pointer's distance below the window's top edge, while it is in
    /// the trigger band's columns.
    private var pointerDistanceFromTop: CGFloat? {
        guard let window = triggerView.window else { return nil }
        let point = triggerView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard point.x >= 0, point.x <= triggerView.bounds.width else { return nil }
        return triggerView.isFlipped ? point.y : triggerView.bounds.height - point.y
    }

    private func pointerLeftEdge() {
        // Passing up to the menu bar doesn't open the bar.
        revealWork?.cancel()
        revealWork = nil
        if isRevealed { scheduleHideCheck() }
    }

    // The tracking area sends AppKit's selectors to its owner.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        hideWork?.cancel()
        hideWork = nil
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        guard isRevealed else { return }
        scheduleHideCheck()
    }

    private func scheduleHideCheck() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            guard self.isEnabled, self.isRevealed else { return }
            if self.isPointerOnBar || self.isHeldOpen?() == true || self.hasOpenSurface {
                // Something from the bar is still up; look again shortly.
                self.scheduleHideCheck()
                return
            }
            self.setRevealed(false, animated: true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
    }

    private var isPointerOnBar: Bool {
        guard let bar = barView, let window = bar.window else { return false }
        let point = bar.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bar.bounds.insetBy(dx: 0, dy: -Self.panelInset).contains(point)
            || triggerView.bounds.contains(triggerView.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// A popover, a hover card or a preview panel shown from the bar: each
    /// is a window of its own, so the pointer on it has left the bar.
    private var hasOpenSurface: Bool {
        guard let window = barView?.window else { return false }
        if isMenuOpen { return true }
        if window.childWindows?.contains(where: { $0.isVisible }) == true { return true }
        return NSApp.windows.contains { candidate in
            candidate.isVisible && candidate !== window
                && String(describing: type(of: candidate)).contains("Popover")
        }
    }

    /// The panel's glass. On while the bar is hidden; the container also
    /// keeps it on while the bar docks, and takes it off once docked.
    func setGlassShown(_ shown: Bool) {
        glassView.isHidden = !shown
    }

    private func setRevealed(_ revealed: Bool, animated: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        onRevealChange?(revealed, animated && !reduceMotion)
    }

    private func cancelTimers() {
        revealWork?.cancel()
        revealWork = nil
        hideWork?.cancel()
        hideWork = nil
    }
}

/// The band along the window's top edge that brings a hidden top bar back.
/// It watches the pointer and never takes a click: clicks fall through to
/// the page or the titlebar under it.
private final class TopBarRevealTriggerView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let newArea = NSTrackingArea(rect: .zero,
                                     options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                     owner: self, userInfo: nil)
        addTrackingArea(newArea)
        area = newArea
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
