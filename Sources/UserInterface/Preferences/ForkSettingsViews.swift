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
