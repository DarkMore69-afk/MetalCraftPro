import SwiftUI

struct MaterialCostView: View {
    @Environment(LocalStore.self) private var store
    let project: MCProject
    @State private var purchasePartToEdit: MCPart?
    @State private var laborPartToEdit: MCPart?
    @State private var showLaborRateEditor = false
    @State private var showQuoteExport = false
    @State private var problem: String?

    private var estimate: MaterialCostEstimate { ExportBridge.materialCostEstimate(for: project) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                projectHeader
                totalCard
                cuttingCostSection
                Button { showQuoteExport = true } label: {
                    Label("Angebots-PDF erstellen", systemImage: "doc.text.image")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .foregroundStyle(.black)
                if !estimate.topPositions.isEmpty { topPositionsCard }
                positionsSection
                NavigationLink {
                    ProfileCatalogView(project: project)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "shippingbox.and.arrow.backward.fill")
                            .font(.system(size: 21, weight: .light))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 44, height: 46)
                            .background(Theme.card(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Materialpreise verwalten").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("€/kg in der lokalen Materialdatenbank").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(13)
                    .background(Theme.card())
                }
                .buttonStyle(.plain)

                Label("Lokale Schätzung ohne Gewähr. Profilgewichte sind idealisierte Berechnungen; Verschnitt nutzt den eingestellten Schnittplan. Bearbeitung, Beschichtung und Steuern sind nicht enthalten.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.appBackground)
        .navigationTitle("Materialkosten & Aufmaß")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: $showQuoteExport) {
            ExportView(project: project, initialExport: .quotePDF)
        }
        .sheet(item: $purchasePartToEdit) { part in
            PurchasePartPriceSheet(part: part)
                .environment(store)
                .presentationDetents([.medium])
        }
        .sheet(item: $laborPartToEdit) { part in
            LaborHoursSheet(part: part)
                .environment(store)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showLaborRateEditor) {
            LaborRateSheet(project: project)
                .environment(store)
                .presentationDetents([.medium])
        }
        .alert("Änderung nicht gespeichert", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(project.name).font(.title3.weight(.semibold))
            Text("\(project.number) · Revision \(project.revisionLabel)")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card())
    }

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("GESAMTSCHÄTZUNG", systemImage: "eurosign.circle")
                    .font(.caption.weight(.semibold)).tracking(1.1).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chart.bar.fill").foregroundStyle(Theme.accent.opacity(0.85))
            }
            Text(estimate.totalWithLaborEUR.map(EuroFormat.string) ?? "—")
                .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .minimumScaleFactor(0.7).lineLimit(1)
                .accessibilityLabel(estimate.totalWithLaborEUR.map { "Gesamtschätzung inklusive Arbeitskosten \(EuroFormat.string($0))" } ?? "Gesamtschätzung nicht verfügbar")
            VStack(spacing: 8) {
                costComponentRow("Material & Zukaufteile", amount: estimate.totalEUR)
                if let cuttingSummary = estimate.cuttingSummary, !cuttingSummary.profiles.isEmpty {
                    costComponentRow("Verschnittkosten", amount: cuttingSummary.wasteTotalEUR)
                }
                costComponentRow("Arbeitskosten", amount: estimate.laborTotalEUR)
            }
            Divider()
            HStack(spacing: 8) {
                summaryChip("\(estimate.pricedPositionCount) mit Preis", symbol: "checkmark.circle.fill", color: .green)
                summaryChip("\(estimate.unpricedPositionCount) offen", symbol: "circle.dashed", color: estimate.unpricedPositionCount == 0 ? .secondary : Theme.accent)
            }
            if estimate.unpricedPositionCount > 0 {
                Text("Positionen ohne Material- oder Stückpreis fehlen in der bekannten Zwischensumme.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if estimate.unpricedLaborPositionCount > 0 {
                Text("Für \(estimate.unpricedLaborPositionCount) Position(en) ist Arbeitszeit erfasst, aber noch kein Stundensatz hinterlegt.")
                    .font(.caption).foregroundStyle(Theme.accent)
            }
            Button { showLaborRateEditor = true } label: {
                HStack {
                    Label("Stundensatz", systemImage: "clock")
                    Spacer()
                    Text(project.laborRateEURPerHour.map { "\(EuroFormat.string($0)) / h" } ?? "Festlegen")
                        .fontWeight(.semibold)
                    Image(systemName: "pencil").font(.caption)
                }
                .font(.subheadline)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel(project.laborRateEURPerHour.map { "Stundensatz \(EuroFormat.string($0)) pro Stunde bearbeiten" } ?? "Stundensatz festlegen")
        }
        .padding(18)
        .background(Theme.card())
    }

    private func costComponentRow(_ title: String, amount: Double?) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(amount.map(EuroFormat.string) ?? "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private func summaryChip(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.1), in: Capsule())
    }

    private var topPositionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Größte Positionen").font(.headline)
            ForEach(Array(estimate.topPositions.enumerated()), id: \.element.id) { index, line in
                HStack(spacing: 11) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28, height: 28)
                        .background(Theme.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pos. \(line.positionNumber) · \(line.name)")
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(line.kind == .purchased ? "Zukaufteil" : line.detail)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(line.amountEUR.map(EuroFormat.string) ?? "—")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                if index < estimate.topPositions.count - 1 { Divider().padding(.leading, 39) }
            }
        }
        .padding(16)
        .background(Theme.card())
    }

    private var cuttingCostSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Stangen & Verschnitt").font(.headline)
                    Text("\(DeFormat.number(project.stockBarLengthMm ?? CuttingCostBuilder.defaultStockLengthMm)) mm Stange · \(DeFormat.number(project.sawKerfMm ?? CuttingCostBuilder.defaultKerfMm)) mm Schnittfuge")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                NavigationLink {
                    CutListView(project: project)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.glass)
                .tint(.white)
                .accessibilityLabel("Stangenlänge und Schnittfuge einstellen")
            }

            if let summary = estimate.cuttingSummary, !summary.profiles.isEmpty {
                ForEach(Array(summary.profiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profile.profileLabel + (profile.materialGrade.isEmpty ? "" : " · \(profile.materialGrade)"))
                            .font(.subheadline.weight(.semibold))
                        cuttingDetailRow("Einkaufsstangen", value: "\(profile.stockBarCount) × \(DeFormat.number(project.stockBarLengthMm ?? CuttingCostBuilder.defaultStockLengthMm)) mm", amount: profile.stockPurchaseEUR)
                        let remnantSummary = profile.reusableOffcutsMm.isEmpty
                            ? "Keine verwertbaren Reste"
                            : "\(profile.reusableOffcutsMm.count) Stück · " + profile.reusableOffcutsMm.map { "\(DeFormat.number($0)) mm" }.joined(separator: ", ")
                        cuttingDetailRow("Verwertbare Reststücke", value: remnantSummary)
                        cuttingDetailRow("Verschnitt", value: "\(DeFormat.number(profile.wasteMm)) mm", amount: profile.wasteCostEUR)
                        if profile.stockPurchaseEUR == nil {
                            Text("Kein eindeutiger Materialpreis für \(profile.materialGrade.isEmpty ? "den Werkstoff" : profile.materialGrade) hinterlegt.")
                                .font(.caption).foregroundStyle(Theme.accent)
                        }
                        if profile.overlongPieceCount > 0 {
                            Label("\(profile.overlongPieceCount) Teil(e) länger als die Stange", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Divider()
                HStack {
                    Text(estimate.cuttingSummary?.unpricedProfileCount == 0 ? "Verschnittkosten gesamt" : "Bepreiste Verschnittkosten")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(summary.wasteTotalEUR.map(EuroFormat.string) ?? "Nicht verfügbar")
                        .font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Theme.accent)
                }
                HStack {
                    Text(summary.unpricedProfileCount == 0 ? "Einkaufswert Stangen · Information" : "Bekannter Einkaufswert Stangen")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(summary.stockPurchaseTotalEUR.map(EuroFormat.string) ?? "—")
                        .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                }
                if summary.unpricedProfileCount > 0 {
                    Text("Für \(summary.unpricedProfileCount) Profil(e) ist kein eindeutiger €/kg-Preis hinterlegt; nicht bepreiste Kosten sind nicht in den Summen enthalten.")
                        .font(.caption).foregroundStyle(Theme.accent)
                }
                if summary.overlongPieceCount > 0 {
                    Text("Zu lange Teile brauchen eine längere Stange oder eine andere Aufteilung.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Noch keine Profilpositionen für die Stangenkalkulation.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Verschnittkosten sind der Materialwert nicht verwertbarer Reststücke. Der Einkaufswert der Stangen ist informativ und wird nicht zusätzlich zur Materialsumme addiert.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Theme.card())
    }

    private func cuttingDetailRow(_ title: String, value: String, amount: Double? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(.caption.monospacedDigit()).multilineTextAlignment(.trailing)
                if let amount {
                    Text(EuroFormat.string(amount)).font(.caption.weight(.semibold).monospacedDigit())
                } else if title == "Verschnitt" || title == "Einkaufsstangen" {
                    Text("Preis fehlt").font(.caption2).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var positionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Positionen").font(.headline)
                Spacer()
                Text("\(estimate.lines.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if estimate.lines.isEmpty {
                ContentUnavailableView("Noch keine kalkulierbaren Positionen", systemImage: "shippingbox", description: Text("Bauteile und Zukaufteile erscheinen hier automatisch aus dem Projekt."))
                    .frame(minHeight: 210)
            } else {
                VStack(spacing: 1) {
                    ForEach(estimate.lines) { line in
                        costRow(line)
                        if line.id != estimate.lines.last?.id { Divider().padding(.leading, 16) }
                    }
                }
                .background(Theme.card())
            }
        }
    }

    private func costRow(_ line: MaterialCostLine) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: line.kind == .purchased ? "shippingbox" : "cube")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(line.kind == .purchased ? Color(white: 0.76) : Theme.accent)
                    .frame(width: 34, height: 38)
                    .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pos. \(line.positionNumber) · \(line.name)")
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(line.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(line.priceDescription)
                        .font(.caption2)
                        .foregroundStyle(line.amountEUR == nil ? Theme.accent : .secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if line.kind == .purchased,
                   let part = project.parts.first(where: { $0.id == line.id }) {
                    Button { purchasePartToEdit = part } label: {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glass)
                    .tint(.white)
                    .accessibilityLabel("Stückpreis für \(line.name) bearbeiten")
                } else {
                    Text(line.amountEUR.map(EuroFormat.string) ?? "Offen")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(line.amountEUR == nil ? Theme.accent : .primary)
                        .frame(minWidth: 58, alignment: .trailing)
                        .padding(.top, 2)
                }
            }
            HStack(spacing: 8) {
                Label("Arbeitszeit", systemImage: "clock")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(line.laborHours.map { "\(DeFormat.number($0, maxFractionDigits: 2)) h" } ?? "Nicht angesetzt")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let laborEUR = line.laborEUR {
                    Text("· \(EuroFormat.string(laborEUR))")
                        .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.primary)
                } else if line.laborHours != nil {
                    Text("· Stundensatz fehlt").font(.caption2).foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 4)
                if let part = project.parts.first(where: { $0.id == line.id }) {
                    Button { laborPartToEdit = part } label: {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .frame(width: 32, height: 30)
                    }
                    .buttonStyle(.glass)
                    .tint(.white)
                    .accessibilityLabel("Arbeitszeit für Position \(line.positionNumber) \(line.name) bearbeiten")
                }
            }
            .padding(.leading, 45)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LaborRateSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject
    @State private var rate = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Stundensatz") {
                    HStack {
                        Text("Arbeitskosten pro Stunde")
                        TextField("EUR / h", text: $rate)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("€/h").foregroundStyle(.secondary)
                    }
                    Text("Dieser Satz wird mit den erfassten Arbeitsstunden aller Positionen multipliziert.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if project.laborRateEURPerHour != nil {
                    Section { Button("Stundensatz entfernen", role: .destructive) { save(nil) } }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .navigationTitle("Stundensatz").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { saveEnteredRate() } }
            }
            .onAppear {
                if let value = project.laborRateEURPerHour { rate = DeFormat.number(value, maxFractionDigits: 6) }
            }
        }
    }

    private func saveEnteredRate() {
        guard let value = DeFormat.parse(rate), value >= 0, value <= 1_000_000 else {
            problem = "Bitte gib einen gültigen Stundensatz zwischen 0 und 1.000.000 € ein."
            return
        }
        save(value)
    }

    private func save(_ value: Double?) {
        do { try store.setLaborRate(project, eurosPerHour: value); dismiss() }
        catch { problem = error.localizedDescription }
    }
}

private struct LaborHoursSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let part: MCPart
    @State private var hours = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Position") {
                    LabeledContent("Bauteil", value: "Pos. \(part.positionNumber) · \(part.name)")
                    LabeledContent("Menge", value: "\(max(1, part.quantity)) Stück")
                    HStack {
                        Text("Arbeitszeit")
                        TextField("Stunden", text: $hours)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("h").foregroundStyle(.secondary)
                    }
                    Text("Erfasse die Gesamtarbeitszeit für diese Position inklusive ihrer Stückzahl.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if part.laborHours != nil {
                    Section { Button("Arbeitszeit entfernen", role: .destructive) { save(nil) } }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .navigationTitle("Arbeitszeit erfassen").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { saveEnteredHours() } }
            }
            .onAppear {
                if let value = part.laborHours { hours = DeFormat.number(value, maxFractionDigits: 6) }
            }
        }
    }

    private func saveEnteredHours() {
        guard let value = DeFormat.parse(hours), value >= 0, value <= 1_000_000 else {
            problem = "Bitte gib eine gültige Arbeitszeit zwischen 0 und 1.000.000 Stunden ein."
            return
        }
        save(value)
    }

    private func save(_ value: Double?) {
        do { try store.setLaborHours(part, hours: value); dismiss() }
        catch { problem = error.localizedDescription }
    }
}

private struct PurchasePartPriceSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let part: MCPart
    @State private var price = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Zukaufteil") {
                    LabeledContent("Position", value: "Pos. \(part.positionNumber) · \(part.name)")
                    LabeledContent("Menge", value: "\(max(1, part.quantity)) Stück")
                    HStack {
                        Text("Stückpreis")
                        TextField("EUR", text: $price)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("€").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Der Gesamtbetrag dieser Position ergibt sich aus Stückpreis × Menge.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if part.unitPrice != nil {
                        Button("Stückpreis entfernen", role: .destructive) { save(price: nil) }
                    }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .navigationTitle("Stückpreis").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { saveEnteredPrice() } }
            }
            .onAppear {
                if let unitPrice = part.unitPrice { price = DeFormat.number(unitPrice, maxFractionDigits: 6) }
            }
        }
    }

    private func saveEnteredPrice() {
        guard let value = DeFormat.parse(price), value >= 0 else {
            problem = "Bitte gib einen gültigen Preis ab 0 € ein."
            return
        }
        save(price: value)
    }

    private func save(price: Double?) {
        do {
            try store.setPurchasedPartPrice(part, unitPrice: price)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

private enum EuroFormat {
    static func string(_ value: Double) -> String {
        value.formatted(.currency(code: "EUR").locale(Locale(identifier: "de_DE")))
    }
}
