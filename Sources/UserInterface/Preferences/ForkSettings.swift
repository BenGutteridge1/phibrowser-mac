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

/// Preferences added by this fork. Kept in one place, separate from
/// `PhiPreferences`, so upstream merges stay conflict-free. Every key is
/// prefixed with `fork.` and read through `UserDefaults.standard`, which is
/// also what the `@AppStorage` bindings in the views observe.
enum ForkSettings {
    enum Key {
        static let spaceSwitcherPlacement = "fork.spaceSwitcherPlacement"
        static let spaceSwitcherUsesDots = "fork.spaceSwitcherUsesDots"
    }

    static var spaceSwitcherPlacement: SpaceSwitcherPlacement {
        get {
            UserDefaults.standard.string(forKey: Key.spaceSwitcherPlacement)
                .flatMap(SpaceSwitcherPlacement.init(rawValue:)) ?? .top
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.spaceSwitcherPlacement) }
    }

    /// Draws each Space as a small dot instead of its icon.
    static var spaceSwitcherUsesDots: Bool {
        get { UserDefaults.standard.bool(forKey: Key.spaceSwitcherUsesDots) }
        set { UserDefaults.standard.set(newValue, forKey: Key.spaceSwitcherUsesDots) }
    }
}
