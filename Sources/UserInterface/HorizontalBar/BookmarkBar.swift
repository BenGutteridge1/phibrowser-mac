// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit

/// The Space's pins in the Comfortable top bar: the Space's bookmarks and
/// folders, as pills between the pinned tiles and the tabs. Bookmarks that
/// do not fit go into the More menu. A folder opens in place, its bookmarks
/// sliding out beside it in one wash; folders inside it open the same way
/// (`BookmarkFolderGroupView`).
class BookmarkBar: NSView {
    // MARK: - Properties
    private let state: BrowserState
    private var cancellables = Set<AnyCancellable>()
    private var isActive = false
    private var pageColorPresentation = WebContentHeaderPageColorPresentation.inherited

    // Bookmarks currently rendered in the bar.
    private var bookmarks: [Bookmark] = []

    /// Read-only count used by the shared host when deciding visibility.
    var bookmarkCount: Int { state.bookmarkManager.rootFolder.children.count }

    // Bookmarks that overflow into the More menu.
    private var overflowBookmarks: [Bookmark] = []

    // Tracks the current drop index during drag-and-drop.
    private var lastDropIndex: Int = 0

    var showSeparator: Bool = false {
        didSet {
            separatorView.isHidden = !showSeparator
        }
    }
    var onBookmarksChanged: ((Int) -> Void)?

    /// Whether the pills show their titles; the top bar turns them off when
    /// it is short of room.
    var showsTitles = true {
        didSet {
            guard showsTitles != oldValue else { return }
            items.forEach { $0.showsTitle = showsTitles }
            refreshFolderWidths()
            reportPreferredWidth()
            needsLayout = true
        }
    }

    /// The width that shows every pill, reported whenever it changes so the
    /// top bar can size this zone; past it the rest go into the More menu.
    private(set) var preferredWidth: CGFloat = 0
    var onPreferredWidthChange: ((CGFloat) -> Void)?

    /// The width with titles and without, for the top bar's width ladder.
    var titledWidth: CGFloat { contentWidth(showingTitles: true) }
    var iconOnlyWidth: CGFloat { contentWidth(showingTitles: false) }

    /// Every pill built, folders' bookmarks included.
    private var items: [BookmarkItemView] {
        stackView.arrangedSubviews.flatMap { view -> [BookmarkItemView] in
            if let item = view as? BookmarkItemView { return [item] }
            if let group = view as? BookmarkFolderGroupView { return group.allItems }
            return []
        }
    }

    /// The bookmark a unit of the row stands for: a pill's, or a folder's.
    private static func bookmark(of unit: NSView) -> Bookmark? {
        (unit as? BookmarkItemView)?.bookmark ?? (unit as? BookmarkFolderGroupView)?.folderItem.bookmark
    }

    /// Folders open in the bar, at any depth: their bookmarks show beside
    /// them, in one wash. The bar's own state, apart from the sidebar's
    /// expanded rows.
    private var openFolderGuids: Set<String> = []

    /// True while a folder is opening or shutting: the width reported then
    /// is one the bar's host animates to.
    private(set) var isTogglingFolder = false

    // MARK: - Layout Constants
    private let barHeight: CGFloat = 40
    private let itemSpacing: CGFloat = 3
    private let horizontalPadding: CGFloat = 0
    private let verticalPadding: CGFloat = 6
    private let moreButtonWidth: CGFloat = 28
    private let faviconSize: CGFloat = 16

    // MARK: - Subviews
    /// Container for visible bookmark items.
    private lazy var stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = itemSpacing
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.detachesHiddenViews = true
        return stack
    }()

    /// Button that reveals overflow bookmarks.
    private lazy var moreButton: HoverableButtonNSView = {
        let config = HoverableButtonConfig(
                image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "More Bookmarks"),
                imageSize: NSSize(width: 14, height: 14),
                displayMode: .imageOnly,
                hoverBackgroundColor: .sidebarTabHoveredBackground,
                cornerRadius: 8
        )
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(showMoreMenu))
        button.isHidden = true
        return button
    }()

    /// Visual indicator for bookmark drag-and-drop.
    private lazy var dropIndicator: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.isHidden = true
        return view
    }()

    private lazy var separatorView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.isHidden = !showSeparator
        return view
    }()

    // MARK: - Initialization
    init(browserState: BrowserState) {
        self.state = browserState
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Data Binding
    func setActive(_ active: Bool) {
        if active {
            activate()
        } else {
            deactivate()
        }
    }

    private func activate() {
        guard isActive == false else { return }
        isActive = true
        bindData()
        syncCurrentState()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        cancellables.removeAll()
        clearRenderedBookmarks()
    }

    private func bindData() {
        cancellables.removeAll()
        state.bookmarkManager.$rootFolder
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rootFolder in
                self?.updateBookmarks(rootFolder.children)
            }
            .store(in: &cancellables)

        state.themeContext.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.applyThemeAppearance()
            }
            .store(in: &cancellables)
    }

    private func syncCurrentState() {
        updateBookmarks(state.bookmarkManager.rootFolder.children)
        applyThemeAppearance()
    }

    private func clearRenderedBookmarks() {
        bookmarks = []
        overflowBookmarks = []
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        moreButton.isHidden = true
        needsLayout = true
    }

    private func updateBookmarks(_ bookmarks: [Bookmark]) {
        self.bookmarks = bookmarks
        onBookmarksChanged?(bookmarkCount)
        AppLogDebug("Bookmarks updated bookmarks: \(bookmarkCount)")

        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        openFolderGuids.formIntersection(Self.folderGuids(in: bookmarks))

        for bookmark in bookmarks {
            stackView.addArrangedSubview(makeUnit(for: bookmark, nested: false))
        }

        refreshFolderWidths()
        reportPreferredWidth()
        self.needsLayout = true
    }

    private static func folderGuids(in bookmarks: [Bookmark]) -> Set<String> {
        var guids = Set<String>()
        for bookmark in bookmarks where bookmark.isFolder {
            guids.insert(bookmark.guid)
            guids.formUnion(folderGuids(in: bookmark.children))
        }
        return guids
    }

    /// A bookmark's pill, or a folder's group: its pill and, built when it
    /// first opens, its bookmarks.
    private func makeUnit(for bookmark: Bookmark, nested: Bool) -> NSView {
        let item = makeItem(for: bookmark)
        guard bookmark.isFolder else { return item }
        let group = BookmarkFolderGroupView(folderItem: item, spacing: itemSpacing, isNested: nested) { [weak self] child in
            self?.makeUnit(for: child, nested: true) ?? NSView()
        }
        item.onClick = { [weak self, weak group] _ in
            guard let self, let group else { return }
            self.toggleFolder(group)
        }
        if openFolderGuids.contains(bookmark.guid) {
            group.setOpen(true)
            group.setContentShown(true)
        }
        return group
    }

    /// Folders' widths follow their bookmarks', innermost first.
    private func refreshFolderWidths() {
        for case let group as BookmarkFolderGroupView in stackView.arrangedSubviews {
            group.updateWidths(showingTitles: showsTitles)
        }
    }

    private func makeItem(for bookmark: Bookmark) -> BookmarkItemView {
        let itemView = BookmarkItemView(bookmark: bookmark)
        itemView.showsTitle = showsTitles
        itemView.onWidthChange = { [weak self] in self?.schedulePreferredWidthReport() }
        itemView.onClick = { [weak self, weak itemView] clickedBookmark in
            guard let self, let itemView else { return }
            self.handleBookmarkClick(clickedBookmark, itemView: itemView)
        }
        return itemView
    }

    private func width(of unit: NSView, showingTitles: Bool) -> CGFloat {
        if let item = unit as? BookmarkItemView { return item.width(showingTitle: showingTitles) }
        if let group = unit as? BookmarkFolderGroupView { return group.width(showingTitles: showingTitles) }
        return 0
    }

    private func contentWidth(showingTitles: Bool) -> CGFloat {
        let widths = stackView.arrangedSubviews.map { width(of: $0, showingTitles: showingTitles) }
        guard !widths.isEmpty else { return 0 }
        return horizontalPadding * 2 + widths.reduce(0, +) + itemSpacing * CGFloat(widths.count - 1)
    }

    private var preferredWidthReportScheduled = false

    /// Titles arrive one by one after the pills are built; the width is
    /// measured once they have, in one pass.
    private func schedulePreferredWidthReport() {
        guard !preferredWidthReportScheduled else { return }
        preferredWidthReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.preferredWidthReportScheduled = false
            self.refreshFolderWidths()
            self.reportPreferredWidth()
            self.needsLayout = true
        }
    }

    private func reportPreferredWidth() {
        let width = contentWidth(showingTitles: showsTitles)
        guard abs(width - preferredWidth) > 0.5 else { return }
        preferredWidth = width
        onPreferredWidthChange?(width)
    }

    private func applyThemeAppearance(animatesPageColor: Bool = false) {
        let theme = state.themeContext.currentTheme
        let pageAppearance = pageColorPresentation.appearance
        let resolvedAppearance = pageAppearance ?? state.themeContext.currentAppearance
        // No fill of its own: the pills sit on the top bar's themed glass.
        layer?.backgroundColor = NSColor.clear.cgColor
        separatorView.layer?.backgroundColor = ThemedColor.separator.resolve(
            theme: theme, appearance: resolvedAppearance
        ).cgColor
        if appearance?.phiAppearance != pageAppearance {
            appearance = pageAppearance?.nsAppearance
        }
        updateDropIndicatorColor()
    }

    func setPageColorPresentation(_ presentation: WebContentHeaderPageColorPresentation, animated: Bool) {
        pageColorPresentation = presentation
        // Also snaps a fade carried over from the previous tab toward the same color.
        if !animated {
            layer?.removeAnimation(forKey: "backgroundColor")
        }
        applyThemeAppearance(animatesPageColor: animated)
    }

    private func updateDropIndicatorColor() {
        let theme = state.themeContext.currentTheme
        let appearance = state.themeContext.currentAppearance
        dropIndicator.layer?.backgroundColor = ThemedColor.themeColor
            .resolve(theme: theme, appearance: appearance)
            .cgColor
    }

    // MARK: -Setup
    private func setupUI() {
        wantsLayer = true
        layer?.masksToBounds = true
        applyThemeAppearance()

        addSubview(stackView)
        addSubview(dropIndicator)
        addSubview(moreButton)

        moreButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(horizontalPadding)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(moreButtonWidth)
        }
        stackView.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(horizontalPadding)
            // make.trailing.lessThanOrEqualTo(moreButton.snp.leading).offset(-itemSpacing)
            make.top.bottom.equalToSuperview().inset(verticalPadding)
        }

        addSubview(separatorView)
        separatorView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(1)
        }

        // Also accept tabs and pinned tabs so the user can drag any tab from
        // the sidebar / tab strip onto the bar to create a bookmark. Split-
        // pair tabs become one split-view bookmark via
        // `BrowserState.addSplitBookmarkFromTab`.
        registerForDraggedTypes([.phiBookmark, .normalTab, .pinnedTab])
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    override func layout() {
        super.layout()

        let availableWidth = bounds.width
        // The More button only takes room when something overflows.
        let fitsAll = contentWidth(showingTitles: showsTitles) <= availableWidth + 0.5
        let moreAreaWidth = fitsAll ? 0 : moreButtonWidth + itemSpacing + horizontalPadding
        let maxDisplayWidth = availableWidth - moreAreaWidth

        var currentX: CGFloat = horizontalPadding
        var newOverflow: [Bookmark] = []

        var hasOverflowed = false

        for unit in stackView.arrangedSubviews {
            let unitWidth = width(of: unit, showingTitles: showsTitles)

            if currentX + unitWidth > maxDisplayWidth {
                hasOverflowed = true
            }
            if hasOverflowed {
                unit.isHidden = true
                if let bookmark = Self.bookmark(of: unit) {
                    newOverflow.append(bookmark)
                }
            } else {
                unit.isHidden = false
                currentX += (unitWidth + itemSpacing)
            }
        }

        self.overflowBookmarks = newOverflow
        self.moreButton.isHidden = newOverflow.isEmpty
    }

    // MARK: - Helper Methods
    private func createMenuItem(for bookmark: Bookmark) -> NSMenuItem {
        let item = NSMenuItem(title: bookmark.title, action: #selector(menuItemClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = bookmark

        if bookmark.isFolder {
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.submenu = createMenu(for: bookmark)
            return item
        }

        if let secondaryUrl = bookmark.secondaryUrl, !secondaryUrl.isEmpty {
            // Split-view bookmark: mirror the in-bar rendering so the folder
            // dropdown also reads as a split — combined "primary • secondary"
            // label and a dual favicon. Without this, both panes collapse to a
            // single globe icon and the menu looks like a plain bookmark.
            let secondaryDisplay = Self.displayName(forSecondaryTitle: bookmark.secondaryTitle, url: secondaryUrl)
            item.title = secondaryDisplay.isEmpty ? bookmark.title : "\(bookmark.title) • \(secondaryDisplay)"
            item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            loadSplitFavicons(bookmark: bookmark, secondaryUrl: secondaryUrl) { [weak item] image in
                item?.image = image
            }
            return item
        }

        item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let iconSize = self.faviconSize
        BookmarkFaviconLoader.loadPrimaryFavicon(for: bookmark,
                                                 pageURLString: bookmark.url) { [weak item] image in
            guard let image = image else { return }
            DispatchQueue.main.async {
                image.size = NSSize(width: iconSize, height: iconSize)
                item?.image = image
            }
        }
        return item
    }

    /// Returns the best display label for the secondary pane: the stored title
    /// if present, otherwise the URL's host with any leading `www.` stripped.
    /// Mirrors `BookmarkItemView.displayName` so the folder dropdown and the
    /// in-bar item stay visually consistent.
    private static func displayName(forSecondaryTitle title: String?, url: String) -> String {
        if let title, !title.isEmpty { return title }
        guard let parsed = URL(string: url), let host = parsed.host else { return "" }
        if host.hasPrefix("www."), host.count > 4 {
            return String(host.dropFirst(4))
        }
        return host
    }

    /// Loads both favicons of a split bookmark and composes them into a single
    /// side-by-side image suitable for use as an `NSMenuItem.image`. Missing
    /// favicons fall back to the globe symbol so the layout slot still renders.
    private func loadSplitFavicons(bookmark: Bookmark,
                                   secondaryUrl: String,
                                   completion: @escaping (NSImage) -> Void) {
        let iconSize = self.faviconSize
        BookmarkFaviconLoader.loadPrimaryFavicon(for: bookmark,
                                                 pageURLString: bookmark.url) { primaryImage in
            BookmarkFaviconLoader.loadFavicon(profileId: bookmark.profileId,
                                              pageURLString: secondaryUrl) { secondaryResult in
                DispatchQueue.main.async {
                    let composed = BookmarkBar.composeSplitFavicon(primary: primaryImage,
                                                                   secondary: secondaryResult.image,
                                                                   iconSize: iconSize)
                    completion(composed)
                }
            }
        }
    }

    /// Draws two favicons side-by-side with a 2pt gap (matches
    /// `BookmarkItemView`'s in-bar layout) into a single NSImage.
    private static func composeSplitFavicon(primary: NSImage?,
                                            secondary: NSImage?,
                                            iconSize: CGFloat) -> NSImage {
        let gap: CGFloat = 2
        let totalSize = NSSize(width: iconSize * 2 + gap, height: iconSize)
        let composed = NSImage(size: totalSize)
        let fallback = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        composed.lockFocus()
        (primary ?? fallback)?.draw(in: NSRect(x: 0, y: 0, width: iconSize, height: iconSize))
        (secondary ?? fallback)?.draw(in: NSRect(x: iconSize + gap, y: 0, width: iconSize, height: iconSize))
        composed.unlockFocus()
        return composed
    }

    private func createMenu(for folder: Bookmark) -> NSMenu {
        let menu = NSMenu(title: folder.title)
        menu.autoenablesItems = true
        for child in folder.children {
            let item = self.createMenuItem(for: child)
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - NSDraggingDestination
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        let types = pasteboard.types ?? []
        if types.contains(.phiBookmark) {
            return .move
        }
        if types.contains(.normalTab) || types.contains(.pinnedTab) {
            // Use `.copy` for tab → bookmark so the macOS drag cursor shows a
            // "+" badge: the existing tab keeps running and a new bookmark is
            // added on top.
            return .copy
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        let operation: NSDragOperation
        if types.contains(.phiBookmark) {
            operation = .move
        } else if types.contains(.normalTab) || types.contains(.pinnedTab) {
            operation = .copy
        } else {
            return []
        }

        let locationInStack = stackView.convert(sender.draggingLocation, from: nil)
        let visibleItems = stackView.arrangedSubviews.filter { !$0.isHidden }

        var targetX: CGFloat = horizontalPadding
        var insertIndex: Int = 0
        if visibleItems.isEmpty {
            targetX = horizontalPadding
            insertIndex = 0
        } else {
            var found = false
            for (index, item) in visibleItems.enumerated() {
                if locationInStack.x < (item.frame.minX + item.frame.width / 2) {
                    targetX = item.frame.minX - (itemSpacing / 2)
                    insertIndex = index
                    found = true
                    break
                }
            }

            if !found, let last = visibleItems.last {
                targetX = last.frame.maxX + (itemSpacing / 2)
                insertIndex = visibleItems.count
            }
        }
        self.lastDropIndex = insertIndex

        let targetPointInStack = CGPoint(x: targetX - 1, y: 0)
        let targetPointInBar = convert(targetPointInStack, from: stackView)

        dropIndicator.frame = CGRect(x: targetPointInBar.x, y: verticalPadding, width: 2, height: bounds.height - verticalPadding * 2)
        dropIndicator.isHidden = false
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropIndicator.isHidden = true

        guard let pasteboardItem = sender.draggingPasteboard.pasteboardItems?.first else {
            return false
        }

        // Reorder existing bookmark — current behavior. Computed targetIndex
        // is *post-removal* because `moveBookmark` removes-then-inserts.
        if let guid = pasteboardItem.string(forType: .phiBookmark),
           let draggedBookmark = state.bookmarkManager.bookmark(withGuid: guid),
           let currentIndex = bookmarks.firstIndex(of: draggedBookmark) {
            var targetIndex = resolvedDropIndex()
            if targetIndex > currentIndex {
                targetIndex -= 1
            }
            state.bookmarkManager.moveBookmark(draggedBookmark, to: state.bookmarkManager.rootFolder, at: targetIndex)
            return true
        }

        // Tab → bookmark. Drop index here is an *insertion* index (pre-add),
        // so no off-by-one adjustment is needed.
        let sourceState = sourceBrowserState(for: sender.draggingPasteboard) ?? state
        let dropIndex = resolvedDropIndex()

        let batchTabIds = sender.draggingPasteboard.phiNormalTabIds()
        if batchTabIds.count > 1 {
            guard sourceState === state else { return false }
            return state.moveNormalTabs(tabIds: batchTabIds,
                                        toBookmark: nil,
                                        index: dropIndex)
        }

        if let guidString = pasteboardItem.string(forType: .normalTab),
           let tabGuid = Int(guidString),
           let draggedTab = sourceState.tabs.first(where: { $0.guid == tabGuid }) {
            return performTabDrop(draggedTab, sourceState: sourceState, at: dropIndex)
        }

        if let pinnedGuid = pasteboardItem.string(forType: .pinnedTab) {
            return performPinnedTabDrop(pinnedGuid: pinnedGuid,
                                        sourceState: sourceState,
                                        at: dropIndex)
        }

        return false
    }

    /// Translates `lastDropIndex` (visible-row index) back into a position in
    /// the canonical `bookmarks` array used for insertion / move.
    private func resolvedDropIndex() -> Int {
        let units = stackView.arrangedSubviews
        let visibleItems = units.filter { !$0.isHidden }
        let hiddenItems = units.filter { $0.isHidden }
        if lastDropIndex < visibleItems.count, let anchorBookmark = Self.bookmark(of: visibleItems[lastDropIndex]) {
            return bookmarks.firstIndex(of: anchorBookmark) ?? 0
        }
        if let firstHidden = hiddenItems.first, let hiddenBookmark = Self.bookmark(of: firstHidden) {
            return bookmarks.firstIndex(of: hiddenBookmark) ?? bookmarks.count
        }
        return bookmarks.count
    }

    /// Creates a bookmark from a tab. Split-pair tabs become one split-view
    /// bookmark (both panes saved together); ordinary tabs go through the
    /// migrating `moveNormalTab` path so the open tab gets bound to the new
    /// bookmark.
    private func performTabDrop(_ tab: Tab, sourceState: BrowserState, at index: Int) -> Bool {
        if sourceState.addSplitBookmarkFromTab(tab, toFolder: nil, targetIndex: index) {
            return true
        }
        sourceState.moveNormalTab(tabId: tab.guid, toBookmark: nil, index: index)
        return true
    }

    /// Pinned tabs can never be in a split (the right-click "Open as Split"
    /// entry is suppressed for pinned tabs), so the drop always reuses the
    /// existing single-URL conversion path.
    private func performPinnedTabDrop(pinnedGuid: String, sourceState: BrowserState, at index: Int) -> Bool {
        sourceState.movePinnedTabOut(pinnedGuid: pinnedGuid, toBookmark: nil, index: index)
        return true
    }

    /// Resolves the source window's `BrowserState` from the pasteboard's
    /// `.sourceWindowId` entry. Falls back to nil for same-window drags.
    private func sourceBrowserState(for pasteboard: NSPasteboard) -> BrowserState? {
        guard let idString = pasteboard.string(forType: .sourceWindowId),
              let sourceId = Int(idString),
              sourceId != state.windowId else {
            return nil
        }
        return SpaceSessionControllersManager.shared.getBrowserState(for: sourceId)
    }

    // MARK: - Actions
    @objc private func showMoreMenu() {
        let menu = NSMenu(title: "More")
        menu.autoenablesItems = true
        for bookmark in overflowBookmarks {
            menu.addItem(createMenuItem(for: bookmark))
        }
        let origin = NSPoint(x: moreButton.bounds.width, y: 6)
        menu.popUp(positioning: nil, at: origin, in: moreButton)
    }

    private func handleBookmarkClick(_ bookmark: Bookmark, itemView: NSView) {
        AppLogDebug("Bookmark clicked: \(bookmark.title)")
        // Folders open in place (`makeUnit` routes their clicks).
        guard !bookmark.isFolder else { return }
        openBookmark(bookmark)
    }

    /// Opens a folder in place, or shuts it. Nothing is rebuilt: the
    /// folder's bookmarks are laid out at rest behind a clip that widens or
    /// narrows on the same clock as the zone and the tabs after it, and they
    /// fade in or out as it does.
    private func toggleFolder(_ group: BookmarkFolderGroupView) {
        let opening = !group.isOpen
        let guid = group.folderItem.bookmark.guid
        if opening {
            openFolderGuids.insert(guid)
            // Built and laid out at rest behind the shut clip before anything
            // moves, so the bookmarks slide out from behind the folder
            // instead of flying in from nowhere.
            group.setOpen(true)
            group.setContentShown(false)
            group.layoutSubtreeIfNeeded()
            refreshFolderWidths()
        } else {
            openFolderGuids.remove(guid)
            group.setOpen(false)
            refreshFolderWidths()
        }

        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isTogglingFolder = true
        reportPreferredWidth()
        isTogglingFolder = false
        guard animates else {
            group.setContentShown(opening)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = BookmarkFolderGroupView.toggleDuration
            context.timingFunction = BookmarkFolderGroupView.toggleTiming
            group.setContentShown(opening, animated: true)
        }
    }

    private func openBookmark(_ bookmark: Bookmark) {
        state.openBookmark(bookmark)
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        if let bookmark = sender.representedObject as? Bookmark {
            if !bookmark.isFolder {
                openBookmark(bookmark)
            }
        }
    }

    // MARK: - Context Menu
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let superview = self.superview else { return nil }
        let locationInSuperview = superview.convert(event.locationInWindow, from: nil)
        let hit = hitTest(locationInSuperview)
        if hit !== self && hit !== stackView {
            return nil
        }

        let menu = NSMenu()
        let newFolderItem = NSMenuItem(
            title: NSLocalizedString("toolbar.bookmarkBar.newFolderAction", value: "New Folder", comment: "Bookmark New Folder menu item"),
            action: #selector(newFolderAction),
            keyEquivalent: ""
        )
        newFolderItem.target = self
        menu.addItem(newFolderItem)
        return menu
    }

    @MainActor @objc private func newFolderAction() {
        EditPinnedTabPresenter.presentModal(
            mode: .newFolder,
            from: state.windowController?.window
        ) { [weak self] result in
            guard let self, let folderName = result.title, !folderName.isEmpty else { return }
            self.state.bookmarkManager.addFolder(title: folderName)
        }
    }
}

/// A folder in the bar: its pill and, while it is open, its bookmarks
/// beside it in one wash. Folders inside it are groups of their own and open
/// the same way. Its bookmarks are built the first time it opens and kept,
/// laid out at rest behind a clip; opening and shutting only change the
/// clip's width (`updateWidths`), which the bar animates with the zone, and
/// fade the bookmarks and the wash (`setContentShown`).
final class BookmarkFolderGroupView: NSView {
    /// The wash's margin beside the pills; above and below it is half that,
    /// so a top-level folder fills the row's 28pt.
    static let inset: CGFloat = 2
    static let pillHeight: CGFloat = 26
    static let toggleDuration: TimeInterval = 0.22
    static let toggleTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    let folderItem: BookmarkItemView
    private let spacing: CGFloat
    private let makeUnit: (Bookmark) -> NSView
    private(set) var isOpen = false
    /// The folder's bookmarks and folders, once built.
    private(set) var units: [NSView] = []
    private var hasBuiltUnits = false

    private let wash = NSView()
    private let clip = NSView()
    private let childStack = NSStackView()
    private var leadingPad: NSLayoutConstraint!
    private var trailingPad: NSLayoutConstraint!
    private var clipWidth: NSLayoutConstraint!

    /// Every pill built in this folder, its own included.
    var allItems: [BookmarkItemView] {
        [folderItem] + units.flatMap { unit -> [BookmarkItemView] in
            if let item = unit as? BookmarkItemView { return [item] }
            return (unit as? BookmarkFolderGroupView)?.allItems ?? []
        }
    }

    init(folderItem: BookmarkItemView, spacing: CGFloat, isNested: Bool,
         makeUnit: @escaping (Bookmark) -> NSView) {
        self.folderItem = folderItem
        self.spacing = spacing
        self.makeUnit = makeUnit
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        wash.wantsLayer = true
        wash.layer?.cornerRadius = isNested ? 8 : 10
        wash.layer?.cornerCurve = .continuous
        wash.alphaValue = 0
        wash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wash)

        folderItem.translatesAutoresizingMaskIntoConstraints = false
        addSubview(folderItem)

        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)

        childStack.orientation = .horizontal
        childStack.alignment = .centerY
        childStack.spacing = spacing
        childStack.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(childStack)

        leadingPad = folderItem.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailingPad = trailingAnchor.constraint(equalTo: clip.trailingAnchor)
        clipWidth = clip.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.pillHeight + (isNested ? 0 : Self.inset)),
            wash.leadingAnchor.constraint(equalTo: leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: trailingAnchor),
            wash.topAnchor.constraint(equalTo: topAnchor),
            wash.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingPad,
            folderItem.centerYAnchor.constraint(equalTo: centerYAnchor),
            folderItem.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            clip.leadingAnchor.constraint(equalTo: folderItem.trailingAnchor),
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            clipWidth,
            trailingPad,
            childStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: spacing),
            childStack.centerYAnchor.constraint(equalTo: clip.centerYAnchor),
        ])
        updateWash()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens or shuts the folder: builds its bookmarks the first time and
    /// marks its pill. Widths follow on `updateWidths`.
    func setOpen(_ open: Bool) {
        if open, !hasBuiltUnits {
            hasBuiltUnits = true
            units = folderItem.bookmark.children.map(makeUnit)
            for unit in units {
                unit.translatesAutoresizingMaskIntoConstraints = false
                childStack.addArrangedSubview(unit)
                if unit is BookmarkItemView {
                    unit.heightAnchor.constraint(equalToConstant: Self.pillHeight).isActive = true
                }
            }
        }
        isOpen = open
        folderItem.isFolderOpen = open
    }

    /// Shows or hides the wash and the bookmarks; animated inside the
    /// caller's animation group.
    func setContentShown(_ shown: Bool, animated: Bool = false) {
        let alpha: CGFloat = shown ? 1 : 0
        let views = [wash] + units
        for view in views {
            if animated {
                view.animator().alphaValue = alpha
            } else {
                view.alphaValue = alpha
            }
        }
    }

    /// Sets the clip to the bookmarks' width while open, and to nothing
    /// while shut; folders inside it first.
    func updateWidths(showingTitles: Bool) {
        for case let group as BookmarkFolderGroupView in units {
            group.updateWidths(showingTitles: showingTitles)
        }
        let pad = isOpen ? Self.inset : 0
        leadingPad.constant = pad
        trailingPad.constant = pad
        clipWidth.constant = isOpen ? spacing + childrenWidth(showingTitles: showingTitles) : 0
    }

    func width(showingTitles: Bool) -> CGFloat {
        let folderWidth = folderItem.width(showingTitle: showingTitles)
        guard isOpen else { return folderWidth }
        return folderWidth + 2 * Self.inset + spacing + childrenWidth(showingTitles: showingTitles)
    }

    private func childrenWidth(showingTitles: Bool) -> CGFloat {
        let widths = units.map { unit -> CGFloat in
            if let item = unit as? BookmarkItemView { return item.width(showingTitle: showingTitles) }
            return (unit as? BookmarkFolderGroupView)?.width(showingTitles: showingTitles) ?? 0
        }
        return widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
    }

    /// The wash between and around the pills belongs to the group, not the
    /// window: a press there doesn't move the window, and a quick double
    /// press while the folder opens or shuts doesn't zoom it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is BookmarkItemView || hit is BookmarkFolderGroupView ? hit : self
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateWash()
    }

    private func updateWash() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            wash.layer?.backgroundColor = NSColor.topBarControlFill.cgColor
        }
    }
}
