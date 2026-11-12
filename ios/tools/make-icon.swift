// Renders the app icon: flat brand orange, ink halftone dots from the top-right corner, "kg" in Bricolage ExtraBold.
// Run from ios/: swift tools/make-icon.swift
import AppKit
import CoreText

let size = 1024, s = CGFloat(size)
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
	space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ hex: UInt32) -> CGColor {
	CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}
let orange = rgb(0xff5a1f), ink = rgb(0x1a0a04)

ctx.setFillColor(orange)
ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

// Halftone: dots shrink with the distance from the top-right corner (origin is bottom-left here).
ctx.setFillColor(ink)
let step: CGFloat = 52
for row in 0...Int(s / step) {
	for col in 0...Int(s / step) {
		let x = s - CGFloat(col) * step - (row.isMultiple(of: 2) ? 0 : step / 2), y = s - CGFloat(row) * step
		let d = 34 * pow(max(0, 1 - hypot(s - x, s - y) / (s * 0.95)), 1.6)
		// Smaller dots would speckle the letters.
		if d > 5 { ctx.fillEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)) }
	}
}

CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "Bilancia/Fonts/bricolage-grotesque.woff2") as CFURL, .process, nil)
let font = CTFontCreateWithName("BricolageGrotesque96ptExtraBold-Regular_ExtraBold" as CFString, 560, nil)
precondition((CTFontCopyPostScriptName(font) as String).hasPrefix("Bricolage"), "font not found: run from ios/")
let text = NSAttributedString(string: "kg", attributes: [
	.font: font, .foregroundColor: NSColor(cgColor: ink)!, .kern: -36,
])
ctx.textPosition = CGPoint(x: 96, y: 210)
CTLineDraw(CTLineCreateWithAttributedString(text), ctx)

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Bilancia/Assets.xcassets/AppIcon.appiconset/icon.png")
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: out)
print("wrote", out.path)
