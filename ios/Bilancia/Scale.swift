// Decoder, formulas and reference ranges for the Xiaomi Mi Body Composition Scale 2 ("MIBFS").
// The decoder and everything derived from impedance are as found in Zepp Life 6.17.0 (../../scale.swift,
// evidence in ../../REPORT.md). Metabolism, healthy weight and the waist values use published equations
// instead, so those do not match what Zepp Life shows.
import Foundation

struct Measurement: Equatable {
	var weightKg: Double
	var impedance: Int?  // ohms; nil until the scale has measured it (bare feet, a few seconds after the weight)
	var stabilized: Bool
	var removed: Bool
	var time: Date?  // the scale's own clock, which is UTC; nil when the fields are not a date
}

// 13 bytes of service data under UUID 0x181B (Body Composition).
func decode(_ d: [UInt8]) -> Measurement? {
	guard d.count == 13 else { return nil }
	let raw = Double(UInt16(d[11]) | UInt16(d[12]) << 8)
	guard raw != 0xFFF0 else { return nil }  // overload marker
	// Unit: catty (jin) is tested before lbs, as the app does.
	let kg = d[1] & 0x40 != 0 ? raw / 100 * 0.5 : d[0] & 0x01 != 0 ? raw / 100 * 0.45359237 : raw / 200
	let imp = Int(UInt16(d[9]) | UInt16(d[10]) << 8)
	let t = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: Int(d[2]) | Int(d[3]) << 8,
		month: Int(d[4]), day: Int(d[5]), hour: Int(d[6]), minute: Int(d[7]), second: Int(d[8]))
	return Measurement(
		weightKg: kg,
		impedance: d[1] & 0x02 != 0 && imp > 0 && imp < 3000 ? imp : nil,
		stabilized: d[1] & 0x20 != 0,
		removed: d[1] & 0x80 != 0,
		time: t.isValidDate ? t.date : nil)
}

// shortcut: trusts the scale's clock when it is plausible, because the app never sets it; a scale with a
// reset clock gets the phone's time instead. Upgrade by writing the clock (characteristic 2A2B) if dates drift.
func stamp(_ m: Measurement, now: Date) -> Date {
	guard let t = m.time, t > Date(timeIntervalSince1970: 1_420_070_400), t < now + 86_400 else { return now }  // 2015 … tomorrow
	return t
}

// shortcut: stable packets within 30 s and 0.5 kg are one weigh-in (the scale sends weight first, impedance later).
// Two people of almost the same weight stepping on back to back would merge; upgrade when there are several profiles.
func sameWeighIn(_ aDate: Date, _ aKg: Double, _ bDate: Date, _ bKg: Double) -> Bool {
	abs(aDate.timeIntervalSince(bDate)) <= 30 && abs(aKg - bKg) <= 0.5
}

struct Body {
	var bmi, fatPct, waterPct, boneKg, muscleKg, proteinPct: Double
	var visceral: Int
}

// Same maths as libBodyfat.so (Holtek) plus the protein value Zepp Life adds in Java. These stay as the vendor
// wrote them: they are fitted to this scale's foot-to-foot electrodes, published hand-to-foot equations are not.
// nil when an input is outside the range the library accepts.
func body(weightKg w: Double, heightCm h: Double, age: Int, male: Bool, impedance: Int) -> Body? {
	guard (90...220).contains(h), w > 10, w < 200, (6...99).contains(age), (50...3000).contains(impedance) else { return nil }
	func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }
	let z = clamp(Double(impedance), 200, 1200), a = Double(age)

	let lbm = h * 9.058 / 100 * h / 100 + 12.226 + w * 0.32 - z * 0.0068 - a * 0.0542
	var c = lbm - (male ? 0.8 : age <= 49 ? 9.25 : 7.25)
	if male {
		if w < 61 { c *= 0.98 }
	} else {
		if w < 50 { c *= 1.02 }
		if w > 60 { c *= 0.96 }
		if h > 160 { c *= 1.03 }
	}
	let fat = clamp((1 - c / w) * 100, 5, 75)

	let x = (100 - fat) * 0.7
	let water = clamp(x > 50 ? x * 0.98 : x * 1.02, 35, 75)

	var bone = lbm * 0.05158 - (male ? 0.18016894 : 0.245691014)
	bone = clamp(bone > 2.2 ? bone + 0.1 : bone - 0.1, 0.5, 8)

	let muscle = clamp(w - fat * 0.01 * w - bone, 10, 120)

	let vf: Double
	if male {
		vf = h < 1.6 * w + 63
			? 305 * w / (0.0826 * h * h - 0.4 * h + 48) - 2.9 + 0.15 * a
			: w * (0.765 - 0.0015 * h) - 0.143 * h + 0.15 * a - 5
	} else {
		vf = w <= h * 0.5 - 13
			? w * (0.691 - 0.0024 * h) - 0.027 * h + 0.07 * a - 10.5
			: 500 * w / (0.1158 * h * h + 1.45 * h - 120) - 6 + 0.07 * a
	}

	return Body(
		bmi: clamp(w / (h / 100 * h / 100), 10, 90),
		fatPct: fat, waterPct: water, boneKg: bone, muscleKg: muscle,
		proteinPct: clamp(muscle / w * 100 - water, 5, 32),
		visceral: Int(clamp(vf, 1, 50)))
}

// Mifflin-St Jeor (1990), the resting-energy equation that agrees best with measured values in adults.
// The scale's own formula is not used: its result goes down as height goes up.
func bmr(weightKg w: Double, heightCm h: Double, age: Int, male: Bool) -> Double {
	10 * w + 6.25 * h - 5 * Double(age) + (male ? 5 : -161)
}

// Relative Fat Mass (Woolcott & Bergman 2018): body fat % from height and waist, fitted against DXA scans.
func rfm(heightCm h: Double, waistCm: Double, male: Bool) -> Double {
	min(max(64 - 20 * h / waistCm + (male ? 0 : 12), 5), 75)
}

/// Mean weight of the 7 days up to `end`, one value per calendar day so three weigh-ins in a day do not count three times.
func weekAverage(_ all: [(date: Date, kg: Double)], until end: Date, calendar: Calendar = .current) -> (kg: Double, days: Int)? {
	let week = all.filter { $0.date <= end && $0.date > end - 7 * 86_400 }
	let perDay = Dictionary(grouping: week) { calendar.startOfDay(for: $0.date) }.values.map { $0.map(\.kg).reduce(0, +) / Double($0.count) }
	return perDay.isEmpty ? nil : (perDay.reduce(0, +) / Double(perDay.count), perDay.count)
}

// MARK: - What the screens show

/// One value on screen: number, unit, a plain explanation and, when the scale's library has
/// reference boundaries for it, the bands and the one the value falls in.
struct Metric: Identifiable {
	var name, value, unit, about: String
	var x = 0.0
	var cuts: [Double] = []  // boundaries between bands, ascending
	var bands: [String] = []  // cuts.count + 1 names, low to high
	var id: String { name }
	var band: Int { cuts.filter { x >= $0 }.count }

	/// "< 18,5", "18,5–25", "≥ 30"
	func range(_ i: Int) -> String {
		func f(_ c: Double) -> String { num(c, c == c.rounded() ? 0 : 1) }
		return i == 0 ? "< \(f(cuts[0]))" : i == cuts.count ? "≥ \(f(cuts[i - 1]))" : "\(f(cuts[i - 1]))–\(f(cuts[i]))"
	}
}

func num(_ x: Double, _ digits: Int = 1) -> String { x.formatted(.number.precision(.fractionLength(digits))) }

// Body-fat boundaries per age row: ages 6…17, then 18–39, 40–59, 60 and over.
private let fatFemale: [[Double]] = [
	[8, 16, 25, 29], [9, 17, 25, 30], [10, 18, 26, 31], [10, 19, 28, 32], [11, 20, 29, 33], [13, 22, 31, 35],
	[14, 23, 32, 36], [15, 25, 34, 38], [17, 26, 35, 39], [18, 27, 36, 41], [19, 28, 37, 41], [20, 28, 37, 41],
	[21, 28, 35, 40], [22, 29, 36, 41], [23, 30, 37, 42],
]
private let fatMale: [[Double]] = [
	[7, 16, 25, 30], [7, 16, 25, 30], [7, 16, 26, 30], [7, 16, 26, 30], [7, 16, 26, 30], [7, 16, 26, 30],
	[7, 16, 25, 30], [7, 16, 25, 30], [7, 15, 25, 29], [8, 15, 24, 29], [8, 16, 24, 28], [9, 16, 23, 28],
	[11, 17, 22, 27], [12, 16, 23, 28], [14, 16, 25, 30],
]

func fatCuts(age: Int, male: Bool) -> [Double] {
	(male ? fatMale : fatFemale)[age < 18 ? max(age, 6) - 6 : age < 40 ? 12 : age < 60 ? 13 : 14]
}

/// Everything that can be worked out for one weigh-in. Without impedance there is no body composition;
/// without a valid height there is nothing. `waistCm` 0 means not measured.
func metrics(weightKg w: Double, impedance: Int?, heightCm h: Double, waistCm: Double = 0, age: Int, male: Bool) -> [Metric] {
	guard (90...220).contains(h) else { return [] }
	let m2 = h / 100 * h / 100
	let bmi = min(max(w / m2, 10), 90)
	// shortcut: the published equations below are for adults, so under 18 only the scale's own values show;
	// add the paediatric ones (Schofield, BMI percentiles) if a minor uses the app.
	let adult = age >= 18, waist = adult ? waistCm : 0
	var list = [Metric(name: "BMI", value: num(bmi), unit: "",
		about: "Indice di massa corporea: il peso in rapporto all'altezza. Non distingue il grasso dai muscoli.",
		x: bmi, cuts: [18.5, 25, 30], bands: ["Sottopeso", "Normale", "Sovrappeso", "Obesità"])]

	if let z = impedance, let b = body(weightKg: w, heightCm: h, age: age, male: male, impedance: z) {
		let muscle: [Double] = male ? (h < 160 ? [38.5, 46.5] : h < 170 ? [44, 52.4] : [49.5, 59.4])
			: (h < 160 ? [29.1, 34.7] : h < 170 ? [32.9, 37.5] : [36.5, 42.5])
		let bone: [Double] = male ? (w < 60 ? [1.5, 3.5] : w < 75 ? [1.9, 3.9] : [2.2, 4.2])
			: (w < 45 ? [0.8, 2.8] : w < 60 ? [1.2, 3.2] : [1.5, 3.5])
		list += [
			Metric(name: "Grasso corporeo", value: num(b.fatPct), unit: "%",
				about: "Quanta parte del tuo peso è grasso, stimata dalla bilancia con l'impedenza. Le fasce dipendono da età e sesso.",
				x: b.fatPct, cuts: fatCuts(age: age, male: male), bands: fatBands),
			Metric(name: "Massa muscolare", value: num(b.muscleKg), unit: "kg",
				about: "Il peso dei tuoi muscoli, compresa l'acqua che contengono. Le fasce dipendono dall'altezza.",
				x: b.muscleKg, cuts: muscle, bands: ["Bassa", "Normale", "Alta"]),
			Metric(name: "Acqua", value: num(b.waterPct), unit: "%",
				about: "Quanta parte del tuo peso è acqua. Chi ha più muscoli e meno grasso ne ha di più.",
				x: b.waterPct, cuts: [53, 67], bands: ["Bassa", "Normale", "Alta"]),
			Metric(name: "Proteine", value: num(b.proteinPct), unit: "%",
				about: "Quanta parte del tuo peso è fatta di proteine. Sale quando crescono i muscoli."),
			Metric(name: "Massa ossea", value: num(b.boneKg, 2), unit: "kg",
				about: "Il peso stimato dei minerali delle ossa. Le fasce dipendono dal tuo peso.",
				x: b.boneKg, cuts: bone, bands: ["Bassa", "Normale", "Alta"]),
		]
		// The scale's level is only weight, height and age: the waist ratio below replaces it when there is one.
		if waist == 0 {
			list.append(Metric(name: "Grasso viscerale", value: "\(b.visceral)", unit: "livello",
				about: "Il grasso attorno agli organi dell'addome, da 1 a 50. La bilancia non lo misura: lo ricava da peso, altezza ed età."
					+ (adult ? " Aggiungi il girovita nel Profilo per un dato più affidabile." : ""),
				x: Double(b.visceral), cuts: [10, 15], bands: ["Normale", "Alto", "Molto alto"]))
		}
	}
	if waist > 0 {
		let fat = rfm(heightCm: h, waistCm: waist, male: male), ratio = waist / h
		// Right after the scale's body fat when there is one, so the two estimates can be compared.
		list.insert(Metric(name: "Grasso dal girovita", value: num(fat), unit: "%",
			about: "Il grasso stimato da altezza e girovita, senza impedenza (Relative Fat Mass, messa a punto sulla DEXA). Se è vicino al valore della bilancia la stima è più solida; se sono lontani, guarda come cambiano nel tempo più che il numero.",
			x: fat, cuts: fatCuts(age: age, male: male), bands: fatBands), at: min(2, list.count))
		list.append(Metric(name: "Rapporto vita-altezza", value: num(ratio, 2), unit: "",
			about: "Il girovita diviso per l'altezza: misura il grasso addominale, quello che conta di più per la salute. Il riferimento è stare sotto 0,5 (linee guida NICE 2022): per te, una vita sotto \(num(h / 2, 0)) cm.",
			x: ratio, cuts: [0.5, 0.6], bands: ["Normale", "Aumentato", "Alto"]))
	}
	if adult {
		let lo = 18.5 * m2, hi = 25 * m2
		list += [
			Metric(name: "Metabolismo basale", value: num(bmr(weightKg: w, heightCm: h, age: age, male: male), 0), unit: "kcal",
				about: "Le calorie che il corpo brucia in un giorno a riposo completo. Viene dalla formula di Mifflin-St Jeor, con peso, altezza, età e sesso: sulla singola persona può sbagliare del 10 %."),
			Metric(name: "Peso sano", value: "\(num(lo, 0))–\(num(hi, 0))", unit: "kg",
				about: "Il peso che alla tua altezza dà un BMI tra 18,5 e 25. "
					+ (w > hi ? "Oggi sei \(num(w - hi)) kg sopra." : w < lo ? "Oggi sei \(num(lo - w)) kg sotto." : "Oggi ci sei dentro.")),
		]
	}
	return list
}

let fatBands = ["Molto basso", "Basso", "Normale", "Alto", "Molto alto"]

#if DEBUG
/// Runs at launch in debug builds: decoder, formulas, ranges and the storage rule.
func selfCheck() {
	// kg unit, stabilized + impedance, 2026-11-11 21:50:00 UTC, 500 ohm, 15000/200 = 75.00 kg
	let m = decode([0x02, 0x22, 0xEA, 0x07, 11, 11, 21, 50, 0, 0xF4, 0x01, 0x98, 0x3A])!
	precondition(m.weightKg == 75 && m.impedance == 500 && m.stabilized && !m.removed)
	precondition(m.time == Date(timeIntervalSince1970: 1_794_433_800))
	// Laid out like the packet captured from the real scale: 82.40 kg, 512 ohm, stable, stepped off.
	let real = decode([0x02, 0xA6, 0xEA, 0x07, 0x0B, 0x0B, 0x14, 0x2F, 0x37, 0x00, 0x02, 0x60, 0x40])!
	precondition(real.weightKg == 82.4 && real.impedance == 512 && real.stabilized && real.removed)
	precondition(decode([0x03, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0x27])!.weightKg == 45.359237)  // 100.00 lbs
	precondition(decode([0x00, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0x27])!.weightKg == 50)  // 100.00 jin
	precondition(decode([0x03, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0x27])!.time == nil)  // month 0 is not a date
	precondition(decode([0x02, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xF0, 0xFF]) == nil)  // overload
	precondition(decode([1, 2, 3]) == nil)

	// Expected values worked out separately from the formulas in REPORT.md (not from a real Zepp Life reading).
	func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }
	let man = body(weightKg: 75, heightCm: 175, age: 35, male: true, impedance: 500)!
	precondition(near(man.bmi, 24.49) && near(man.fatPct, 22.841) && near(man.waterPct, 52.931) && near(man.boneKg, 2.946))
	precondition(near(man.muscleKg, 54.923) && near(man.proteinPct, 20.3) && man.visceral == 11)
	let woman = body(weightKg: 58, heightCm: 165, age: 55, male: false, impedance: 600)!
	precondition(near(woman.fatPct, 26.949) && near(woman.waterPct, 50.113) && near(woman.boneKg, 2.35) && near(woman.muscleKg, 40.019))
	precondition(near(woman.proteinPct, 18.886) && woman.visceral == 6)
	precondition(body(weightKg: 75, heightCm: 175, age: 35, male: true, impedance: 20) == nil)

	// Published equations, worked out by hand: 750 + 1093.75 − 175 + 5; 580 + 1031.25 − 275 − 161; 64 − 3500/90; 76 − 3300/80.
	precondition(bmr(weightKg: 75, heightCm: 175, age: 35, male: true) == 1673.75 && bmr(weightKg: 58, heightCm: 165, age: 55, male: false) == 1175.25)
	precondition(near(rfm(heightCm: 175, waistCm: 90, male: true), 25.111) && near(rfm(heightCm: 165, waistCm: 80, male: false), 34.75))

	// Ranges: the 75 kg man is BMI "normale" (band 1) and his fat, 22.8 %, is above 22 (band 3).
	precondition(fatCuts(age: 5, male: true) == [7, 16, 25, 30] && fatCuts(age: 17, male: false) == [20, 28, 37, 41])
	precondition(fatCuts(age: 39, male: true) == [11, 17, 22, 27] && fatCuts(age: 40, male: true) == [12, 16, 23, 28])
	precondition(fatCuts(age: 60, male: false) == [23, 30, 37, 42])
	func names(_ z: Int?, waist: Double = 0, age: Int = 35) -> [String] {
		let list = metrics(weightKg: 75, impedance: z, heightCm: 175, waistCm: waist, age: age, male: true)
		precondition(list.allSatisfy { $0.bands.isEmpty || $0.bands.count == $0.cuts.count + 1 })
		return list.map(\.name)
	}
	let fromScale = ["Grasso corporeo", "Massa muscolare", "Acqua", "Proteine", "Massa ossea"]
	precondition(names(500) == ["BMI"] + fromScale + ["Grasso viscerale", "Metabolismo basale", "Peso sano"])
	precondition(names(500, waist: 90) == ["BMI", "Grasso corporeo", "Grasso dal girovita"] + fromScale.dropFirst()
		+ ["Rapporto vita-altezza", "Metabolismo basale", "Peso sano"])
	precondition(names(nil, waist: 90) == ["BMI", "Grasso dal girovita", "Rapporto vita-altezza", "Metabolismo basale", "Peso sano"])
	precondition(names(nil) == ["BMI", "Metabolismo basale", "Peso sano"] && names(nil, waist: 90, age: 10) == ["BMI"])
	let list = metrics(weightKg: 75, impedance: 500, heightCm: 175, waistCm: 90, age: 35, male: true)
	// 90 / 175 = 0.51 is "aumentato"; the healthy range for 175 cm is 56.7–76.6 kg, which 75 kg is inside.
	precondition(list[0].band == 1 && list[1].band == 3 && list[7].band == 1 && list[9].value == "57–77" && list[9].about.hasSuffix("dentro."))
	precondition(metrics(weightKg: 75, impedance: 500, heightCm: 0, age: 35, male: true).isEmpty)

	// Week average: two weigh-ins on the same day count once, the one 7 days back is outside.
	var utc = Calendar(identifier: .gregorian)
	utc.timeZone = .gmt
	let noon = Date(timeIntervalSince1970: 1_794_398_400)  // 2026-11-11 12:00 UTC
	let week = weekAverage([(noon, 80), (noon - 3600, 82), (noon - 86_400, 79), (noon - 7 * 86_400, 99)], until: noon, calendar: utc)!
	precondition(week.kg == 80 && week.days == 2 && weekAverage([(noon + 1, 80)], until: noon, calendar: utc) == nil)

	// Storage rule.
	let t = Date(timeIntervalSince1970: 1_794_433_800)
	precondition(sameWeighIn(t, 75, t + 30, 75.5) && !sameWeighIn(t, 75, t + 31, 75) && !sameWeighIn(t, 75, t, 75.55))
	precondition(stamp(m, now: t + 5) == t && stamp(m, now: t - 200_000) == t - 200_000)  // a clock far in the future is not trusted
}
#endif
