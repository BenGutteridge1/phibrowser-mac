// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Settings rows for the fork's own preferences (see `ForkSettings`). Each
/// group is one view so upstream panes gain only a single line per group.

/// Settings → Spaces: how the sidebar's Space switcher looks and where it sits.
struct ForkSpaceSwitcherSettingsRows: View {
    @AppStorage(ForkSettings.Key.spaceSwitcherUsesDots) private var usesDots = false
    @AppStorage(ForkSettings.Key.spaceSwitcherPlacement) private var placement: SpaceSwitcherPlacement = .top

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.spaces.fork.spaceSwitcherDots.title", value: "Show Spaces as dots",
                        comment: "Spaces settings - toggle that draws each Space in the sidebar switcher as a small dot"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("settings.spaces.fork.spaceSwitcherDots.description", value: "Draws each Space as a small dot instead of its icon. Hover a dot to see the Space's name.",
                        comment: "Spaces settings - description under the Space switcher dots toggle"))
                        .font(.system(size: 11))
                        .themedForeground(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $usesDots)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
                    .labelsHidden()
            }
            .padding(.vertical, 12)

            Divider()

            HStack(alignment: .center, spacing: 12) {
                Text(NSLocalizedString("settings.spaces.fork.spaceSwitcherPlacement.title", value: "Space switcher position",
                    comment: "Spaces settings - picker for where the sidebar shows the Space switcher"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Spacer(minLength: 12)
                Picker("", selection: $placement) {
                    ForEach(SpaceSwitcherPlacement.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings → General → Browsing: what closing the last tab leaves behind.
struct ForkLastTabEmptyStateRow: View {
    @AppStorage(ForkSettings.Key.lastTabShowsEmptyState) private var showsEmptyState = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("settings.general.fork.lastTabEmptyState.title", value: "Keep the window empty after closing the last tab",
                    comment: "General settings - toggle: closing the last tab shows an empty page instead of opening a new tab"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Text(NSLocalizedString("settings.general.fork.lastTabEmptyState.description", value: "Shows the Phi mark on your Space's color instead of opening a new tab.",
                    comment: "General settings - description under the empty-after-last-tab toggle"))
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $showsEmptyState)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
                .labelsHidden()
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings → General → Browsing: Chromium's Esc hint when a page goes fullscreen.
struct ForkFullscreenHintRow: View {
    @AppStorage(ForkSettings.Key.hidesFullscreenExitHint) private var hidesHint = true

    var body: some View {
        ForkToggleRow(
            title: NSLocalizedString("settings.general.fork.fullscreenExitHint.title", value: "Hide “Press Esc to exit full screen”",
                comment: "General settings - toggle that hides the message shown when a page or video goes full screen"),
            description: NSLocalizedString("settings.general.fork.fullscreenExitHint.description", value: "Videos and pages go full screen without the message. Esc still leaves full screen.",
                comment: "General settings - description under the toggle that hides the full-screen exit message"),
            isOn: $hidesHint)
    }
}

/// Settings → General → Browsing: the picture-in-picture button over videos.
struct ForkVideoPiPButtonRow: View {
    @AppStorage(ForkSettings.Key.videoPiPButtonEnabled) private var isEnabled = true

    var body: some View {
        ForkToggleRow(
            title: NSLocalizedString("settings.general.fork.videoPiPButton.title", value: "Picture-in-picture button on videos",
                comment: "General settings - toggle for the picture-in-picture button shown when hovering a video"),
            description: NSLocalizedString("settings.general.fork.videoPiPButton.description", value: "Hover a video to show the picture-in-picture icon in its corner. Applies to pages loaded after the change.",
                comment: "General settings - description under the toggle for the picture-in-picture button on videos"),
            isOn: $isEnabled)
    }
}

/// One labelled switch, in the style of the settings panes' toggle rows.
struct ForkToggleRow: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .themedForeground(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
                .labelsHidden()
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings → Spaces: which tabs the tab switcher and ⌘1–⌘8 skip.
struct ForkTabExclusionSettingsRows: View {
    @AppStorage(ForkSettings.Key.tabSwitcherExcludesPinnedTabs) private var switcherSkipsPinned = true
    @AppStorage(ForkSettings.Key.numberShortcutsExcludePinnedTabs) private var numbersSkipPinned = true
    @AppStorage(ForkSettings.Key.tabSelectionExcludesClosedFolders) private var skipsClosedFolders = true

    var body: some View {
        VStack(spacing: 0) {
            ForkToggleRow(
                title: NSLocalizedString("settings.spaces.fork.switcherSkipsPinned.title", value: "Tab Switcher skips pinned tabs",
                    comment: "Spaces settings - toggle that leaves pinned tabs out of the Ctrl-Tab tab switcher"),
                description: nil, isOn: $switcherSkipsPinned)
            Divider()
            ForkToggleRow(
                title: NSLocalizedString("settings.spaces.fork.numbersSkipPinned.title", value: "⌘1–⌘8 skip pinned tabs",
                    comment: "Spaces settings - toggle that makes the Command-number tab shortcuts count from the first tab that is not pinned"),
                description: NSLocalizedString("settings.spaces.fork.numbersSkipPinned.description", value: "⌘1 selects the first tab after your pinned tabs.",
                    comment: "Spaces settings - description under the toggle that makes Command-number shortcuts skip pinned tabs"),
                isOn: $numbersSkipPinned)
            Divider()
            ForkToggleRow(
                title: NSLocalizedString("settings.spaces.fork.skipClosedFolders.title", value: "Skip tabs in closed folders",
                    comment: "Spaces settings - toggle that leaves tabs inside collapsed folders and tab groups out of the tab switcher and Command-number shortcuts"),
                description: NSLocalizedString("settings.spaces.fork.skipClosedFolders.description", value: "The Tab Switcher and ⌘1–⌘8 leave out tabs inside collapsed folders and tab groups.",
                    comment: "Spaces settings - description under the toggle that skips tabs in closed folders"),
                isOn: $skipsClosedFolders)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings → Navigations: the system-wide "Open Address Bar from Any App".
struct ForkAddressBarShortcutSection: View {
    @AppStorage(ForkSettings.Key.addressBarGlobalShortcutEnabled) private var isEnabled = true
    @State private var status = AppController.shared?.forkAddressBarShortcutRegistrar.status ?? .disabled
    @State private var shortcut = Shortcuts.key(for: .FORK_OPEN_ADDRESS_BAR_ANYWHERE)?.displayString ?? "—"

    private var statusDescription: String? {
        switch status {
        case .disabled: return nil
        case .registered:
            return NSLocalizedString("settings.navigations.fork.addressBarShortcut.registered", value: "Works while any app is active. Change the key in Shortcuts.",
                comment: "Navigations settings - status when the system-wide open-address-bar shortcut is registered")
        case .unassigned:
            return NSLocalizedString("settings.navigations.fork.addressBarShortcut.unassigned", value: "Assign an Open Address Bar from Any App shortcut in Shortcuts.",
                comment: "Navigations settings - status when the system-wide open-address-bar shortcut has no key assigned")
        case .unsupported, .failed:
            return NSLocalizedString("settings.navigations.fork.addressBarShortcut.unavailable", value: "This shortcut can't be used system-wide, often because another app owns it. Choose another in Shortcuts.",
                comment: "Navigations settings - status when the system-wide open-address-bar shortcut could not be registered")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("settings.navigations.fork.addressBarShortcut.sectionTitle", value: "Address Bar",
                comment: "Navigations settings - title of the section for the system-wide open-address-bar shortcut"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            SettingsDetailCard {
                ForkToggleRow(
                    title: String(format: NSLocalizedString("settings.navigations.fork.addressBarShortcut.title", value: "Open the address bar when pressing %@ in any app",
                        comment: "Navigations settings - toggle for the system-wide open-address-bar shortcut; %@ is the shortcut, such as ⌥Space"), shortcut),
                    description: statusDescription,
                    isOn: $isEnabled)
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            AppController.shared?.forkAddressBarShortcutRegistrar.setEnabled(enabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: KioskGlobalShortcutRegistrar.statusDidChangeNotification)) { _ in
            status = AppController.shared?.forkAddressBarShortcutRegistrar.status ?? .disabled
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutsDidChange)) { _ in
            shortcut = Shortcuts.key(for: .FORK_OPEN_ADDRESS_BAR_ANYWHERE)?.displayString ?? "—"
        }
    }
}

/// Settings → Spaces: live hover cards for Gmail and TickTick pinned tabs.
struct ForkPinnedPreviewSettingsRow: View {
    @AppStorage(ForkSettings.Key.pinnedTabLivePreviewsEnabled) private var isEnabled = true
    @AppStorage(ForkSettings.Key.gmailCardSource) private var gmailSource: GmailCardSource = .website
    @AppStorage(ForkSettings.Key.tickTickCardSource) private var tickTickSource: TickTickCardSource = .native

    var body: some View {
        VStack(spacing: 0) {
            ForkToggleRow(
                title: NSLocalizedString("settings.spaces.fork.pinnedLivePreviews.title", value: "Live previews for Gmail and TickTick pinned tabs",
                    comment: "Spaces settings - toggle for interactive hover cards on Gmail and TickTick pinned tabs"),
                description: NSLocalizedString("settings.spaces.fork.pinnedLivePreviews.description", value: "Hover the pinned tab to see and use the site in a small card.",
                    comment: "Spaces settings - description under the live pinned-tab preview toggle"),
                isOn: $isEnabled)
            if isEnabled {
                Divider()
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("settings.spaces.fork.gmailCardSource.title", value: "Gmail card shows",
                            comment: "Spaces settings - picker for what the Gmail pinned tab's hover card shows"))
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                        Text(NSLocalizedString("settings.spaces.fork.gmailCardSource.description", value: "Thunderbird shows your latest mail from the Thunderbird app, through a small add-on the card helps you install.",
                            comment: "Spaces settings - description under the Gmail card source picker"))
                            .font(.system(size: 11))
                            .themedForeground(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: $gmailSource) {
                        ForEach(GmailCardSource.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .padding(.vertical, 12)
                Divider()
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("settings.spaces.fork.tickTickCardSource.title", value: "TickTick card shows",
                            comment: "Spaces settings - picker for what the TickTick pinned tab's hover card shows"))
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                        Text(NSLocalizedString("settings.spaces.fork.tickTickCardSource.description", value: "Task list shows your tasks natively, from TickTick's API with your API token. The TickTick app doesn't need to be open.",
                            comment: "Spaces settings - description under the TickTick card source picker"))
                            .font(.system(size: 11))
                            .themedForeground(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: $tickTickSource) {
                        ForEach(TickTickCardSource.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .padding(.vertical, 12)
            }
        }
        .onChange(of: gmailSource) { _, source in
            if source == .thunderbird { ForkThunderbirdMail.shared.start() }
        }
    }
}
