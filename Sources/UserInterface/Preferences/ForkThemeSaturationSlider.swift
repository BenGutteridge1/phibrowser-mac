// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Fork: the theme editor's sliders, modeled on the 2.12 theme slider (a
/// rounded gradient track with a round knob that previews the result).
private struct ForkThemeSlider: View {
    /// The knob position, 0...1.
    let position: Double
    let trackColors: [Color]
    let knobColor: Color
    /// Draw a checkerboard under the track and knob, so transparency shows.
    let showsCheckerboard: Bool
    let appearance: Appearance
    let accessibilityLabel: String
    let onChanged: (Double) -> Void
    let onEnded: (Double) -> Void

    private static let trackHeight: CGFloat = 10
    private static let knobDiameter: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let usable = geometry.size.width - Self.knobDiameter
            ZStack(alignment: .leading) {
                ZStack {
                    if showsCheckerboard { ForkCheckerboard() }
                    LinearGradient(colors: trackColors, startPoint: .leading, endPoint: .trailing)
                }
                .clipShape(Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(appearance.isDark ? 0.2 : 0.1), lineWidth: 1)
                }
                .frame(height: Self.trackHeight)
                .padding(.horizontal, Self.knobDiameter / 2)
                ZStack {
                    if showsCheckerboard { ForkCheckerboard() }
                    knobColor
                }
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
                .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                .offset(x: usable * min(max(position, 0), 1))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onChanged(min(max((value.location.x - Self.knobDiameter / 2) / max(usable, 1), 0), 1))
                }
                .onEnded { value in
                    onEnded(min(max((value.location.x - Self.knobDiameter / 2) / max(usable, 1), 0), 1))
                })
        }
        .frame(height: Self.knobDiameter)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { onEnded(max(position - 0.05, 0)); return .handled }
        .onKeyPress(.rightArrow) { onEnded(min(position + 0.05, 1)); return .handled }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Text(verbatim: "\(Int((position * 100).rounded()))%"))
        .accessibilityAdjustableAction { direction in
            onEnded(min(max(position + (direction == .increment ? 0.05 : -0.05), 0), 1))
        }
    }
}

/// A small grey checkerboard, the usual backdrop for showing transparency.
private struct ForkCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 4
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.85)))
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                             width: cell, height: cell)), with: .color(Color(white: 0.6)))
                }
            }
        }
    }
}

/// Fork: saturation. For a colored palette it sets the palette's saturation,
/// the handle's distance from the color field's center; for the neutral
/// palette (saturation 0, the old Pure theme) it sets brightness, lighter on
/// the left, as 2.12 did.
struct ForkThemeSaturationSlider: View {
    let palette: ThemePalette
    let appearance: Appearance
    /// Live updates while dragging, then the final value.
    let onChanged: (ThemePalette) -> Void
    let onEnded: (ThemePalette) -> Void

    /// 2.12's lowest saturation; the slider never reaches the neutral
    /// center, so a colored palette never flips into brightness mode.
    private static let minSaturation = 0.1
    private static let trackStops = 8

    private var adjustsBrightness: Bool { palette.saturation == 0 }

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

    var body: some View {
        ForkThemeSlider(
            position: position,
            // The real resolved colors along the track, so it previews the result.
            trackColors: (0..<Self.trackStops).map { stop in
                let sample = palette(at: Double(stop) / Double(Self.trackStops - 1))
                return Color(nsColor: sample.colors(for: appearance)[0].withAlphaComponent(1))
            },
            knobColor: Color(nsColor: palette.colors(for: appearance)[0].withAlphaComponent(1)),
            showsCheckerboard: false,
            appearance: appearance,
            accessibilityLabel: adjustsBrightness
                ? NSLocalizedString("theme.editor.brightnessSlider", value: "Brightness",
                    comment: "Theme editor - accessible label of the slider that sets a neutral theme's brightness")
                : NSLocalizedString("theme.editor.saturationSlider", value: "Saturation",
                    comment: "Theme editor - accessible label of the slider that sets how saturated the theme color is"),
            onChanged: { onChanged(palette(at: $0)) },
            onEnded: { onEnded(palette(at: $0)) }
        )
    }
}

/// Fork: transparency of the Space's sidebar color, opaque on the left and
/// most transparent on the right (`ForkSettings.overlayOpacityRange`).
struct ForkThemeTransparencySlider: View {
    /// The current overlay opacity.
    let opacity: Double
    /// The Space's sidebar color, any alpha.
    let color: NSColor
    let appearance: Appearance
    let onChanged: (Double) -> Void
    let onEnded: (Double) -> Void

    private static var range: ClosedRange<Double> { ForkSettings.overlayOpacityRange }

    private var position: Double {
        (Self.range.upperBound - opacity) / (Self.range.upperBound - Self.range.lowerBound)
    }

    private static func opacity(at position: Double) -> Double {
        range.upperBound - min(max(position, 0), 1) * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        ForkThemeSlider(
            position: position,
            trackColors: [
                Color(nsColor: color.withAlphaComponent(Self.range.upperBound)),
                Color(nsColor: color.withAlphaComponent(Self.range.lowerBound))
            ],
            knobColor: Color(nsColor: color.withAlphaComponent(opacity)),
            showsCheckerboard: true,
            appearance: appearance,
            accessibilityLabel: NSLocalizedString("theme.editor.transparencySlider", value: "Transparency",
                comment: "Theme editor - accessible label of the slider that sets how see-through the Space's sidebar color is"),
            onChanged: { onChanged(Self.opacity(at: $0)) },
            onEnded: { onEnded(Self.opacity(at: $0)) }
        )
    }
}
