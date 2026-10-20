//
//  CutListView.swift
//  MetalCraftPro
//
//  Zuschnittliste: automatisch aus dem parametrischen Modell abgeleitet,
//  Schnittoptimierer mit Alternativen, CSV-Export. Immer synchron zum CAD.
//

import SwiftUI
import SwiftData

struct CutListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocalStore.self) private var store
    let project: MCProject
    @State private var stockText = "6000"
    @State private var kerfText = "3"
    @State private var planStrategy: String?
    @State private var settingsProblem: String?
    @State private var settingsSaved = false
    @State private var orderExpanded = false
    @State private var showPlans = false

    // MARK: Abgeleitete Daten (nie gespeichert – dadurch immer synchron)

    private var stockLength: Double { DeFormat.parse(stockText) ?? project.stockBarLengthMm ?? CuttingCostBuilder.defaultStockLengthMm }
    private var kerfWidth: Double { DeFormat.parse(kerfText) ?? project.sawKerfMm ?? CuttingCostBuilder.defaultKerfMm }

    private var entries: [CutListEntry] { ExportBridge.cutEntries(for: project) }

    private var remarks: [CutListRemark] { CutListBuilder.remarks(for: entries) }
    private var summary: CutListSummary { CutListBuilder.summary(entries: entries) }

    private var job: CuttingJob {
        CuttingJob(pieces: entries.flatMap { entry in
            (0..<entry.quantity).map { index in
                CuttingPiece(id: "\(entry.positionNumber)-\(index)", entryID: entry.id,
                             positionNumber: entry.positionNumber, lengthMm: entry.lengthMm,
                             profileLabel: entry.profile.dimensionLabel)
            }
        }, stockLengthMm: stockLength, kerfMm: kerfWidth)
    }

    private var plans: [CuttingPlan] { (try? CuttingOptimizer.plans(for: job)) ?? [] }
    private var plan: CuttingPlan? { plans.first(where: { $0.id == planStrategy }) ?? plans.first }

    private var csvText: String { CutListCSV.export(entries: entries, plan: plan, stockLengthMm: stockLength) }

    private func saveCuttingSettings() {
        guard let stock = DeFormat.parse(stockText), let kerf = DeFormat.parse(kerfText) else {
            settingsProblem = "Bitte gib eine gültige Stangenlänge und Schnittfuge ein."
            return
        }
        do {
            try store.setCuttingSettings(project, stockLengthMm: stock, kerfMm: kerf)
            settingsSaved = true
        } catch {
            settingsProblem = error.localizedDescription
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            topBar
            optimizerCard
            if entries.isEmpty {
                Spacer()
                ContentUnavailableView("Noch keine Zuschnittteile",
                                       systemImage: "square.3.layers.3d",
                                       description: Text("Lege Bauteile mit Profil und Länge an – die Liste folgt automatisch dem parametrischen Modell."))
                Spacer()
            } else {
                listSection
            }
            if !entries.isEmpty { footerBar }
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
        .background(Theme.appBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPlans) { plansSheet }
        .onAppear {
            stockText = DeFormat.number(project.stockBarLengthMm ?? CuttingCostBuilder.defaultStockLengthMm, maxFractionDigits: 2)
            kerfText = DeFormat.number(project.sawKerfMm ?? CuttingCostBuilder.defaultKerfMm, maxFractionDigits: 2)
        }
        .onChange(of: stockText) { _, _ in settingsSaved = false }
        .onChange(of: kerfText) { _, _ in settingsSaved = false }
        .alert("Schnittparameter nicht gespeichert", isPresented: Binding(
            get: { settingsProblem != nil }, set: { if !$0 { settingsProblem = nil } }
        )) {
            Button("OK", role: .cancel) { settingsProblem = nil }
        } message: {
            Text(settingsProblem ?? "")
        }
    }

    // MARK: Kopfzeile

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("Zurück")
            VStack(alignment: .leading, spacing: 3) {
                Text("Zuschnittliste").font(.headline)
                Text("\(project.name) · synchron zum CAD").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            ShareLink(item: csvText, preview: SharePreview("Zuschnittliste \(project.name)")) {
                Image(systemName: "square.and.arrow.up").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("CSV exportieren")
        }
    }

    // MARK: Optimierer-Karte

    private var optimizerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("Stangenlänge").font(.headline)
                        TextField("6000", text: $stockText)
                            .font(.headline.weight(.semibold)).monospacedDigit()
                            .keyboardType(.decimalPad).multilineTextAlignment(.leading)
                            .frame(width: 72)
                            .accessibilityLabel("Stangenlänge in Millimeter")
                        Text("mm").font(.headline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text("Schnittfuge").font(.subheadline).foregroundStyle(.secondary)
                        TextField("3", text: $kerfText)
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .keyboardType(.decimalPad).multilineTextAlignment(.leading)
                            .frame(width: 52)
                            .accessibilityLabel("Schnittfuge in Millimeter")
                        Text("mm").font(.subheadline).foregroundStyle(.secondary)
                    }
                    planSummary
                }
                Spacer(minLength: 4)
                Button { showPlans = true } label: {
                    Text("Schnittplan optimieren").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).frame(minHeight: 42)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
            }
            Button(action: saveCuttingSettings) {
                Label(settingsSaved ? "Für Kosten gespeichert" : "Schnittparameter speichern",
                      systemImage: settingsSaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.glass)
            .tint(settingsSaved ? .green : .white)
            if !entries.isEmpty {
                Divider().padding(.vertical, 2)
                sequenceRow
                if orderExpanded, let plan { barDetails(plan) }
            }
        }
        .padding(14).background(Theme.card(cornerRadius: 20))
    }

    private var planSummary: some View {
        Group {
            if let plan {
                let waste = DeFormat.number(plan.totalWasteMm / 1000, maxFractionDigits: 2)
                let bars = plan.barCount == 1 ? "1 Stange" : "\(plan.barCount) Stangen"
                if plan.offcutCount > 0 {
                    Text("\(bars) · Verschnitt \(waste) m · \(plan.offcutCount) Reststück\(plan.offcutCount == 1 ? "" : "e")")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(bars) · Verschnitt \(waste) m").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Keine Stückenlängen eingegeben").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sequenceRow: some View {
        Button { orderExpanded.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: orderExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold)).frame(width: 12)
                Text("Schnittreihenfolge: \(plan?.sequenceDescription ?? "–")")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(orderExpanded ? nil : 1)
                Spacer()
            }
        }.buttonStyle(.plain)
    }

    private func barDetails(_ plan: CuttingPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(plan.bars) { bar in
                HStack(alignment: .top, spacing: 8) {
                    Text("Stange \(bar.id + 1)").font(.caption.weight(.semibold)).frame(width: 64, alignment: .leading)
                    Text(bar.profileLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(bar.pieces.map { DeFormat.number($0.lengthMm) }.joined(separator: " · "))
                        .font(.caption.monospacedDigit())
                    if bar.offcutMm > 0 {
                        Text("Rest \(DeFormat.number(bar.offcutMm)) mm").font(.caption2).foregroundStyle(.green)
                    } else if bar.wasteMm > 0 {
                        Text("Verschnitt \(DeFormat.number(bar.wasteMm)) mm").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !plan.overlongPieces.isEmpty {
                Label("Zu lang für die Stangenlänge: \(plan.overlongPieces.map { "Pos \($0.positionNumber)" }.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.accent)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Liste

    private var listSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                headerRow
                ForEach(entries) { entry in
                    entryRow(entry)
                }
                ForEach(remarks) { remark in
                    remarkCard(remark)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Text("Pos").font(.caption).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
            Text("Profil").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("Länge").font(.caption).foregroundStyle(.secondary).frame(minWidth: 72, alignment: .trailing)
            Text("Stück").font(.caption).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
            Text("Schnitt").font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .trailing)
        }.padding(.horizontal, 14)
    }

    private func entryRow(_ entry: CutListEntry) -> some View {
        HStack(spacing: 12) {
            Text("\(entry.positionNumber)").font(.headline).monospacedDigit()
                .frame(width: 26, alignment: .leading)
            profileBadge(entry.profile)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayLabel).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                if !entry.materialGrade.isEmpty {
                    Text(entry.materialGrade).font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text("\(DeFormat.number(entry.lengthMm)) mm")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            Text("\(entry.quantity)").font(.subheadline).monospacedDigit()
                .frame(width: 32, alignment: .trailing)
            Text(entry.angleLabel).font(.subheadline).monospacedDigit()
                .frame(width: 78, alignment: .trailing)
        }
        .padding(14).background(Theme.card(cornerRadius: 14))
    }

    private func profileBadge(_ profile: ProfileSpec) -> some View {
        Image(systemName: profile.type.iconSystemName)
            .font(.system(size: 15))
            .foregroundStyle(Color(white: 0.85))
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(white: 0.32), lineWidth: 1))
    }

    private func remarkCard(_ remark: CutListRemark) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Bemerkung").font(.subheadline.weight(.semibold))
                Text(remark.text).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14).background(Theme.card(cornerRadius: 14))
    }

    // MARK: Fußzeile

    private var footerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Gesamt").font(.headline)
                Text("\(summary.pieceCount) Teile · \(DeFormat.number(summary.totalLengthMm / 1000, maxFractionDigits: 1)) m · \(DeFormat.number(summary.totalWeightKg, maxFractionDigits: 1)) kg")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            ShareLink(item: csvText, preview: SharePreview("Zuschnittliste \(project.name)")) {
                Text("Als CSV exportieren").font(.headline)
                    .padding(.horizontal, 14).frame(minHeight: 42)
            }
            .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: Alternativen

    private var plansSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Alternative Schnittpläne für die Stangenlänge \(DeFormat.number(stockLength)) mm. Sortiert nach Verschnitt; unterschiedliche Profile werden nie auf einer Stange gemischt.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(plans) { candidate in
                    Button {
                        planStrategy = candidate.id
                        showPlans = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.strategyName).font(.headline)
                                Text("\(candidate.barCount) Stangen · Verschnitt \(DeFormat.number(candidate.totalWasteMm / 1000, maxFractionDigits: 2)) m · Reststücke \(candidate.offcutCount)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(candidate.sequenceDescription).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if candidate.id == plan?.id {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            .navigationTitle("Schnittpläne").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showPlans = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
