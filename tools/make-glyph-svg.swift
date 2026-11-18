// Turns a single CJK glyph from a system font into an SVG path, so the app icon can be a
// vector layer rather than a bitmap.
//
// Icon Composer icons are layered documents: the glyph is one layer and the tile is a fill
// behind it. A bitmap glyph at 1024 looks soft at large sizes; an outline scales cleanly and
// is what the glass material needs in order to refract an edge.
//
//     swiftc -O tools/make-glyph-svg.swift -o /tmp/make-glyph-svg
//     /tmp/make-glyph-svg HiraginoSans-W4 0.70 Support/AppIcon.icon/Assets/軽.svg
//
import AppKit
import CoreText
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("usage: make-glyph-svg <postscript-font-name> <ink-fraction> <output.svg>")
    exit(1)
}
let fontName = arguments[1]
let fraction = CGFloat(Double(arguments[2]) ?? 0.70)
let outputPath = arguments[3]

let canvas: CGFloat = 1024
let character: [UniChar] = [0x8EFD]      // 軽

let font = CTFontCreateWithName(fontName as CFString, 1000, nil)
var chars = character
var glyphs = [CGGlyph](repeating: 0, count: 1)
guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1), glyphs[0] != 0 else {
    fatalError("\(fontName) has no glyph for U+8EFD")
}
guard let outline = CTFontCreatePathForGlyph(font, glyphs[0], nil) else {
    fatalError("no outline")
}

// Scale so the ink fills `fraction` of the canvas, then centre it.
let ink = outline.boundingBoxOfPath
let scale = (canvas * fraction) / ink.height
let offsetX = (canvas - ink.width * scale) / 2 - ink.minX * scale
let offsetY = (canvas - ink.height * scale) / 2 + ink.maxY * scale

var commands: [String] = []
func number(_ value: CGFloat) -> String {
    String(format: "%.2f", value)
}
// Core Text is y-up and SVG is y-down, so y is flipped here rather than by a transform:
// the path stays readable and needs no group wrapper.
func point(_ p: CGPoint) -> String {
    "\(number(p.x * scale + offsetX)),\(number(offsetY - p.y * scale))"
}

outline.applyWithBlock { element in
    let points = element.pointee.points
    switch element.pointee.type {
    case .moveToPoint:
        commands.append("M\(point(points[0]))")
    case .addLineToPoint:
        commands.append("L\(point(points[0]))")
    case .addQuadCurveToPoint:
        commands.append("Q\(point(points[0])) \(point(points[1]))")
    case .addCurveToPoint:
        commands.append("C\(point(points[0])) \(point(points[1])) \(point(points[2]))")
    case .closeSubpath:
        commands.append("Z")
    @unknown default:
        break
    }
}

let svg = """
<?xml version="1.0" encoding="UTF-8"?>
<svg width="\(Int(canvas))px" height="\(Int(canvas))px" viewBox="0 0 \(Int(canvas)) \(Int(canvas))" version="1.1" xmlns="http://www.w3.org/2000/svg">
    <title>軽</title>
    <g stroke="none" stroke-width="1" fill-rule="evenodd">
        <path d="\(commands.joined(separator: " "))"/>
    </g>
</svg>

"""
try! svg.write(toFile: outputPath, atomically: true, encoding: .utf8)
print("wrote \(outputPath)  (\(commands.count) path commands)")
