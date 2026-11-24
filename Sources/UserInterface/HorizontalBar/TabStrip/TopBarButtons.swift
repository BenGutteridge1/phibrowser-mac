// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
import Combine

// MARK: - Navigation

/// What the top bar's navigation buttons show: the focused tab's history and
/// loading state.
final class TopBarNavigationState: ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false

    private var cancellables = Set<AnyCancellable>()
    private var tabCancellables = Set<AnyCancellable>()

    init(browserState: BrowserState) {
        browserState.$focusingTab
            .removeDuplicates { $0 === $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in self?.bind(tab) }
            .store(in: &cancellables)
        bind(browserState.focusingTab)
    }

    private func bind(_ tab: Tab?) {
        tabCancellables.removeAll()
        guard let tab else {
            canGoBack = false
            canGoForward = false
            isLoading = false
            return
        }
        tab.$canGoBack
            .combineLatest(tab.$canGoForward)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] back, forward in
                self?.canGoBack = back
                self?.canGoForward = forward
            }
            .store(in: &tabCancellables)
        tab.$isLoading
            .combineLatest(tab.$loadingProgress)
            .map { isLoading, progress in !tab.isNTP && isLoading && progress < 1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in self?.isLoading = loading }
            .store(in: &tabCancellables)
    }
}

/// Hide Top Bar, back, forward and reload/stop: the sidebar header's
/// buttons, at the head of the top bar.
struct TopBarNavigationButtons: View {
    @ObservedObject var state: TopBarNavigationState

    // The sidebar header's button settings (the bar's Top Buttons menu).
    @AppStorage(PhiPreferences.GeneralSettings.sidebarHeaderShowsSidebarToggle.rawValue)
    private var showsToggle = PhiPreferences.GeneralSettings.sidebarHeaderShowsSidebarToggle.defaultValue
    @AppStorage(PhiPreferences.GeneralSettings.sidebarHeaderShowsBack.rawValue)
    private var showsBack = PhiPreferences.GeneralSettings.sidebarHeaderShowsBack.defaultValue
    @AppStorage(PhiPreferences.GeneralSettings.sidebarHeaderShowsForward.rawValue)
    private var showsForward = PhiPreferences.GeneralSettings.sidebarHeaderShowsForward.defaultValue
    @AppStorage(PhiPreferences.GeneralSettings.sidebarHeaderShowsReload.rawValue)
    private var showsReload = PhiPreferences.GeneralSettings.sidebarHeaderShowsReload.defaultValue

    let onToggleTopBar: () -> Void
    let onBack: () -> Void
    let onForward: () -> Void
    let onReload: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if showsToggle {
                NavigationButton(
                    systemName: "rectangle.topthird.inset.filled",
                    accessibilityLabel: hideTopBarLabel,
                    action: onToggleTopBar
                )
                .help(hideTopBarLabel)
            }
            if showsBack {
                NavigationButton(
                    systemName: "chevron.left",
                    isEnabled: state.canGoBack,
                    accessibilityLabel: NSLocalizedString("browser.webContentHeader.backButton.accessibilityLabel", value: "Back", comment: "Web content header - Accessibility description for back navigation button"),
                    action: onBack
                )
            }
            if showsForward {
                NavigationButton(
                    systemName: "chevron.right",
                    isEnabled: state.canGoForward,
                    accessibilityLabel: NSLocalizedString("browser.webContentHeader.forwardButton.accessibilityLabel", value: "Forward", comment: "Web content header - Accessibility description for forward navigation button"),
                    action: onForward
                )
            }
            if showsReload {
                RefreshStopNavigationButton(
                    isProgressVisible: state.isLoading,
                    onRefreshTap: onReload,
                    onStopLoadingTap: onStop
                )
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var hideTopBarLabel: String {
        NSLocalizedString("browser.topBar.toggleButton.accessibilityLabel", value: "Hide Top Bar", comment: "Comfortable layout top bar - Tooltip and accessibility label of the button that hides the top bar")
    }
}

// MARK: - Trailing buttons

/// What the trailing buttons fold to, set by the top bar's width ladder.
final class TopBarTrailingState: ObservableObject {
    @Published var foldsButtons = false
}

/// The sidebar's bottom-bar buttons at the top bar's trailing end: Update
/// (once one is downloaded), downloads, the cards bulb, Organize Tabs,
/// Memory, Chat, Feedback and the profile. Each follows the Comfortable top
/// bar's own setting where it has one. When the row is short of room all
/// but downloads (and the profile) fold into one menu, Organize Tabs among
/// them; downloads folds too once nothing is downloading.
struct TopBarTrailingButtons: View {
    @ObservedObject var cardManager: NotificationCardManager
    @ObservedObject var layout: TopBarTrailingState
    @ObservedObject var downloadViewModel: DownloadButtonViewModel
    let browserState: BrowserState
    let onCardEntryTap: () -> Void
    let onMemoryTap: () -> Void
    let onChatTap: () -> Void
    let onFeedbackTap: () -> Void

    /// Set once Sparkle has prepared a downloaded update for installation.
    @State private var availableUpdateVersion: String? = nil
    @State private var isDownloadPopoverShown = false

    @AppStorage(PhiPreferences.AISettings.phiAIEnabled.rawValue)
    private var phiAIEnabled: Bool = PhiPreferences.AISettings.phiAIEnabled.defaultValue
    @AppStorage(PhiPreferences.GeneralSettings.topBarShowsProfile.rawValue)
    private var showsProfile = PhiPreferences.GeneralSettings.topBarShowsProfile.defaultValue
    @AppStorage(PhiPreferences.GeneralSettings.topBarShowsDownloads.rawValue)
    private var showsDownloads = PhiPreferences.GeneralSettings.topBarShowsDownloads.defaultValue
    @AppStorage(PhiPreferences.GeneralSettings.topBarShowsMemory.rawValue)
    private var showsMemory = PhiPreferences.GeneralSettings.topBarShowsMemory.defaultValue
    @AppStorage(PhiPreferences.GeneralSettings.topBarShowsFeedback.rawValue)
    private var showsFeedback = PhiPreferences.GeneralSettings.topBarShowsFeedback.defaultValue

    /// `BrowserState` isn't an `ObservableObject`, so the eligible page count is
    /// mirrored from the `$normalTabs` publisher via `onReceive`.
    @State private var eligibleTabCount: Int

    init(
        cardManager: NotificationCardManager,
        layout: TopBarTrailingState,
        downloadViewModel: DownloadButtonViewModel,
        browserState: BrowserState,
        onCardEntryTap: @escaping () -> Void,
        onMemoryTap: @escaping () -> Void,
        onChatTap: @escaping () -> Void,
        onFeedbackTap: @escaping () -> Void
    ) {
        self.cardManager = cardManager
        self.layout = layout
        self.downloadViewModel = downloadViewModel
        self.browserState = browserState
        self.onCardEntryTap = onCardEntryTap
        self.onMemoryTap = onMemoryTap
        self.onChatTap = onChatTap
        self.onFeedbackTap = onFeedbackTap
        _eligibleTabCount = State(
            initialValue: FarringdonOrganizer.eligibleTabCount(in: browserState.normalTabs))

        #if DEBUG && !PHI_OSS_BUILD
        _availableUpdateVersion = State(initialValue: Self.uiTestUpdateVersion())
        #endif
    }

    var body: some View {
        HStack(spacing: 4) {
            #if !PHI_OSS_BUILD
            if availableUpdateVersion != nil {
                TabStripUpdateButton {
                    AppController.shared.checkForUpdate(nil)
                }
            }
            #endif

            if showsDownloadButton {
                DownloadButtonView(
                    viewModel: downloadViewModel,
                    useCircularHoverShape: true,
                    onTap: {
                        FeatureEntryAnalytics.capture(.download, surface: .webContentHeader)
                        isDownloadPopoverShown.toggle()
                    }
                )
                .popover(isPresented: $isDownloadPopoverShown, arrowEdge: .bottom) {
                    downloadPopoverContent
                }
            }

            if layout.foldsButtons {
                if !foldedItems.isEmpty {
                    HeaderMoreButton(items: foldedItems) { item in
                        handleFoldedItem(item)
                    }
                    .popover(
                        isPresented: showsDownloadButton ? .constant(false) : $isDownloadPopoverShown,
                        arrowEdge: .bottom
                    ) {
                        downloadPopoverContent
                    }
                }
            } else {
                if showCardEntry {
                    CardEntryButton(action: onCardEntryTap)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8)),
                            removal: .opacity
                        ))
                }
                if showFarringdonButton {
                    TabStripFarringdonButton(eligibleTabCount: eligibleTabCount)
                }
                if showsMemoryButton {
                    MemoryButton(action: onMemoryTap, useCircularHoverShape: true)
                }
                if showsFeedbackButton {
                    FeedbackButtonSwiftUI(action: onFeedbackTap, useCircularHoverShape: true)
                }
                if showsChatButton {
                    ChatButton(action: onChatTap, contentWidth: ChatButton.preferredContentWidth)
                }
            }

            if showsProfile {
                ProfileButton(surface: .tabStrip)
                    .frame(width: 24, height: 24)
            }
        }
        .onReceive(browserState.$normalTabs.receive(on: DispatchQueue.main)) { tabs in
            eligibleTabCount = FarringdonOrganizer.eligibleTabCount(in: tabs)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showCardEntry)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showFarringdonButton)
        #if !PHI_OSS_BUILD
        .onReceive(NotificationCenter.default.publisher(for: .sparkleDidDownloadUpdate)) { notification in
            availableUpdateVersion = notification.userInfo?["displayVersion"] as? String ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .sparkleDidSkipUpdate)) { _ in
            availableUpdateVersion = nil
        }
        #endif
        .frame(maxHeight: .infinity, alignment: .trailing)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: availableUpdateVersion != nil)
        .ignoresSafeArea()
    }

    private var showCardEntry: Bool {
        cardManager.latestCard != nil
    }

    private var showsDownloadButton: Bool {
        showsDownloads && (!layout.foldsButtons || downloadViewModel.hasActiveDownloads)
    }

    private var showsMemoryButton: Bool {
        showsMemory && phiAIEnabled && !browserState.isIncognito
    }

    private var showsFeedbackButton: Bool {
        showsFeedback && !ApplicationState.shared.isGuest
    }

    private var showsChatButton: Bool {
        phiAIEnabled && !browserState.isIncognito
    }

    private var showFarringdonButton: Bool {
        FarringdonOrganizer.canOrganizeTabs(
            phiAIEnabled: phiAIEnabled,
            isIncognito: browserState.isIncognito,
            eligibleTabCount: eligibleTabCount
        )
    }

    /// The buttons in the folded menu, in row order.
    private var foldedItems: [MoreMenuItem] {
        var items: [MoreMenuItem] = []
        if showsDownloads && !showsDownloadButton {
            items.append(MoreMenuItem(
                id: "download",
                title: NSLocalizedString("browser.headerMoreMenu.downloadsAction", value: "Downloads", comment: "Header more menu - Downloads action"),
                systemImage: "arrow.down.circle"
            ))
        }
        if showFarringdonButton {
            items.append(MoreMenuItem(
                id: "organize",
                title: NSLocalizedString("toolbar.organizeTabs.accessibilityLabel", value: "Organize tabs with AI",
                    comment: "Organize Tabs - Button tooltip and accessibility label"),
                systemImage: "wand.and.stars"
            ))
        }
        if showCardEntry {
            items.append(MoreMenuItem(
                id: "cards",
                title: NSLocalizedString("browser.topBar.moreMenu.cardsAction", value: "Cards", comment: "Comfortable layout top bar - Menu item, shown when the bar is short of room, that opens the latest notification cards"),
                systemImage: "lightbulb"
            ))
        }
        if showsMemoryButton {
            items.append(MoreMenuItem(
                id: "memory",
                title: NSLocalizedString("browser.headerMoreMenu.memoryAction", value: "Browser Memory", comment: "Header more menu - AI memory"),
                image: Image(.memoryIcon).renderingMode(.original)
            ))
        }
        if showsFeedbackButton {
            items.append(MoreMenuItem(
                id: "feedback",
                title: NSLocalizedString("browser.headerMoreMenu.feedbackAction", value: "Feedback", comment: "Header more menu - Feedback action"),
                image: Image(.sidebarFeedback)
            ))
        }
        if showsChatButton {
            items.append(MoreMenuItem(
                id: "chat",
                title: NSLocalizedString("browser.topBar.moreMenu.chatAction", value: "Chat", comment: "Comfortable layout top bar - Menu item, shown when the bar is short of room, that opens the AI chat"),
                systemImage: "bubble.left"
            ))
        }
        return items
    }

    private func handleFoldedItem(_ item: MoreMenuItem) {
        switch item.id {
        case "download":
            isDownloadPopoverShown.toggle()
        case "organize":
            FeatureEntryAnalytics.capture(.organizeTabs, surface: .webContentHeader)
            FarringdonOrganizer.organizeFocusedWindow(eligibleTabCount: eligibleTabCount)
        case "cards":
            onCardEntryTap()
        case "memory":
            onMemoryTap()
        case "feedback":
            onFeedbackTap()
        case "chat":
            onChatTap()
        default:
            break
        }
    }

    @ViewBuilder
    private var downloadPopoverContent: some View {
        if let manager = downloadViewModel.downloadsManager {
            DownloadsListView(downloadsManager: manager) {
                isDownloadPopoverShown = false
                guard let owner = browserState.windowController,
                      let source = owner.window?.contentView else { return }
                owner.showLibrary(from: source, section: .downloads)
            }
            .frame(width: 340, height: 317)
        }
    }

    #if DEBUG && !PHI_OSS_BUILD
    private static func uiTestUpdateVersion() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uitest"),
              let versionFlagIndex = arguments.firstIndex(of: "-tabStripUpdateVersion"),
              arguments.indices.contains(versionFlagIndex + 1) else {
            return nil
        }

        let version = arguments[versionFlagIndex + 1]
        return version.isEmpty ? nil : version
    }
    #endif
}

#if !PHI_OSS_BUILD
/// Update action displayed to the left of the notification-card entry once
/// Sparkle has a downloaded update ready to install. Its visual configuration
/// intentionally mirrors `SidebarHeaderView.upgradeButton`.
private struct TabStripUpdateButton: View {
    private static let accessibilityIdentifier = "tabStrip.updateButton"

    @StateObject private var state = HoverableButtonState()
    let action: () -> Void

    private var title: String {
        NSLocalizedString(
            "sidebar.updateReminder.updateButton",
            value: "Update",
            comment: "Tab strip update button title"
        )
    }

    private var config: HoverableButtonConfig {
        HoverableButtonConfig(
            title: title,
            displayMode: .titleOnly,
            backgroundColor: .themeColor,
            hoverBackgroundColor: .themeColorOnHover,
            titleColor: .custom(light: .white, dark: .white),
            titleFont: .system(size: 11, weight: .medium),
            edgeInsets: EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4),
            cornerRadius: 6
        )
    }

    var body: some View {
        HoverableButton(config: config, state: state, action: action)
            .frame(width: 56, height: 24)
            .help(title)
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            .accessibilityLabel(Text(title))
    }
}
#endif

/// "Organize tabs with AI" (Farringdon) button for the top bar. Triggers the same focused-window organize run
/// as the sidebar broom and loops its Lottie animation while a run is in progress
/// (driven by the shared `.farringdonOrganizeDidStart` /
/// `.farringdonOrganizeDidFinish` events).
private struct TabStripFarringdonButton: View {
    let eligibleTabCount: Int

    @StateObject private var lottieState = LottieAnimationViewState()
    @State private var isOrganizing = false
    @State private var organizeStartedAt: Date?
    @State private var anchorView: NSView?

    private let buttonSize: CGFloat = 24
    private static let safetyTimeout: TimeInterval = 8.0

    private let animationConfig = LottieAnimationViewConfig(
        animationName: "broom",
        size: CGSize(width: 24, height: 24),
        hoverBackgroundColor: Color.sidebarTabHovered,
        cornerRadius: 6,
        animationTrigger: .manual,
        themedTintColor: .custom(light: .black, dark: .white),
        loopMode: .loop
    )

    private var label: String {
        NSLocalizedString("toolbar.organizeTabs.accessibilityLabel", value: "Organize tabs with AI",
            comment: "Organize Tabs - Button tooltip and accessibility label")
    }

    var body: some View {
        LottieAnimationView(config: animationConfig, state: lottieState) {
            guard !isOrganizing else { return }
            FeatureEntryAnalytics.capture(.organizeTabs, surface: .webContentHeader)
            FarringdonOrganizer.organizeFocusedWindow(eligibleTabCount: eligibleTabCount)
        }
        .frame(width: buttonSize, height: buttonSize)
        .background(
            TabStripAnchorReader { view in
                // Set once: a state write on every update would re-render
                // the button on every update.
                if self.anchorView !== view { self.anchorView = view }
            }
        )
        .help(label)
        .accessibilityLabel(Text(label))
        .onReceive(NotificationCenter.default.publisher(for: .farringdonOrganizeDidStart)) { _ in
            // Only the window that triggered the run (the key window) animates,
            // and in it only the strip of the Space on screen.
            guard let anchorView, anchorView.window?.isKeyWindow == true,
                  !anchorView.isHiddenOrHasHiddenAncestor else { return }
            startAnimation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .farringdonOrganizeDidFinish)) { _ in
            stopAnimation()
        }
    }

    private func startAnimation() {
        guard !isOrganizing else { return }
        isOrganizing = true
        organizeStartedAt = Date()
        lottieState.triggerAnimation()
        // Stop even if the completion signal never arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.safetyTimeout) {
            stopAnimation()
        }
    }

    private func stopAnimation() {
        guard isOrganizing else { return }

        // Complete at least one full playback even when the organize run finishes immediately.
        let elapsed = organizeStartedAt.map { Date().timeIntervalSince($0) }
            ?? BroomAnimation.minimumPlaybackDuration
        let remaining = max(0, BroomAnimation.minimumPlaybackDuration - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
            guard isOrganizing else { return }
            isOrganizing = false
            organizeStartedAt = nil
            lottieState.stopAnimation()
        }
    }
}

private struct TabStripAnchorReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughAnchorView()
        DispatchQueue.main.async {
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PassthroughAnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
