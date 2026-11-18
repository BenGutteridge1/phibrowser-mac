// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Fork: the theme editor's saturation slider, modeled on the 2.12 theme
/// slider (a rounded gradient track with a round knob). For a colored palette
/// it sets the palette's saturation, the handle's distance from the color
/// field's center; for the neutral palette (saturation 0, the old Pure theme)
/// it sets brightness, lighter on the left, as 2.12 did.
struct ForkThemeSaturationSlider: View {
    let palette: ThemePalette
    let appearance: Appearance
    /// Live updates while dragging, then the final value.
    let onChanged: (ThemePalette) -> Void
    let onEnded: (ThemePalette) -> Void

    /// 2.12's lowest saturation; the slider never reaches the neutral
    /// center, so a colored palette never flips into brightness mode.
    private static let minSaturation = 0.1
    private static let trackHeight: CGFloat = 10
    private static let knobDiameter: CGFloat = 18
    private static let trackStops = 8

    private var adjustsBrightness: Bool { palette.saturation == 0 }

    /// The slider position, 0...1.
    private var position: Double {
        adjustsBrightness
            ? 1 - palette.brightness
            : (palette.saturation - Self.minSaturation) / (1 - Self.minSaturation)
    }

    private func palette(at position: Double) -> ThemePalette {
        let position = min(max(position, 0), 1)
        return adjustsBrightness
            ? palette.settingBrightness(1 - position)
            : ThemePalette(
                hue: palette.hue,
                saturation: Self.minSaturation + position * (1 - Self.minSaturation),
                brightness: palette.brightness,
                harmony: palette.harmony
            )
    }

    /// The real resolved colors along the track, so it previews the result.
    private var trackColors: [Color] {
        (0..<Self.trackStops).map { stop in
            let sample = palette(at: Double(stop) / Double(Self.trackStops - 1))
            return Color(nsColor: sample.colors(for: appearance)[0].withAlphaComponent(1))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let usable = geometry.size.width - Self.knobDiameter
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: trackColors, startPoint: .leading, endPoint: .trailing))
                    .overlay {
                        Capsule().strokeBorder(Color.primary.opacity(appearance.isDark ? 0.2 : 0.1), lineWidth: 1)
                    }
                    .frame(height: Self.trackHeight)
                    .padding(.horizontal, Self.knobDiameter / 2)
                Circle()
                    .fill(Color(nsColor: palette.colors(for: appearance)[0].withAlphaComponent(1)))
                    .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
                    .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                    .offset(x: usable * position)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onChanged(palette(at: (value.location.x - Self.knobDiameter / 2) / max(usable, 1)))
                }
                .onEnded { value in
                    onEnded(palette(at: (value.location.x - Self.knobDiameter / 2) / max(usable, 1)))
                })
        }
        .frame(height: Self.knobDiameter)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { onEnded(palette(at: position - 0.05)); return .handled }
        .onKeyPress(.rightArrow) { onEnded(palette(at: position + 0.05)); return .handled }
        .accessibilityElement()
        .accessibilityLabel(adjustsBrightness
            ? NSLocalizedString("theme.editor.brightnessSlider", value: "Brightness",
                comment: "Theme editor - accessible label of the slider that sets a neutral theme's brightness")
            : NSLocalizedString("theme.editor.saturationSlider", value: "Saturation",
                comment: "Theme editor - accessible label of the slider that sets how saturated the theme color is"))
        .accessibilityValue(Text(verbatim: "\(Int((position * 100).rounded()))%"))
        .accessibilityAdjustableAction { direction in
            onEnded(palette(at: position + (direction == .increment ? 0.05 : -0.05)))
        }
    }
}
