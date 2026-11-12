# Xiaomi Mi Body Composition Scale 2 and Zepp Life: protocol and formulas

What the scale sends over Bluetooth, and how Zepp Life turns weight and impedance into body fat, muscle, water and the rest.

Everything here was read out of the Zepp Life Android app without running it (decompiled Java, disassembled native library). The record layout has since been confirmed on a real scale (section 3). The body-composition numbers have not yet been compared with what Zepp Life shows. Each section says what was read directly in the code, what is inferred, and what is still unknown.

## 1. Sources

| Item | Value |
|---|---|
| App | Zepp Life (`com.xiaomi.hm.health`) 6.17.0, versionCode 50852 |
| Bundle | `apk/zepp-life-6.17.0.apkm`, SHA-256 `c25ab680c09481aba1664caea9fc47e58bf85e2dc8175f7b18c26d5f1c1ea912` |
| Base APK | `apk/bundle/base.apk`, SHA-256 `9cd3e6478abd8df85be7d8453b61aa34684104de692178bbeea5423434a787ba` |
| Signing | v2 and v3 signers declare certificate SHA-256 `b145a7cb364e812592115efcb1e3a8bc7b5645c570493cb90a075c3593dc2acb` (the Huami certificate). REA evidence `ev_7e681b5601305d9077fa0e26bca88a73c7a5005e343983ee505cb7f0b74583db`, parent `ev_cc3b18b4b0a78eb92139492109c23777a309c930360f50131c8c44300fa55ce6`. This is the identity the file declares, not a trust verdict. |
| Formula library | `apk/lib/arm64-v8a/libBodyfat.so`, SHA-256 `f9f928430dd42056a634a575a84c4de228996a033f443341c0608b7b8033f658`; disassembly in `apk/libBodyfat.asm` |
| Not analysed | `libhtBodyfatBia4TwoLegs.so` (SHA-256 `8fc02562…7efe494`): used for a different scale, see section 6 |

The app is obfuscated. Class names below are the obfuscated ones, with the original file name JADX recovered in brackets.

| Class | Original file | Role |
|---|---|---|
| `zg0` | — | Splits a scan result into AD structures and routes service data by UUID |
| `bac0` | WeightBfsProfile.java | This scale's profile: record parser, GATT UUIDs, config writes |
| `z9c0` | WeightBaseProfile.java | Shared scale profile: vendor UUIDs, time write |
| `ihj`, `jhj` | HMWeightSyncDataProfile.java | History download |
| `gl4`, `cm4` | — | Picks the algorithm and builds the result map |
| `ckj` | HTPeopleGeneral.java | Java wrapper around `libBodyfat.so` |
| `l09` | — | Body age, protein, standard weight (Java) |
| `xec0` | WeightUnitUtils.kt | Unit conversion |

## 2. Advertisement

Read in `zg0`. The scale (BLE name `MIBFS`) puts each measurement in a Service Data AD structure (type 0x16) under the 16-bit UUID **0x181B** (Body Composition). The payload after the two UUID bytes is the 13-byte record of section 3. No connection or pairing is needed to read it.

The same code routes two other UUIDs to other parsers: 0xFEE0 (a different scale) and 0x181D (the original Mi Scale, a 10-byte record with weight only). Those are out of scope.

## 3. The 13-byte measurement record

Read in `bac0.o000o00O`. The same parser handles advertisements, GATT notifications and history records.

| Byte | Content |
|---|---|
| 0 | Flags A. bit 0: unit is lbs. bit 2: "part" flag (meaning unknown) |
| 1 | Flags B. bit 1: impedance present. bit 5: weight stable. bit 6: unit is jin (catty). bit 7: "finish" flag |
| 2–3 | Year, little-endian |
| 4, 5 | Month, day |
| 6, 7, 8 | Hour, minute, second |
| 9–10 | Impedance in ohms, little-endian |
| 11–12 | Weight, little-endian |

- **Weight**: raw ÷ 200 = kg when neither unit bit is set. With a unit bit set, raw ÷ 100 is the value in that unit. The jin bit is tested before the lbs bit.
- **Conversion to kg** (`xec0`): divide by 2.20462 for lbs, by 2.0 for jin, then round half-up to 2 decimals.
- **Overload**: raw weight 0xFFF0 means the scale is overloaded.
- **Impedance** is only meaningful when bit 1 of byte 1 is set. It arrives a few seconds after the weight stabilises and needs bare feet.
- **Bit 7 of byte 1** is named `FINISH_MASK` in the app. Community projects describe it as "weight removed". The capture below fits both: it is set once the load is gone, and on the final result the scale keeps advertising afterwards.
- **Timestamp**: the app reads it as UTC (`Calendar` built with `GMT+00:00`). In the capture the scale's clock was one hour behind the Mac's CET clock, which fits.

Worked example: `02 22 ea 07 0b 0b 15 32 00 f4 01 98 3a` is kg, stable, impedance present, 2026-11-11 21:50:00, 500 Ω, 15000 ÷ 200 = 75.00 kg.

### Capture from a real scale (2026-11-11)

Taken with the reader script of section 10. Weight and impedance bytes were replaced with made-up values for publication; everything else is as captured.

    02 a6 ea 07 0b 0b 14 2f 37 00 02 60 40    82.40 kg  512 Ω  20:47:55   stable, impedance, finish
    02 04 ea 07 0b 0b 14 36 0d 00 00 38 40    82.20 kg         20:54:13   settling
    02 04 ea 07 0b 0b 14 36 0f 00 00 d4 3f    81.70 kg         20:54:15   settling
    ...
    02 04 ea 07 0b 0b 14 36 13 00 00 32 23    45.05 kg         20:54:19   settling
    02 84 ea 07 0b 0b 14 36 13 00 00 b2 02     3.45 kg         20:54:19   finish

What it shows:

- Length, weight scaling, date and flag positions decode to sensible values, so the layout holds on real hardware.
- The first line is the previous completed weigh-in. The scale keeps advertising its last result, so a reader sees it as soon as it starts. Check the timestamp before trusting a line as new.
- The second weigh-in never reached "stable" (the weight moved by about a kilogram for six seconds), so the scale sent no impedance for it.
- Byte 0 was `02` and bit 2 of byte 1 was set in every packet. The app's parser reads neither bit; their meaning is unknown.

## 4. GATT

Read in `bac0` and `z9c0`. Vendor UUIDs use the base `0000XXXX-0000-3512-2118-0009af100700`.

| UUID | Use |
|---|---|
| Service `181B` | Body Composition |
| `2A9C` | Measurement notifications: same 13-byte record |
| `2A2B` | Current time, 10 bytes: year LE (2), month, day, hour, minute, second, day of week, 0, 0 |
| `2A9E` | Standard characteristic, referenced; use not traced |
| Vendor service `1530` | Vendor service |
| Vendor `1542` | Configuration writes and their acknowledgements |
| Vendor `1543` | Referenced; use unknown |
| Vendor `2A2F` | History download (section 5) |

Configuration writes seen on `1542`:

| Bytes | What is known |
|---|---|
| `06 04 00 <unit>` | Inferred: set the display unit (matches what openScale documents) |
| `06 0A 00 00` / `06 0B 00 00` | Called "set user mode" in the app |
| `06 05 00 00`, `06 0F 00 00`, `06 11 00 00`, `06 12 00 00`, `06 10 00 <0 or 1>`, `04 02`, `04 03`, `04 01`, `04 04` | Sent by the app; meaning unknown |

An acknowledgement is at least 5 bytes: `10 <group> <id> ?? 01`. The app also reads a 16-bit little-endian "mode" value from `1542` and compares it with 3.

## 5. History download

Read in `ihj`. Runs on vendor characteristic `2A2F` of service `181B`. The app passes a 4-byte little-endian id; where it comes from was not traced (community projects use a fixed per-phone value).

1. Write `01 <id, 4 bytes>`. Reply: `01 <count, 2 bytes LE>`. Count 0 means nothing stored.
2. Enable notifications, write `02`. Each notification is one or more 13-byte records back to back. A notification of 1 byte or less ends the transfer.
3. Write `03`. If the number of records received equals the count, write `04 <id, 4 bytes>`. Inferred: this confirms receipt so the scale can drop the records.
4. Disable notifications.

## 6. Which formulas the app uses

Read in `gl4.OooO0Oo`, called from `cm4`. The app picks the algorithm from a device-source number:

| Source | Device | Algorithm |
|---|---|---|
| 101, 102 | Body composition scales (102 = `WEIGHT_BFS`, this scale's profile) | Holtek `libBodyfat.so` (sections 7–8) |
| 104 | Amazfit scale | `libhtBodyfatBia4TwoLegs.so` (not analysed) |
| anything else | — | no body composition |

That this scale maps to source 102 is inferred from the profile class name and the enum; the path from a scanned device to that number was not followed end to end.

## 7. Formulas in `libBodyfat.so`

Inputs: weight `w` (kg), height `h` (cm), `age` (years), sex (1 = male, 0 = female), impedance `z` (Ω). Addresses are function offsets in the arm64 library.

**Input check** (`NN`, 0x12c8). The library refuses the measurement unless 90 ≤ h ≤ 220, 10 < w < 200, 6 ≤ age ≤ 99 and 50 ≤ z ≤ 3000. Impedance is then clamped to 200…1200.

**Lean mass term** (`getlbmCoefficient`, 0x1200)

    lbm = (h × 9.058 / 100) × h / 100 + 12.226 + w × 0.32 − z × 0.0068 − age × 0.0542

**Body fat %** (`CC`, 0x1608)

    c = lbm − 0.8                    male
    c = lbm − 9.25                   female, age ≤ 49
    c = lbm − 7.25                   female, age > 49

    male:    if w < 61   c = c × 0.98
    female:  if w < 50   c = c × 1.02
             if w > 60   c = c × 0.96
             if h > 160  c = c × 1.03

    fat% = (1 − c / w) × 100         clamped to 5…75

The three female adjustments are applied one after another, not nested. Every woman taller than 160 cm gets the ×1.03, whatever her weight.

**Water %** (`HH`, 0x1dc0)

    x = (100 − fat%) × 0.7
    water% = x × 0.98 if x > 50, else x × 1.02      clamped to 35…75

**Bone mass, kg** (`DD`, 0x1820)

    b = lbm × 0.05158 − 0.18016894 (male) or − 0.245691014 (female)
    b = b + 0.1 if b > 2.2, else b − 0.1            clamped to 0.5…8

**Muscle mass, kg** (`FF`, 0x19c8)

    muscle = w − fat% × 0.01 × w − bone             clamped to 10…120

**Visceral fat** (`GG`, 0x1b80)

    male,   h < 1.6 w + 63:   305 w / (0.0826 h² − 0.4 h + 48) − 2.9 + 0.15 age
    male,   otherwise:        w (0.765 − 0.0015 h) − 0.143 h + 0.15 age − 5
    female, w ≤ 0.5 h − 13:   w (0.691 − 0.0024 h) − 0.027 h + 0.07 age − 10.5
    female, otherwise:        500 w / (0.1158 h² + 1.45 h − 120) − 6 + 0.07 age

Clamped to 1…50; the app truncates to a whole number.

**BMR, kcal** (`BB`, 0x1420)

    male:    877.8 + 14.916 w − 0.726 h − 8.976 age
    female:  864.6 + 10.2036 w − 0.39336 h − 6.204 age

Clamped to 500…10000; the app truncates to a whole number.

**BMI** (`EE`, 0x13b0): w / (h/100)², clamped to 10…90.

**Ideal weight** (`QQ`, 0xf40): 22 × h² / 10000. Computed but not put in the app's result map.

### Added by the app in Java (`l09`)

These use the raw impedance (not clamped) and the height cut to a whole number.

    body age, male:    −0.7471 h + 0.9161 w + 0.4184 age + 0.0517 z + 54.2267
    body age, female:  −1.1165 h + 1.5784 w + 0.4615 age + 0.0415 z + 83.2548
                       clamped to 15…80, then truncated

    protein %        = muscle / w × 100 − water%        clamped to 5…32
    standard weight  = (h − 80) × 0.7 male, (h − 70) × 0.6 female

## 8. Rating thresholds in the library

Whether the app shows these native ratings or its own ranges was not traced. The band names were not recovered, only the boundaries.

| Metric | Boundaries |
|---|---|
| BMI | 18.5, 25, 30 |
| Water % | 53, 67 |
| Visceral fat | 10, 15 |
| BMR | compared with w × k. Male k: 36 (age ≤ 12), 30 (≤ 15), 26 (≤ 17), 23 (≤ 29), 21 (≤ 49), 20 (older). Female k: 34, 29, 24, 22, 20, 19 |
| Bone, male | w < 60: 1.5–3.5; w < 75: 1.9–3.9; heavier: 2.2–4.2 |
| Bone, female | w < 45: 0.8–2.8; w < 60: 1.2–3.2; heavier: 1.5–3.5 |
| Muscle, male | h < 160: 38.5–46.5; h < 170: 44–52.4; taller: 49.5–59.4 |
| Muscle, female | h < 160: 29.1–34.7; h < 170: 32.9–37.5; taller: 36.5–42.5 |

**Body fat %**: four boundaries per age row. Under 18 the row is the age itself; 18–39 use row 18, 40–59 row 19, 60 and over row 20.

| Row | Female | Male |
|---|---|---|
| 6 | 8, 16, 25, 29 | 7, 16, 25, 30 |
| 7 | 9, 17, 25, 30 | 7, 16, 25, 30 |
| 8 | 10, 18, 26, 31 | 7, 16, 26, 30 |
| 9 | 10, 19, 28, 32 | 7, 16, 26, 30 |
| 10 | 11, 20, 29, 33 | 7, 16, 26, 30 |
| 11 | 13, 22, 31, 35 | 7, 16, 26, 30 |
| 12 | 14, 23, 32, 36 | 7, 16, 25, 30 |
| 13 | 15, 25, 34, 38 | 7, 16, 25, 30 |
| 14 | 17, 26, 35, 39 | 7, 15, 25, 29 |
| 15 | 18, 27, 36, 41 | 8, 15, 24, 29 |
| 16 | 19, 28, 37, 41 | 8, 16, 24, 28 |
| 17 | 20, 28, 37, 41 | 9, 16, 23, 28 |
| 18 (18–39) | 21, 28, 35, 40 | 11, 17, 22, 27 |
| 19 (40–59) | 22, 29, 36, 41 | 12, 16, 23, 28 |
| 20 (60+) | 23, 30, 37, 42 | 14, 16, 25, 30 |

## 9. Differences from the community ports

Compared with the widely copied Python and openScale implementations:

- The female ×1.03 for height over 160 cm applies independently of the weight conditions (section 7). Ports that nest it give a lower body fat for women between 50 and 60 kg taller than 160 cm.
- BMR has no extra age-dependent caps; only the 500…10000 clamp.
- The male body-fat rating rows 19 and 20 differ from the tables in those ports. The values above are the ones in this library's data section.

## 10. The reader script

[scale.swift](scale.swift) listens for the advertisement, decodes the record and applies the formulas of section 7. It needs no pairing and never connects to the scale.

Run it from the macOS Terminal app (macOS only grants Bluetooth to an app that asked for it; the first run shows the permission prompt):

    swift scale.swift --height 175 --age 35 --sex m

Without the three options it prints weight and impedance only. `swift scale.swift --selftest` checks the decoder and the formulas against values worked out by hand from this report.

Known gaps:

- Decoding works on a real scale (section 3). The body-composition output has not yet been compared with Zepp Life for the same weigh-in.
- For lbs it multiplies by 0.45359237 instead of dividing by 2.20462 and rounding to 2 decimals as the app does. The difference is under 0.01 kg.
- It does not download history or write the clock.

## 11. What is still unknown

- Meaning of most configuration commands on `1542`, and the purpose of `1543`.
- Origin of the 4-byte id used in the history download.
- Meaning of the "part" flag (byte 0 bit 2), and of byte 0 bit 1 and byte 1 bit 2, which were always set in the capture.
- How a scanned device ends up as source 102.
- Whether Zepp Life's numbers on screen match these formulas to the last digit. Comparing one real weigh-in between the app and the script would settle it.
