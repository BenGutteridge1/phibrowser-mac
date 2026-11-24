// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class PinnedTabLayout: NSCollectionViewLayout {
    enum Section: Int {
        case extensions = 0
        case tabs = 1
    }

    private struct SectionMetrics {
        var numberOfItems: Int = 0
        var numberOfColumns: Int = 0
        var numberOfRows: Int = 0
        var itemSize: NSSize = .zero
        var sectionHeight: CGFloat = 0

        static let empty = SectionMetrics()
    }

    private struct LayoutInput: Equatable {
        let contentWidth: CGFloat
        let tabCount: Int
        let extensionCount: Int
    }

    private enum Constants {
        static let spacing: CGFloat = 8
        static let insets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        static let tabHeight: CGFloat = 45
        static let extensionHeight: CGFloat = 28
        static let tabMinimumWidth: CGFloat = 53
        static let extensionMinimumWidth: CGFloat = 26
    }

    /// `grid`: the sidebar's band, rows of tiles filling its width.
    /// `row`: the Comfortable top bar's run, every tile in one row at its own
    /// width (extensions first), as wide as its tiles.
    enum Style {
        case grid
        case row
    }

    enum RowMetrics {
        static let tileWidth: CGFloat = 30
        static let tileHeight: CGFloat = 28
        static let spacing: CGFloat = 3
        /// Between the last extension and the first pinned tab.
        static let sectionGap: CGFloat = 6
        /// A pinned split's tile: one 16pt favicon slot per pane.
        static func splitTileWidth(paneCount: Int) -> CGFloat {
            12 + CGFloat(max(2, paneCount)) * 18
        }
    }

    let style: Style

    /// Row style: the width of the tile at an index path, for tiles wider
    /// than one (pinned splits). Nil answers `RowMetrics.tileWidth`.
    var rowItemWidth: ((IndexPath) -> CGFloat?)?

    /// Row style: the run's width, reported after every layout pass that
    /// changes it, so the top bar can size the zone.
    private(set) var rowContentWidth: CGFloat = 0
    var onRowContentWidthChange: ((CGFloat) -> Void)?

    /// Gaps before the first row and after the last row of the grid.
    let topInset: CGFloat
    let bottomInset: CGFloat

    private var pendingConfiguredWidth: CGFloat?
    private var lastPreparedInput: LayoutInput?
    private var cachedAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var orderedAttributes: [NSCollectionViewLayoutAttributes] = []
    private var contentSize: NSSize = .zero

    private var tabMetrics: SectionMetrics = .empty
    private var extensionMetrics: SectionMetrics = .empty

    init(topInset: CGFloat, bottomInset: CGFloat, style: Style = .grid) {
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.style = style
        super.init()
    }

    override convenience init() {
        self.init(topInset: Constants.insets.top, bottomInset: Constants.insets.bottom)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var numberOfRows: Int {
        tabMetrics.numberOfRows
    }

    var currentItemSize: NSSize {
        tabMetrics.itemSize
    }

    var contentHeight: CGFloat {
        contentSize.height
    }

    var tabLayoutInfo: (columns: Int, rows: Int, itemSize: NSSize) {
        (tabMetrics.numberOfColumns, tabMetrics.numberOfRows, tabMetrics.itemSize)
    }

    var extensionLayoutInfo: (columns: Int, rows: Int, itemSize: NSSize) {
        (extensionMetrics.numberOfColumns, extensionMetrics.numberOfRows, extensionMetrics.itemSize)
    }

    func configure(parentWidth: CGFloat, tabCount: Int, extensionCount: Int) {
        let input = LayoutInput(contentWidth: parentWidth, tabCount: tabCount, extensionCount: extensionCount)
        if lastPreparedInput != input {
            pendingConfiguredWidth = parentWidth
            invalidateLayout()
        }
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else {
            return
        }

        let extensionCount = numberOfItems(in: .extensions, collectionView: collectionView)
        let tabCount = numberOfItems(in: .tabs, collectionView: collectionView)
        let contentWidth = pendingConfiguredWidth ?? collectionView.bounds.width
        let input = LayoutInput(contentWidth: contentWidth, tabCount: tabCount, extensionCount: extensionCount)

        guard input != lastPreparedInput else {
            return
        }
        lastPreparedInput = input
        recalculateLayout(using: input)
    }

    override var collectionViewContentSize: NSSize {
        contentSize
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        orderedAttributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        cachedAttributes[indexPath]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard style == .grid, let collectionView else { return false }
        return abs(newBounds.width - collectionView.bounds.width) > .ulpOfOne
    }
}

// MARK: - Private Helpers
private extension PinnedTabLayout {
    func numberOfItems(in section: Section, collectionView: NSCollectionView) -> Int {
        guard collectionView.numberOfSections > section.rawValue else { return 0 }
        return collectionView.numberOfItems(inSection: section.rawValue)
    }

    private func recalculateLayout(using input: LayoutInput) {
        if style == .row {
            recalculateRowLayout(using: input)
            return
        }
        guard input.contentWidth > 0 else {
            resetLayoutState(withWidth: input.contentWidth)
            return
        }

        pendingConfiguredWidth = nil
        cachedAttributes.removeAll()
        orderedAttributes.removeAll()

        let tabMaxColumns = tabColumnsLimit(for: input.contentWidth)
        let extensionMaxColumns = extensionColumnsLimit(for: input.contentWidth)
        extensionMetrics = metrics(for: input.extensionCount, itemHeight: Constants.extensionHeight, minimumWidth: Constants.extensionMinimumWidth, contentWidth: input.contentWidth, columnLimit: extensionMaxColumns)
        tabMetrics = metrics(for: input.tabCount, itemHeight: Constants.tabHeight, minimumWidth: Constants.tabMinimumWidth, contentWidth: input.contentWidth, columnLimit: tabMaxColumns)

        let hasExtensions = extensionMetrics.numberOfItems > 0
        let hasTabs = tabMetrics.numberOfItems > 0
        var yOffset: CGFloat = 0
        if hasExtensions || hasTabs {
            yOffset = topInset
        }

        if hasExtensions {
            layout(section: .extensions, metrics: extensionMetrics, yOffset: &yOffset)
        }

        if hasTabs {
            if hasExtensions {
                yOffset += Constants.spacing
            }
            layout(section: .tabs, metrics: tabMetrics, yOffset: &yOffset)
        }

        if hasExtensions || hasTabs {
            yOffset += bottomInset
        }

        contentSize = NSSize(width: input.contentWidth, height: yOffset)
    }

    /// One row, extensions then pinned tabs, each tile at its own width.
    /// The run does not depend on the view's width: the view takes the run's.
    private func recalculateRowLayout(using input: LayoutInput) {
        pendingConfiguredWidth = nil
        cachedAttributes.removeAll()
        orderedAttributes.removeAll()
        tabMetrics = .empty
        extensionMetrics = .empty

        var x: CGFloat = 0
        func place(_ section: Section, count: Int) {
            for index in 0..<count {
                let indexPath = IndexPath(item: index, section: section.rawValue)
                let width = rowItemWidth?(indexPath) ?? RowMetrics.tileWidth
                let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
                attributes.frame = NSRect(x: x, y: 0, width: width, height: RowMetrics.tileHeight)
                cachedAttributes[indexPath] = attributes
                orderedAttributes.append(attributes)
                x += width + RowMetrics.spacing
            }
        }
        place(.extensions, count: input.extensionCount)
        if input.extensionCount > 0, input.tabCount > 0 {
            x += RowMetrics.sectionGap - RowMetrics.spacing
        }
        place(.tabs, count: input.tabCount)
        let width = max(0, x - (orderedAttributes.isEmpty ? 0 : RowMetrics.spacing))
        contentSize = NSSize(width: width, height: orderedAttributes.isEmpty ? 0 : RowMetrics.tileHeight)
        if abs(width - rowContentWidth) > 0.5 {
            rowContentWidth = width
            let report = onRowContentWidthChange
            DispatchQueue.main.async { report?(width) }
        }
    }

    func resetLayoutState(withWidth width: CGFloat) {
        cachedAttributes.removeAll()
        orderedAttributes.removeAll()
        tabMetrics = .empty
        extensionMetrics = .empty
        contentSize = NSSize(width: width, height: 0)
    }

    /// Width used for column-limit breakpoints. Parent width grew by the same
    /// amount as `insets.right` when the sidebar trailing edge was added.
    func columnDecisionWidth(for contentWidth: CGFloat) -> CGFloat {
        max(contentWidth - Constants.insets.right, 0)
    }

    func tabColumnsLimit(for contentWidth: CGFloat) -> Int {
        let width = columnDecisionWidth(for: contentWidth)
        if width < 236 {
            return 3
        } else if width < 294 {
            return 4
        } else if width < 352 {
            return 5
        } else {
            return 6
        }
    }

    func extensionColumnsLimit(for contentWidth: CGFloat) -> Int {
        let width = columnDecisionWidth(for: contentWidth)
        if width <= 250 {
            return 5
        } else if width <= 350 {
            return 7
        } else {
            return 10
        }
    }

    private func metrics(for itemCount: Int, itemHeight: CGFloat, minimumWidth: CGFloat, contentWidth: CGFloat, columnLimit: Int) -> SectionMetrics {
        guard itemCount > 0 else {
            return .empty
        }

        var columns = min(columnLimit, itemCount)
        let availableWidth = max(contentWidth - Constants.insets.left - Constants.insets.right, 0)

        while columns > 1 {
            let itemWidth = (availableWidth - CGFloat(columns - 1) * Constants.spacing) / CGFloat(columns)
            if itemWidth >= minimumWidth {
                break
            }
            columns -= 1
        }

        var itemWidth: CGFloat
        if columns == 0 {
            columns = 1
        }

        let calculatedWidth = (availableWidth - CGFloat(columns - 1) * Constants.spacing) / CGFloat(columns)
        itemWidth = max(minimumWidth, calculatedWidth)

        let rows = Int(ceil(Double(itemCount) / Double(columns)))
        let sectionHeight = CGFloat(rows) * itemHeight + CGFloat(max(0, rows - 1)) * Constants.spacing
        return SectionMetrics(
            numberOfItems: itemCount,
            numberOfColumns: columns,
            numberOfRows: rows,
            itemSize: NSSize(width: itemWidth, height: itemHeight),
            sectionHeight: sectionHeight
        )
    }

    private func layout(section: Section, metrics: SectionMetrics, yOffset: inout CGFloat) {
        guard metrics.numberOfItems > 0, metrics.numberOfColumns > 0, let collectionView else { return }
        let itemsInSection = min(metrics.numberOfItems, numberOfItems(in: section, collectionView: collectionView))
        guard itemsInSection > 0 else { return }

        for itemIndex in 0..<itemsInSection {
            let row = itemIndex / metrics.numberOfColumns
            let column = itemIndex % metrics.numberOfColumns

            let originX = Constants.insets.left + CGFloat(column) * (metrics.itemSize.width + Constants.spacing)
            let originY = yOffset + CGFloat(row) * (metrics.itemSize.height + Constants.spacing)

            let indexPath = IndexPath(item: itemIndex, section: section.rawValue)
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = NSRect(x: originX, y: originY, width: metrics.itemSize.width, height: metrics.itemSize.height)
            cachedAttributes[indexPath] = attributes
            orderedAttributes.append(attributes)
        }

        yOffset += metrics.sectionHeight
    }
}

/// Root view for every item in a `PinnedTabLayout` grid. The layout gives
/// each item an exact frame and never takes a preferred size back (it keeps
/// `shouldInvalidateLayout(forPreferredLayoutAttributes:withOriginalAttributes:)`
/// at its default, false), but `NSCollectionView` still asks each visible
/// item to fit itself — a full Auto Layout fitting pass per item — every
/// time the grid lays out, which is every frame of a sidebar resize. The
/// layout's attributes are returned as they are. (`NSView` answers the
/// `NSCollectionViewElement` requirement in a category Swift does not see, so
/// this implements it through the conformance rather than an `override`.)
class PinnedGridItemView: NSView, NSCollectionViewElement {
    func preferredLayoutAttributesFitting(
        _ layoutAttributes: NSCollectionViewLayoutAttributes
    ) -> NSCollectionViewLayoutAttributes {
        layoutAttributes
    }
}
