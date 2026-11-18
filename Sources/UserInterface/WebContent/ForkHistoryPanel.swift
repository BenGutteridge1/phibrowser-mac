// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

// MARK: - Model

/// Fork: state of one window's floating history panel.
@MainActor
final class ForkHistoryPanelModel: ObservableObject {
    enum Range: CaseIterable, Identifiable {
        case today, yesterday, week
        var id: Self { self }

        var title: String {
            switch self {
            case .today:
                return NSLocalizedString("history.floatingPanel.range.today", value: "Today",
                    comment: "Floating history panel - filter chip that shows only today's visits")
            case .yesterday:
                return NSLocalizedString("history.floatingPanel.range.yesterday", value: "Yesterday",
                    comment: "Floating history panel - filter chip that shows only yesterday's visits")
            case .week:
                return NSLocalizedString("history.floatingPanel.range.week", value: "Week",
                    comment: "Floating history panel - filter chip that shows the last seven days of visits")
            }
        }
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        let entries: [ForkHistoryEntry]
    }

    @Published var searchText = "" {
        didSet { if searchText != oldValue { reload(debounced: true) } }
    }
    /// Nil shows all history.
    @Published var range: Range? = .week {
        didSet { if range != oldValue { reload(debounced: false) } }
    }
    @Published private(set) var sections: [Section] = []
    @Published var selectedId: String?
    @Published private(set) var hasLoaded = false

    /// Rows per page; scrolling near the end asks for the next page.
    private static let pageSize = 150
    private let service: ForkHistoryService
    private var entries: [ForkHistoryEntry] = []
    private var limit = pageSize
    private var reachedEnd = false
    private var queryTask: Task<Void, Never>?
    let onOpen: (ForkHistoryEntry, _ inNewTab: Bool) -> Void
    let onShowFullHistory: () -> Void
    let onClose: () -> Void

    init(service: ForkHistoryService,
         onOpen: @escaping (ForkHistoryEntry, Bool) -> Void,
         onShowFullHistory: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.service = service
        self.onOpen = onOpen
        self.onShowFullHistory = onShowFullHistory
        self.onClose = onClose
    }

    func favicon(for entry: ForkHistoryEntry) -> NSImage? { service.cachedFavicon(for: entry.url) }

    func loadFavicon(for entry: ForkHistoryEntry, completion: @escaping (NSImage?) -> Void) {
        service.loadFavicon(for: entry.url, completion: completion)
    }

    func reload(debounced: Bool) {
        limit = Self.pageSize
        reachedEnd = false
        runQuery(delay: debounced ? 0.12 : 0)
    }

    /// Re-runs the current search at the current size (new visits appear).
    func refresh() {
        runQuery(delay: 0)
    }

    func loadMoreIfNeeded(after entry: ForkHistoryEntry) {
        guard !reachedEnd, queryTask == nil,
              let index = entries.firstIndex(of: entry), index >= entries.count - 10 else { return }
        limit += Self.pageSize
        runQuery(delay: 0)
    }

    private func runQuery(delay: TimeInterval) {
        queryTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = range
        let limit = limit
        queryTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            let since: Date? = switch range {
            case .today: startOfToday
            case .yesterday: calendar.date(byAdding: .day, value: -1, to: startOfToday)
            case .week: calendar.date(byAdding: .day, value: -7, to: Date())
            case nil: nil
            }
            var results = await self.service.query(text, since: since, limit: limit)
            guard !Task.isCancelled else { return }
            self.reachedEnd = results.count < limit
            if range == .yesterday { results.removeAll { $0.time >= startOfToday } }
            self.apply(results)
            self.queryTask = nil
        }
    }

    private func apply(_ results: [ForkHistoryEntry]) {
        entries = results
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        var built: [Section] = []
        var current: (day: Date, entries: [ForkHistoryEntry])?
        func flush() {
            guard let current else { return }
            let title: String
            if calendar.isDateInToday(current.day) {
                title = Range.today.title
            } else if calendar.isDateInYesterday(current.day) {
                title = Range.yesterday.title
            } else {
                title = formatter.string(from: current.day)
            }
            built.append(Section(id: "\(current.day.timeIntervalSince1970)", title: title, entries: current.entries))
        }
        for entry in results {
            let day = calendar.startOfDay(for: entry.time)
            if current?.day == day {
                current?.entries.append(entry)
            } else {
                flush()
                current = (day, [entry])
            }
        }
        flush()
        sections = built
        hasLoaded = true
        if let selectedId, !results.contains(where: { $0.id == selectedId }) {
            self.selectedId = nil
        }
    }

    // MARK: Keyboard

    func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        let index = selectedId.flatMap { id in entries.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + delta, 0), entries.count - 1) } ?? (delta > 0 ? 0 : entries.count - 1)
        selectedId = entries[next].id
    }

    func openSelection(inNewTab: Bool) {
        guard let entry = entries.first(where: { $0.id == selectedId }) ?? entries.first else { return }
        onOpen(entry, inNewTab)
    }
}

// MARK: - View

/// Fork: the floating history card (design: handoff/design/Main.dc.html).
struct ForkHistoryPanelView: View {
    @ObservedObject var model: ForkHistoryPanelModel
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.phiTheme) private var theme
    @FocusState private var searchFocused: Bool

    private var isDark: Bool { appearance.isDark }
    private var accent: Color { Color(nsColor: theme.color(for: .themeColor, appearance: appearance)) }
    private var onAccent: Color { isDark ? Color(red: 0x12 / 255, green: 0x14 / 255, blue: 0x2A / 255) : .white }
    // Same treatment as the omnibox: the Space's color, opaque and untouched
    // by the theme sliders, with translucent black or white on top.
    private var ink: Color { isDark ? .white : .black }
    private var text: Color { ink.opacity(0.85) }
    private var muted: Color { ink.opacity(0.5) }
    private var field: Color { ink.opacity(isDark ? 0.08 : 0.06) }
    private var hairline: Color { ink.opacity(isDark ? 0.14 : 0.1) }
    private var background: Color {
        Color(nsColor: ThemedColor.forkOmniboxBackground.resolve(theme: theme, appearance: appearance))
    }
    static let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            chips
            list
            footer
        }
        .padding(EdgeInsets(top: 10, leading: 6, bottom: 8, trailing: 6))
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(hairline, lineWidth: 1)
        }
        .onAppear {
            searchFocused = true
            if !model.hasLoaded { model.reload(debounced: false) }
        }
        .onKeyPress(.escape) {
            if model.searchText.isEmpty { model.onClose() } else { model.searchText = "" }
            return .handled
        }
    }

    private var header: some View {
        HStack {
            Text(NSLocalizedString("history.floatingPanel.title", value: "History",
                comment: "Floating history panel - title at the top of the panel"))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(text)
            Spacer()
            Button(action: model.onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(muted)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(field))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("history.floatingPanel.close", value: "Close history",
                comment: "Floating history panel - accessible label of the close button"))
        }
        .padding(EdgeInsets(top: 0, leading: 6, bottom: 8, trailing: 6))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(muted)
            TextField("", text: $model.searchText,
                      prompt: Text(NSLocalizedString("history.floatingPanel.searchPlaceholder", value: "Search history",
                          comment: "Floating history panel - placeholder of the search field")).foregroundStyle(muted))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(text)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onSubmit {
                    model.openSelection(inNewTab: NSEvent.modifierFlags.contains(.command))
                }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(field))
        .padding(EdgeInsets(top: 0, leading: 6, bottom: 8, trailing: 6))
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(ForkHistoryPanelModel.Range.allCases) { range in
                let selected = model.range == range
                Button {
                    // Tapping the selected chip clears the filter: all history.
                    model.range = selected ? nil : range
                } label: {
                    Text(range.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(selected ? onAccent : muted)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(selected ? accent : field))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 0, leading: 6, bottom: 2, trailing: 6))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sections) { section in
                        Text(section.title.uppercased())
                            .font(.system(size: 11))
                            .tracking(0.66)
                            .foregroundStyle(muted)
                            .padding(EdgeInsets(top: 8, leading: 8, bottom: 2, trailing: 8))
                        ForEach(section.entries) { entry in
                            ForkHistoryRow(entry: entry, model: model, isSelected: model.selectedId == entry.id,
                                           accent: accent, text: text, muted: muted, field: field)
                                .id(entry.id)
                                .onAppear { model.loadMoreIfNeeded(after: entry) }
                        }
                    }
                    if model.hasLoaded, model.sections.isEmpty {
                        Text(NSLocalizedString("history.floatingPanel.empty", value: "No history found",
                            comment: "Floating history panel - shown when no visits match the search or filter"))
                            .font(.system(size: 12))
                            .foregroundStyle(muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
            }
            .scrollIndicators(.never)
            .onChange(of: model.selectedId) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private var footer: some View {
        Button(action: model.onShowFullHistory) {
            Text(NSLocalizedString("history.floatingPanel.showAll", value: "Show full history",
                comment: "Floating history panel - footer button that opens the full history page in a tab"))
                .font(.system(size: 11.5))
                .foregroundStyle(muted)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}

private struct ForkHistoryRow: View {
    let entry: ForkHistoryEntry
    @ObservedObject var model: ForkHistoryPanelModel
    let isSelected: Bool
    let accent: Color
    let text: Color
    let muted: Color
    let field: Color
    @State private var favicon: NSImage?
    @State private var isHovered = false

    var body: some View {
        Button {
            model.selectedId = entry.id
            model.onOpen(entry, NSEvent.modifierFlags.contains(.command))
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(field)
                    if let favicon {
                        Image(nsImage: favicon).resizable().interpolation(.high).frame(width: 14, height: 14)
                    } else {
                        Text(verbatim: entry.fallbackLetter)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(muted)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(text)
                        .lineLimit(1)
                    Text(verbatim: entry.timeOfDay.isEmpty ? entry.domain : "\(entry.domain) · \(entry.timeOfDay)")
                        .font(.system(size: 11))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? accent.opacity(0.16) : (isHovered ? field : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(entry.url)
        .onAppear {
            favicon = model.favicon(for: entry)
            guard favicon == nil else { return }
            model.loadFavicon(for: entry) { favicon = $0 }
        }
    }
}

// MARK: - Panel

/// A borderless panel that can take keyboard focus for the search field.
private final class ForkHistoryNSPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// While the panel is key, Show History (⌘Y, or its remapped key) must
    /// close it here: the panel is not a browser window, so the menu would
    /// otherwise hand the command to Chromium, which opens a history tab.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ShortcutsKey.eventKeys(for: event)?.matches(Shortcuts.key(for: .IDC_SHOW_HISTORY)) == true {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Fork: the floating history panel, a native child window of the browser
/// window (so it stays up across page loads, tab switches and Space
/// switches, unlike an extension drawn inside the page). Show History (⌘Y)
/// toggles it (`CommandDispatcher`); it slides in from the window's right
/// edge and back out.
@MainActor
final class ForkHistoryPanelController: NSObject {
    private static var controllers: [ObjectIdentifier: ForkHistoryPanelController] = [:]

    static let width: CGFloat = 236
    private static let edgeInset: CGFloat = 12
    /// Room for the card's shadow on the sides that are not the window edge.
    private static let shadowMargin: CGFloat = 20
    private static let maxHeight: CGFloat = 560

    /// Toggles the panel for the browser window behind `window` (or closes
    /// the panel when `window` is the panel itself). Returns false when the
    /// window is not one this panel can serve, so the command falls through.
    @discardableResult
    static func toggle(from window: NSWindow) -> Bool {
        if let panel = window as? ForkHistoryNSPanel, let parent = panel.parent {
            controllers[ObjectIdentifier(parent)]?.close()
            return true
        }
        if let existing = controllers[ObjectIdentifier(window)] {
            existing.close()
            return true
        }
        guard let controller = SpaceSessionControllersManager.shared.findControllerWith(window: window) else {
            return false
        }
        let panelController = ForkHistoryPanelController(parent: window, session: controller)
        controllers[ObjectIdentifier(window)] = panelController
        panelController.show()
        return true
    }

    private weak var parent: NSWindow?
    private let service: ForkHistoryService
    private let panel: ForkHistoryNSPanel
    private let container = NSView()
    private var hosting: NSView!
    private var model: ForkHistoryPanelModel!
    private var observers: [NSObjectProtocol] = []
    private var refreshSubscription: AnyCancellable?
    private var isClosing = false

    private init(parent: NSWindow, session: SpaceSessionController) {
        self.parent = parent
        let state = session.browserState
        service = ForkHistoryService(windowId: Int64(state.windowId), profileId: state.profileId)
        panel = ForkHistoryNSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
        super.init()
        model = ForkHistoryPanelModel(
            service: service,
            onOpen: { [weak self] entry, inNewTab in self?.open(entry.url, inNewTab: inNewTab) },
            onShowFullHistory: { [weak self] in self?.open("chrome://history/", inNewTab: true) },
            onClose: { [weak self] in self?.close() }
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws its own shadow, so it slides with the card.
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.onCancel = { [weak self] in self?.close() }

        // The card draws its own rounded, opaque background and shadow in
        // SwiftUI, inset from every side but the window edge. The container
        // clips at the window's right edge, so sliding the card out of it
        // makes it disappear into that edge.
        let root = ForkHistoryPanelView(model: model)
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            .padding(EdgeInsets(top: Self.shadowMargin, leading: Self.shadowMargin,
                                bottom: Self.shadowMargin, trailing: Self.edgeInset))
        let hosting = ThemedHostingView(rootView: root, themeSource: state.themeContext)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        self.hosting = hosting
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.addSubview(hosting)
        panel.contentView = container
        panel.appearance = parent.effectiveAppearance

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: false) }
        })

        // Keep the list live: any tab in this window that commits a
        // navigation or settles its title refreshes it, a beat later.
        refreshSubscription = state.$tabs
            .map { tabs in
                Publishers.MergeMany(tabs.flatMap { tab in
                    [tab.$url.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                     tab.$title.dropFirst().map { _ in () }.eraseToAnyPublisher()]
                })
            }
            .switchToLatest()
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.model.refresh() }
    }

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func show() {
        guard let parent else { return }
        position()
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        guard !reducesMotion else { return }
        hosting.setFrameOrigin(NSPoint(x: container.bounds.width, y: 0))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            hosting.animator().setFrameOrigin(.zero)
        }
    }

    /// Against the browser window's right edge, vertically centered.
    private func position() {
        guard let parent else { return }
        let frame = parent.frame
        let cardHeight = min(Self.maxHeight, frame.height - 2 * 60)
        let size = NSSize(width: Self.width + Self.shadowMargin + Self.edgeInset,
                          height: cardHeight + 2 * Self.shadowMargin)
        panel.setFrame(NSRect(x: frame.maxX - size.width, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        container.frame = NSRect(origin: .zero, size: size)
        if !isClosing { hosting.frame = container.bounds }
    }

    private func open(_ url: String, inNewTab: Bool) {
        guard let parent,
              let controller = SpaceSessionControllersManager.shared.findControllerWith(window: parent) else { return }
        let state = controller.browserState
        if !inNewTab, !state.isInPlaceholderMode, let wrapper = state.focusingTab?.webContentWrapper {
            wrapper.navigate(toURL: url)
        } else {
            state.createTab(url)
        }
    }

    func close(animated: Bool = true) {
        guard !isClosing else { return }
        isClosing = true
        // Free the slot first, so a toggle during the slide-out opens anew.
        if let parent { Self.controllers[ObjectIdentifier(parent)] = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        refreshSubscription = nil
        parent?.makeKey()
        let finish = { [self] in
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            service.close()
        }
        guard animated, !reducesMotion, panel.isVisible else { finish(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            hosting.animator().setFrameOrigin(NSPoint(x: container.bounds.width, y: 0))
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
    }
}
