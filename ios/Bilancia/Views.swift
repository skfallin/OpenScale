import SwiftData
import SwiftUI

struct Home: View {
	@Environment(ScaleReader.self) private var reader
	@Environment(\.openURL) private var openURL
	@Query(sort: \Weighing.date, order: .reverse) private var all: [Weighing]

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					Text("Bilancia / \(reader.status)").eyebrow().padding(.trailing, 120)  // clear of the halftone
					if reader.state == .unauthorized {
						Text("Senza Bluetooth l'app non può sentire la bilancia.").font(Brand.text(19))
						Button { openURL(URL(string: UIApplication.openSettingsURLString)!) } label: { Text("Apri Impostazioni ↗\u{FE0E}").pill(inverse: true) }
					}
					if let error = reader.saveError { Text(error).font(Brand.text(19)) }

					if let m = reader.live {
						BigWeight(kg: m.weightKg)
						Text("Misura in corso / resta fermo").eyebrow()
					} else if let w = all.first {
						BigWeight(kg: w.weightKg)
						Text("Ultima pesata / \(Text(w.date, format: when))").eyebrow()
					} else {
						Text("Sali sulla bilancia a piedi nudi.")
							.font(Brand.display(54)).tracking(-3.5)
						Text("Tieni aperta l'app. Il peso arriva da solo via Bluetooth e resta salvato su questo iPhone.")
							.font(Brand.text(19))
					}

					HStack(spacing: 12) {
						NavigationLink { History() } label: { Text("Storico ↗\u{FE0E}").pill() }
						NavigationLink { Profile() } label: { Text("Profilo ↗\u{FE0E}").pill() }
					}
					if reader.live == nil, let w = all.first { Details(w: w) }
				}
				.padding(18)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(alignment: .topTrailing) { Halftone().frame(width: 170, height: 170).scaleEffect(x: -1) }
			}
			.screen()
			// Keeps the scrolled content out from under the clock and battery.
			.overlay(alignment: .top) { Color.clear.frame(height: 0).background(Brand.ground) }  // a style background fills the safe area
			.toolbar(.hidden, for: .navigationBar)
		}
	}
}

private let when = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).hour().minute()

extension View {
	/// Brand ground, ink text.
	func screen() -> some View { foregroundStyle(Brand.ink).background(Brand.ground) }
}

struct BigWeight: View {
	var kg: Double

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			// The scale resolves 0.05 kg, so two decimals.
			Text(num(kg, 2)).font(Brand.display(104)).tracking(-6).lineLimit(1).minimumScaleFactor(0.4)
				.contentTransition(.numericText())
			Text("kg").font(Brand.display(32))
		}
		.accessibilityElement(children: .combine)
	}
}

/// Everything known about one weigh-in, one value per block: number, band, what it means.
struct Details: View {
	var w: Weighing
	@AppStorage("height") private var height = 0.0
	@AppStorage("birth") private var birth = 0.0  // timeIntervalSinceReferenceDate
	@AppStorage("male") private var male = true
	// shortcut: one waist value for every weigh-in, old ones included; store it with a date if its history matters.
	@AppStorage("waist") private var waist = 0.0
	@Query private var all: [Weighing]

	var body: some View {
		let age = Calendar.current.dateComponents([.year], from: Date(timeIntervalSinceReferenceDate: birth), to: w.date).year ?? 0
		var list = metrics(weightKg: w.weightKg, impedance: w.impedance, heightCm: height, waistCm: waist, age: age, male: male)
		let days = all.map { (date: $0.date, kg: $0.weightKg) }
		// One day alone is not an average.
		if let now = weekAverage(days, until: w.date), now.days > 1 {
			let before = weekAverage(days, until: w.date - 7 * 86_400).map {
				" Rispetto ai 7 giorni prima: \((now.kg - $0.kg).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) kg."
			}
			list.insert(Metric(name: "Media di 7 giorni", value: num(now.kg), unit: "kg",
				about: "La media di \(now.days) giorni con pesata nell'ultima settimana. Il peso cambia anche di 1–2 kg in un giorno per acqua e cibo: la media mostra la direzione vera. Pesati al mattino, a digiuno.\(before ?? "")"), at: 0)
		}
		if let z = w.impedance {
			list.append(Metric(name: "Impedenza", value: "\(z)", unit: "Ω",
				about: "La resistenza elettrica del corpo misurata dai piedi. Da qui la bilancia stima grasso, acqua e muscoli."))
		}
		return VStack(alignment: .leading, spacing: 18) {
			if height == 0 {
				NavigationLink { Profile() } label: {
					Text("Imposta altezza, età e sesso per vedere grasso, acqua e muscoli ↗\u{FE0E}")
						.font(Brand.text(19)).multilineTextAlignment(.leading)
						.padding(18).frame(maxWidth: .infinity, alignment: .leading)
						.foregroundStyle(Brand.ground)
						.background(Brand.accent, in: RoundedRectangle(cornerRadius: 12))
				}
			} else if w.impedance == nil {
				Text("Questa pesata non ha l'impedenza. Per grasso, acqua e muscoli sali a piedi nudi e resta fermo finché il numero smette di lampeggiare.")
					.font(Brand.text(16))
			} else if Bilancia.body(weightKg: w.weightKg, heightCm: height, age: age, male: male, impedance: w.impedance ?? 0) == nil {
				Text("Età, peso o impedenza sono fuori dai limiti che la bilancia sa calcolare (6–99 anni).").font(Brand.text(16))
			}

			ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
				MetricRow(m: m, counter: String(format: "%02d / %02d", i + 1, list.count))
			}

			Rule()
			Text("Dati grezzi").eyebrow()
			Text(w.raw.map { String(format: "%02X", $0) }.joined(separator: " ")).font(.system(.footnote, design: .monospaced))
			if let t = decode([UInt8](w.raw))?.time {
				Text("Orologio della bilancia / \(t.formatted(.iso8601))").label()
			}
			Text("Sono stime, non una diagnosi. Grasso, acqua, muscoli e ossa vengono dalle formule della bilancia; metabolismo, peso sano e valori del girovita da formule pubblicate.")
				.font(Brand.text(16))
		}
	}
}

struct MetricRow: View {
	var m: Metric
	var counter: String

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Rule()
			HStack {
				Text(m.name).eyebrow()
				Spacer()
				Text(counter).eyebrow().accessibilityHidden(true)
			}
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Text(m.value).font(Brand.display(56)).tracking(-3)
				Text(m.unit).font(Brand.text(19))
				Spacer()
				if !m.bands.isEmpty { Text(m.bands[m.band]).pill(inverse: true) }
			}
			if !m.bands.isEmpty { Bands(m: m) }
			Text(m.about).font(Brand.text(16))
		}
		.accessibilityElement(children: .combine)
	}
}

/// The reference bands side by side, the current one filled. VoiceOver gets the band name from the row instead.
struct Bands: View {
	var m: Metric

	var body: some View {
		HStack(alignment: .top, spacing: 6) {
			ForEach(m.bands.indices, id: \.self) { i in
				VStack(alignment: .leading, spacing: 6) {
					Capsule().fill(i == m.band ? Brand.accent : .clear)
						.overlay(Capsule().strokeBorder(Brand.line))
						.frame(height: 10)
					Text(m.bands[i]).label().lineLimit(2, reservesSpace: m.bands.count > 4)  // "Molto basso" wraps
					Text(m.range(i)).label()
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.accessibilityHidden(true)
	}
}

struct History: View {
	@Environment(\.modelContext) private var context
	@Query(sort: \Weighing.date, order: .reverse) private var all: [Weighing]

	var body: some View {
		List {
			ForEach(all) { w in
				NavigationLink { Detail(w: w) } label: {
					HStack(alignment: .firstTextBaseline) {
						VStack(alignment: .leading, spacing: 6) {
							Text(w.date, format: .dateTime.day().month(.wide).year().hour().minute()).eyebrow()
							Text(w.impedance.map { "Impedenza \($0) Ω" } ?? "Solo peso").label()
						}
						Spacer()
						Text("\(num(w.weightKg, 2)) kg").font(Brand.display(26)).tracking(-1.2)
					}
					.foregroundStyle(Brand.ink)
					.padding(.vertical, 6)
				}
				.listRowBackground(Color.clear)
				.listRowSeparatorTint(Brand.line)
			}
			.onDelete { for i in $0 { context.delete(all[i]) } }
		}
		.listStyle(.plain)
		.scrollContentBackground(.hidden)
		.overlay { if all.isEmpty { Text("Ancora nessuna pesata.").font(Brand.text(19)) } }
		.screen()
		.navigationTitle("Storico")
	}
}

struct Detail: View {
	var w: Weighing

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				BigWeight(kg: w.weightKg)
				Text(w.date, format: when).eyebrow()
				Details(w: w)
			}
			.padding(18)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.screen()
		.navigationTitle("Pesata")
		.navigationBarTitleDisplayMode(.inline)
	}
}

struct Profile: View {
	@Environment(\.dismiss) private var dismiss
	@AppStorage("height") private var height = 0.0
	@AppStorage("birth") private var birth = 0.0
	@AppStorage("male") private var male = true
	@AppStorage("waist") private var waist = 0.0
	@State private var h = 170.0
	@State private var girth = 0.0  // 0 = not measured
	@State private var born = Calendar.current.date(byAdding: .year, value: -30, to: .now) ?? .now
	@State private var isMale: Bool?

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				Text("Servono per calcolare grasso, acqua e muscoli. Restano su questo iPhone.").font(Brand.text(19))
				Rule()
				Text("Altezza").eyebrow()
				Stepper(value: $h, in: 90...220) { Text("\(Int(h)) cm").font(Brand.display(44)).tracking(-2) }
				Rule()
				Text("Data di nascita").eyebrow()
				DatePicker("Data di nascita", selection: $born, in: ...Date.now, displayedComponents: .date).labelsHidden()
				Rule()
				Text("Sesso").eyebrow()
				HStack(spacing: 12) {
					Button { isMale = true } label: { Text("Uomo").pill(inverse: isMale == true) }
						.accessibilityAddTraits(isMale == true ? .isSelected : [])
					Button { isMale = false } label: { Text("Donna").pill(inverse: isMale == false) }
						.accessibilityAddTraits(isMale == false ? .isSelected : [])
				}
				Text("La bilancia ha due serie di formule, una per uomo e una per donna.").label()
				Rule()
				Text("Girovita / facoltativo").eyebrow()
				if girth > 0 {
					Stepper(value: $girth, in: 40...200) { Text("\(Int(girth)) cm").font(Brand.display(44)).tracking(-2) }
					Button { girth = 0 } label: { Text("Togli").pill() }
				} else {
					Button { girth = (h / 2).rounded() } label: { Text("Aggiungi ↗\u{FE0E}").pill() }
				}
				Text("Serve per il grasso addominale, che la bilancia non misura. Metro orizzontale a metà tra l'ultima costola e l'osso del fianco, a fine espirazione, senza stringere.").font(Brand.text(16))
				Rule()
				Button {
					guard let isMale else { return }
					height = h
					birth = born.timeIntervalSinceReferenceDate
					male = isMale
					waist = girth
					dismiss()
				} label: { Text("Salva ↗\u{FE0E}").pill(inverse: true) }
					.disabled(isMale == nil).opacity(isMale == nil ? 0.4 : 1)
			}
			.padding(18)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.screen()
		.navigationTitle("Profilo")
		.onAppear {
			guard height > 0 else { return }
			h = height
			born = Date(timeIntervalSinceReferenceDate: birth)
			isMale = male
			girth = waist
		}
	}
}
