import CoreBluetooth
import SwiftData
import SwiftUI

/// One stored weigh-in. `raw` keeps the packet exactly as the scale sent it.
@Model final class Weighing {
	var date: Date
	var weightKg: Double
	var impedance: Int?
	var raw: Data

	init(date: Date, weightKg: Double, impedance: Int?, raw: Data) {
		self.date = date
		self.weightKg = weightKg
		self.impedance = impedance
		self.raw = raw
	}
}

/// Listens to the scale's advertisements (no pairing, no connection) and stores every stable result.
/// Works only while the app is open: iOS does not deliver these packets to a backgrounded app.
@Observable final class ScaleReader: NSObject, CBCentralManagerDelegate {
	var state = CBManagerState.unknown
	var live: Measurement?  // the weight while it is still settling
	var saveError: String?

	@ObservationIgnored private var central: CBCentralManager?
	@ObservationIgnored private var last: [UInt8] = []
	@ObservationIgnored private let context: ModelContext

	init(context: ModelContext) {
		self.context = context
		super.init()
	}

	/// Asks for the Bluetooth permission the first time.
	func start() {
		if central == nil { central = CBCentralManager(delegate: self, queue: nil) }
	}

	var status: String {
		switch state {
		case .poweredOn: "in ascolto"
		case .poweredOff: "Bluetooth spento"
		case .unauthorized: "Bluetooth non autorizzato"
		case .unsupported: "Bluetooth non disponibile"
		default: "avvio"
		}
	}

	func centralManagerDidUpdateState(_ c: CBCentralManager) {
		state = c.state
		// Duplicates are needed: the scale re-advertises from the same address with changing data.
		if c.state == .poweredOn { c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
	}

	func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
		guard let all = ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], let data = all[CBUUID(string: "181B")] else { return }
		ingest([UInt8](data))
	}

	func ingest(_ bytes: [UInt8], now: Date = .now) {
		guard bytes != last, let m = decode(bytes) else { return }
		last = bytes
		live = m.stabilized || m.removed ? nil : m
		guard m.stabilized else { return }
		let date = stamp(m, now: now), raw = Data(bytes)
		do {
			// shortcut: reads every record for each new stable packet (a few per weigh-in); fine for
			// years of daily use, switch to a date-bounded fetch if the history reaches tens of thousands.
			let all = try context.fetch(FetchDescriptor<Weighing>())
			// The scale keeps repeating its last result, also after the app restarts.
			guard !all.contains(where: { $0.raw == raw }) else { return }
			if let w = all.first(where: { sameWeighIn($0.date, $0.weightKg, date, m.weightKg) }) {
				w.weightKg = m.weightKg
				w.impedance = m.impedance ?? w.impedance
				w.raw = raw
			} else {
				context.insert(Weighing(date: date, weightKg: m.weightKg, impedance: m.impedance, raw: raw))
			}
			try context.save()
			saveError = nil
		} catch {
			saveError = "Pesata non salvata: \(error.localizedDescription)"
		}
	}
}
