// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-28, AC-28.02, AC-28.04.
// Refs: US-03, AC-03.05, AC-03.08, AC-03.10; US-13, AC-13.07, AC-13.08; US-04, AC-04.13.
// Drawing support for the opt-in product film render (ProductFilmRenderTests). It reproduces only what the window
// server adds around Lunlet's own views — springs and fades, glass, the desktop, a camera, a pointer and captions —
// and never reads the screen.
import AppKit
import CoreImage
import QuartzCore
import SwiftUI
@testable import LunletDesktop

/// A surface spring evaluated from the same CASpringAnimation NotchSurfaceView uses, so a frame at any time shows the
/// outline the window server would draw then.
struct FilmSpring {
    let omega: Double
    let zeta: Double
    init(response: TimeInterval) {
        let spring = NotchSurfaceView.spring(response: response)
        let mass = Double(spring.mass), stiffness = Double(spring.stiffness), damping = Double(spring.damping)
        omega = (stiffness / mass).squareRoot()
        zeta = damping / (2 * (stiffness * mass).squareRoot())
    }
    /// The fraction of the way from its start to its target `t` seconds after the spring began at rest.
    func value(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        if abs(zeta - 1) < 1e-4 { return 1 - (1 + omega * t) * exp(-omega * t) }
        if zeta < 1 {
            let damped = omega * (1 - zeta * zeta).squareRoot()
            return 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
        }
        let root = omega * (zeta * zeta - 1).squareRoot(), a = -zeta * omega + root, b = -zeta * omega - root
        return 1 - (b * exp(a * t) - a * exp(b * t)) / (b - a)
    }
}

enum FilmEasing {
    /// Core Animation's cubic timing curve for a timing function.
    static func evaluate(_ function: CAMediaTimingFunction?, _ x: Double) -> Double {
        let x = min(1, max(0, x))
        guard let function else { return x }
        var first = [Float](repeating: 0, count: 2), second = [Float](repeating: 0, count: 2)
        function.getControlPoint(at: 1, values: &first)
        function.getControlPoint(at: 2, values: &second)
        func bezier(_ s: Double, _ p1: Float, _ p2: Float) -> Double {
            3 * (1 - s) * (1 - s) * s * Double(p1) + 3 * (1 - s) * s * s * Double(p2) + s * s * s
        }
        var low = 0.0, high = 1.0
        for _ in 0..<48 {
            let middle = (low + high) / 2
            if bezier(middle, first[0], second[0]) < x { low = middle } else { high = middle }
        }
        return bezier((low + high) / 2, first[1], second[1])
    }
    static var easeInOut: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
    /// A smooth start and stop for film-only motion such as the pointer and the camera.
    static func smooth(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}

/// Replays the keyframe animations a view added to its layers by setting the animated model values for each frame,
/// because an offscreen `render(in:)` draws model values only.
@MainActor final class FilmKeyframes {
    private struct Track { let layer: CALayer; let keyPath: String; let animation: CAKeyframeAnimation }
    private var tracks: [Track] = []
    var isEmpty: Bool { tracks.isEmpty }
    var duration: Double { tracks.map(\.animation.duration).max() ?? 0 }

    init(capturing root: CALayer) { visit(root) }
    private func visit(_ layer: CALayer) {
        for key in layer.animationKeys() ?? [] {
            if let animation = layer.animation(forKey: key) as? CAKeyframeAnimation, let keyPath = animation.keyPath,
               ["transform", "path"].contains(keyPath) {
                tracks.append(.init(layer: layer, keyPath: keyPath, animation: animation))
            }
        }
        layer.removeAllAnimations()
        for sublayer in layer.sublayers ?? [] { visit(sublayer) }
        if let mask = layer.mask { visit(mask) }
    }
    /// Sets every animated property to its value `time` seconds into the motion; outside it, the resting value.
    func apply(at time: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for track in tracks {
            let animation = track.animation
            guard let values = animation.values, values.count > 1 else { continue }
            let times = animation.keyTimes?.map(\.doubleValue)
                ?? (0..<values.count).map { Double($0) / Double(values.count - 1) }
            let fraction = min(1, max(0, time / max(animation.duration, 1e-6)))
            var index = 0
            while index < times.count - 2, fraction > times[index + 1] { index += 1 }
            let span = max(1e-9, times[index + 1] - times[index])
            let local = FilmEasing.evaluate(animation.timingFunctions?[safe: index], (fraction - times[index]) / span)
            switch track.keyPath {
            case "transform":
                guard let from = (values[index] as? NSValue)?.caTransform3DValue,
                      let to = (values[index + 1] as? NSValue)?.caTransform3DValue else { continue }
                track.layer.transform = Self.blend(from, to, local)
            default:
                // Path keyframes hold CGPaths by construction.
                let from = values[index] as! CGPath, to = values[index + 1] as! CGPath
                (track.layer as? CAShapeLayer)?.path = Self.blend(from, to, CGFloat(local))
            }
        }
        CATransaction.commit()
    }
    /// The lettering moves by a translation and a small rotation; both are interpolated, as Core Animation does.
    private static func blend(_ a: CATransform3D, _ b: CATransform3D, _ t: Double) -> CATransform3D {
        func parts(_ m: CATransform3D) -> (Double, Double, Double) { (Double(m.m41), Double(m.m42), atan2(Double(m.m12), Double(m.m11))) }
        let (ax, ay, aa) = parts(a), (bx, by, ba) = parts(b)
        let affine = CGAffineTransform(translationX: ax + (bx - ax) * t, y: ay + (by - ay) * t).rotated(by: aa + (ba - aa) * t)
        return CATransform3DMakeAffineTransform(affine)
    }
    private static func blend(_ a: CGPath, _ b: CGPath, _ t: CGFloat) -> CGPath {
        let first = elements(a), second = elements(b)
        guard first.count == second.count, zip(first, second).allSatisfy({ $0.0 == $1.0 && $0.1.count == $1.1.count }) else {
            return t < 0.5 ? a : b
        }
        let path = CGMutablePath()
        for ((type, from), (_, to)) in zip(first, second) {
            let points = zip(from, to).map { CGPoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t) }
            switch type {
            case .moveToPoint: path.move(to: points[0])
            case .addLineToPoint: path.addLine(to: points[0])
            case .addQuadCurveToPoint: path.addQuadCurve(to: points[1], control: points[0])
            case .addCurveToPoint: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closeSubpath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
    private static func elements(_ path: CGPath) -> [(CGPathElementType, [CGPoint])] {
        var result: [(CGPathElementType, [CGPoint])] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let count: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            default: count = 0
            }
            result.append((element.type, (0..<count).map { element.points[$0] }))
        }
        return result
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The desktop around Lunlet: a generated wallpaper in Lunlet's palette and its frosted copy. Nothing is captured
/// from a real screen.
struct FilmDesktop {
    /// The whole synthetic display in film points around the notch's center, with y pointing down from its top edge.
    static let region = CGRect(x: -FilmScreen.geometry.frame.width / 2, y: 0, width: FilmScreen.geometry.frame.width,
                               height: FilmScreen.geometry.frame.height)
    static let density: CGFloat = 2
    let wallpaper: CGImage
    let frosted: CGImage

    init() {
        let size = CGSize(width: Self.region.width * Self.density, height: Self.region.height * Self.density)
        // Float components keep the gradients finer than 8 bits until the final, dithered quantization.
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 32,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
        // Film points with a y axis pointing down, like every other drawing here.
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: Self.density, y: -Self.density)
        context.translateBy(x: -Self.region.minX, y: 0)
        func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor { AllowanceColor(hex: hex).nsColor.withAlphaComponent(alpha).cgColor }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = CGGradient(colorsSpace: space, colors: [color(0x1b1631), color(0x2a2046), color(0x3a2a57)] as CFArray,
                              locations: [0, 0.55, 1])!
        context.drawLinearGradient(base, start: .init(x: 0, y: Self.region.minY), end: .init(x: 0, y: Self.region.maxY), options: [])
        // Soft light in the vine's lavender and pearl blue, and the second agent's plum, never a photograph.
        for (center, radius, hex, alpha) in [(CGPoint(x: -420, y: 560), 640.0, 0x917bc5, 0.55),
                                             (CGPoint(x: 460, y: 170), 560.0, 0x8ea6e8, 0.42),
                                             (CGPoint(x: 120, y: 820), 520.0, 0xa0569c, 0.40),
                                             (CGPoint(x: -60, y: 120), 360.0, 0x5d4f9c, 0.35)] {
            let glow = CGGradient(colorsSpace: space, colors: [color(hex, alpha), color(hex, 0)] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        // Three calm ribbons give the glass something to soften.
        let ribbons: [(CGFloat, CGFloat, Int, CGFloat)] = [(330, 120, 0xb7afe5, 0.16), (470, 160, 0x8ea6e8, 0.13),
                                                            (610, 140, 0xcf8fb8, 0.12)]
        let edge = Self.region.maxX + 40
        for (index, (y, thickness, hex, alpha)) in ribbons.enumerated() {
            let lift = CGFloat(index) * 40
            let ribbon = CGMutablePath()
            ribbon.move(to: .init(x: -edge, y: y + 60))
            ribbon.addCurve(to: .init(x: edge, y: y - 90 + lift), control1: .init(x: -260, y: y - 210 + lift),
                            control2: .init(x: 260, y: y + 190))
            ribbon.addLine(to: .init(x: edge, y: y - 90 + lift + thickness))
            ribbon.addCurve(to: .init(x: -edge, y: y + 60 + thickness * 0.7), control1: .init(x: 260, y: y + 190 + thickness),
                            control2: .init(x: -260, y: y - 210 + lift + thickness * 0.8))
            ribbon.closeSubpath()
            context.saveGState(); context.addPath(ribbon); context.clip()
            let fill = CGGradient(colorsSpace: space, colors: [color(hex, alpha * 0.2), color(hex, alpha), color(hex, alpha * 0.3)] as CFArray,
                                  locations: [0, 0.5, 1])!
            context.drawLinearGradient(fill, start: .init(x: Self.region.minX, y: 0), end: .init(x: Self.region.maxX, y: 0),
                                       options: [])
            context.restoreGState()
        }
        let sharp = context.makeImage()!
        wallpaper = Self.blurred(sharp, radius: 3 * Self.density)
        frosted = Self.blurred(sharp, radius: 30 * Self.density)
    }

    /// What the window server's glass blurs: the desktop as `draw` paints it in film points, frosted like the wallpaper.
    func backdrop(_ draw: (CGContext) -> Void) -> CGImage {
        let size = Self.region.size
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -Self.region.minX, y: 0)
        context.interpolationQuality = .high
        FilmCanvas(context: context).draw(wallpaper, in: Self.region)
        draw(context)
        return Self.blurred(context.makeImage()!, radius: 30)
    }

    /// Core Image Gaussian blur with clamped edges, computed in floating point and quantized to 8 bits with a fixed
    /// triangular dither of about one level, so the gradients do not band once encoded.
    static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue)])
        let width = image.width, height = image.height, count = width * height * 4
        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { buffer in
            context.render(output, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: input.extent, format: .RGBAf,
                           colorSpace: space)
        }
        var bytes = [UInt8](repeating: 255, count: count)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(state >> 40) / Float(1 << 24)
        }
        values.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { target in
                var index = 0
                while index < count {
                    // One dither value per pixel keeps the noise neutral in color.
                    let dither = random() - random() + 0.5
                    for channel in 0..<3 {
                        let value = source[index + channel] * 255 + dither
                        target[index + channel] = UInt8(max(0, min(255, value.rounded(.down))))
                    }
                    index += 4
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// A camera framing of the synthetic display: a film point `p` lands on pixel `origin + p × scale`.
struct FilmShot: Equatable {
    let scale: CGFloat
    let origin: CGPoint
    /// The whole display, centered vertically, with its center at `centerX` pixels.
    static func whole(scale: CGFloat = 1, centerX: CGFloat = FilmCanvas.size.width / 2) -> FilmShot {
        FilmShot(scale: scale, origin: CGPoint(x: centerX, y: (FilmCanvas.size.height - FilmDesktop.region.height * scale) / 2))
    }
    /// The display's top edge at the frame's top edge, centered on the notch.
    static func top(scale: CGFloat) -> FilmShot { FilmShot(scale: scale, origin: CGPoint(x: FilmCanvas.size.width / 2, y: 0)) }
    /// A camera move: a zoom about the one point both framings put on the same pixel, so nothing drifts sideways,
    /// or a pan when the scales match. The scale changes geometrically, so the zoom feels even.
    static func blend(_ a: FilmShot, _ b: FilmShot, _ amount: Double) -> FilmShot {
        let u = CGFloat(min(1, max(0, amount)))
        guard abs(a.scale - b.scale) > 1e-6 else {
            return FilmShot(scale: a.scale, origin: CGPoint(x: a.origin.x + (b.origin.x - a.origin.x) * u,
                                                            y: a.origin.y + (b.origin.y - a.origin.y) * u))
        }
        let fixed = CGPoint(x: (a.origin.x - b.origin.x) / (b.scale - a.scale), y: (a.origin.y - b.origin.y) / (b.scale - a.scale))
        let pixel = CGPoint(x: a.origin.x + fixed.x * a.scale, y: a.origin.y + fixed.y * a.scale)
        let scale = a.scale * pow(b.scale / a.scale, u)
        return FilmShot(scale: scale, origin: CGPoint(x: pixel.x - fixed.x * scale, y: pixel.y - fixed.y * scale))
    }
}

/// A 1920 × 1080 frame. Drawing uses film points around the notch's center with y pointing down; the camera's shot
/// sets where the display sits and how many pixels a point covers.
struct FilmCanvas {
    static let size = CGSize(width: 1920, height: 1080)
    let context: CGContext

    /// A frame with `density` device pixels per frame pixel: 1 for the film, more for stills shown at a higher resolution.
    init(density: CGFloat = 1) {
        context = CGContext(data: nil, width: Int(Self.size.width * density), height: Int(Self.size.height * density),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.setShouldAntialias(true); context.setAllowsFontSmoothing(true)
        context.translateBy(x: 0, y: Self.size.height * density); context.scaleBy(x: density, y: -density)
    }
    /// Wraps a context that already draws with y pointing down.
    init(context: CGContext) { self.context = context }
    func camera(_ shot: FilmShot, _ body: () -> Void) {
        context.saveGState()
        context.translateBy(x: shot.origin.x, y: shot.origin.y); context.scaleBy(x: shot.scale, y: shot.scale)
        body()
        context.restoreGState()
    }
    /// Draws an image upright in the y-down space.
    func draw(_ image: CGImage, in rect: CGRect, alpha: CGFloat = 1) {
        guard alpha > 0.001 else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
    /// Linear interpolation between two images (premultiplied), so content common to both never dims.
    func crossfade(_ from: CGImage, _ to: CGImage, amount: CGFloat, in rect: CGRect) {
        if amount <= 0 { draw(from, in: rect); return }
        if amount >= 1 { draw(to, in: rect); return }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        draw(from, in: rect, alpha: 1 - amount)
        context.setBlendMode(.plusLighter)
        draw(to, in: rect, alpha: amount)
        context.endTransparencyLayer()
    }
    /// A window shadow around a shape, without filling the shape itself.
    func shadow(_ path: CGPath, opacity: CGFloat, radius: CGFloat, offset: CGFloat) {
        guard opacity > 0.001 else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        // Shadow offsets are in device space, where y points up.
        let scale = context.ctm.a
        context.setShadow(offset: CGSize(width: 0, height: -offset * scale), blur: radius * scale,
                          color: CGColor(gray: 0, alpha: opacity))
        context.addPath(path); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setBlendMode(.destinationOut)
        context.addPath(path); context.fillPath()
        context.endTransparencyLayer()
        context.restoreGState()
    }
    /// Approximated glass: the frosted desktop behind it with a dark tint and a faint rim, inside the outline.
    func glass(_ path: CGPath, backdrop: CGImage, opacity: CGFloat) {
        guard opacity > 0.001 else { return }
        context.saveGState()
        context.addPath(path); context.clip()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        draw(backdrop, in: FilmDesktop.region)
        context.setFillColor(CGColor(srgbRed: 0.07, green: 0.06, blue: 0.11, alpha: 0.5))
        context.fill(FilmDesktop.region)
        // A faint rim, except along the top edge, which meets the screen's edge.
        context.clip(to: CGRect(x: FilmDesktop.region.minX, y: 1, width: FilmDesktop.region.width, height: FilmDesktop.region.height))
        context.addPath(path); context.setStrokeColor(CGColor(gray: 1, alpha: 0.16)); context.setLineWidth(1.5)
        context.strokePath()
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// The pointer, captions and title card: film affordances drawn in the frame, not Lunlet interface.
enum FilmArt {
    /// A plain arrow pointer, its tip at the origin, in points.
    static var arrow: CGPath {
        let path = CGMutablePath()
        path.addLines(between: [.init(x: 0, y: 0), .init(x: 0, y: 17), .init(x: 4.1, y: 13.3), .init(x: 6.9, y: 19.7),
                                .init(x: 9.5, y: 18.6), .init(x: 6.8, y: 12.4), .init(x: 12.2, y: 12.4)])
        path.closeSubpath()
        return path
    }
    static func pointer(_ canvas: FilmCanvas, at point: CGPoint, press: CGFloat, ring: CGFloat?) {
        let context = canvas.context
        if let ring, ring < 1 {
            context.saveGState()
            let radius = 6 + 14 * CGFloat(FilmEasing.smooth(Double(ring)))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.55 * (1 - ring))); context.setLineWidth(1.6)
            context.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            context.restoreGState()
        }
        context.saveGState()
        context.translateBy(x: point.x, y: point.y); context.scaleBy(x: 1 - 0.1 * press, y: 1 - 0.1 * press)
        let scale = context.ctm.a
        context.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 3 * scale, color: CGColor(gray: 0, alpha: 0.45))
        context.addPath(arrow); context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(2.2)
        context.setLineJoin(.round); context.strokePath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.addPath(arrow); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fillPath()
        context.restoreGState()
    }

    /// Wrapped lines of system text, each drawn centered on `centerX` from the top `y`, in a y-down pixel space.
    @discardableResult
    static func text(_ canvas: FilmCanvas, _ string: String, font: NSFont, color: CGColor, centerX: CGFloat, top: CGFloat,
                     maxWidth: CGFloat, lineGap: CGFloat = 6, measureOnly: Bool = false) -> CGSize {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [CTLine] = [], start = 0
        while start < attributed.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        let ascent = font.ascender, descent = -font.descender, lineHeight = ascent + descent + lineGap
        let width = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        let height = CGFloat(lines.count) * lineHeight - lineGap
        guard !measureOnly else { return CGSize(width: width, height: height) }
        let context = canvas.context
        for (index, line) in lines.enumerated() {
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.saveGState()
            context.translateBy(x: centerX - lineWidth / 2, y: top + CGFloat(index) * lineHeight + ascent)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        return CGSize(width: width, height: height)
    }

    /// One line of text from `x` with its baseline at `baseline`, in a y-down space; returns its width.
    @discardableResult
    static func line(_ context: CGContext, _ text: NSAttributedString, x: CGFloat, baseline: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(text)
        context.saveGState()
        context.translateBy(x: x, y: baseline); context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
    static func attributed(_ string: String, _ font: NSFont, _ color: CGColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!])
    }

    /// A lower-third caption in pixels, faded by `opacity`.
    static func caption(_ canvas: FilmCanvas, _ string: String, opacity: CGFloat) {
        guard opacity > 0.001 else { return }
        let font = NSFont.systemFont(ofSize: 34, weight: .medium)
        let size = text(canvas, string, font: font, color: .white, centerX: 0, top: 0, maxWidth: 1400, measureOnly: true)
        let padding = CGSize(width: 30, height: 16)
        let box = CGRect(x: FilmCanvas.size.width / 2 - size.width / 2 - padding.width,
                         y: FilmCanvas.size.height - 70 - size.height - 2 * padding.height,
                         width: size.width + 2 * padding.width, height: size.height + 2 * padding.height)
        let context = canvas.context
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 20, cornerHeight: 20, transform: nil))
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.04, blue: 0.08, alpha: 0.62)); context.fillPath()
        text(canvas, string, font: font, color: .white, centerX: box.midX, top: box.minY + padding.height, maxWidth: 1400)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
