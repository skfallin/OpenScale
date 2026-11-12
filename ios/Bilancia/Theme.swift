import CoreText
import SwiftUI

/// torinz.it design system: orange ground with ink text (light), ink ground with cream text (dark).
/// Never cream on orange; secondary text is smaller and uppercase, not paler.
enum Brand {
	static let ground = Color(UIColor(light: 0xff5a1f, dark: 0x1a0a04))
	static let ink = Color(UIColor(light: 0x1a0a04, dark: 0xfbf8f3))
	/// 1px rules and control borders.
	static let line = Color(UIColor(light: 0x1a0a04, dark: 0x8c7b73))
	/// Links and inverse slabs; ground-coloured content goes on it.
	static let accent = Color(UIColor(light: 0x1a0a04, dark: 0xff5a1f))

	// Bricolage Grotesque, weights 600 and 800 only.
	private static let heavy = "BricolageGrotesque96ptExtraBold-Regular_ExtraBold"
	private static let semi = "BricolageGrotesque96ptExtraBold-Regular_SemiBold"

	static func setup() {
		if let url = Bundle.main.url(forResource: "bricolage-grotesque", withExtension: "woff2") {
			CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
		}
		let ink = UIColor(light: 0x1a0a04, dark: 0xfbf8f3)
		let bar = UINavigationBar.appearance()
		bar.largeTitleTextAttributes = [.font: UIFont(name: heavy, size: 38) ?? .systemFont(ofSize: 38, weight: .black), .foregroundColor: ink]
		bar.titleTextAttributes = [.font: UIFont(name: heavy, size: 18) ?? .systemFont(ofSize: 18, weight: .black), .foregroundColor: ink]
	}

	static func display(_ size: CGFloat, _ style: Font.TextStyle = .largeTitle) -> Font {
		.custom(heavy, size: size, relativeTo: style)
	}

	static func text(_ size: CGFloat, _ style: Font.TextStyle = .body) -> Font {
		.custom(semi, size: size, relativeTo: style)
	}
}

extension Color {
	init(hex: UInt32) { self.init(UIColor(hex: hex)) }
}

extension UIColor {
	nonisolated convenience init(hex: UInt32) {
		self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
	}

	nonisolated convenience init(light: UInt32, dark: UInt32) {
		self.init { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
	}
}

extension Text {
	/// Category line: uppercase, wide tracking, parts joined with " / ".
	func eyebrow() -> some View { font(Brand.text(13, .footnote)).tracking(1.6).textCase(.uppercase) }
	func label() -> some View { font(Brand.text(11, .caption)).textCase(.uppercase) }
}

extension View {
	func pill(inverse: Bool = false) -> some View {
		font(Brand.text(15, .subheadline))
			.padding(.horizontal, 18).padding(.vertical, 12)
			.foregroundStyle(inverse ? Brand.ground : Brand.ink)
			.background(inverse ? Brand.accent : .clear, in: Capsule())
			.overlay(Capsule().strokeBorder(inverse ? .clear : Brand.line))
			.contentShape(Capsule())
	}
}

struct Rule: View {
	var body: some View { Rectangle().fill(Brand.line).frame(height: 1) }
}

/// The site's halftone: dots that shrink away from the top-leading corner.
struct Halftone: View {
	var color = Brand.accent
	var spacing: CGFloat = 10
	var dot: CGFloat = 5

	var body: some View {
		Canvas { ctx, size in
			let diagonal = hypot(size.width, size.height)
			for row in 0...Int(size.height / spacing) {
				for col in 0...Int(size.width / spacing) {
					let x = CGFloat(col) * spacing + (row.isMultiple(of: 2) ? 0 : spacing / 2)
					let y = CGFloat(row) * spacing
					let d = dot * pow(max(0, 1 - hypot(x, y) / diagonal), 1.6)
					if d > 0.4 { ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)), with: .color(color)) }
				}
			}
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}
