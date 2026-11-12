#!/usr/bin/env swift
// Passive reader for the Xiaomi Mi Body Composition Scale 2 (BLE name "MIBFS").
// The scale broadcasts each measurement in its advertisements, so no pairing or connection is needed.
//   swift scale.swift                                  step on the scale; prints every new packet, raw and decoded
//   swift scale.swift --height 175 --age 35 --sex m    also prints body composition once impedance is in
//   swift scale.swift --selftest                       checks the decoder and the formulas
// Packet layout and formulas are the ones in Zepp Life 6.17.0; see REPORT.md.
import CoreBluetooth
import Foundation

struct Measurement: Equatable {
    var weightKg: Double
    var impedance: Int?  // ohms; nil until the scale has measured it (bare feet, a few seconds after weight)
    var stabilized: Bool
    var removed: Bool
    var time: String
}

// 13 bytes of service data under UUID 0x181B (Body Composition).
func decode(_ d: [UInt8]) -> Measurement? {
    guard d.count == 13 else { return nil }
    let raw = Double(UInt16(d[11]) | UInt16(d[12]) << 8)
    guard raw != 0xFFF0 else { return nil }  // overload marker
    // Unit: catty (jin) is tested before lbs, as the app does.
    let kg = d[1] & 0x40 != 0 ? raw / 100 * 0.5 : d[0] & 0x01 != 0 ? raw / 100 * 0.45359237 : raw / 200
    let imp = Int(UInt16(d[9]) | UInt16(d[10]) << 8)
    let year = Int(d[2]) | Int(d[3]) << 8
    return Measurement(
        weightKg: kg,
        impedance: d[1] & 0x02 != 0 && imp > 0 && imp < 3000 ? imp : nil,
        stabilized: d[1] & 0x20 != 0,
        removed: d[1] & 0x80 != 0,
        time: String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, d[4], d[5], d[6], d[7], d[8]))
}

struct Body {
    var bmi, fatPct, waterPct, boneKg, muscleKg, proteinPct, standardKg: Double
    var visceral, bmrKcal, bodyAge: Int
}

// Same maths as libBodyfat.so (Holtek) plus the three values Zepp Life adds in Java (protein, body age, standard weight).
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

    let bmr = male
        ? 877.8 + w * 14.916 - h * 0.726 - a * 8.976
        : 864.6 + w * 10.2036 - h * 0.39336 - a * 6.204

    // The app feeds the unclamped impedance and an integer height to its own (Java) formulas.
    let hi = h.rounded(.towardZero), zi = Double(impedance)
    let bodyAge = male
        ? hi * -0.7471 + w * 0.9161 + a * 0.4184 + zi * 0.0517 + 54.2267
        : hi * -1.1165 + w * 1.5784 + a * 0.4615 + zi * 0.0415 + 83.2548

    return Body(
        bmi: clamp(w / (h / 100 * h / 100), 10, 90),
        fatPct: fat, waterPct: water, boneKg: bone, muscleKg: muscle,
        proteinPct: clamp(muscle / w * 100 - water, 5, 32),
        standardKg: male ? (hi - 80) * 0.7 : (hi - 70) * 0.6,
        visceral: Int(clamp(vf, 1, 50)), bmrKcal: Int(clamp(bmr, 500, 10000)), bodyAge: Int(clamp(bodyAge, 15, 80)))
}

func describe(_ b: Body) -> String {
    String(format: "  BMI %.1f  fat %.1f%%  water %.1f%%  muscle %.1f kg  bone %.2f kg  protein %.1f%%  visceral %d  BMR %d kcal  body age %d  standard weight %.1f kg",
           b.bmi, b.fatPct, b.waterPct, b.muscleKg, b.boneKg, b.proteinPct, b.visceral, b.bmrKcal, b.bodyAge, b.standardKg)
}

let args = CommandLine.arguments
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

if args.contains("--selftest") {
    // kg unit, stabilized + impedance, 2026-11-11 21:50:00, 500 ohm, 15000/200 = 75.00 kg
    let m = decode([0x02, 0x22, 0xEA, 0x07, 11, 11, 21, 50, 0, 0xF4, 0x01, 0x98, 0x3A])
    precondition(m == Measurement(weightKg: 75, impedance: 500, stabilized: true, removed: false, time: "2026-11-11 21:50:00"))
    precondition(decode([0x03, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0x27])!.weightKg == 45.359237)  // 100.00 lbs, no impedance
    precondition(decode([0x00, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0x27])!.weightKg == 50)  // 100.00 jin
    precondition(decode([0x02, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xF0, 0xFF]) == nil)  // overload
    precondition(decode([1, 2, 3]) == nil)

    // Expected values worked out separately from the formulas in REPORT.md (not from a real Zepp Life reading).
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }
    let man = body(weightKg: 75, heightCm: 175, age: 35, male: true, impedance: 500)!
    precondition(near(man.bmi, 24.49) && near(man.fatPct, 22.841) && near(man.waterPct, 52.931) && near(man.boneKg, 2.946))
    precondition(near(man.muscleKg, 54.923) && near(man.proteinPct, 20.3) && near(man.standardKg, 66.5))
    precondition(man.visceral == 11 && man.bmrKcal == 1555 && man.bodyAge == 32)
    let woman = body(weightKg: 58, heightCm: 165, age: 55, male: false, impedance: 600)!
    precondition(near(woman.fatPct, 26.949) && near(woman.waterPct, 50.113) && near(woman.boneKg, 2.35) && near(woman.muscleKg, 40.019))
    precondition(near(woman.proteinPct, 18.886) && woman.visceral == 6 && woman.bmrKcal == 1050 && woman.bodyAge == 40)
    precondition(body(weightKg: 75, heightCm: 175, age: 35, male: true, impedance: 20) == nil)
    print("selftest ok")
    exit(0)
}

// Optional profile; without it only weight and impedance are printed.
let profile: (h: Double, age: Int, male: Bool)? = {
    guard let h = arg("--height").flatMap(Double.init), let age = arg("--age").flatMap({ Int($0) }),
          let sex = arg("--sex"), ["m", "f"].contains(sex) else { return nil }
    return (h, age, sex == "m")
}()
if profile == nil && (args.contains("--height") || args.contains("--age") || args.contains("--sex")) {
    print("For body composition give all three: --height <cm> --age <years> --sex m|f")
    exit(2)
}

final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var last: [UInt8] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            print("Bluetooth not ready (state \(c.state.rawValue)); turn it on and allow this terminal under Privacy > Bluetooth.")
            return
        }
        // Duplicates are needed: the scale re-advertises the same address with changing data.
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        print("Scanning. Step on the scale (bare feet for impedance). Ctrl-C to stop.")
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        guard let all = ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let data = all[CBUUID(string: "181B")] else { return }
        let bytes = [UInt8](data)
        guard bytes != last else { return }
        last = bytes
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        guard let m = decode(bytes) else { return print("\(hex)  (overload or unexpected length \(bytes.count))") }
        let imp = m.impedance.map { "\($0) ohm" } ?? "-"
        let flags = (m.stabilized ? "stable" : "settling") + (m.removed ? ", stepped off" : "")
        print("\(hex)  \(String(format: "%.2f", m.weightKg)) kg  \(imp)  \(m.time) UTC  [\(flags)]  rssi \(rssi)")
        if let p = profile, m.stabilized, let z = m.impedance {
            print(body(weightKg: m.weightKg, heightCm: p.h, age: p.age, male: p.male, impedance: z).map(describe)
                ?? "  (weight, height, age or impedance outside the range the formulas accept)")
        }
    }
}

let scanner = Scanner()
RunLoop.main.run()
