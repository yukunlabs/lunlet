// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-36, AC-36.01, AC-36.03; US-06, AC-06.01, AC-06.02; US-28, AC-28.02.
// The Slack and Telegram chats on the product page's phone: each notice is read back from the message Lunlet
// actually composes (SlackNoticeMessage, TelegramNoticeMessage), then drawn as a generic messenger would show
// it, with the reply made the way that channel takes it: in the notice's thread, or by answering the prompt its
// button opens. No messenger's artwork is reproduced.
import CoreGraphics
import Foundation
import SwiftUI
import LunletCore
import LunletMessaging

/// Lunlet's Slack notice, as blocks in order, with their mrkdwn turned into attributed text.
struct FilmSlackNotice {
    enum Block: Equatable { case header(String), context(String), section(String) }
    let blocks: [Block]
    /// The fallback text a phone notification shows.
    let summary: String

    init(_ body: [String: Any]) throws {
        guard let blocks = body["blocks"] as? [[String: Any]], let summary = body["text"] as? String else {
            throw FilmChannelError.unexpectedMessage
        }
        self.summary = summary
        self.blocks = try blocks.map { block in
            switch block["type"] as? String {
            case "header":
                guard let text = (block["text"] as? [String: Any])?["text"] as? String else { throw FilmChannelError.unexpectedMessage }
                return .header(text)
            case "context":
                guard let text = ((block["elements"] as? [[String: Any]])?.first)?["text"] as? String else { throw FilmChannelError.unexpectedMessage }
                return .context(text)
            case "section":
                guard let text = (block["text"] as? [String: Any])?["text"] as? String else { throw FilmChannelError.unexpectedMessage }
                return .section(text)
            default: throw FilmChannelError.unexpectedMessage
            }
        }
    }
    var headerText: String? { blocks.compactMap { if case .header(let text) = $0 { text } else { nil } }.first }
    var contextLines: [String] { blocks.compactMap { if case .context(let text) = $0 { FilmChannelText.plain(mrkdwn: text) } else { nil } } }

    /// Lines of one block: a line quoted with `&gt;` is drawn as a quote.
    static func lines(_ text: String) -> [(quote: Bool, text: AttributedString)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let quote = line.hasPrefix("&gt; ")
            let content = quote ? String(line.dropFirst(5)) : String(line)
            return (quote, FilmChannelText.attributed(markdown: FilmChannelText.markdown(mrkdwn: content)))
        }
    }
}

/// Lunlet's Telegram notice: its HTML paragraphs as attributed text, and the inline button an open notice carries.
struct FilmTelegramNotice {
    struct Paragraph: Equatable { let quote: Bool; let text: AttributedString }
    let paragraphs: [Paragraph]
    let button: String?

    init(html: String, markup: [String: Any]?) throws {
        paragraphs = html.components(separatedBy: "\n\n").map { part in
            var text = part
            let quote = text.hasPrefix("<blockquote")
            if quote {
                text = text.replacingOccurrences(of: #"^<blockquote[^>]*>"#, with: "", options: .regularExpression)
                text = text.replacingOccurrences(of: #"</blockquote>$"#, with: "", options: .regularExpression)
            }
            return Paragraph(quote: quote, text: FilmChannelText.attributed(markdown: FilmChannelText.markdown(html: text)))
        }
        if let markup {
            guard let rows = markup["inline_keyboard"] as? [[[String: Any]]], let text = rows.first?.first?["text"] as? String else {
                throw FilmChannelError.unexpectedMessage
            }
            button = text
        } else { button = nil }
    }
    var plainText: String { paragraphs.map { String($0.text.characters) }.joined(separator: "\n") }
}

enum FilmChannelError: Error { case unexpectedMessage }

/// The small translations from each channel's markup to attributed text. Only the constructs Lunlet's composers
/// emit are handled; anything else stays literal.
enum FilmChannelText {
    static func attributed(markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
    static func plain(mrkdwn: String) -> String { String(attributed(markdown: markdown(mrkdwn: mrkdwn)).characters) }

    static func markdown(mrkdwn text: String) -> String {
        var result = text
        for (pattern, template) in [(#"<(https?://[^|>]+)\|([^>]+)>"#, "[$2]($1)"), (#"<(https?://[^>]+)>"#, "$1"),
                                    (#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, "**$1**"),
                                    (#"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#, "*$1*")] {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return unescaped(result)
    }
    static func markdown(html text: String) -> String {
        var result = text.replacingOccurrences(of: #"<a href="([^"]+)">(.*?)</a>"#, with: "[$2]($1)", options: .regularExpression)
        result = result.replacingOccurrences(of: #"<pre><code[^>]*>"#, with: "`", options: .regularExpression)
        for (tag, mark) in [("</code></pre>", "`"), ("<b>", "**"), ("</b>", "**"), ("<i>", "*"), ("</i>", "*"), ("<code>", "`"), ("</code>", "`")] {
            result = result.replacingOccurrences(of: tag, with: mark)
        }
        return unescaped(result)
    }
    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// A quoted line or paragraph: a bar in the channel's accent beside the text.
private struct FilmQuote: View {
    let text: AttributedString
    let accent: Color
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3)
            Text(text).font(.system(size: 15.5)).foregroundStyle(.white.opacity(0.82)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Slack chat with the app: the notice as its blocks; replied, the notice's thread with the owner's reply.
struct FilmSlackChat: View {
    let notice: FilmSlackNotice
    let avatar: CGImage
    let time: String
    let stamp: String
    var reply: String? = nil
    private let accent = FilmInk.swiftUI(0x8ea6e8)

    var body: some View {
        FilmChatScreen(subtitle: "Your Slack app", avatar: avatar, time: time, stamp: stamp) {
            message
            if let reply {
                HStack(spacing: 10) {
                    Text("1 reply").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                }
                .padding(.horizontal, 14).padding(.top, 14)
                HStack(alignment: .top, spacing: 10) {
                    Text("Y").font(.system(size: 17, weight: .semibold)).foregroundStyle(FilmInk.swiftUI(0x1a1726))
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FilmInk.swiftUI(FilmInk.lavender)))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("You").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                            Text(time + " PM").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        }
                        Text(reply).font(.system(size: 15.5)).foregroundStyle(FilmInk.swiftUI(0xebe8f6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12)
            }
        }
    }

    private var message: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(decorative: avatar, scale: 1).resizable().frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Lunlet").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    Text("APP").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.16)))
                    Text(stamp.hasPrefix("Today") ? String(stamp.dropFirst(6)) : stamp).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                ForEach(Array(notice.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .header(let text):
                        Text(text).font(.system(size: 17.5, weight: .bold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    case .context(let text):
                        ForEach(Array(FilmSlackNotice.lines(text).enumerated()), id: \.offset) { _, line in
                            Text(line.text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    case .section(let text):
                        ForEach(Array(FilmSlackNotice.lines(text).enumerated()), id: \.offset) { _, line in
                            if line.quote { FilmQuote(text: line.text, accent: .white.opacity(0.35)) }
                            else {
                                Text(line.text).font(.system(size: 15.5)).foregroundStyle(FilmInk.swiftUI(0xebe8f6)).lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 12)
    }
}

/// The Telegram chat with the bot: the notice as one message with its reply button; replied, the edited notice,
/// the prompt the button opened, and the owner's answer to it.
struct FilmTelegramChat: View {
    let notice: FilmTelegramNotice
    let avatar: CGImage
    let time: String
    let stamp: String
    /// The prompt the button sent and the owner's reply to it.
    var prompt: String? = nil
    var reply: String? = nil
    private let accent = FilmInk.swiftUI(0x9ec4f0)

    var body: some View {
        FilmChatScreen(subtitle: "Your Telegram bot", avatar: avatar, time: time, stamp: stamp) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 8) {
                    Image(decorative: avatar, scale: 1).resizable().frame(width: 32, height: 32).clipShape(Circle())
                    // The notice keeps its sending time; a rewrite marks it edited, as Telegram does.
                    bubble(time: "4:52", edited: reply != nil) {
                        ForEach(Array(notice.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            if paragraph.quote { FilmQuote(text: paragraph.text, accent: accent) }
                            else {
                                Text(paragraph.text).font(.system(size: 15.5)).foregroundStyle(FilmInk.swiftUI(0xebe8f6)).lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Spacer(minLength: 40)
                }
                if let button = notice.button {
                    Text(button).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.14)))
                        .padding(.leading, 40).padding(.trailing, 40)
                }
            }
            .padding(.horizontal, 12).padding(.top, 12)
            if let prompt {
                HStack(alignment: .bottom, spacing: 8) {
                    Image(decorative: avatar, scale: 1).resizable().frame(width: 32, height: 32).clipShape(Circle())
                    bubble(time: time, edited: false) {
                        Text(prompt).font(.system(size: 15.5)).foregroundStyle(FilmInk.swiftUI(0xebe8f6)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            if let reply, let prompt {
                HStack {
                    Spacer(minLength: 70)
                    VStack(alignment: .leading, spacing: 6) {
                        // The answer quotes the prompt it replies to.
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(FilmInk.swiftUI(0x1a1726, 0.7)).frame(width: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Lunlet").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(FilmInk.swiftUI(0x1a1726, 0.85))
                                Text(prompt).font(.system(size: 12.5)).foregroundStyle(FilmInk.swiftUI(0x1a1726, 0.7)).lineLimit(1)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Text(reply).font(.system(size: 16.5)).foregroundStyle(FilmInk.swiftUI(0x1a1726)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FilmInk.swiftUI(FilmInk.lavender)))
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
        }
    }

    private func bubble(time: String, edited: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            content()
            Text((edited ? "edited " : "") + time + " PM").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FilmInk.swiftUI(0x252233)))
    }
}
