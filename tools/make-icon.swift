// Renders the app icon set.
//
// The design is a solid tile with one large glyph: the Japanese 軽 in Hiragino Sans, which
// is the same character the Android app has always used, set plainly so it reads at 60pt.
//
// Three appearances are produced, which is every style iOS lets a reader choose for the
// home screen: light, dark, and tinted. There is no fourth "clear" asset to author — iOS 26
// derives its glass style from the default icon (verified: actool ignores a `clear`
// appearance entry without error).
//
//     swiftc -O tools/make-icon.swift -o /tmp/make-icon
//     /tmp/make-icon Support/Assets.xcassets/AppIcon.appiconset HiraginoSans-W7 0.70
//
import AppKit
import CoreText
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("usage: make-icon <output-directory> <postscript-font-name> <glyph-fraction>")
    exit(1)
}
let directory = arguments[1]
let fontName = arguments[2]
let glyphFraction = CGFloat(Double(arguments[3]) ?? 0.70)

let tile = 1024
let character: [UniChar] = [0x8EFD]                       // 軽
let accent = CGColor(red: 0.34, green: 0.47, blue: 0.94, alpha: 1)   // #5778F0, the app's accent
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let nearBlack = CGColor(red: 0.055, green: 0.055, blue: 0.075, alpha: 1)

func render(background: CGColor, glyphColor: CGColor, to path: String) {
    guard let context = CGContext(
        data: nil, width: tile, height: tile,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fatalError("could not create a bitmap context") }

    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: tile, height: tile))

    // Measure at a large size, then scale so the ink — not the em box — is what gets
    // centred. Different fonts sit differently inside their em, and this keeps the glyph
    // optically centred whatever the font is.
    let probe = CTFontCreateWithName(fontName as CFString, 1000, nil)
    var chars = character
    var glyphs = [CGGlyph](repeating: 0, count: 1)
    guard CTFontGetGlyphsForCharacters(probe, &chars, &glyphs, 1), glyphs[0] != 0 else {
        fatalError("\(fontName) has no glyph for U+8EFD")
    }
    var ink = CGRect.zero
    _ = CTFontGetBoundingRectsForGlyphs(probe, .default, &glyphs, &ink, 1)

    let fontSize = 1000 * (CGFloat(tile) * glyphFraction) / ink.height
    let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
    var scaledChars = character
    var scaledGlyphs = [CGGlyph](repeating: 0, count: 1)
    _ = CTFontGetGlyphsForCharacters(font, &scaledChars, &scaledGlyphs, 1)
    var scaledInk = CGRect.zero
    _ = CTFontGetBoundingRectsForGlyphs(font, .default, &scaledGlyphs, &scaledInk, 1)

    context.setFillColor(glyphColor)
    context.textMatrix = .identity
    context.setFont(CTFontCopyGraphicsFont(font, nil))
    var position = CGPoint(
        x: (CGFloat(tile) - scaledInk.width) / 2 - scaledInk.minX,
        y: (CGFloat(tile) - scaledInk.height) / 2 - scaledInk.minY
    )
    CTFontDrawGlyphs(font, &scaledGlyphs, &position, 1, context)

    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("could not encode the icon") }
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

// Light: the accent fills the tile, the glyph is white.
render(background: accent, glyphColor: white, to: "\(directory)/AppIcon.png")
// Dark: a near-black tile, the glyph back in the accent colour.
render(background: nearBlack, glyphColor: accent, to: "\(directory)/AppIcon-Dark.png")
// Tinted: greyscale, so the system can map it onto the reader's chosen tint.
render(background: nearBlack, glyphColor: white, to: "\(directory)/AppIcon-Tinted.png")
