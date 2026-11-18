import CoreText
import SwiftUI
import UIKit
import Wenku8Core

/// Splits one chapter into pages that fit the reading area.
///
/// Left/right reading means turning *pages*, not chapters, so the prose has to be
/// measured against the visible height. CoreText's framesetter is used instead of
/// SwiftUI layout because it can report exactly which character range fits in a
/// given box, which is what makes page boundaries stable across sizes.
enum ChapterPaginator {
    /// Gap between paragraphs. Used by CoreText when measuring *and* by the SwiftUI
    /// `VStack` that renders the page, so the two can never drift apart (a mismatch
    /// made CoreText fit one line more than SwiftUI could draw, clipping the last
    /// line of every page).
    static let paragraphSpacing: CGFloat = 18

    /// One page of content.
    struct Page: Identifiable {
        let id: Int
        let blocks: [ChapterContent.Block]
    }

    static func paginate(
        blocks: [ChapterContent.Block],
        size: CGSize,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        indent: CGFloat,
        textColor: UIColor,
        /// Chapter title, laid out on the first page with `titleFont` and the same
        /// first-line indent as the prose.
        title: String = "",
        titleFont: UIFont? = nil
    ) -> [Page] {
        guard size.width > 20, size.height > 20 else {
            return [Page(id: 0, blocks: blocks)]
        }

        // The title is measured as part of the same attributed string the pages are
        // cut from, so a tall bold title can no longer overflow page one.
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var pages: [[ChapterContent.Block]] = []
        var pendingText: [String] = []
        var paraStarts: [Int] = []
        var buffer = NSMutableAttributedString()
        if !trimmedTitle.isEmpty {
            let display = indent > 0 ? "\u{3000}\u{3000}" + trimmedTitle : trimmedTitle
            pendingText.append(display)
            paraStarts.append(0)
            buffer.append(NSAttributedString(
                string: display,
                attributes: attributes(
                    fontSize: fontSize,
                    lineSpacing: lineSpacing,
                    indent: 0,
                    textColor: textColor,
                    fontOverride: titleFont
                )
            ))
            buffer.append(NSAttributedString(
                string: "\n",
                attributes: attributes(
                    fontSize: fontSize,
                    lineSpacing: lineSpacing,
                    indent: 0,
                    textColor: textColor
                )
            ))
        }

        func flushText() {
            guard !buffer.string.isEmpty else {
                pendingText = []
                paraStarts = []
                return
            }
            pages.append(contentsOf: splitAttributed(
                buffer,
                paraStarts: paraStarts,
                size: size,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                indent: indent,
                textColor: textColor
            ))
            pendingText = []
            paraStarts = []
            buffer = NSMutableAttributedString()
        }

        for block in blocks {
            switch block {
            case .paragraph(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                // The indent is part of the string, matching how the vertical
                // reader renders it. Using `firstLineHeadIndent` here measured the
                // text with an indent the SwiftUI renderer never applied, so pages
                // were paginated for text that did not match what was drawn — the
                // indent simply looked missing in paged mode.
                let display = indent > 0 ? "\u{3000}\u{3000}" + trimmed : trimmed
                pendingText.append(display)
                paraStarts.append(buffer.length)
                buffer.append(attributedParagraph(
                    display,
                    fontSize: fontSize,
                    lineSpacing: lineSpacing,
                    indent: 0,
                    textColor: textColor
                ))
                buffer.append(NSAttributedString(
                    string: "\n",
                    attributes: attributes(
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        indent: 0,
                        textColor: textColor
                    )
                ))
            case .image(let url):
                // An illustration gets its own page; it is never split and never
                // shares a page with prose.
                flushText()
                pages.append([.image(url)])
            }
        }
        flushText()

        if pages.isEmpty { pages = [blocks] }
        return pages.enumerated().map { Page(id: $0.offset, blocks: $0.element) }
    }

    // MARK: - CoreText

    private static func splitAttributed(
        _ attributed: NSAttributedString,
        paraStarts: [Int],
        size: CGSize,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        indent: CGFloat,
        textColor: UIColor
    ) -> [[ChapterContent.Block]] {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(
            rect: CGRect(origin: .zero, size: size),
            transform: nil
        )

        var pages: [[ChapterContent.Block]] = []
        var location = 0
        let total = attributed.length

        while location < total {
            let range = CFRange(location: location, length: 0)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            var length = visible.length
            if length <= 0 { break }

            // Trim the trailing newline so the page's last paragraph is not
            // followed by an empty line.
            var text = (attributed.string as NSString).substring(
                with: NSRange(location: location, length: length)
            )
            while text.hasSuffix("\n") || text.hasSuffix(" ") {
                text.removeLast()
                length -= 1
            }
            if !text.isEmpty {
                pages.append(text
                    .components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { .paragraph($0) }
                )
            }
            location += length
            if location >= total { break }
            // Skip the newline the previous page ended on.
            while location < total,
                  (attributed.string as NSString).substring(with: NSRange(location: location, length: 1)) == "\n" {
                location += 1
            }
        }
        return pages
    }

    private static func attributes(
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        indent: CGFloat,
        textColor: UIColor,
        fontOverride: UIFont? = nil
    ) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = Self.paragraphSpacing
        style.lineBreakMode = .byWordWrapping
        return [
            .font: fontOverride ?? UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: textColor,
            .paragraphStyle: style,
        ]
    }

    private static func attributedParagraph(
        _ text: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        indent: CGFloat,
        textColor: UIColor
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: attributes(
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                indent: indent,
                textColor: textColor
            )
        )
    }
}
