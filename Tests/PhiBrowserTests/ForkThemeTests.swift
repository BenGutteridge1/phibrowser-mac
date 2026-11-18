// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class ForkThemeTests: XCTestCase {
    private func components(_ color: NSColor) -> [CGFloat] {
        let c = color.usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    func testOmniboxIgnoresPaletteSaturationAndStaysOpaque() {
        for appearance in [Appearance.light, .dark] {
            let low = ThemePalette(hue: 0.55, saturation: 0.15, brightness: 0.5).applying(to: Theme.pure)
            let high = ThemePalette(hue: 0.55, saturation: 0.95, brightness: 0.5).applying(to: Theme.pure)
            let lowColor = ThemedColor.forkOmniboxBackground.resolve(theme: low, appearance: appearance)
            let highColor = ThemedColor.forkOmniboxBackground.resolve(theme: high, appearance: appearance)
            XCTAssertEqual(components(lowColor), components(highColor))
            XCTAssertEqual(components(lowColor)[3], 1)
            // The sidebar itself does change with saturation.
            XCTAssertNotEqual(components(low.color(for: .windowOverlayBackground, appearance: appearance)),
                              components(high.color(for: .windowOverlayBackground, appearance: appearance)))
        }
    }

    func testNeutralPaletteOmniboxIsNeutralAtAnyBrightness() {
        for appearance in [Appearance.light, .dark] {
            let neutral = ThemedColor.searchPanelBackground.resolve(theme: Theme.pure, appearance: appearance)
            for brightness in [0.0, 0.4, 1.0] {
                let theme = ThemePalette(hue: 0, saturation: 0, brightness: brightness).applying(to: Theme.pure)
                let color = ThemedColor.forkOmniboxBackground.resolve(theme: theme, appearance: appearance)
                XCTAssertEqual(components(color), components(neutral))
            }
        }
    }

    func testOverlayOpacityAppliesToSidebarColorsButNotTheOmnibox() {
        let theme = ThemePalette(hue: 0.55, saturation: 0.6, brightness: 0.5, harmony: .analogous)
            .applying(to: Theme.pure)
        XCTAssertEqual(theme.color(for: .windowOverlayBackground, appearance: .dark).alphaComponent,
                       ThemeColorAdjustment.defaultOverlayAlpha, accuracy: 0.0001)
        theme.forkOverlayAlpha = 0.3
        let copy = theme.duplicating()
        for candidate in [theme, copy] {
            for appearance in [Appearance.light, .dark] {
                XCTAssertEqual(candidate.color(for: .windowOverlayBackground, appearance: appearance).alphaComponent,
                               0.3, accuracy: 0.0001)
                for color in candidate.navigationColors(for: appearance) ?? [] {
                    XCTAssertEqual(color.alphaComponent, 0.3, accuracy: 0.0001)
                }
                let omnibox = ThemedColor.forkOmniboxBackground.resolve(theme: candidate, appearance: appearance)
                XCTAssertEqual(omnibox.alphaComponent, 1, accuracy: 0.0001)
            }
        }
        XCTAssertEqual(theme.navigationColors(for: .dark)?.count, 2)
    }

    func testOverlayOpacityIsStoredPerSpaceAndClamped() {
        let id = "fork-test-\(UUID().uuidString)"
        defer { ForkSettings.setOverlayOpacity(nil, forSpaceId: id) }
        XCTAssertNil(ForkSettings.overlayOpacity(forSpaceId: id))
        ForkSettings.setOverlayOpacity(0.5, forSpaceId: id)
        XCTAssertEqual(ForkSettings.overlayOpacity(forSpaceId: id), 0.5)
        ForkSettings.setOverlayOpacity(0.01, forSpaceId: id)
        XCTAssertEqual(ForkSettings.overlayOpacity(forSpaceId: id), ForkSettings.overlayOpacityRange.lowerBound)
        ForkSettings.setOverlayOpacity(nil, forSpaceId: id)
        XCTAssertNil(ForkSettings.overlayOpacity(forSpaceId: id))
    }

    func testClassicPresetsMatchTheOriginalDarkColors() {
        let originals: [Int] = [0x383838, 0x1B380B, 0x0B2938, 0x0B3738, 0x100B38, 0x2D0B38, 0x380B0B, 0x382D0B]
        for (palette, hex) in zip(ThemePalette.forkClassicPresets, originals) {
            let color = palette.colors(for: .dark)[0].usingColorSpace(.sRGB)!
            let rgb = (Int((color.redComponent * 255).rounded()) << 16)
                | (Int((color.greenComponent * 255).rounded()) << 8)
                | Int((color.blueComponent * 255).rounded())
            XCTAssertEqual(rgb, hex, String(format: "expected #%06X, got #%06X", hex, rgb))
        }
    }
}
