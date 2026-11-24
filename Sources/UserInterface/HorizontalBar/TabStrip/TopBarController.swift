// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit
import SwiftUI

/// Contextual clicks open the strip context menu; scroll gestures feed the
/// swipe-to-switch-Space handler (`TabStripBarView.scrollWheel`) and play
/// no part in window drag/zoom, so claiming them from titlebar space costs
/// nothing. Everything else falls through to the system titlebar.
private func shouldConsumeTitlebarEvent(_ event: NSEvent?) -> Bool {
    ContextMenuEvent.isMouseDown(event) || event?.type == .scrollWheel
}

private func popUpControlClickMenu(for event: NSEvent, in view: NSView) -> Bool {
    guard ContextMenuEvent.isControlClick(event),
          let menu = view.menu(for: event) else {
        return false
    }
    NSMenu.popUpContextMenu(menu, with: event, for: view)
    return true
}

/// ThemedHostingView variant that ignores safe area insets while preserving
/// the right-button cluster's titlebar hit-test behavior.
private final class SafeAreaIgnoringHostingView: ThemedHostingView, TitlebarAwareHitTestable {
    /// Called when the SwiftUI content's size changes (a button shown or
    /// hidden), so the bar can refit without measuring on every layout.
    var onIntrinsicSizeChange: (() -> Void)?

    override var safeAreaInsets: NSEdgeInsets {
        return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if ContextMenuEvent.isControlClick(NSApp.currentEvent), hit != nil {
            return self
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        guard !popUpControlClickMenu(for: event, in: self) else { return }
        super.mouseDown(with: event)
    }

    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        // Right-buttons host wraps interactive SwiftUI controls, so claim
        // left/right clicks (origin/dev) and also scroll so swipe-to-switch-Space
        // works over this region too.
        guard let event = NSApp.currentEvent else {
            return true
        }
        return event.type == .leftMouseDown
            || event.type == .rightMouseDown
            || event.type == .scrollWheel
    }
}

/// ThemedHostingView variant for the Space strip: ignores the titlebar's
/// safe area and takes its clicks inside titlebar space.
private final class SafeAreaIgnoringThemedHostingView: ThemedHostingView, TitlebarAwareHitTestable {
    override var safeAreaInsets: NSEdgeInsets {
        return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if ContextMenuEvent.isControlClick(NSApp.currentEvent), hit != nil {
            return self
        }
        return hit
    }

    /// A click on a Space switches to it, so left clicks are the strip's,
    /// not a window drag.
    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        if NSApp.currentEvent?.type == .leftMouseDown { return true }
        return shouldConsumeTitlebarEvent(NSApp.currentEvent)
    }

    override func mouseDown(with event: NSEvent) {
        guard !popUpControlClickMenu(for: event, in: self) else { return }
        super.mouseDown(with: event)
    }
}

/// The top bar's root view. Empty stretches of the bar fall through to the
/// titlebar, so they move the window and zoom it on a double click; context
/// clicks open the bar's menu and two-finger swipes change Space.
final class TopBarView: NSView, TitlebarAwareHitTestable {
    var onWindowChanged: (() -> Void)?
    var onLayout: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    /// Swipe-to-switch-Space gesture (see `SpaceSwipeTracker`). Gestures land
    /// here when made over the bar itself and when the tab strip declines
    /// them (content fits, or already scrolled to a clamp edge — see
    /// `TabStrip.scrollWheel`).
    var onSpaceSwipe: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        guard !popUpControlClickMenu(for: event, in: self) else { return }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if onSpaceSwipe?(event) != true { super.scrollWheel(with: event) }
    }

    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        shouldConsumeTitlebarEvent(NSApp.currentEvent)
    }
}

/// A 1pt rule between the bar's zones.
private final class TopBarSeparator: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 16) }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}

/// The Comfortable layout's top bar: everything the vertical sidebar holds,
/// along one row.
///
/// From the leading edge: the window's lights, Hide Top Bar, back, forward
/// and reload, the Spaces, the pinned extensions and pinned tabs (the
/// sidebar's own pinned tiles, `PinnedTabViewController` in its row style),
/// the Space's pins and folders (`BookmarkBar`), the address field (the
/// sidebar's own address bar, `TopBarAddressField`), the tab strip with its
/// groups and splits (`TabStrip`), the mini player, and the sidebar's
/// bottom-bar buttons. The tabs come after the address field; the active
/// tab is a selected pill among them.
///
/// The bar paints nothing of its own while docked: it sits on the shell's
/// themed backdrop, the sidebar's glass and Space color, so the theme
/// editor's transparency and saturation apply to it as they do to the
/// sidebar. When the bar is hidden (⌘S) and revealed from the top edge, the
/// container wraps it in the floating glass panel.
final class TopBarController: NSViewController {

    // MARK: - Dependencies

    private let browserState: BrowserState

    /// The window's media controller, for the mini player. Set by the page
    /// tree, which receives it from the window (`useMediaController`).
    var mediaController: SidebarMediaController? {
        didSet {
            guard mediaController !== oldValue else { return }
            mountMiniPlayer()
        }
    }

    // MARK: - Zones

    /// Horizontal tab strip: the Space's tabs, groups and splits.
    private(set) lazy var tabStrip = TabStrip(browserState: browserState)

    private lazy var pinnedTiles = PinnedTabViewController(state: browserState, hostVC: self, style: .row)
    private lazy var spacePins = BookmarkBar(browserState: browserState)
    private lazy var addressField = TopBarAddressField(browserState: browserState)

    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.detachesHiddenViews = true
        return stack
    }()

    private var navigationHost: SafeAreaIgnoringHostingView?
    private lazy var navigationState = TopBarNavigationState(browserState: browserState)
    private var trailingHost: SafeAreaIgnoringHostingView?
    private let trailingState = TopBarTrailingState()
    private let downloadViewModel = DownloadButtonViewModel()
    private var miniPlayerHost: SidebarMediaHostingView?
    private var miniPlayerWidthConstraint: NSLayoutConstraint?
    private var miniPlayerCancellables = Set<AnyCancellable>()
    private var isMiniPlayerShown = false

    private var addressFieldWidth: NSLayoutConstraint?
    private let pinnedSeparator = TopBarSeparator()
    private let tabsSeparator = TopBarSeparator()
    private var pinnedTilesWidth: NSLayoutConstraint?
    private var spacePinsWidth: NSLayoutConstraint?
    private var leadingInsetConstraint: NSLayoutConstraint?

    private var fit = TopBarWidths.Fit()

    // MARK: - Space picker

    /// Hosting view for the Space strip, at the head of the bar after the
    /// navigation buttons.
    private var spacesPickerHostingView: SafeAreaIgnoringThemedHostingView?
    private var spacesPickerSlot: SpaceWindowSlot?
    /// The strip's style when last built (Settings › Spaces: icons or dots).
    private var spacesPickerUsesDots = SpacesStripView.usesDots
    /// The picker's slot in the row. It clips the strip to its Spaces and
    /// slides open to show the "+" while the pointer is on it.
    private let spacesPickerRow = TopBarSpacesRowView()
    private var spacesPickerWidth: NSLayoutConstraint?
    private var spacesHostWidth: NSLayoutConstraint?
    /// The most the strip takes before it scrolls its Spaces.
    private static let spaceStripMaxWidth: CGFloat = 220

    /// Floating hover-card panel for the Space strip.
    private let chipHoverTooltipController = SpaceHoverTooltipController()

    private var cancellables = Set<AnyCancellable>()
    /// Frame observers of this bar and of the zoom button the bar starts
    /// after; see `observeFrameChanges(zoomButton:)`.
    private var frameObservers: [NSObjectProtocol] = []
    private weak var observedZoomButton: NSButton?
    private var leadingInset: CGFloat = 80

    private lazy var contextMenuHelper = TabAreaContextMenuHelper(browserState: browserState, isHorizontalLayout: true)

    private lazy var stripContextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    // MARK: - Initialization

    init(browserState: BrowserState) {
        self.browserState = browserState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        frameObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Lifecycle

    override func loadView() {
        let barView = TopBarView()
        barView.onWindowChanged = { [weak self] in self?.updateLeadingInset() }
        barView.onLayout = { [weak self] in self?.barDidLayout() }
        view = barView
        view.wantsLayer = true
        view.postsFrameChangedNotifications = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    func setActive(_ active: Bool) {
        tabStrip.setActive(active)
        pinnedTiles.setActive(active)
        spacePins.setActive(active)
    }

    func setActivePageStyle(backgroundColor: NSColor?, appearance: Appearance?, animated: Bool = false) {
        tabStrip.setActivePageStyle(backgroundColor: backgroundColor, appearance: appearance, animated: animated)
    }

    /// The address bar inside the field: what ⌘L lays the Omnibox over.
    var addressFieldAnchorView: NSView? {
        addressField.anchorView
    }

    func bindDownloadsManager(_ manager: DownloadsManager) {
        downloadViewModel.bindTo(manager)
    }

    // MARK: - UI Setup

    private func setupUI() {
        let bar = view
        bar.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        let leading = stackView.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: leadingInset)
        leadingInsetConstraint = leading
        NSLayoutConstraint.activate([
            leading,
            stackView.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            stackView.topAnchor.constraint(equalTo: bar.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])

        // Navigation.
        let navigation = TopBarNavigationButtons(
            state: navigationState,
            onToggleTopBar: { [weak self] in self?.browserState.toggleSidebar() },
            onBack: { [weak self] in self?.goBack() },
            onForward: { [weak self] in self?.goForward() },
            onReload: { [weak self] in self?.browserState.focusingTab?.reload() },
            onStop: { [weak self] in self?.browserState.focusingTab?.stopLoading() }
        )
        let navigationHost = SafeAreaIgnoringHostingView(rootView: navigation, themeSource: browserState.themeContext)
        hug(navigationHost)
        navigationHost.onIntrinsicSizeChange = { [weak self] in self?.scheduleFit() }
        navigationHost.setAccessibilityIdentifier("topBar.navigation")
        self.navigationHost = navigationHost
        stackView.addArrangedSubview(navigationHost)

        // Space strip: mounted once the session has a slot.
        mountSpacesPicker()

        // Pinned extensions and pinned tabs.
        addChild(pinnedTiles)
        pinnedTiles.enableContextMenuClickRouting()
        let tiles = pinnedTiles.view
        stackView.addArrangedSubview(tiles)
        tiles.translatesAutoresizingMaskIntoConstraints = false
        pinnedTilesWidth = tiles.widthAnchor.constraint(equalToConstant: 0)
        // Short of required so a window at its narrowest clips the tiles
        // instead of breaking the row's constraints.
        pinnedTilesWidth?.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            pinnedTilesWidth!,
            tiles.heightAnchor.constraint(equalToConstant: PinnedTabLayout.RowMetrics.tileHeight),
        ])
        pinnedTiles.$rowContentWidth
            .removeDuplicates()
            .sink { [weak self] width in self?.pinnedTilesWidthChanged(width) }
            .store(in: &cancellables)

        stackView.addArrangedSubview(pinnedSeparator)

        // Space pins and folders.
        stackView.addArrangedSubview(spacePins)
        spacePins.translatesAutoresizingMaskIntoConstraints = false
        let pinsWidth = spacePins.widthAnchor.constraint(equalToConstant: 0)
        pinsWidth.priority = NSLayoutConstraint.Priority(700)
        spacePinsWidth = pinsWidth
        NSLayoutConstraint.activate([
            pinsWidth,
            spacePins.heightAnchor.constraint(equalTo: stackView.heightAnchor),
        ])
        spacePins.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(650), for: .horizontal)
        spacePins.onPreferredWidthChange = { [weak self] width in
            guard let self else { return }
            let animates = self.spacePins.isTogglingFolder
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            guard animates else {
                self.spacePinsWidth?.constant = width
                self.updateZoneVisibility()
                self.updateFit()
                return
            }
            // A folder opening or shutting: the zone widens or narrows on
            // the folder icon's clock and the tabs after it slide along.
            self.updateZoneVisibility()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                context.allowsImplicitAnimation = true
                self.spacePinsWidth?.constant = width
                self.view.layoutSubtreeIfNeeded()
            }, completionHandler: { [weak self] in
                self?.updateFit()
            })
        }
        stackView.addArrangedSubview(tabsSeparator)

        // The address field, then the tabs.
        stackView.addArrangedSubview(addressField)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        let fieldWidth = addressField.widthAnchor.constraint(equalToConstant: Self.addressFieldWidth)
        // The field keeps the sidebar's width; only a window at its
        // narrowest (400pt), with the tabs and pins already spent, makes it
        // give way rather than break the row's constraints.
        fieldWidth.priority = NSLayoutConstraint.Priority(999)
        addressFieldWidth = fieldWidth
        NSLayoutConstraint.activate([
            fieldWidth,
            addressField.heightAnchor.constraint(equalToConstant: TopBarAddressField.height),
        ])
        addressField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(999), for: .horizontal)

        // Tabs.
        stackView.addArrangedSubview(tabStrip)
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.heightAnchor.constraint(equalTo: stackView.heightAnchor).isActive = true
        tabStrip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabStrip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let minimumTabs = tabStrip.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        minimumTabs.priority = NSLayoutConstraint.Priority(750)
        minimumTabs.isActive = true

        // Mini player, then the sidebar's bottom-bar buttons.
        mountMiniPlayer()
        let trailing = TopBarTrailingButtons(
            cardManager: NotificationCardManager.shared,
            layout: trailingState,
            downloadViewModel: downloadViewModel,
            browserState: browserState,
            onCardEntryTap: { NotificationCardManager.shared.showManually(for: .legacy) },
            onMemoryTap: { [weak self] in self?.openMemory() },
            onChatTap: { [weak self] in self?.toggleChat() },
            onFeedbackTap: { [weak self] in self?.browserState.windowController?.showFeedbackWindow() }
        )
        let trailingHost = SafeAreaIgnoringHostingView(rootView: trailing, themeSource: browserState.themeContext)
        hug(trailingHost)
        trailingHost.onIntrinsicSizeChange = { [weak self] in self?.scheduleFit() }
        self.trailingHost = trailingHost
        stackView.addArrangedSubview(trailingHost)
        downloadViewModel.bindTo(browserState.downloadsManager)

        bar.menu = stripContextMenu
        tabStrip.menu = stripContextMenu
        navigationHost.menu = stripContextMenu
        trailingHost.menu = stripContextMenu

        (bar as? TopBarView)?.onSpaceSwipe = { [weak self] event in
            guard let self, self.spacesPickerEligible,
                  let slot = self.browserState.windowController?.slot else { return false }
            return slot.handleSpaceSwipe(event)
        }

        observeState()
        updateZoneVisibility()
    }

    private func hug(_ view: NSView) {
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func observeState() {
        browserState.$normalTabs
            .map(\.count)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFit() }
            .store(in: &cancellables)
        // Settings the bar reads: Spaces on or off, icons or dots, and the
        // sidebar width the address field follows. Defaults change often for
        // other reasons, so only a change to one of these does any work.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in Self.observedSettings }
            .removeDuplicates()
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        SpaceManager.shared.$spaces
            .map(\.count)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySpacesPickerVisibility() }
            .store(in: &cancellables)
    }

    private struct ObservedSettings: Equatable {
        var spacesEnabled: Bool
        var spacesUseDots: Bool
        var addressFieldWidth: CGFloat
    }

    private static var observedSettings: ObservedSettings {
        ObservedSettings(
            spacesEnabled: PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue(),
            spacesUseDots: SpacesStripView.usesDots,
            addressFieldWidth: addressFieldWidth
        )
    }

    private func settingsChanged() {
        applySpacesPickerVisibility()
        let width = Self.addressFieldWidth
        if let constraint = addressFieldWidth, abs(constraint.constant - width) > 0.5 {
            constraint.constant = width
        }
        updateFit()
    }

    // MARK: - Zones

    private func pinnedTilesWidthChanged(_ width: CGFloat) {
        pinnedTilesWidth?.constant = width
        updateZoneVisibility()
        updateFit()
    }

    /// An empty zone and the rule after it leave the row.
    private func updateZoneVisibility() {
        let hasTiles = pinnedTiles.rowContentWidth > 0
        pinnedTiles.view.isHidden = !hasTiles
        pinnedSeparator.isHidden = !hasTiles
        let hasPins = spacePins.preferredWidth > 0
        spacePins.isHidden = !hasPins
        tabsSeparator.isHidden = !hasPins
    }

    /// The bar's width at the last fit. Layout passes that keep the width
    /// (animations inside the row) don't refit.
    private var fittedWidth: CGFloat = 0

    private func barDidLayout() {
        updateLeadingInset()
        guard abs(view.bounds.width - fittedWidth) > 0.5 else { return }
        updateFit()
    }

    private var fitScheduled = false

    /// Refits once on the next turn, however many changes arrive in this one.
    private func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            self.updateFit()
        }
    }

    // MARK: - Width ladder

    private func updateFit() {
        guard isViewLoaded, view.bounds.width > 0 else { return }
        fittedWidth = view.bounds.width
        let spaceRowWidth = spacesPickerRow.isHidden ? 0
            : spaceStripWidth - SpacesStripView.trailingSlotWidth
        let parts = TopBarWidths.Parts(
            fixed: leadingInset + 8 + (navigationHost?.intrinsicContentSize.width ?? 0)
                + stackView.spacing * 8 + 2 + TabStripMetrics.NewTabButton.size.width
                + (addressFieldWidth?.constant ?? Self.addressFieldWidth) + spaceRowWidth,
            pinnedTiles: pinnedTiles.rowContentWidth,
            spacePinsTitled: spacePins.titledWidth,
            spacePinsIconOnly: spacePins.iconOnlyWidth,
            trailingFull: trailingFullWidth,
            trailingFolded: trailingFoldedWidth,
            playerFull: isMiniPlayerShown ? Self.miniPlayerFullWidth : 0,
            playerCompact: isMiniPlayerShown ? Self.miniPlayerCompactWidth : 0,
            tabCount: browserState.normalTabs.count
        )
        let newFit = TopBarWidths.solve(room: view.bounds.width, parts: parts)
        guard newFit != fit else { return }
        let playerChanged = newFit.compactPlayer != fit.compactPlayer
        fit = newFit
        spacePins.showsTitles = newFit.spacePinTitles
        if trailingState.foldsButtons != newFit.foldsTrailingButtons {
            trailingState.foldsButtons = newFit.foldsTrailingButtons
        }
        if playerChanged { applyMiniPlayerWidth() }
    }

    /// The sidebar's address bar's width: the width the user gave the
    /// sidebar, less the address bar's insets, on the side they keep it.
    static var addressFieldWidth: CGFloat {
        let side = PhiPreferences.GeneralSettings.loadSidebarPosition()
        let stored = AccountController.shared.localDataAccount?.userDefaults
            .lastKnownSidebarWidth(for: side) ?? 0
        let sidebarWidth = stored >= ShellSplitViewController.leftItemMinWidth
            ? min(stored, ShellSplitViewController.leftItemMaxWidth)
            : ShellSplitViewController.leftItemMinWidth
        return sidebarWidth - 2 * WebContentConstant.edgesSpacing
    }

    /// The trailing buttons' width unfolded, measured while they are, and an
    /// estimate before that.
    private var measuredTrailingFullWidth: CGFloat?
    private var trailingFullWidth: CGFloat {
        if !trailingState.foldsButtons, let host = trailingHost {
            measuredTrailingFullWidth = host.intrinsicContentSize.width
        }
        return measuredTrailingFullWidth ?? 180
    }
    private var trailingFoldedWidth: CGFloat { 3 * 28 + 8 }

    // MARK: - Mini player

    private static let miniPlayerFullWidth: CGFloat = 138
    private static let miniPlayerCompactWidth: CGFloat = 62

    private func mountMiniPlayer() {
        guard isViewLoaded, let mediaController else { return }
        let surface = SidebarMediaController.Surface(session: browserState, kind: .topBar)
        let host: SidebarMediaHostingView
        if let existing = miniPlayerHost {
            host = existing
            host.mediaController = mediaController
            host.mediaSurface = surface
            host.setThemedContent(SidebarMediaPlayerView(controller: mediaController, surface: surface,
                                                        showsTrackControls: !fit.compactPlayer))
        } else {
            host = SidebarMediaHostingView(
                rootView: SidebarMediaPlayerView(controller: mediaController, surface: surface,
                                                 showsTrackControls: !fit.compactPlayer),
                themeSource: browserState.themeContext
            )
            host.subtreeThemeSource = browserState.themeContext
            host.ignoresSafeAreaInsets = true
            host.mediaController = mediaController
            host.mediaSurface = surface
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            let width = host.widthAnchor.constraint(equalToConstant: Self.miniPlayerFullWidth)
            miniPlayerWidthConstraint = width
            NSLayoutConstraint.activate([width, host.heightAnchor.constraint(equalToConstant: 28)])
            host.isHidden = true
            miniPlayerHost = host
            if let trailingHost, let index = stackView.arrangedSubviews.firstIndex(of: trailingHost) {
                stackView.insertArrangedSubview(host, at: index)
            } else {
                stackView.addArrangedSubview(host)
            }
        }
        bindMiniPlayer(mediaController)
        updateMiniPlayerActivation()
    }

    /// Shown while the player has something to show: the same conditions the
    /// sidebar's player height follows.
    private func bindMiniPlayer(_ controller: SidebarMediaController) {
        miniPlayerCancellables.removeAll()
        controller.$item
            .combineLatest(controller.$isRevalidating, controller.$isSourceVisible, controller.$isDismissed)
            .combineLatest(controller.$isEnabled, controller.$activeSurface)
            .map { [weak self] state, enabled, activeSurface in
                let (item, revalidating, sourceVisible, dismissed) = state
                guard let self else { return false }
                return enabled && item != nil && !revalidating && !sourceVisible && !dismissed
                    && activeSurface?.kind == .topBar
                    && activeSurface?.sessionID == ObjectIdentifier(self.browserState)
            }
            .removeDuplicates()
            .debounce(for: .zero, scheduler: DispatchQueue.main)
            .sink { [weak self] shown in
                guard let self else { return }
                self.isMiniPlayerShown = shown
                self.miniPlayerHost?.isHidden = !shown
                self.updateFit()
            }
            .store(in: &miniPlayerCancellables)
    }

    private func applyMiniPlayerWidth() {
        guard let mediaController, let host = miniPlayerHost else { return }
        miniPlayerWidthConstraint?.constant = fit.compactPlayer ? Self.miniPlayerCompactWidth : Self.miniPlayerFullWidth
        let surface = SidebarMediaController.Surface(session: browserState, kind: .topBar)
        host.setThemedContent(SidebarMediaPlayerView(controller: mediaController, surface: surface,
                                                    showsTrackControls: !fit.compactPlayer))
    }

    /// The player takes interactions while this bar is on screen.
    func updateMiniPlayerActivation() {
        guard let mediaController else { return }
        let surface = SidebarMediaController.Surface(session: browserState, kind: .topBar)
        let window = view.window
        let active = browserState.layoutMode.isTraditional
            && window?.isVisible == true && window?.isMiniaturized == false
            && !view.isHiddenOrHasHiddenAncestor
        mediaController.setActive(active, on: surface)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateMiniPlayerActivation()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        updateMiniPlayerActivation()
    }

    // MARK: - Actions

    private func goBack() {
        if browserState.closePeekForBackForwardNavigation() { return }
        if browserState.closeReaderOverlayForBackForwardNavigation() { return }
        browserState.focusingTab?.goBack()
    }

    private func goForward() {
        if browserState.closePeekForBackForwardNavigation() { return }
        if browserState.closeReaderOverlayForBackForwardNavigation() { return }
        browserState.focusingTab?.goForward()
    }

    private func openMemory() {
        FeatureEntryAnalytics.capture(.memory, surface: .webContentHeader)
        browserState.createTab("chrome://memory/memory.html", focusAfterCreate: true)
        FirstTimeActionTracker.capture(.memoryOpened)
    }

    private func toggleChat() {
        guard !browserState.isInPlaceholderMode, browserState.groupOverviewState == nil else {
            NSSound.beep()
            return
        }
        FeatureEntryAnalytics.capture(.chat, surface: .webContentHeader)
        browserState.toggleAIChat()
    }

    // MARK: - Space picker

    /// Builds the active-Space picker against this Space's own slot. Hosted
    /// mode can build the bar before its session has one — a prewarmed spare
    /// is loaded before any session adopts it — and the key window's slot it
    /// used to fall back to is another window's: the strip then showed and
    /// switched that window's Space. So it waits for `bindSpacesPickerToSession`.
    ///
    /// Windows that don't participate in Spaces (standalone incognito), and
    /// windows that resolve no slot, skip the picker instead of building it
    /// and hiding it; neither may mint a slot (see
    /// `SpaceManager.reclaimsMintedSlot`).
    private func mountSpacesPicker() {
        guard spacesPickerHostingView == nil, browserState.participatesInSpaces,
              let slot = browserState.windowController?.slot else { return }
        spacesPickerSlot = slot
        let spacesHostingView = SafeAreaIgnoringThemedHostingView(
            rootView: makeSpacesPicker(slot: slot),
            themeSource: browserState.themeContext
        )
        hug(spacesHostingView)
        hug(spacesPickerRow)
        spacesHostingView.setAccessibilityIdentifier("tabStrip.spacePicker")
        spacesPickerHostingView = spacesHostingView
        stackView.insertArrangedSubview(spacesPickerRow, at: navigationHost == nil ? 0 : 1)
        spacesPickerRow.translatesAutoresizingMaskIntoConstraints = false
        spacesPickerRow.addSubview(spacesHostingView)
        spacesHostingView.translatesAutoresizingMaskIntoConstraints = false
        let rowWidth = spacesPickerRow.widthAnchor.constraint(equalToConstant: 0)
        let hostWidth = spacesHostingView.widthAnchor.constraint(equalToConstant: 0)
        spacesPickerWidth = rowWidth
        spacesHostWidth = hostWidth
        spacesPickerRow.clipsContent = true
        NSLayoutConstraint.activate([
            rowWidth,
            hostWidth,
            spacesPickerRow.heightAnchor.constraint(equalToConstant: SpacesStripView.height),
            spacesHostingView.leadingAnchor.constraint(equalTo: spacesPickerRow.leadingAnchor),
            spacesHostingView.topAnchor.constraint(equalTo: spacesPickerRow.topAnchor),
            spacesHostingView.bottomAnchor.constraint(equalTo: spacesPickerRow.bottomAnchor),
        ])
        spacesPickerRow.onHoverChange = { [weak self] hovering in
            self?.setSpaceRowOpen(hovering)
        }
        layoutSpacesPickerRow()
        // Right-click shows the bar's menu (the active-Space controls); a
        // click on a Space switches to it, as in the sidebar.
        spacesHostingView.menu = stripContextMenu
        applySpacesPickerVisibility()
    }

    /// The sidebar's own Space strip: one icon or dot per Space (Settings ›
    /// Spaces) and the "+" at its end.
    private func makeSpacesPicker(slot: SpaceWindowSlot) -> SpacesStripView {
        SpacesStripView(
            manager: SpaceManager.shared,
            slot: slot,
            rowHeight: SpacesStripView.height,
            showsEllipsisAffordance: true,
            alwaysShowsAddButton: true,
            resolveOwnerController: { [weak browserState] in browserState?.windowController },
            chipTooltipController: chipHoverTooltipController
        )
    }

    private var spaceStripWidth: CGFloat {
        min(SpacesStripView.fullStripWidth(count: SpaceManager.shared.spaces.count), Self.spaceStripMaxWidth)
    }

    /// The strip keeps its full width; the row shows its Spaces, or its
    /// Spaces and the "+" while open.
    private func layoutSpacesPickerRow() {
        let full = spaceStripWidth
        spacesHostWidth?.constant = full
        spacesPickerWidth?.constant = isSpaceRowOpen ? full : full - SpacesStripView.trailingSlotWidth
    }

    private var isSpaceRowOpen = false

    /// Slides the Space row open to show the "+", or shut to its Spaces.
    private func setSpaceRowOpen(_ open: Bool) {
        guard open != isSpaceRowOpen else { return }
        isSpaceRowOpen = open
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layoutSpacesPickerRow()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = open ? 0.2 : 0.16
            context.timingFunction = open
                ? CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                : CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            layoutSpacesPickerRow()
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Follows Settings › Spaces: icons and dots have different widths.
    private func applySpacesPickerStyle() {
        guard let host = spacesPickerHostingView, let slot = spacesPickerSlot else { return }
        let usesDots = SpacesStripView.usesDots
        if usesDots != spacesPickerUsesDots {
            spacesPickerUsesDots = usesDots
            host.setThemedContent(makeSpacesPicker(slot: slot))
        }
        layoutSpacesPickerRow()
    }

    /// The session wired this Space into its window: mount the picker if it
    /// was deferred.
    func bindSpacesPickerToSession() {
        guard spacesPickerHostingView == nil, isViewLoaded else { return }
        mountSpacesPicker()
    }

    /// Whether the active-Space picker should appear in this window: the
    /// master Spaces flag must be on and the window must participate in
    /// Spaces. The Incognito Space's window is a Space and keeps the picker.
    private var spacesPickerEligible: Bool {
        PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue() && browserState.participatesInSpaces
    }

    /// With a single Space there is nothing to switch to, so the row stays
    /// hidden until a second Space exists.
    private func applySpacesPickerVisibility() {
        let enabled = spacesPickerEligible && SpaceManager.shared.spaces.count > 1
        spacesPickerRow.isHidden = !enabled || spacesPickerHostingView == nil
        applySpacesPickerStyle()
    }

    // MARK: - Leading inset

    /// The row starts just past the window's lights.
    private func updateLeadingInset() {
        let window = view.window
        let button = window?.standardWindowButton(.zoomButton)
        observeFrameChanges(zoomButton: button)
        let inset: CGFloat
        // In full screen the lights live in the system's titlebar window,
        // shown over the bar on demand, so the row starts at the edge.
        if let window, let button, !button.isHidden, button.window === window,
           !window.styleMask.contains(.fullScreen) {
            let frameInWindow = button.convert(button.bounds, to: nil)
            inset = view.convert(frameInWindow, from: nil).maxX + 10
        } else {
            inset = 12
        }
        guard abs(leadingInset - inset) > 0.01 else { return }
        leadingInset = inset
        leadingInsetConstraint?.constant = inset
    }

    /// Realigns the row when this bar or the zoom button changes frame. Both
    /// are observed as objects: an observer without one runs for every view
    /// resized anywhere in the app. The block form keeps neither view, and so
    /// not the window, alive.
    private func observeFrameChanges(zoomButton: NSButton?) {
        if let zoomButton, zoomButton === observedZoomButton { return }
        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers = []
        observedZoomButton = zoomButton
        guard let zoomButton else { return }
        frameObservers = [view, zoomButton].map { observed in
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: observed,
                queue: .main
            ) { [weak self] _ in
                self?.updateLeadingInset()
            }
        }
        if let window = view.window {
            frameObservers += [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification]
                .map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.updateLeadingInset()
                    }
                }
        }
    }
}

// MARK: - Context Menu

extension TopBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === stripContextMenu {
            contextMenuHelper.populate(menu)
        }
    }
}

/// The Space picker's slot in the top bar. It clips the strip to its
/// Spaces, and reports the pointer coming and going so the bar can
/// slide it open to the "+". Tracked here, in AppKit, the pointer opens it
/// from whichever side it arrives.
final class TopBarSpacesRowView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    private var closeWork: DispatchWorkItem?

    var clipsContent = false {
        didSet {
            wantsLayer = true
            layer?.masksToBounds = clipsContent
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let newArea = NSTrackingArea(rect: .zero,
                                     options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                     owner: self, userInfo: nil)
        addTrackingArea(newArea)
        area = newArea
    }

    override func mouseEntered(with event: NSEvent) {
        closeWork?.cancel()
        closeWork = nil
        onHoverChange?(true)
    }

    /// Shuts a moment after the pointer leaves, so passing out and back in
    /// doesn't make it twitch.
    override func mouseExited(with event: NSEvent) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.closeWork = nil
            self?.onHoverChange?(false)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
