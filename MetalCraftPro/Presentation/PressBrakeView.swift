//
//  PressBrakeView.swift
//  MetalCraftPro
//
//  Blechzuschnitt calculator and suggested press-brake bend order.
//

import SwiftUI

struct PressBrakeView: View {
    @Environment(\.dismiss) private var dismiss
    let project: MCProject

    @State private var legsText = "100; 80; 100"
    @State private var anglesText = "90; 90"
    @State private var sheetWidthText = "1000"
    @State private var thicknessText = "1.5"
    @State private var radiusText = "1.4"
    @State private var kFactorText = "0.42"
    @State private var vOpeningText = "9"

    private var input: PressBrakeInput? {
        guard let legs = parseList(legsText), legs.count >= 2,
              let width = DeFormat.parse(sheetWidthText),
              let thickness = DeFormat.parse(thicknessText),
              let radius = DeFormat.parse(radiusText),
              let k = DeFormat.parse(kFactorText),
              let v = DeFormat.parse(vOpeningText),
              let enteredAngles = parseList(anglesText) else { return nil }
        let bendCount = legs.count - 1
        let angles: [Double]
        if enteredAngles.count == 1 {
            angles = Array(repeating: enteredAngles[0], count: bendCount)
        } else if enteredAngles.count == bendCount {
            angles = enteredAngles
        } else {
            return nil
        }
        return PressBrakeInput(legLengthsMm: legs, bendAnglesDeg: angles,
                               sheetWidthMm: width, thicknessMm: thickness,
                               insideRadiusMm: radius, kFactor: k, vOpeningMm: v)
    }

    private var calculation: PressBrakeResult? {
        guard let input else { return nil }
        return try? PressBrakeCalculator.calculate(input)
    }

    private var validationMessage: String? {
        guard let input else {
            return "Eingaben prüfen: Flansche mit Semikolon trennen; ein Winkel gilt für alle Biegungen."
        }
        do {
            _ = try PressBrakeCalculator.calculate(input)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    inputCard
                    if let calculation {
                        resultCard(calculation)
                    } else {
                        Label(validationMessage ?? "Eingaben prüfen.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(Theme.accent)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.card(cornerRadius: 16))
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
        .background(Theme.appBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            let profile = project.profileSpec
            if profile.type == .blech, profile.thicknessMm > 0 {
                thicknessText = DeFormat.number(profile.thicknessMm)
                let opening = PressBrakeCalculator.recommendedVOpening(forThicknessMm: profile.thicknessMm)
                vOpeningText = DeFormat.number(opening)
                radiusText = DeFormat.number(max(0.1, opening * 0.16))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 32)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).tint(.white)
            .accessibilityLabel("Zurück")
            VStack(alignment: .leading, spacing: 3) {
                Text("Kantbank · Blechzuschnitt").font(.headline)
                Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profil und Werkzeugeingaben").font(.headline)
            Text("Flansche als Außenmaße ab theoretischen Ecken eingeben. Beispiel U-Profil: 100; 80; 100 mm.")
                .font(.caption).foregroundStyle(.secondary)
            field("Flanschmaße", text: $legsText, prompt: "100; 80; 100", unit: "mm", keyboard: .numbersAndPunctuation)
            field("Biegewinkel je Knick", text: $anglesText, prompt: "90; 90", unit: "°", keyboard: .numbersAndPunctuation)
            Text("Winkel ab flachem Blech; ein Wert wird für alle Knicke verwendet.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            field("Blechbreite entlang der Biegelinie", text: $sheetWidthText, prompt: "1000", unit: "mm", keyboard: .decimalPad)
            field("Blechdicke", text: $thicknessText, prompt: "1,5", unit: "mm", keyboard: .decimalPad)
            field("Innenradius", text: $radiusText, prompt: "1,4", unit: "mm", keyboard: .decimalPad)
            field("K-Faktor", text: $kFactorText, prompt: "0,42", unit: "", keyboard: .decimalPad)
            field("V-Öffnung", text: $vOpeningText, prompt: "9", unit: "mm", keyboard: .decimalPad)
        }
        .padding(14).background(Theme.card(cornerRadius: 18))
    }

    private func field(_ title: String, text: Binding<String>, prompt: String,
                       unit: String, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            TextField(prompt, text: text)
                .keyboardType(keyboard).multilineTextAlignment(.trailing)
                .font(.subheadline.monospacedDigit())
                .frame(width: 132)
                .accessibilityLabel(title)
            if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .leading) }
        }
        .padding(.vertical, 4)
    }

    private func resultCard(_ result: PressBrakeResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Abwicklung").font(.headline)
            Text("\(DeFormat.number(result.flatLengthMm)) × \(DeFormat.number(result.flatWidthMm)) mm")
                .font(.title2.weight(.bold)).monospacedDigit().minimumScaleFactor(0.75)
            Text("Zuschnittmaß · Länge × Blechbreite")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                metric("Fläche", "\(DeFormat.number(result.blankAreaM2, maxFractionDigits: 3)) m²")
                Spacer()
                metric("Biegezugabe", "\(DeFormat.number(result.totalBendAllowanceMm)) mm")
                Spacer()
                metric("Biegeverkürzung", "\(DeFormat.number(result.totalBendDeductionMm)) mm")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Biegevorschlag").font(.headline)
                Text(result.bendOrder.map(String.init).joined(separator: " → "))
                    .font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.accent)
                Text(result.sequenceNote).font(.caption).foregroundStyle(.secondary)
                ForEach(result.bends) { bend in
                    HStack {
                        Text("Knick \(bend.number) · \(DeFormat.number(bend.angleDeg))°")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("BA \(DeFormat.number(bend.bendAllowanceMm)) · BD \(DeFormat.number(bend.bendDeductionMm)) mm")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Text("V-Öffnung eingetragen: \(DeFormat.number(Double(vOpeningText) ?? 0)) mm")
                Spacer()
                Text("Richtwert: \(DeFormat.number(result.recommendedVOpeningMm)) mm")
            }
            .font(.caption).foregroundStyle(.secondary)
            Text("Radius und K-Faktor im Ergebnis prüfen und mit Musterkantung bzw. Maschinenwerten abstimmen.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14).background(Theme.card(cornerRadius: 18))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
    }

    private func parseList(_ text: String) -> [Double]? {
        let tokens = text.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !tokens.isEmpty, !tokens.contains(where: { $0.isEmpty }) else { return nil }
        let values = tokens.compactMap(DeFormat.parse)
        return values.count == tokens.count ? values : nil
    }
}
