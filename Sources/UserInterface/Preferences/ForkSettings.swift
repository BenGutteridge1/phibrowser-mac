// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Where the sidebar shows the Spaces switcher.
enum SpaceSwitcherPlacement: String, CaseIterable, Identifiable {
    /// Below the navigation row, above the address bar (upstream default).
    case top
    /// Centered in the sidebar's bottom bar, between the leading buttons and Chat.
    case bottomCenter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top:
            return NSLocalizedString("settings.general.spaceSwitcherPlacement.topOption", value: "Top of sidebar", comment: "Space switcher placement option - below the navigation buttons")
        case .bottomCenter:
            return NSLocalizedString("settings.general.spaceSwitcherPlacement.bottomCenterOption", value: "Bottom center", comment: "Space switcher placement option - centered in the sidebar bottom bar")
        }
    }
}

/// What the Gmail pinned tab's hover card shows.
enum GmailCardSource: String, CaseIterable, Identifiable {
    /// Gmail's mobile site, live in the card.
    case website
    /// A native list of the latest mail, from Thunderbird through its add-on.
    case thunderbird

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .website:
            return NSLocalizedString("settings.spaces.fork.gmailCardSource.website", value: "Gmail website", comment: "Gmail card source option - the card shows Gmail's mobile site")
        case .thunderbird:
            return NSLocalizedString("settings.spaces.fork.gmailCardSource.thunderbird", value: "Thunderbird", comment: "Gmail card source option - the card shows the latest mail from the Thunderbird app")
        }
    }
}

/// What the TickTick pinned tab's hover card shows.
enum TickTickCardSource: String, CaseIterable, Identifiable {
    /// TickTick's mobile site, live in the card.
    case website
    /// A native task list, from TickTick's Open API (`ForkTickTickTasks`).
    case native

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .website:
            return NSLocalizedString("settings.spaces.fork.tickTickCardSource.website", value: "TickTick website", comment: "TickTick card source option - the card shows TickTick's mobile site")
        case .native:
            return NSLocalizedString("settings.spaces.fork.tickTickCardSource.native", value: "Task list", comment: "TickTick card source option - the card shows a native list of tasks from TickTick")
        }
    }
}

/// A site's own autoplay rule, overriding the tab rules.
enum AutoplaySiteRule: String, CaseIterable, Identifiable {
    /// Never paused: excluded from the autoplay rules.
    case allow
    /// Always starts paused, wherever it opens.
    case pause

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allow:
            return NSLocalizedString("settings.autoplay.siteRule.allow", value: "Always allow", comment: "Autoplay site rule - the site may always play media on its own")
        case .pause:
            return NSLocalizedString("settings.autoplay.siteRule.pause", value: "Always pause", comment: "Autoplay site rule - the site's media always starts paused")
        }
    }
}

/// Preferences added by this fork. Kept in one place, separate from
/// `PhiPreferences`, so upstream merges stay conflict-free. Every key is
/// prefixed with `fork.` and read through `UserDefaults.standard`, which is
/// also what the `@AppStorage` bindings in the views observe.
enum ForkSettings {
    enum Key {
        static let spaceSwitcherPlacement = "fork.spaceSwitcherPlacement"
        static let spaceSwitcherUsesDots = "fork.spaceSwitcherUsesDots"
        /// Comfortable: whether new windows open with the top bar hidden (⌘S).
        static let topBarHidden = "fork.topBarHidden"
        static let spaceOverlayOpacities = "fork.spaceOverlayOpacities"
        static let lastTabShowsEmptyState = "fork.lastTabShowsEmptyState"
        static let tabSwitcherExcludesPinnedTabs = "fork.tabSwitcherExcludesPinnedTabs"
        static let numberShortcutsExcludePinnedTabs = "fork.numberShortcutsExcludePinnedTabs"
        static let tabSelectionExcludesClosedFolders = "fork.tabSelectionExcludesClosedFolders"
        static let addressBarGlobalShortcutEnabled = "fork.addressBarGlobalShortcutEnabled"
        static let pinnedTabLivePreviewsEnabled = "fork.pinnedTabLivePreviewsEnabled"
        /// Comfortable: hide the top bar while a video plays in the focused tab.
        static let hidesTopBarDuringVideo = "fork.hidesTopBarDuringVideo"
        static let gmailCardSource = "fork.gmailCardSource"
        static let thunderbirdAddonSeen = "fork.thunderbirdAddonSeen"
        /// The Thunderbird card shows messages darkened in dark mode.
        static let mailMessagesDark = "fork.mailMessagesDark"
        static let hidesFullscreenExitHint = "fork.hidesFullscreenExitHint"
        static let videoPiPButtonEnabled = "fork.videoPiPButtonEnabled"
        static let autoplayControlEnabled = "fork.autoplay.enabled"
        static let autoplayPausesLinkTabs = "fork.autoplay.pausesLinkTabs"
        static let autoplayPausesRestoredTabs = "fork.autoplay.pausesRestoredTabs"
        static let autoplayPausesBackgroundLoads = "fork.autoplay.pausesBackgroundLoads"
        static let autoplayAllowsMuted = "fork.autoplay.allowsMuted"
        static let autoplayUnlocksOnInteraction = "fork.autoplay.unlocksOnInteraction"
        /// Sites with their own autoplay rule: host → `AutoplaySiteRule` raw value.
        static let autoplaySiteRules = "fork.autoplay.siteRules"
        static let showsCopyLinkButton = "fork.addressBar.showsCopyLink"
        static let showsAutoplayButton = "fork.addressBar.showsAutoplay"
        static let tickTickCardSource = "fork.tickTickCardSource"
        /// The list the TickTick card last showed ("today", "next7", "inbox", "project:<id>").
        static let tickTickCardView = "fork.tickTickCardView"
    }

    /// What the Gmail pinned tab's card shows. The website by default.
    static var gmailCardSource: GmailCardSource {
        UserDefaults.standard.string(forKey: Key.gmailCardSource).flatMap(GmailCardSource.init(rawValue:)) ?? .website
    }

    /// What the TickTick pinned tab's card shows. The native task list by default.
    static var tickTickCardSource: TickTickCardSource {
        UserDefaults.standard.string(forKey: Key.tickTickCardSource).flatMap(TickTickCardSource.init(rawValue:)) ?? .native
    }

    /// Set once the Phi+ add-on in Thunderbird has connected, so the card
    /// stops offering to install it.
    static var thunderbirdAddonSeen: Bool {
        get { UserDefaults.standard.bool(forKey: Key.thunderbirdAddonSeen) }
        set { UserDefaults.standard.set(newValue, forKey: Key.thunderbirdAddonSeen) }
    }

    /// Videos show a picture-in-picture button on hover (`ForkVideoPiPButton`). On by default.
    static var videoPiPButtonEnabled: Bool { bool(Key.videoPiPButtonEnabled, default: true) }

    // MARK: Autoplay control (`ForkAutoplay`)

    /// Pages may be kept from playing media on their own. On by default.
    static var autoplayControlEnabled: Bool { bool(Key.autoplayControlEnabled, default: true) }
    /// Pages in tabs opened from a link (in the background or not) start paused. On by default.
    static var autoplayPausesLinkTabs: Bool { bool(Key.autoplayPausesLinkTabs, default: true) }
    /// Pages in unloaded (restored, discarded) tabs start paused when they load again. On by default.
    static var autoplayPausesRestoredTabs: Bool { bool(Key.autoplayPausesRestoredTabs, default: true) }
    /// Pages that load in a tab while it isn't the selected one start paused. On by default.
    static var autoplayPausesBackgroundLoads: Bool { bool(Key.autoplayPausesBackgroundLoads, default: true) }
    /// Muted media may still play on its own (previews, animated backgrounds). On by default.
    static var autoplayAllowsMuted: Bool { bool(Key.autoplayAllowsMuted, default: true) }
    /// After a click or key press on the page, it plays as normal. On by default.
    static var autoplayUnlocksOnInteraction: Bool { bool(Key.autoplayUnlocksOnInteraction, default: true) }

    static var autoplaySiteRules: [String: AutoplaySiteRule] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: Key.autoplaySiteRules) as? [String: String] ?? [:]
            return raw.compactMapValues(AutoplaySiteRule.init(rawValue:))
        }
        set {
            UserDefaults.standard.set(newValue.mapValues(\.rawValue), forKey: Key.autoplaySiteRules)
        }
    }

    /// The sidebar address bar's Copy Link button. On by default.
    static var showsCopyLinkButton: Bool { bool(Key.showsCopyLinkButton, default: true) }
    /// The sidebar address bar's Autoplay button. On by default.
    static var showsAutoplayButton: Bool { bool(Key.showsAutoplayButton, default: true) }

    /// Chromium's "Press Esc to exit full screen" bubble stays hidden. On by default.
    static var hidesFullscreenExitHint: Bool { bool(Key.hidesFullscreenExitHint, default: true) }

    /// Gmail and TickTick pinned tabs show a live card on hover. On by default.
    static var pinnedTabLivePreviewsEnabled: Bool { bool(Key.pinnedTabLivePreviewsEnabled, default: true) }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    /// The tab switcher (Ctrl-Tab) skips pinned tabs. On by default.
    static var tabSwitcherExcludesPinnedTabs: Bool { bool(Key.tabSwitcherExcludesPinnedTabs, default: true) }
    /// ⌘1–⌘8 count from the first non-pinned tab. On by default.
    static var numberShortcutsExcludePinnedTabs: Bool { bool(Key.numberShortcutsExcludePinnedTabs, default: true) }
    /// The tab switcher and ⌘1–⌘8 skip tabs inside closed folders (collapsed
    /// tab groups and bookmark folders). On by default.
    static var tabSelectionExcludesClosedFolders: Bool { bool(Key.tabSelectionExcludesClosedFolders, default: true) }
    /// "Open Address Bar from Any App" is registered system-wide. On by default.
    static var addressBarGlobalShortcutEnabled: Bool { bool(Key.addressBarGlobalShortcutEnabled, default: true) }

    /// Closing the last tab leaves the window on the native empty state
    /// (`ForkEmptyStateView`) instead of opening a new tab. On by default.
    static var lastTabShowsEmptyState: Bool {
        get { UserDefaults.standard.object(forKey: Key.lastTabShowsEmptyState) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.lastTabShowsEmptyState) }
    }

    /// Range of the theme editor's transparency slider, as overlay opacity.
    /// 2.3's opacity slider went down to 10%; the top is fully opaque.
    static let overlayOpacityRange: ClosedRange<Double> = 0.10...1.0

    /// A Space's sidebar overlay opacity, or nil for upstream's fixed 80%.
    static func overlayOpacity(forSpaceId spaceId: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: Key.spaceOverlayOpacities) as? [String: Double])?[spaceId]
    }

    static func setOverlayOpacity(_ opacity: Double?, forSpaceId spaceId: String) {
        var map = (UserDefaults.standard.dictionary(forKey: Key.spaceOverlayOpacities) as? [String: Double]) ?? [:]
        map[spaceId] = opacity.map { min(max($0, overlayOpacityRange.lowerBound), overlayOpacityRange.upperBound) }
        UserDefaults.standard.set(map, forKey: Key.spaceOverlayOpacities)
    }

    static var spaceSwitcherPlacement: SpaceSwitcherPlacement {
        get {
            UserDefaults.standard.string(forKey: Key.spaceSwitcherPlacement)
                .flatMap(SpaceSwitcherPlacement.init(rawValue:)) ?? .top
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.spaceSwitcherPlacement) }
    }

    /// Draws each Space as a small dot instead of its icon.
    /// The top bar's hidden state the last window left, which new windows
    /// start with. Each window then keeps its own, as the sidebar does.
    static var topBarHidden: Bool {
        get { UserDefaults.standard.bool(forKey: Key.topBarHidden) }
        set { UserDefaults.standard.set(newValue, forKey: Key.topBarHidden) }
    }

    /// Comfortable: the top bar slides away while a video plays, with sound,
    /// in the focused tab, and back once it stops or another tab is focused.
    /// Off by default.
    static var hidesTopBarDuringVideo: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hidesTopBarDuringVideo) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hidesTopBarDuringVideo) }
    }

    static var spaceSwitcherUsesDots: Bool {
        get { UserDefaults.standard.bool(forKey: Key.spaceSwitcherUsesDots) }
        set { UserDefaults.standard.set(newValue, forKey: Key.spaceSwitcherUsesDots) }
    }
}
