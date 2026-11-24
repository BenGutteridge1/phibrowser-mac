// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit

/// The Space's pins in the Comfortable top bar: the Space's bookmarks and
/// folders, as pills between the pinned tiles and the tabs. Bookmarks that
/// do not fit go into the More menu; folders open as menus.
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

    /// Every pill, open folders' bookmarks included.
    private var items: [BookmarkItemView] {
        stackView.arrangedSubviews.flatMap { view -> [BookmarkItemView] in
            if let item = view as? BookmarkItemView { return [item] }
            if let group = view as? BookmarkFolderGroupView { return group.items }
            return []
        }
    }

    /// Folders open in the bar: their bookmarks show beside them, in one
    /// wash. The bar's own state, apart from the sidebar's expanded rows.
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
        let liveGuids = Set(bookmarks.filter(\.isFolder).map(\.guid))
        openFolderGuids.formIntersection(liveGuids)

        for bookmark in bookmarks {
            let itemView = makeItem(for: bookmark)
            if bookmark.isFolder, openFolderGuids.contains(bookmark.guid) {
                itemView.isFolderOpen = true
                let children = bookmark.children.map { makeItem(for: $0) }
                stackView.addArrangedSubview(BookmarkFolderGroupView(
                    folderItem: itemView, childItems: children, spacing: itemSpacing))
            } else {
                stackView.addArrangedSubview(itemView)
            }
        }

        reportPreferredWidth()
        self.needsLayout = true
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
                if let item = unit as? BookmarkItemView {
                    newOverflow.append(item.bookmark)
                } else if let group = unit as? BookmarkFolderGroupView {
                    newOverflow.append(group.folderItem.bookmark)
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
        let visibleItems = stackView.arrangedSubviews.compactMap { $0 as? BookmarkItemView }.filter { !$0.isHidden }

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
        let visibleItems = stackView.arrangedSubviews.compactMap { $0 as? BookmarkItemView }.filter { !$0.isHidden }
        let hiddenItems = stackView.arrangedSubviews.compactMap { $0 as? BookmarkItemView }.filter { $0.isHidden }
        if lastDropIndex < visibleItems.count {
            let anchorBookmark = visibleItems[lastDropIndex].bookmark
            return bookmarks.firstIndex(of: anchorBookmark) ?? 0
        }
        if let firstHidden = hiddenItems.first {
            return bookmarks.firstIndex(of: firstHidden.bookmark) ?? bookmarks.count
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
        if bookmark.isFolder {
            if bookmarks.contains(where: { $0 === bookmark }) {
                toggleFolder(bookmark)
            } else {
                // A folder inside an open folder opens as a menu.
                showFolderMenu(for: bookmark, relativeTo: itemView)
            }
        } else {
            openBookmark(bookmark)
        }
    }

    /// Opens a top-level folder in place, or shuts it.
    private func toggleFolder(_ folder: Bookmark) {
        if openFolderGuids.contains(folder.guid) {
            openFolderGuids.remove(folder.guid)
        } else {
            openFolderGuids.insert(folder.guid)
        }
        isTogglingFolder = true
        updateBookmarks(bookmarks)
        isTogglingFolder = false
        // The newly shown bookmarks fade up as the zone widens.
        if let group = stackView.arrangedSubviews.lazy
            .compactMap({ $0 as? BookmarkFolderGroupView })
            .first(where: { $0.folderItem.bookmark.guid == folder.guid }),
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            group.childItems.forEach { $0.alphaValue = 0 }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                group.childItems.forEach { $0.animator().alphaValue = 1 }
            }
        }
    }

    private func openBookmark(_ bookmark: Bookmark) {
        state.openBookmark(bookmark)
    }

    private func showFolderMenu(for folder: Bookmark, relativeTo itemView: NSView) {
        let menu = createMenu(for: folder)
        let origin = NSPoint(x: 0, y: -6)
        menu.popUp(positioning: nil, at: origin, in: itemView)
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

/// An open folder in the bar: its pill and its bookmarks in one rounded
/// wash, so where the folder ends reads at a glance.
final class BookmarkFolderGroupView: NSView {
    static let inset: CGFloat = 2
    let folderItem: BookmarkItemView
    let childItems: [BookmarkItemView]
    private let spacing: CGFloat
    private let stack = NSStackView()

    var items: [BookmarkItemView] { [folderItem] + childItems }

    init(folderItem: BookmarkItemView, childItems: [BookmarkItemView], spacing: CGFloat) {
        self.folderItem = folderItem
        self.childItems = childItems
        self.spacing = spacing
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        items.forEach { stack.addArrangedSubview($0) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
        ])
        updateWash()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The wash between and around the pills belongs to the group, not the
    /// window: a press there doesn't move the window, and a quick double
    /// press while the folder opens or shuts doesn't zoom it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is BookmarkItemView ? hit : self
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func width(showingTitles: Bool) -> CGFloat {
        let widths = items.map { $0.width(showingTitle: showingTitles) }
        return Self.inset * 2 + widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width(showingTitles: folderItem.showsTitle), height: NSView.noIntrinsicMetric)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateWash()
    }

    private func updateWash() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = NSColor.sidebarTabHovered.cgColor
        }
    }
}
