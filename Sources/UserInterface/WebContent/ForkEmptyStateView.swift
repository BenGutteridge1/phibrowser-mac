// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine

/// Fork: the page area shown after the last tab closes, instead of a new tab
/// or the chrome://dino placeholder (`ForkSettings.lastTabShowsEmptyState`).
/// It follows the Phi 2.12 new tab page the user rebuilt as an extension:
/// the Space's color as the background, the Space accent as a soft glow at
/// the bottom in dark appearance, and the centered Phi mark with its pointer
/// highlight. Everything is Core Animation layers; pointer moves only retarget
/// implicit animations, so nothing runs per frame while the pointer is still.
final class ForkEmptyStateView: NSView {
    private let themeProvider: ThemeStateProvider
    private var themeSubscription: AnyCancellable?
    private var trackingArea: NSTrackingArea?

    private let glowLayer = CAGradientLayer()
    private let logoLayer = CALayer()
    private let baseMarkLayer = CAShapeLayer()
    private let highlightLayer = CALayer()
    private let fillGradient = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let edgeGradient = CAGradientLayer()
    private let edgeMask = CAShapeLayer()

    /// The mark's SVG viewBox, 35 by 41.
    private static let markSize = CGSize(width: 35, height: 41)
    /// Radii of the highlight's fill and edge gradients, in mark units.
    private static let fillRadius: CGFloat = 23
    private static let edgeRadius: CGFloat = 35
    /// The highlight fades out over this many points outside the mark.
    private static let highlightReach: CGFloat = 280
    /// Matches the original's exponential smoothing (about 100 ms).
    private static let followDuration: CFTimeInterval = 0.12

    private static let markPath: CGPath = ForkSVGPath.parse(
        "M27.2073 16.3279C27.2073 12.0077 23.6892 8.49234 19.3625 8.49234C14.2013 8.49234 9.99695 12.6902 9.99695 17.8506C9.99695 23.9994 15.0035 29.0021 21.1569 29.0021C28.4767 29.0021 34.4304 23.0561 34.4304 15.7388C34.4304 7.063 27.3652 0 18.6762 0C8.37644 0 0 8.37001 0 18.6619C0 30.5763 9.48793 40.3177 21.3148 40.7426V30.5956H21.1602C14.1272 30.5956 8.40543 24.8782 8.40543 17.8506C8.40543 11.8146 13.3218 6.89882 19.3657 6.89882C24.572 6.89882 28.8053 11.1289 28.8053 16.3279C28.8053 20.7737 25.2195 24.3825 20.7864 24.4501C18.4628 24.4501 16.4726 22.5822 16.4726 20.2136C16.4726 17.8893 18.3766 15.9642 20.7252 15.9642C23.0739 15.9642 24.9779 17.8667 24.9779 20.2136C24.9779 20.6385 24.8522 21.0248 24.7363 21.4111C26.2311 20.2103 27.2105 18.3915 27.2105 16.3279H27.2073Z"
    )

    init(themeProvider: ThemeStateProvider) {
        self.themeProvider = themeProvider
        super.init(frame: .zero)
        wantsLayer = true
        setUpLayers()
        themeSubscription = themeProvider.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    private func setUpLayers() {
        guard let root = layer else { return }
        root.masksToBounds = true

        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(glowLayer)

        root.addSublayer(logoLayer)
        baseMarkLayer.path = Self.markPath
        logoLayer.addSublayer(baseMarkLayer)

        highlightLayer.opacity = 0
        logoLayer.addSublayer(highlightLayer)

        fillGradient.type = .radial
        fillGradient.locations = [0, 0.4, 1]
        fillMask.path = Self.markPath
        fillGradient.mask = fillMask
        highlightLayer.addSublayer(fillGradient)

        edgeGradient.type = .radial
        edgeGradient.locations = [0, 0.5, 1]
        edgeMask.path = Self.markPath
        edgeMask.fillColor = nil
        edgeMask.strokeColor = NSColor.black.cgColor
        edgeMask.lineWidth = 0.9
        edgeGradient.mask = edgeMask
        highlightLayer.addSublayer(edgeGradient)
        moveHighlight(to: CGPoint(x: 17.5, y: 20.5), animated: false)
    }

    // MARK: Theme

    private func applyTheme() {
        let theme = themeProvider.currentTheme
        let appearance = themeProvider.currentAppearance
        let isDark = appearance.isDark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Dark: the Space's own color, opaque (the extension's fuller color,
        // without Phi's internal-page scrim). Light: the original near-white.
        let background = isDark
            ? (theme.navigationColors(for: appearance)?.first
                ?? theme.color(for: .windowOverlayBackground, appearance: appearance)).withAlphaComponent(1)
            : NSColor(hex: 0xFAFAFA)
        layer?.backgroundColor = background.cgColor

        // The original glow: the accent mixed 82% toward white, at .25/.18/.08/0.
        glowLayer.isHidden = !isDark
        let accent = (theme.color(for: .themeColor, appearance: appearance).usingColorSpace(.sRGB) ?? .gray)
        let glow = accent.blended(withFraction: 0.18, of: .white) ?? accent
        glowLayer.colors = [0.25, 0.18, 0.08, 0].map { glow.withAlphaComponent($0).cgColor }
        glowLayer.locations = [0, 0.25, 0.5, 0.75]

        let ink: NSColor = isDark ? .white : .black
        baseMarkLayer.fillColor = ink.withAlphaComponent(0.1).cgColor
        fillGradient.colors = [0.85, 0.5, 0].map { ink.withAlphaComponent($0).cgColor }
        edgeGradient.colors = [0.75, 0.35, 0].map { ink.withAlphaComponent($0).cgColor }
        fillGradient.opacity = isDark ? 0.34 : 0.1
        edgeGradient.opacity = isDark ? 0.44 : 0.22
        CATransaction.commit()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The original's fixed 600pt glow, centered on the bottom edge.
        glowLayer.frame = CGRect(x: 0, y: bounds.height - 300, width: bounds.width, height: 600)
        // clamp(112px, 20vmin, 210px), within 70% of the view.
        let width = min(max(112, 0.2 * min(bounds.width, bounds.height)), 210,
                        0.7 * bounds.width, 0.7 * bounds.height * Self.markSize.width / Self.markSize.height)
        let scale = width / Self.markSize.width
        let size = CGSize(width: width, height: Self.markSize.height * scale)
        logoLayer.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height)
        // Sublayers draw in mark units, scaled to the logo frame.
        for sublayer in [baseMarkLayer, highlightLayer] {
            sublayer.bounds = CGRect(origin: .zero, size: Self.markSize)
            sublayer.anchorPoint = .zero
            sublayer.position = .zero
            sublayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
        for gradient in [fillGradient, edgeGradient] {
            gradient.frame = CGRect(origin: .zero, size: Self.markSize)
        }
        fillMask.frame = fillGradient.bounds
        edgeMask.frame = edgeGradient.bounds
        CATransaction.commit()
    }

    // MARK: Pointer highlight

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pointer = convert(event.locationInWindow, from: nil)
        let box = logoLayer.frame
        guard box.width > 0, box.height > 0 else { return }
        let x = (pointer.x - box.minX) / box.width
        let y = (pointer.y - box.minY) / box.height
        let distance = hypot(max(0, -x, x - 1) * box.width, max(0, -y, y - 1) * box.height)
        let opacity = max(0, 1 - distance / Self.highlightReach)
        guard opacity > 0 else { fadeHighlight(); return }
        let inside = (0...1).contains(x) && (0...1).contains(y)
        let angle = atan2(y - 0.5, x - 0.5)
        let unit = inside ? CGPoint(x: x, y: y) : CGPoint(x: 0.5 + cos(angle) * 0.47, y: 0.5 + sin(angle) * 0.47)
        moveHighlight(to: CGPoint(x: unit.x * Self.markSize.width, y: unit.y * Self.markSize.height),
                      animated: highlightLayer.opacity > 0)
        animate { self.highlightLayer.opacity = Float(opacity) }
    }

    override func mouseExited(with event: NSEvent) {
        fadeHighlight()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { fadeHighlight() }
    }

    private func fadeHighlight() {
        animate { self.highlightLayer.opacity = 0 }
    }

    private func animate(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.followDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        changes()
        CATransaction.commit()
    }

    /// Centers both radial gradients on `point`, in mark units.
    private func moveHighlight(to point: CGPoint, animated: Bool) {
        let apply = {
            for (gradient, radius) in [(self.fillGradient, Self.fillRadius), (self.edgeGradient, Self.edgeRadius)] {
                let center = CGPoint(x: point.x / Self.markSize.width, y: point.y / Self.markSize.height)
                gradient.startPoint = center
                gradient.endPoint = CGPoint(x: center.x + radius / Self.markSize.width,
                                            y: center.y + radius / Self.markSize.height)
            }
        }
        if animated {
            animate(apply)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            apply()
            CATransaction.commit()
        }
    }
}

/// Fork: the absolute SVG path commands the Phi mark uses (M, L, H, V, C, Z).
enum ForkSVGPath {
    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        let scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\t")
        var current = CGPoint.zero
        var command: Character = "M"
        func number() -> CGFloat { CGFloat(scanner.scanDouble() ?? 0) }
        while !scanner.isAtEnd {
            if let letter = scanner.scanCharacter(), letter.isLetter {
                command = letter
            } else {
                scanner.currentIndex = data.index(before: scanner.currentIndex)
            }
            switch command {
            case "M":
                current = CGPoint(x: number(), y: number())
                path.move(to: current)
                command = "L"
            case "L":
                current = CGPoint(x: number(), y: number())
                path.addLine(to: current)
            case "H":
                current.x = number()
                path.addLine(to: current)
            case "V":
                current.y = number()
                path.addLine(to: current)
            case "C":
                let c1 = CGPoint(x: number(), y: number())
                let c2 = CGPoint(x: number(), y: number())
                current = CGPoint(x: number(), y: number())
                path.addCurve(to: current, control1: c1, control2: c2)
            case "Z":
                path.closeSubpath()
            default:
                return path
            }
        }
        return path
    }
}
