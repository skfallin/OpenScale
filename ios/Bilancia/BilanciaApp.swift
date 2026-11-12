import SwiftData
import SwiftUI

@main struct BilanciaApp: App {
	private let container: ModelContainer
	@State private var reader: ScaleReader

	init() {
		Brand.setup()
		let args = CommandLine.arguments
		do {
			// "-sample" (debug, simulator) keeps the made-up history out of the real store.
			container = try ModelContainer(for: Weighing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: args.contains("-sample")))
		} catch {
			fatalError("Archivio delle pesate non apribile: \(error)")
		}
		let reader = ScaleReader(context: container.mainContext)
		#if DEBUG
		selfCheck()
		// The simulator has no Bluetooth: these go through the same path as real packets.
		if args.contains("-sample") {
			reader.ingest(packet(day: 2, hour: 6, minute: 45, kg: 84.10, ohm: 524))
			reader.ingest(packet(day: 5, hour: 6, minute: 40, kg: 83.60, ohm: nil))
			reader.ingest(packet(day: 8, hour: 6, minute: 52, kg: 83.30, ohm: 520))
			reader.ingest(packet(day: 10, hour: 7, minute: 5, kg: 82.85, ohm: 516))
			reader.ingest([0x02, 0xA6, 0xEA, 0x07, 0x0B, 0x0B, 0x14, 0x2F, 0x37, 0x00, 0x02, 0x60, 0x40])  // literal bytes, laid out as the scale sends them
			if args.contains("-live") { reader.ingest(packet(day: 11, hour: 21, minute: 0, kg: 82.15, ohm: nil, flags: 0x04)) }
		}
		#endif
		_reader = State(initialValue: reader)
	}

	var body: some Scene {
		WindowGroup {
			Home()
				.environment(reader)
				.tint(Brand.accent)
				.onAppear { reader.start() }
		}
		.modelContainer(container)
	}
}

#if DEBUG
/// A November 2026 packet in kg; flags 0xA4 = stable and stepped off, 0xA6 = the same with impedance.
private func packet(day: UInt8, hour: UInt8, minute: UInt8, kg: Double, ohm: Int?, flags: UInt8? = nil) -> [UInt8] {
	let w = UInt16((kg * 200).rounded()), z = UInt16(ohm ?? 0)
	return [0x02, flags ?? (ohm == nil ? 0xA4 : 0xA6), 0xEA, 0x07, 11, day, hour, minute, 0,
		UInt8(z & 0xff), UInt8(z >> 8), UInt8(w & 0xff), UInt8(w >> 8)]
}
#endif
