import SwiftUI
import SwiftData

struct BasicCalculatorView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case diagonal = "Pythagoras", inner = "Rahmen-Innenmaß", profile = "Profilgewicht", plate = "Blechgewicht"
        var id: String { rawValue }
    }
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MCProfile.name) private var profiles: [MCProfile]
    @State private var mode = Mode.diagonal
    @State private var a = "1200"
    @State private var b = "800"
    @State private var thickness = "2"
    @State private var density = "7,85"
    @State private var profileID = ProfileCatalog.squareTube40x40x2.id
    private var formula: String {
        switch mode {
        case .diagonal: return "c = √(a² + b²)"
        case .inner: return "Innenmaß = Außenmaß − 2 × Profilbreite"
        case .profile: return "kg = Länge (m) × Querschnitt (mm²) × Dichte / 1000"
        case .plate: return "kg = Fläche (m²) × Dicke (mm) × Dichte (g/cm³)"
        }
    }
    private var result: Result<Double, Error> {
        Result {
            guard let x = DeFormat.parse(a) else { throw GeometryError.nonFiniteValue }
            switch mode {
            case .diagonal:
                guard let y = DeFormat.parse(b) else { throw GeometryError.nonFiniteValue }
                return try CalculationEngine.pythagoras(a: x, b: y)
            case .inner:
                guard let y = DeFormat.parse(b) else { throw GeometryError.nonFiniteValue }
                return try CalculationEngine.frameInnerMeasure(outerMm: x, profileWidthMm: y)
            case .profile:
                guard let spec = profiles.first(where: { $0.id == profileID })?.spec,
                      let rho = DeFormat.parse(density) else { throw GeometryError.nonFiniteValue }
                return try CalculationEngine.profileWeight(lengthMm: x, profile: spec, densityGCm3: rho)
            case .plate:
                guard let y = DeFormat.parse(b), let t = DeFormat.parse(thickness), let rho = DeFormat.parse(density) else { throw GeometryError.nonFiniteValue }
                return try CalculationEngine.plateWeight(lengthMm: x, widthMm: y, thicknessMm: t, densityGCm3: rho)
            }
        }
    }
    var body: some View {
        Form {
            Section {
                Picker("Berechnung", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
            }
            Section("Eingaben") {
                input(mode == .inner ? "Außenmaß (mm)" : mode == .diagonal ? "Kathete a (mm)" : "Länge (mm)", text: $a)
                if mode != .profile {
                    input(mode == .inner ? "Profilbreite (mm)" : mode == .diagonal ? "Kathete b (mm)" : "Breite (mm)", text: $b)
                }
                if mode == .plate { input("Dicke (mm)", text: $thickness) }
                if mode == .profile {
                    Picker("Profil", selection: $profileID) {
                        ForEach(profiles) { Text("\($0.spec?.type.displayName ?? "") \($0.name)").tag($0.id) }
                    }
                }
                if mode == .profile || mode == .plate { input("Dichte (g/cm³)", text: $density) }
            }
            Section("Ergebnis") {
                switch result {
                case .success(let value):
                    Text("\(DeFormat.number(value, maxFractionDigits: 3)) \(mode == .profile || mode == .plate ? "kg" : "mm")")
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent).monospacedDigit().minimumScaleFactor(0.5)
                case .failure:
                    Label("Bitte prüfe die Eingaben. Nur endliche, gültige Maße sind zulässig.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                }
                Text(formula).font(.footnote.monospaced()).foregroundStyle(.secondary)
                if mode == .profile { Text("Idealisiertes Profil ohne Eckradien; Gewicht ist ein Näherungswert.").font(.caption).foregroundStyle(.secondary) }
            }
            Section { Label("Deterministisch berechnet · vollständig offline", systemImage: "checkmark.shield").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Grundrechner").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        .onChange(of: mode) { _, newMode in b = newMode == .inner ? "40" : "800" }
    }
    private func input(_ title: String, text: Binding<String>) -> some View {
        HStack { Text(title); TextField(title, text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
    }
}
