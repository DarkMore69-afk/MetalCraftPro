import SwiftUI
import SwiftData

struct ProfileCatalogView: View {
    @Query(sort: \MCProfile.name) private var profiles: [MCProfile]
    @Environment(\.dismiss) private var dismiss
    @Environment(LocalStore.self) private var store
    var onSelect: ((MCProfile) -> Void)? = nil
    /// Mit Projekt: zusätzlich die lokale Materialdatenbank (Werkstoff, Oberfläche, Preis).
    var project: MCProject? = nil
    @State private var search = ""
    @State private var custom = false
    @State private var showAddMaterial = false
    @State private var editingMaterial: MCMaterial?
    private var filtered: [MCProfile] {
        profiles.filter { search.isEmpty || $0.name.localizedStandardContains(search) || ($0.spec?.type.displayName.localizedStandardContains(search) ?? false) }
    }
    var body: some View {
        List {
            Section {
                Text("Lokale Profile · Maße in mm. Querschnitt und Stahlgewicht werden aus idealisierten, scharfkantigen Geometrien berechnet; keine zertifizierten Walzprofiltabellen.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let project { materialsSection(project) }
            if !filtered.filter(\.isCustom).isEmpty {
                Section("Eigene Profile") {
                    ForEach(filtered.filter(\.isCustom)) { profile in profileRow(profile) }
                }
            }
            ForEach(ProfileType.allCases) { type in
                let entries = filtered.filter { !$0.isCustom && $0.typeName == type.rawValue }
                if !entries.isEmpty {
                    Section(type.displayName) { ForEach(entries) { profile in profileRow(profile) } }
                }
            }
            if filtered.isEmpty { ContentUnavailableView.search(text: search) }
        }
        .searchable(text: $search, prompt: "Profil suchen")
        .navigationTitle(project == nil ? "Profilkatalog" : "Material & Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { custom = true } label: { Image(systemName: "plus") }.accessibilityLabel("Eigenes Profil")
            }
        }
        .sheet(isPresented: $custom) { CustomProfileSheet() }
        .sheet(isPresented: $showAddMaterial) {
            if let project { AddMaterialSheet(project: project) }
        }
        .sheet(item: $editingMaterial) { material in
            EditMaterialPriceSheet(material: material)
                .environment(store)
                .presentationDetents([.medium])
        }
    }

    // MARK: Materialdatenbank

    @ViewBuilder private func materialsSection(_ project: MCProject) -> some View {
        Section("Materialien") {
            ForEach(project.materials) { material in
                materialRow(material)
            }
            .onDelete { indexSet in
                let ids = indexSet.map { project.materials[$0].id }
                for id in ids {
                    if let material = project.materials.first(where: { $0.id == id }) {
                        try? store.removeMaterial(material)
                    }
                }
            }
            Button { showAddMaterial = true } label: {
                Label("Material hinzufügen", systemImage: "plus.circle.fill")
            }.tint(Theme.accent)
        }
    }

    private func materialRow(_ material: MCMaterial) -> some View {
        Button { editingMaterial = material } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(material.resolvedName).font(.headline)
                    Spacer()
                    if let price = material.pricePerKg {
                        Text("\(DeFormat.number(price, maxFractionDigits: 2)) €/kg")
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.accent)
                    } else {
                        Text("Preis offen").font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
                }
                Text(materialRowDetail(material)).font(.caption).foregroundStyle(.secondary)
                Text("ca. \(DeFormat.number(material.resolvedWeightPerMeter, maxFractionDigits: 3)) kg/m")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(material.resolvedName), \(material.pricePerKg.map { "\(DeFormat.number($0, maxFractionDigits: 2)) Euro pro Kilogramm" } ?? "kein Preis"), Preis bearbeiten")
    }

    private func materialRowDetail(_ material: MCMaterial) -> String {
        let grade = material.resolvedGrade.isEmpty ? "Werkstoff offen" : material.resolvedGrade
        let surface = material.surface.isEmpty ? "ohne Oberflächenangabe" : material.surface
        return "\(grade) · \(surface)"
    }

    // MARK: Profile

    @ViewBuilder private func profileRow(_ profile: MCProfile) -> some View {
        if let onSelect {
            Button { onSelect(profile); dismiss() } label: { profileLabel(profile) }.buttonStyle(.plain)
        } else { profileLabel(profile) }
    }
    private func profileLabel(_ profile: MCProfile) -> some View {
        HStack(spacing: 14) {
            Image(systemName: profile.spec?.type.iconSystemName ?? "square").font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.name).font(.headline)
                if let spec = profile.spec {
                    Text(profileRowDetail(spec)).font(.caption).foregroundStyle(.secondary)
                    Text("\(DeFormat.number(spec.crossSectionAreaMm2)) mm² · ca. \(DeFormat.number(spec.weightPerMeterKg, maxFractionDigits: 3)) kg/m")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if onSelect != nil { Image(systemName: "plus.circle").foregroundStyle(Theme.accent) }
        }.padding(.vertical, 6).frame(minHeight: 64).contentShape(Rectangle())
    }

    private func profileRowDetail(_ spec: ProfileSpec) -> String {
        let dimensions = "\(spec.type.displayName) · \(spec.dimensionLabel)"
        guard spec.thicknessMm > 0, spec.type != .rundstahl else { return dimensions }
        return dimensions + " · Wand \(DeFormat.number(spec.thicknessMm)) mm"
    }
}

/// Material anlegen: Werkstoff, Oberfläche und optionaler Preis; das Gewicht
/// folgt dem Projekprofil (immer aktuell, keine zweite Kopie).
struct AddMaterialSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject
    @State private var name = ""
    @State private var grade = ""
    @State private var surface = ""
    @State private var price = ""
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Material") {
                    TextField("Bezeichnung (z. B. Rahmenprofil)", text: $name)
                    TextField("Werkstoff (z. B. S235)", text: $grade)
                    TextField("Oberfläche (z. B. verzinkt, roh)", text: $surface)
                    TextField("Preis pro kg (optional)", text: $price)
                        .keyboardType(.decimalPad)
                }
                Section {
                    LabeledContent("Profil", value: project.profileSpec.dimensionLabel)
                    LabeledContent("Gewicht pro Meter", value: "ca. \(DeFormat.number(project.profileSpec.weightPerMeterKg, maxFractionDigits: 3)) kg/m")
                    Text("Das Gewicht folgt dem Projekprofil und wird nie kopiert.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Projektbezug") }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .navigationTitle("Material hinzufügen").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { save() } }
            }
        }
    }
    private func save() {
        let parsedPrice = price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : DeFormat.parse(price)
        if price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, parsedPrice == nil {
            problem = "Bitte gib einen gültigen Preis ein."; return
        }
        do {
            try store.addMaterial(project, name: name, grade: grade, surface: surface, pricePerKg: parsedPrice)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

struct EditMaterialPriceSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let material: MCMaterial
    @State private var price = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Materialpreis") {
                    LabeledContent("Material", value: material.resolvedName)
                    LabeledContent("Werkstoff", value: material.resolvedGrade.isEmpty ? "Nicht angegeben" : material.resolvedGrade)
                    HStack {
                        Text("Preis pro kg")
                        TextField("EUR/kg", text: $price)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("€/kg").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Der Preis wird mit dem errechneten Stahlgewicht der passenden Positionen multipliziert.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if material.pricePerKg != nil {
                        Button("Preis entfernen", role: .destructive) { save(nil) }
                    }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .navigationTitle("Preis pro kg").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { saveEnteredPrice() } }
            }
            .onAppear {
                if let value = material.pricePerKg { price = DeFormat.number(value, maxFractionDigits: 6) }
            }
        }
    }

    private func saveEnteredPrice() {
        let cleaned = price.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let value = DeFormat.parse(cleaned), value >= 0 else {
            problem = "Bitte gib einen gültigen Preis ab 0 € pro kg ein."
            return
        }
        save(value)
    }

    private func save(_ value: Double?) {
        do {
            try store.setMaterialPrice(material, pricePerKg: value)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

struct CustomProfileSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var type = ProfileType.vierkantrohr
    @State private var name = ""
    @State private var height = "40"
    @State private var width = "40"
    @State private var thickness = "2"
    @State private var web = "2"
    @State private var problem: String?
    private var round: Bool { type == .rundrohr || type == .rundstahl }
    private var symmetric: Bool { round || type == .vierkantrohr }
    private var flat: Bool { type == .flachstahl || type == .blech }
    private var hasWeb: Bool { [.uProfil, .tProfil, .hProfil, .iProfil].contains(type) }
    private var specification: ProfileSpec? {
        guard let h = DeFormat.parse(height), let w = DeFormat.parse(width), let t = DeFormat.parse(thickness), let s = DeFormat.parse(web) else { return nil }
        let spec = ProfileSpec(type: type, name: name.trimmingCharacters(in: .whitespacesAndNewlines), heightMm: flat ? w : h, widthMm: symmetric ? h : w, thicknessMm: type == .rundstahl ? 0 : t, webThicknessMm: hasWeb ? s : 0, isCustom: true)
        return (try? spec.validate()) != nil ? spec : nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Eigenes Profil") {
                    TextField("Bezeichnung", text: $name)
                    Picker("Profiltyp", selection: $type) {
                        ForEach(ProfileType.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Abmessungen · mm") {
                    if !flat { field(round ? "Durchmesser" : "Höhe", text: $height) }
                    if !symmetric { field("Breite", text: $width) }
                    if type != .rundstahl { field(hasWeb ? "Flanschdicke" : "Dicke / Wandstärke", text: $thickness) }
                    if hasWeb { field("Stegdicke", text: $web) }
                }
                if let spec = specification {
                    Section("Berechneter Querschnitt") {
                        LabeledContent("Fläche", value: "\(DeFormat.number(spec.crossSectionAreaMm2)) mm²")
                        LabeledContent("Stahlgewicht", value: "ca. \(DeFormat.number(spec.weightPerMeterKg, maxFractionDigits: 3)) kg/m")
                        Text("Idealisiert, ohne Radien · Dichte 7,85 g/cm³").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .navigationTitle("Eigenes Profil").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { save() } }
            }
        }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack { Text(label); TextField("mm", text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
    }
    private func save() {
        guard var spec = specification else { problem = "Abmessungen ungültig. Prüfe Wandstärke, Flansche und Steg; alle Werte müssen endlich und positiv sein."; return }
        if spec.name.isEmpty { spec.name = "\(spec.type.displayName) \(spec.dimensionLabel)" }
        do { try store.addProfile(spec); dismiss() } catch { problem = error.localizedDescription }
    }
}
