// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Colors added by this fork, kept apart from `ThemedColors.swift` so upstream
/// merges stay conflict-free.
public extension ThemedColor {
    /// Fork: the omnibox follows the Space theme instead of upstream's neutral
    /// `searchPanelBackground`. It is the Space's own sidebar color (the first
    /// navigation color, stored as `windowOverlayBackground`) made opaque, in
    /// both appearances, so the panel reads as part of the themed window.
    static let forkOmniboxBackground = ThemedColor { theme, appearance in
        theme.color(for: .windowOverlayBackground, appearance: appearance).withAlphaComponent(1)
    }
}

extension ThemePalette {
    /// Fork: the original 2.12 built-in themes (Pure, Mint, Mist, Aqua, Iris,
    /// Petal, Coral, Amber) as palettes, shown first in the theme editor's
    /// swatch row. Each is solved so its dark overlay matches the original
    /// exactly; light mode gets the palette model's softer tint, because a
    /// palette cannot hold the originals' separate, more saturated light color.
    static let forkClassicPresets: [ThemePalette] = [
        ThemePalette(hue: 0.0000, saturation: 0.0000, brightness: 0.4150), // Pure #383838
        ThemePalette(hue: 0.2741, saturation: 0.6777, brightness: 0.1644), // Mint #1B380B
        ThemePalette(hue: 0.5556, saturation: 0.6777, brightness: 0.1644), // Mist #0B2938
        ThemePalette(hue: 0.5037, saturation: 0.6777, brightness: 0.1644), // Aqua #0B3738
        ThemePalette(hue: 0.6852, saturation: 0.6777, brightness: 0.1644), // Iris #100B38
        ThemePalette(hue: 0.7926, saturation: 0.6777, brightness: 0.1644), // Petal #2D0B38
        ThemePalette(hue: 0.0000, saturation: 0.6777, brightness: 0.1644), // Coral #380B0B
        ThemePalette(hue: 0.1259, saturation: 0.6777, brightness: 0.1644)  // Amber #382D0B
    ]
}
