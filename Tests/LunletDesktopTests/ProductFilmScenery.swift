// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-28, AC-28.04.
// Refs: US-05, AC-05.06; US-06, AC-06.01, AC-06.02.
// The synthetic world around Lunlet in the opt-in product film (ProductFilmRenderTests): a display with its bezel, a
// plain menu bar, an editor and a terminal running a coding agent, a generic lock screen, and a generic phone that
// shows the completion card Lunlet's own SessionCard renders. Every name, line and value is invented; nothing is read
// from this Mac, its screen, its accounts or its agents' sessions. No logo, font file or image is added.
import AppKit
import SwiftUI
import LunletCore
@testable import LunletFeishu

/// sRGB colors from hex values.
enum FilmInk {
    static func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
    static func swiftUI(_ hex: Int, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255, opacity: opacity)
    }
    static let text = 0xe7e3f3, dim = 0x8f89a8, lavender = 0xb7afe5, blue = 0x8ea6e8, green = 0x8fd6a4, red = 0xe58f9b
    static let pink = 0xcf8fb8, peach = 0xe8a07a
}

/// The laptop around the display, drawn in film points: a dark bezel with an aluminum rim and the base's front edge.
enum FilmDevice {
    static let bezel: CGFloat = 15, chin: CGFloat = 19
    static var screen: CGPath { CGPath(roundedRect: FilmDesktop.region, cornerWidth: 10, cornerHeight: 10, transform: nil) }
    static var lid: CGRect {
        let region = FilmDesktop.region
        return CGRect(x: region.minX - bezel, y: region.minY - bezel, width: region.width + 2 * bezel,
                      height: region.height + bezel + chin)
    }
    /// The room around the laptop, in pixels: a dark backdrop with a faint glow in Lunlet's palette.
    static func backdrop(_ context: CGContext) {
        let size = FilmCanvas.size
        context.setFillColor(FilmInk.color(0x0b0a10)); context.fill(CGRect(origin: .zero, size: size))
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [FilmInk.color(0x2b2242, 0.9), FilmInk.color(0x0b0a10, 0)] as CFArray, locations: [0, 1])!
        let center = CGPoint(x: size.width / 2, y: size.height * 0.46)
        context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 1150, options: [])
    }
    static func drawLid(_ canvas: FilmCanvas) {
        let context = canvas.context, lid = Self.lid
        // The base's front edge, slightly wider than the lid, with the thumb recess at its center.
        let base = CGRect(x: lid.minX - 26, y: lid.maxY - 2, width: lid.width + 52, height: 13)
        let basePath = CGPath(roundedRect: base, cornerWidth: 7, cornerHeight: 7, transform: nil)
        canvas.shadow(basePath, opacity: 0.6, radius: 14, offset: 6)
        context.saveGState(); context.addPath(basePath); context.clip()
        let metal = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [FilmInk.color(0x5a5960), FilmInk.color(0x34333a), FilmInk.color(0x1c1b20)] as CFArray,
                               locations: [0, 0.35, 1])!
        context.drawLinearGradient(metal, start: CGPoint(x: 0, y: base.minY), end: CGPoint(x: 0, y: base.maxY), options: [])
        context.setFillColor(FilmInk.color(0x18171c))
        context.fill(CGRect(x: -70, y: base.minY, width: 140, height: 4))
        context.restoreGState()

        let lidPath = CGPath(roundedRect: lid, cornerWidth: 24, cornerHeight: 24, transform: nil)
        canvas.shadow(lidPath, opacity: 0.55, radius: 30, offset: 10)
        context.addPath(lidPath); context.setFillColor(FilmInk.color(0x09090b)); context.fillPath()
        // The aluminum edge of the lid catches a little light, so the laptop keeps its outline when the display sleeps.
        context.addPath(lidPath); context.setStrokeColor(FilmInk.color(0x5c5b66)); context.setLineWidth(1.8); context.strokePath()
        let inner = CGPath(roundedRect: lid.insetBy(dx: 1.6, dy: 1.6), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil)
        context.addPath(inner); context.setStrokeColor(FilmInk.color(0x000000, 0.9)); context.setLineWidth(1); context.strokePath()
    }
    /// The display going to sleep: the panel darkens to its unlit glass, which keeps a faint diagonal reflection.
    static func drawSleep(_ context: CGContext, amount: CGFloat) {
        guard amount > 0.001 else { return }
        let region = FilmDesktop.region
        context.setFillColor(FilmInk.color(0x060608, amount)); context.fill(region)
        let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [FilmInk.color(0xffffff, 0.075 * amount), FilmInk.color(0xffffff, 0.02 * amount),
                                        FilmInk.color(0xffffff, 0)] as CFArray, locations: [0, 0.45, 1])!
        context.drawLinearGradient(sheen, start: CGPoint(x: region.maxX, y: region.minY),
                                   end: CGPoint(x: region.maxX - 760, y: region.minY + 900), options: [])
    }
}

/// A plain menu bar: a neutral app menu and generic status items, drawn in film points.
@MainActor enum FilmMenuBar {
    static func draw(_ context: CGContext, clock: String) {
        let region = FilmDesktop.region, height = FilmScreen.notch.height
        context.setFillColor(CGColor(gray: 0, alpha: 0.22))
        context.fill(CGRect(x: region.minX, y: 0, width: region.width, height: height))
        let baseline: CGFloat = 20.5
        var x = region.minX + 20
        let white = CGColor(gray: 1, alpha: 0.93)
        x += FilmArt.line(context, FilmArt.attributed("Shell", .systemFont(ofSize: 13, weight: .bold), white), x: x, baseline: baseline) + 21
        for item in ["File", "Edit", "View", "Window", "Help"] {
            x += FilmArt.line(context, FilmArt.attributed(item, .systemFont(ofSize: 13), white), x: x, baseline: baseline) + 21
        }
        status(context, clock: clock, alpha: 1)
    }
    /// The right side: battery, Wi-Fi, a generic control glyph and the clock, which the lock screen also shows.
    static func status(_ context: CGContext, clock: String?, alpha: CGFloat) {
        guard alpha > 0.001 else { return }
        let region = FilmDesktop.region, mid = FilmScreen.notch.height / 2
        let white = CGColor(gray: 1, alpha: 0.93 * alpha)
        var right = region.maxX - 16
        if let clock {
            let text = FilmArt.attributed(clock, .systemFont(ofSize: 13), white)
            let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
            FilmArt.line(context, text, x: right - width, baseline: 20.5)
            right -= width + 18
            // Two stacked toggles.
            for (row, knob) in [(mid - 3.6, right - 11), (mid + 3.6, right - 4.5)] {
                context.addPath(CGPath(roundedRect: CGRect(x: right - 15, y: row - 2.6, width: 15, height: 5.2), cornerWidth: 2.6,
                                       cornerHeight: 2.6, transform: nil))
                context.setStrokeColor(white); context.setLineWidth(1.1); context.strokePath()
                context.setFillColor(white); context.fillEllipse(in: CGRect(x: knob - 2, y: row - 2, width: 4, height: 4))
            }
            right -= 15 + 18
        }
        wifi(context, center: CGPoint(x: right - 8, y: mid + 5), color: white)
        right -= 16 + 16
        battery(context, frame: CGRect(x: right - 25, y: mid - 6, width: 25, height: 12), color: white)
    }
    static func wifi(_ context: CGContext, center: CGPoint, color: CGColor) {
        context.saveGState()
        context.setStrokeColor(color); context.setLineCap(.round); context.setLineWidth(1.9)
        for radius in [5.0, 9.4] as [CGFloat] {
            context.addArc(center: center, radius: radius, startAngle: -.pi * 0.76, endAngle: -.pi * 0.24, clockwise: false)
            context.strokePath()
        }
        context.move(to: center)
        context.addArc(center: center, radius: 1.9, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        context.setFillColor(color); context.fillPath()
        context.restoreGState()
    }
    static func battery(_ context: CGContext, frame: CGRect, color: CGColor) {
        context.saveGState()
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 3.6, cornerHeight: 3.6, transform: nil))
        context.setStrokeColor(color.copy(alpha: color.alpha * 0.55)!); context.setLineWidth(1); context.strokePath()
        context.addPath(CGPath(roundedRect: CGRect(x: frame.minX + 2, y: frame.minY + 2, width: (frame.width - 4) * 0.8,
                                                  height: frame.height - 4), cornerWidth: 2, cornerHeight: 2, transform: nil))
        context.setFillColor(color); context.fillPath()
        context.addPath(CGPath(roundedRect: CGRect(x: frame.maxX + 1, y: frame.midY - 2, width: 1.6, height: 4), cornerWidth: 0.8,
                               cornerHeight: 0.8, transform: nil))
        context.setFillColor(color.copy(alpha: color.alpha * 0.55)!); context.fillPath()
        context.restoreGState()
    }
}

/// Generic window chrome: a shadow, a title bar with traffic lights and a hairline edge.
@MainActor enum FilmWindowChrome {
    static let titleBar: CGFloat = 30
    static func draw(_ canvas: FilmCanvas, frame: CGRect, title: String, active: Bool, fill: Int) {
        let context = canvas.context
        let shape = CGPath(roundedRect: frame, cornerWidth: 12, cornerHeight: 12, transform: nil)
        canvas.shadow(shape, opacity: active ? 0.55 : 0.4, radius: active ? 34 : 22, offset: active ? 16 : 9)
        context.saveGState(); context.addPath(shape); context.clip()
        context.setFillColor(FilmInk.color(fill, 0.985)); context.fill(frame)
        context.setFillColor(FilmInk.color(active ? 0x24212f : 0x1f1c28))
        context.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: titleBar))
        context.setFillColor(CGColor(gray: 0, alpha: 0.45))
        context.fill(CGRect(x: frame.minX, y: frame.minY + titleBar - 1, width: frame.width, height: 1))
        context.restoreGState()
        let lights = active ? [0xff5f57, 0xfebc2e, 0x28c840] : [0x55525d, 0x55525d, 0x55525d]
        for (index, hex) in lights.enumerated() {
            let center = CGPoint(x: frame.minX + 18 + CGFloat(index) * 20, y: frame.minY + titleBar / 2)
            context.setFillColor(FilmInk.color(hex))
            context.fillEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.18)); context.setLineWidth(0.6)
            context.strokeEllipse(in: CGRect(x: center.x - 5.7, y: center.y - 5.7, width: 11.4, height: 11.4))
        }
        let text = FilmArt.attributed(title, .systemFont(ofSize: 13, weight: .semibold), CGColor(gray: 1, alpha: active ? 0.82 : 0.42))
        let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
        FilmArt.line(context, text, x: frame.midX - width / 2, baseline: frame.minY + 19.5)
        context.addPath(shape); context.setStrokeColor(CGColor(gray: 1, alpha: 0.11)); context.setLineWidth(1); context.strokePath()
    }
}

/// An inactive editor showing neutral placeholder markup.
@MainActor enum FilmEditor {
    static let frame = CGRect(x: -736, y: 64, width: 720, height: 600)
    static let code = [
        "<!doctype html>", "<html lang=\"en\">", "<head>", "  <meta charset=\"utf-8\">",
        "  <meta name=\"viewport\" content=\"width=device-width\">", "  <title>Product page</title>",
        "  <link rel=\"stylesheet\" href=\"style.css\">", "</head>", "<body>", "  <header class=\"hero\">",
        "    <h1>Your agents, one glance away</h1>", "    <p>Progress and limits beside the notch.</p>",
        "    <a class=\"button\" href=\"#download\">Download</a>", "  </header>", "  <section class=\"features\">",
        "    <article>", "      <h2>Task cues</h2>", "      <p>A short island when a turn ends.</p>", "    </article>",
        "    <article>", "      <h2>Usage</h2>", "      <p>Weekly limits and daily tokens.</p>", "    </article>",
        "  </section>", "</body>", "</html>",
    ]
    static func draw(_ canvas: FilmCanvas) {
        let context = canvas.context, frame = Self.frame
        FilmWindowChrome.draw(canvas, frame: frame, title: "index.html — lunlet-site", active: false, fill: 0x1a1724)
        let top = frame.minY + FilmWindowChrome.titleBar
        // Sidebar.
        let sidebar = CGRect(x: frame.minX, y: top, width: 176, height: frame.maxY - top)
        context.saveGState()
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 12, cornerHeight: 12, transform: nil)); context.clip()
        context.setFillColor(FilmInk.color(0x1e1b29)); context.fill(sidebar)
        context.setFillColor(CGColor(gray: 0, alpha: 0.35)); context.fill(CGRect(x: sidebar.maxX - 1, y: top, width: 1, height: sidebar.height))
        context.restoreGState()
        FilmArt.line(context, FilmArt.attributed("LUNLET-SITE", .systemFont(ofSize: 10.5, weight: .semibold), FilmInk.color(FilmInk.dim)),
                     x: sidebar.minX + 16, baseline: top + 26)
        let files: [(String, Int)] = [("index.html", FilmInk.peach), ("style.css", FilmInk.blue), ("copy.md", FilmInk.lavender),
                                      ("build.sh", FilmInk.green), ("assets", FilmInk.dim)]
        for (index, (name, hex)) in files.enumerated() {
            let row = CGRect(x: sidebar.minX + 8, y: top + 40 + CGFloat(index) * 24, width: sidebar.width - 16, height: 22)
            if index == 0 {
                context.addPath(CGPath(roundedRect: row, cornerWidth: 5, cornerHeight: 5, transform: nil))
                context.setFillColor(CGColor(gray: 1, alpha: 0.07)); context.fillPath()
            }
            context.addPath(CGPath(roundedRect: CGRect(x: row.minX + 8, y: row.midY - 5, width: 10, height: 10), cornerWidth: 2.5,
                                   cornerHeight: 2.5, transform: nil))
            context.setFillColor(FilmInk.color(hex, 0.85)); context.fillPath()
            FilmArt.line(context, FilmArt.attributed(name, .systemFont(ofSize: 12.5), FilmInk.color(FilmInk.text, index == 0 ? 0.95 : 0.72)),
                         x: row.minX + 26, baseline: row.midY + 4.3)
        }
        // Tabs.
        let tabs = CGRect(x: sidebar.maxX, y: top, width: frame.maxX - sidebar.maxX, height: 32)
        context.setFillColor(FilmInk.color(0x1e1b29)); context.fill(tabs)
        let active = CGRect(x: tabs.minX, y: tabs.minY, width: 118, height: tabs.height)
        context.setFillColor(FilmInk.color(0x1a1724)); context.fill(active)
        context.setFillColor(FilmInk.color(FilmInk.lavender, 0.8)); context.fill(CGRect(x: active.minX, y: active.minY, width: active.width, height: 1.5))
        FilmArt.line(context, FilmArt.attributed("index.html", .systemFont(ofSize: 12), FilmInk.color(FilmInk.text, 0.9)),
                     x: active.minX + 16, baseline: active.midY + 4.2)
        FilmArt.line(context, FilmArt.attributed("style.css", .systemFont(ofSize: 12), FilmInk.color(FilmInk.text, 0.5)),
                     x: active.maxX + 16, baseline: active.midY + 4.2)
        // Code, with the current line highlighted.
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), lineHeight: CGFloat = 19
        let codeTop = tabs.maxY + 10
        for (index, line) in code.enumerated() {
            let baseline = codeTop + CGFloat(index) * lineHeight + 14
            guard baseline < frame.maxY - 6 else { break }
            if index == 10 {
                context.setFillColor(CGColor(gray: 1, alpha: 0.045))
                context.fill(CGRect(x: tabs.minX, y: baseline - 14, width: tabs.width, height: lineHeight))
            }
            let number = FilmArt.attributed(String(index + 1), font, FilmInk.color(FilmInk.dim, index == 10 ? 0.9 : 0.5))
            let numberWidth = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(number), nil, nil, nil))
            FilmArt.line(context, number, x: tabs.minX + 34 - numberWidth, baseline: baseline)
            FilmArt.line(context, highlighted(line, font: font), x: tabs.minX + 50, baseline: baseline)
        }
    }
    /// Markup colors: tags, attribute names, strings and text.
    static func highlighted(_ line: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func add(_ text: String, _ hex: Int) { result.append(FilmArt.attributed(text, font, FilmInk.color(hex))) }
        // `named` marks that the tag's name has been read, so later words in the tag are attributes.
        var inTag = false, inString = false, named = false, token = ""
        func flush(_ hex: Int) { if !token.isEmpty { add(token, hex); token = "" } }
        for character in line {
            if inString {
                token.append(character)
                if character == "\"" { flush(FilmInk.green); inString = false }
            } else if character == "<" {
                flush(FilmInk.text); add("<", FilmInk.dim); inTag = true; named = false
            } else if inTag, character == ">" {
                flush(named ? FilmInk.blue : FilmInk.pink); add(">", FilmInk.dim); inTag = false
            } else if inTag, character == "\"" {
                flush(FilmInk.blue); token = "\""; inString = true
            } else if inTag, character == " " {
                flush(named ? FilmInk.blue : FilmInk.pink); named = true; add(" ", FilmInk.text)
            } else if inTag, character == "=" {
                flush(FilmInk.blue); add("=", FilmInk.dim)
            } else if inTag, character == "/", token.isEmpty, !named {
                add("/", FilmInk.dim)
            } else {
                token.append(character)
            }
        }
        flush(inTag ? (named ? FilmInk.blue : FilmInk.pink) : FilmInk.text)
        return result
    }
}

/// A terminal running a coding agent: the first turn works and finishes, then a follow-up is typed and starts.
@MainActor enum FilmTerminal {
    struct Segment { let text: String; let hex: Int; var bold = false }
    typealias Line = [Segment]
    static let frame = CGRect(x: -150, y: 290, width: 880, height: 610)
    static let lineHeight: CGFloat = 18
    /// The first turn was sent before the film starts, so it is already well under way.
    static let firstTurnStart = -128.0
    static let followUp = "Check the page on a narrow window"
    /// Where a click focuses the composer.
    static var composer: CGPoint { CGPoint(x: frame.minX + 150, y: frame.maxY - 49) }

    static func elapsed(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value < 60 ? "\(value)s" : "\(value / 60)m \(String(format: "%02d", value % 60))s"
    }
    static func working(_ t: Double, since start: Double) -> Line {
        let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        let spinner = frames[(Int((t * 12).rounded(.down)) % frames.count + frames.count) % frames.count]
        return [Segment(text: String(spinner) + " ", hex: FilmInk.lavender), Segment(text: "Working", hex: FilmInk.text, bold: true),
                Segment(text: " (" + elapsed(t - start) + " • esc to interrupt)", hex: FilmInk.dim)]
    }
    static func edited(_ file: String, _ added: Int, _ removed: Int) -> Line {
        [Segment(text: "• ", hex: FilmInk.blue), Segment(text: "Edited ", hex: FilmInk.text, bold: true),
         Segment(text: file + " ", hex: FilmInk.text), Segment(text: "(", hex: FilmInk.dim), Segment(text: "+\(added)", hex: FilmInk.green),
         Segment(text: " ", hex: FilmInk.dim), Segment(text: "−\(removed)", hex: FilmInk.red), Segment(text: ")", hex: FilmInk.dim)]
    }
    static func step(_ verb: String, _ object: String = "") -> Line {
        [Segment(text: "• ", hex: FilmInk.blue), Segment(text: verb, hex: FilmInk.text, bold: true), Segment(text: object, hex: FilmInk.text)]
    }
    static func detail(_ text: String) -> Line { [Segment(text: "  └ " + text, hex: FilmInk.dim)] }
    static func prompt(_ text: String) -> Line {
        [Segment(text: "› ", hex: FilmInk.lavender), Segment(text: text, hex: FilmInk.text, bold: true)]
    }

    /// The transcript at film time `t`.
    static func transcript(at t: Double) -> [Line] {
        let finish = FilmStoryboard.finishedCue, submit = FilmStoryboard.submit
        var lines: [Line] = [prompt("Refine the product page"), []]
        let first: [(Double, Line)] = [(-90, step("Explored")), (-90, detail("Read index.html, style.css, copy.md")),
                                       (-40, edited("index.html", 24, 9)), (0.9, edited("style.css", 11, 4)),
                                       (2.4, step("Ran ", "./build.sh")), (3.2, detail("Built 1 page and 3 assets, no warnings"))]
        lines += first.filter { t >= $0.0 }.map(\.1)
        lines.append([])
        guard t >= finish else { return lines + [working(t, since: firstTurnStart)] }
        lines.append([Segment(text: "• ", hex: FilmInk.text),
                      Segment(text: "Refined the product page: a clearer hero line and a shorter feature list.", hex: FilmInk.text)])
        lines.append([])
        lines.append([Segment(text: "─ Worked for " + elapsed(finish - firstTurnStart) + " ─", hex: FilmInk.dim)])
        guard t >= submit else { return lines }
        lines += [[], prompt(followUp), []]
        let second: [(Double, Line)] = [(submit + 0.9, step("Explored")), (submit + 0.9, detail("Read style.css, index.html")),
                                        (submit + 1.9, edited("style.css", 6, 2))]
        lines += second.filter { t >= $0.0 }.map(\.1)
        if t >= submit + 0.9 { lines.append([]) }
        return lines + [working(t, since: submit)]
    }

    static func draw(_ canvas: FilmCanvas, at t: Double) {
        let context = canvas.context, frame = Self.frame
        FilmWindowChrome.draw(canvas, frame: frame, title: "lunlet-site — agent", active: true, fill: 0x15131d)
        let regular = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let left = frame.minX + 18
        // The agent's header card.
        let header = CGRect(x: left, y: frame.minY + FilmWindowChrome.titleBar + 14, width: 372, height: 52)
        context.addPath(CGPath(roundedRect: header, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.setStrokeColor(FilmInk.color(FilmInk.dim, 0.55)); context.setLineWidth(1); context.strokePath()
        var x = left + 14
        x += FilmArt.line(context, FilmArt.attributed(">_ ", bold, FilmInk.color(FilmInk.lavender)), x: x, baseline: header.minY + 21)
        FilmArt.line(context, FilmArt.attributed("coding agent", bold, FilmInk.color(FilmInk.text)), x: x, baseline: header.minY + 21)
        FilmArt.line(context, FilmArt.attributed("   workspace  lunlet-site", regular, FilmInk.color(FilmInk.dim)),
                     x: left + 14, baseline: header.minY + 40)

        let composerTop = frame.maxY - 74
        let lines = transcript(at: t)
        let firstBaseline = header.maxY + 30
        let capacity = Int(((composerTop - 12) - firstBaseline) / lineHeight) + 1
        for (index, line) in lines.suffix(capacity).enumerated() {
            var x = left
            for segment in line {
                x += FilmArt.line(context, FilmArt.attributed(segment.text, segment.bold ? bold : regular, FilmInk.color(segment.hex)),
                                  x: x, baseline: firstBaseline + CGFloat(index) * lineHeight)
            }
        }

        // The composer: what is being typed, or a placeholder with a blinking cursor.
        let box = CGRect(x: left - 4, y: composerTop, width: frame.width - 28, height: 40)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.setFillColor(CGColor(gray: 1, alpha: 0.04)); context.fillPath()
        let baseline = box.midY + 4.5
        x = left + 8
        x += FilmArt.line(context, FilmArt.attributed("› ", bold, FilmInk.color(FilmInk.lavender)), x: x, baseline: baseline)
        let typing = FilmStoryboard.typing
        let typed: String
        if t >= typing.start, t < FilmStoryboard.submit {
            let count = Int((Double(followUp.count) * min(1, (t - typing.start) / (typing.end - typing.start))).rounded(.down))
            typed = String(followUp.prefix(count))
        } else { typed = "" }
        let cursorOn = (t >= typing.start && t < FilmStoryboard.submit + 0.3) || t.truncatingRemainder(dividingBy: 1.06) < 0.6
        if typed.isEmpty {
            if cursorOn { context.setFillColor(FilmInk.color(FilmInk.text, 0.85)); context.fill(CGRect(x: x, y: baseline - 12, width: 7.6, height: 16)) }
            FilmArt.line(context, FilmArt.attributed("Ask for a change", regular, FilmInk.color(FilmInk.dim, 0.75)), x: x + 10, baseline: baseline)
        } else {
            x += FilmArt.line(context, FilmArt.attributed(typed, regular, FilmInk.color(FilmInk.text)), x: x, baseline: baseline)
            context.setFillColor(FilmInk.color(FilmInk.text, 0.85)); context.fill(CGRect(x: x + 1, y: baseline - 12, width: 7.6, height: 16))
        }
        FilmArt.line(context, FilmArt.attributed("⏎ send   ⌃J newline   ⌃C quit", .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                                                 FilmInk.color(FilmInk.dim, 0.7)), x: left + 4, baseline: frame.maxY - 13)
    }
}

/// The completion card exactly as Lunlet's SessionCard renders it, read back from its JSON for display: the header
/// with the reply's state tag, the text of its blocks in order, the reply box and the reply's progress line.
struct FilmNoticeCard {
    struct Input {
        let text: String?
        let placeholder: String
        let enabled: Bool
    }
    let title: String
    let subtitle: String
    let template: String
    /// The header tag naming the reply's state; none before a reply.
    let tag: String?
    /// The body's text, in order, up to the reply box.
    let paragraphs: [String]
    /// The reply box; nil on a notification-only card.
    let input: Input?
    let button: (text: String, enabled: Bool)?
    /// The reply's progress line under the box, once there is one.
    let status: [String]
    /// Whether the card carries anything other than text, such as a form or a button.
    var interactive: Bool { input != nil || button != nil }

    init(_ rendered: RenderedSessionCard) throws {
        let object = try JSONSerialization.jsonObject(with: Data(rendered.delivery.content.utf8)) as? [String: Any] ?? [:]
        let header = object["header"] as? [String: Any] ?? [:]
        title = (header["title"] as? [String: Any])?["content"] as? String ?? ""
        subtitle = (header["subtitle"] as? [String: Any])?["content"] as? String ?? ""
        template = header["template"] as? String ?? ""
        tag = ((header["text_tag_list"] as? [[String: Any]])?.first?["text"] as? [String: Any])?["content"] as? String
        // Text lives inside the card's blocks, so every nested component is read in order.
        func flatten(_ items: [[String: Any]]) -> [[String: Any]] {
            items.flatMap { [$0] + flatten(($0["elements"] as? [[String: Any]] ?? []) + ($0["columns"] as? [[String: Any]] ?? [])) }
        }
        var paragraphs: [String] = [], status: [String] = []
        var input: Input?, button: (text: String, enabled: Bool)?
        for element in flatten((object["body"] as? [String: Any])?["elements"] as? [[String: Any]] ?? []) {
            switch element["tag"] as? String {
            case "markdown":
                guard let text = (element["content"] as? String).map(Self.unescape) else { continue }
                if input == nil { paragraphs.append(text) } else { status.append(text) }
            case "input":
                input = Input(text: element["default_value"] as? String,
                              placeholder: (element["placeholder"] as? [String: Any])?["content"] as? String ?? "",
                              enabled: element["disabled"] as? Bool != true)
            case "button":
                button = ((element["text"] as? [String: Any])?["content"] as? String ?? "", element["disabled"] as? Bool != true)
            default: continue
            }
        }
        self.paragraphs = paragraphs; self.status = status; self.input = input; self.button = button
    }
    /// Approximately what the messenger shows for SessionCard's markdown: labels lose their asterisks, the
    /// footer's font tag is dropped and numeric entities are decoded.
    static func unescape(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"</?font[^>]*>"#, with: "", options: .regularExpression)
        while let range = text.range(of: #"&#[0-9]{2,3};"#, options: .regularExpression) {
            let code = UInt32(text[range].dropFirst(2).dropLast()) ?? 63
            text.replaceSubrange(range, with: String(UnicodeScalar(code).map(Character.init) ?? "?"))
        }
        return text
    }
}

// MARK: - Lock screen and phone, laid out with SwiftUI and rendered once offscreen.

/// A generic lock screen: the blurred wallpaper, the date and a large time, and a neutral account.
struct FilmMacLockScreen: View {
    let wallpaper: CGImage
    let date: String
    let time: String
    var body: some View {
        ZStack {
            Image(decorative: wallpaper, scale: 1).resizable().frame(width: FilmDesktop.region.width, height: FilmDesktop.region.height)
            LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.06), .black.opacity(0.34)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Text(date).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.86)).padding(.top, 78)
                Text(time).font(.system(size: 128, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                    .padding(.top, -8)
                Spacer()
                ZStack {
                    Circle().fill(LinearGradient(colors: [FilmInk.swiftUI(0x9d8ad6), FilmInk.swiftUI(0x6c5aa8)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("A").font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
                .frame(width: 66, height: 66).overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
                Text("Alex").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).padding(.top, 12)
                Capsule().fill(.white.opacity(0.16)).frame(width: 178, height: 30)
                    .overlay(Text("Enter Password").font(.system(size: 13)).foregroundStyle(.white.opacity(0.58)))
                    .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                    .padding(.top, 12).padding(.bottom, 150)
            }
        }
    }
}

/// Generic status-bar glyphs drawn as shapes.
struct FilmSignalGlyph: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.6) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1).frame(width: 3.2, height: 4.5 + CGFloat(index) * 2.4)
            }
        }
    }
}
struct FilmWifiShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY - 1.5)
        for radius in [rect.height * 0.5, rect.height * 0.95] {
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(-137), endAngle: .degrees(-43), clockwise: false)
            path.addPath(arc.strokedPath(.init(lineWidth: 2, lineCap: .round)))
        }
        path.addEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
        return path
    }
}
struct FilmBatteryGlyph: View {
    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.6).stroke(.white.opacity(0.5), lineWidth: 1).frame(width: 25, height: 12)
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 16, height: 8).padding(.leading, 2)
            }
            RoundedRectangle(cornerRadius: 0.8).fill(.white.opacity(0.5)).frame(width: 1.6, height: 4)
        }
    }
}
struct FilmPhoneStatusBar: View {
    let time: String?
    var body: some View {
        HStack(spacing: 6) {
            if let time { Text(time).font(.system(size: 16, weight: .semibold)) }
            Spacer()
            FilmSignalGlyph()
            FilmWifiShape().frame(width: 16, height: 11)
            FilmBatteryGlyph()
        }
        .foregroundStyle(.white).padding(.horizontal, 30).frame(height: 50)
    }
}
/// A neutral messenger glyph: a chat bubble on a tile in Lunlet's palette.
struct FilmMessengerGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [FilmInk.swiftUI(0x8ea6e8), FilmInk.swiftUI(0x7c68c4)], startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            Path { path in
                path.addRoundedRect(in: CGRect(x: 9, y: 11, width: 24, height: 16), cornerSize: CGSize(width: 7, height: 7))
                path.move(to: CGPoint(x: 14, y: 25)); path.addLine(to: CGPoint(x: 12, y: 31)); path.addLine(to: CGPoint(x: 20, y: 26))
            }
            .fill(.white)
        }
        .frame(width: 42, height: 42)
    }
}

struct FilmPhoneLockScreen: View {
    let wallpaper: CGImage
    let date: String
    let time: String
    var body: some View {
        ZStack(alignment: .top) {
            Image(decorative: wallpaper, scale: 1).resizable().frame(width: FilmPhone.screenSize.width, height: FilmPhone.screenSize.height)
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.05), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                FilmPhoneStatusBar(time: nil)
                ZStack(alignment: .bottom) {
                    Circle().trim(from: 0.5, to: 1).stroke(.white.opacity(0.9), lineWidth: 2).frame(width: 11, height: 11).offset(y: -9)
                    RoundedRectangle(cornerRadius: 2.5).fill(.white.opacity(0.9)).frame(width: 15, height: 11)
                }
                .frame(height: 20).padding(.top, 8)
                Text(date).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).padding(.top, 10)
                Text(time).font(.system(size: 92, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.95)).padding(.top, -6)
                Spacer()
                Capsule().fill(.white.opacity(0.85)).frame(width: 134, height: 5).padding(.bottom, 9)
            }
        }
    }
}

/// The messenger's notification for the bot's card.
struct FilmPhoneBanner: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            FilmMessengerGlyph()
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Text("now").font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                }
                Text(detail).font(.system(size: 15)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .frame(width: FilmPhone.banner.width, height: FilmPhone.banner.height)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(FilmInk.swiftUI(0x1d1830, 0.78)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

/// The bot chat: a neutral messenger in Lunlet's palette with the completion card and, once sent, the owner's reply.
struct FilmPhoneChat: View {
    let card: FilmNoticeCard
    let avatar: CGImage
    let time: String
    let stamp: String
    var outgoing: String? = nil
    var body: some View {
        ZStack(alignment: .top) {
            FilmInk.swiftUI(0x14121c)
            VStack(spacing: 0) {
                FilmPhoneStatusBar(time: time)
                HStack(spacing: 10) {
                    Path { path in
                        path.move(to: CGPoint(x: 10, y: 2)); path.addLine(to: CGPoint(x: 2, y: 10)); path.addLine(to: CGPoint(x: 10, y: 18))
                    }
                    .stroke(FilmInk.swiftUI(FilmInk.lavender), style: .init(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 12, height: 20)
                    Image(decorative: avatar, scale: 1).resizable().frame(width: 36, height: 36).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("Lunlet").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            Text("Bot").font(.system(size: 11, weight: .semibold)).foregroundStyle(FilmInk.swiftUI(FilmInk.lavender))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(FilmInk.swiftUI(FilmInk.lavender, 0.18)))
                        }
                        Text("Your Feishu bot").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).frame(height: 58)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                Text(stamp).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.5)).padding(.top, 18)
                HStack(alignment: .top, spacing: 10) {
                    Image(decorative: avatar, scale: 1).resizable().frame(width: 38, height: 38).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Lunlet").font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                        FilmNoticeCardView(card: card)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12)
                if let outgoing {
                    // The owner's reply, sent from the card's box, as the messenger echoes it.
                    HStack {
                        Spacer(minLength: 70)
                        Text(outgoing).font(.system(size: 16.5)).foregroundStyle(FilmInk.swiftUI(0x1a1726))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FilmInk.swiftUI(FilmInk.lavender)))
                    }
                    .padding(.horizontal, 14).padding(.top, 10)
                }
                Spacer()
                Capsule().fill(.white.opacity(0.75)).frame(width: 134, height: 5).padding(.bottom, 9)
            }
        }
    }
}

/// The card's header carries SessionCard's template color and the reply's state tag; its body holds each text
/// element in order, then the reply box and the reply's progress line, as the messenger lays them out.
struct FilmNoticeCardView: View {
    let card: FilmNoticeCard
    var body: some View {
        let header: [Color] = switch card.template {
        case "orange": [FilmInk.swiftUI(0xb86a2c), FilmInk.swiftUI(0xd48a45)]
        case "blue": [FilmInk.swiftUI(0x3552b4), FilmInk.swiftUI(0x5470d2)]
        case "green": [FilmInk.swiftUI(0x2f7a4f), FilmInk.swiftUI(0x3f9a66)]
        default: [FilmInk.swiftUI(0x3a3648), FilmInk.swiftUI(0x4a4560)]
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                    Text(card.subtitle).font(.system(size: 14.5)).foregroundStyle(.white.opacity(0.84))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let tag = card.tag {
                    Text(tag).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.22)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 15).padding(.vertical, 13)
            .background(LinearGradient(colors: header, startPoint: .leading, endPoint: .trailing))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(card.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    // A block's short heading reads as a label above its text.
                    let label = paragraph.count <= 24 && !paragraph.contains(".") && index + 1 < card.paragraphs.count
                    Text(paragraph)
                        .font(.system(size: label ? 13 : 16.5, weight: label ? .semibold : .regular))
                        .foregroundStyle(label ? FilmInk.swiftUI(FilmInk.lavender) : FilmInk.swiftUI(0xebe8f6))
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, label && index > 0 ? 6 : 0)
                }
                if let input = card.input {
                    let fieldColor: Color = input.text == nil ? .white.opacity(0.4) : (input.enabled ? .white : .white.opacity(0.6))
                    HStack(spacing: 8) {
                        Text(input.text ?? input.placeholder).font(.system(size: 15))
                            .foregroundStyle(fieldColor)
                            .lineLimit(2).padding(.horizontal, 12).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(input.enabled ? 0.08 : 0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
                        if let button = card.button {
                            Text(button.text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(FilmInk.swiftUI(0x5470d2, button.enabled ? 1 : 0.45)))
                        }
                    }
                    .padding(.top, 4)
                }
                ForEach(Array(card.status.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 15, weight: .medium)).foregroundStyle(FilmInk.swiftUI(FilmInk.green))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FilmInk.swiftUI(FilmInk.green, 0.12)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(15)
            .background(FilmInk.swiftUI(0x221f2e))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

/// A generic modern phone: a rounded body with a metal rim, side keys and a punch-hole camera. No brand.
@MainActor enum FilmPhone {
    static let screenSize = CGSize(width: 390, height: 844)
    static let bezel: CGFloat = 12
    static var bodySize: CGSize { CGSize(width: screenSize.width + 2 * bezel, height: screenSize.height + 2 * bezel) }
    /// The notification's place on the lock screen, in screen points.
    static let banner = CGRect(x: 12, y: 316, width: 366, height: 92)

    /// Draws the phone with its top-left at `origin` pixels and `scale` pixels per point; `screen` paints the display in
    /// screen points, already clipped to it.
    static func draw(_ canvas: FilmCanvas, origin: CGPoint, scale: CGFloat, alpha: CGFloat, screen: (CGContext) -> Void) {
        guard alpha > 0.001 else { return }
        let context = canvas.context
        context.saveGState()
        context.setAlpha(alpha); context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.translateBy(x: origin.x, y: origin.y); context.scaleBy(x: scale, y: scale)
        let body = CGRect(origin: .zero, size: bodySize)
        let shape = CGPath(roundedRect: body, cornerWidth: 62, cornerHeight: 62, transform: nil)
        // Side keys sit behind the rim.
        context.setFillColor(FilmInk.color(0x2c2a33))
        for key in [CGRect(x: body.maxX - 2, y: 220, width: 5, height: 96), CGRect(x: -3, y: 182, width: 5, height: 58),
                    CGRect(x: -3, y: 254, width: 5, height: 58)] {
            context.addPath(CGPath(roundedRect: key, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil)); context.fillPath()
        }
        canvas.shadow(shape, opacity: 0.65, radius: 38, offset: 18)
        context.saveGState(); context.addPath(shape); context.clip()
        let metal = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [FilmInk.color(0x4b4853), FilmInk.color(0x1d1b22), FilmInk.color(0x3a3741)] as CFArray,
                               locations: [0, 0.5, 1])!
        context.drawLinearGradient(metal, start: .zero, end: CGPoint(x: body.maxX, y: body.maxY), options: [])
        context.restoreGState()
        let glass = CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 59, cornerHeight: 59, transform: nil)
        context.addPath(glass); context.setFillColor(FilmInk.color(0x050506)); context.fillPath()
        context.addPath(shape); context.setStrokeColor(FilmInk.color(0x77737f, 0.9)); context.setLineWidth(1.4); context.strokePath()

        let display = CGRect(x: bezel, y: bezel, width: screenSize.width, height: screenSize.height)
        context.saveGState()
        context.addPath(CGPath(roundedRect: display, cornerWidth: 50, cornerHeight: 50, transform: nil)); context.clip()
        context.translateBy(x: bezel, y: bezel)
        context.setFillColor(FilmInk.color(0x000000)); context.fill(CGRect(origin: .zero, size: screenSize))
        screen(context)
        context.restoreGState()
        // The punch-hole camera.
        let lens = CGRect(x: body.midX - 6.5, y: bezel + 17, width: 13, height: 13)
        context.setFillColor(FilmInk.color(0x020203)); context.fillEllipse(in: lens)
        context.setStrokeColor(FilmInk.color(0x2a2a33)); context.setLineWidth(1); context.strokeEllipse(in: lens.insetBy(dx: 3, dy: 3))
        context.endTransparencyLayer(); context.restoreGState()
    }
}
