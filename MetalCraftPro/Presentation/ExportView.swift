//
//  ExportView.swift
//  MetalCraftPro
//
//  Export & technische Zeichnungen: Übersicht über alle Formate mit klarem Status.
//  Fertige Formate erzeugen die Datei lokal und bieten sie zum Teilen an; Formate,
//  die (noch) nicht vollständig möglich sind, sind als „In Entwicklung" gekennzeichnet
//  statt als toter Button zu erscheinen.
//

import SwiftUI

struct ExportView: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject

    @State private var sheetFormat: TechnicalSheet.Format = .a4
    @State private var shareFile: ShareFile?
    @State private var problem: String?
    @State private var infoText: String?
    @State private var isGenerating = false
    @State private var didHandleInitialExport = false
    var initialExport: ExportFormatID? = nil

    struct ShareFile: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        VStack(spacing: 12) {
            topBar
            ScrollView {
                VStack(spacing: 10) {
                    section("Angebot", ids: [.quotePDF])
                    section("Zeichnungen", ids: [.drawingPDF, .drawingPNG, .drawingJPEG, .drawingSVG, .drawingDXF])
                    section("Protokolle", ids: [.montagePDF, .weldingPDF, .worksiteSurveyPDF])
                    section("Daten", ids: [.cutListCSV, .materialCSV])
                    section("3D-Modell", ids: [.modelSTL, .modelSTEP])
                    Label("Alle Dateien entstehen lokal auf dem Gerät.", systemImage: "internaldrive")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Theme.appBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $shareFile) { file in
            ActivityView(url: file.url)
        }
        .alert("Export nicht möglich", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .alert("In Entwicklung", isPresented: Binding(get: { infoText != nil }, set: { if !$0 { infoText = nil } })) {
            Button("Verstanden", role: .cancel) {}
        } message: { Text(infoText ?? "") }
        .onAppear {
            if !project.parts.isEmpty { try? store.ensureAssemblySteps(project) }
            guard !didHandleInitialExport, let initialExport,
                  let spec = ExportCatalog.specs.first(where: { $0.id == initialExport }) else { return }
            didHandleInitialExport = true
            handle(spec)
        }
    }

    // MARK: Kopf

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 32)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).tint(.white)
            .accessibilityLabel("Zurück")
            VStack(alignment: .leading, spacing: 2) {
                Text("Exportieren").font(.headline)
                Text("\(project.name) · \(project.number) · Rev \(project.revisionLabel)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(TechnicalSheet.Format.allCases, id: \.rawValue) { format in
                    Button(format == sheetFormat ? "✓ \(format.rawValue)" : format.rawValue) {
                        sheetFormat = format
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc")
                    Text("Blatt \(sheetFormat.rawValue)")
                }
                .font(.subheadline.weight(.semibold))
                .frame(height: 32).padding(.horizontal, 10)
            }
            .buttonStyle(.glass).buttonBorderShape(.capsule).tint(.white)
            .accessibilityLabel("Blattformat wählen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    // MARK: Abschnitte

    private func section(_ title: String, ids: [ExportFormatID]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase).padding(.leading, 4)
            ForEach(ids, id: \.self) { id in
                if let spec = ExportCatalog.specs.first(where: { $0.id == id }) {
                    row(spec)
                }
            }
        }
    }

    private func row(_ spec: ExportFormatSpec) -> some View {
        let hint = availabilityHint(spec)
        let generatable = spec.isReady && hint == nil
        return Button {
            handle(spec)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: spec.systemImage).font(.system(size: 22, weight: .light))
                    .foregroundStyle(generatable ? Color(white: 0.82) : Color(white: 0.45))
                    .frame(width: 44, height: 47).background(Theme.card(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(spec.title).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(generatable ? .primary : .secondary)
                    Text(hint ?? spec.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer()
                if case .inDevelopment = spec.availability {
                    Text("In Entwicklung").font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay { Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 0.8) }
                } else if generatable {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(12).frame(minHeight: 66).background(Theme.card())
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
        .accessibilityLabel("\(spec.title) exportieren")
    }

    private func availabilityHint(_ spec: ExportFormatSpec) -> String? {
        switch spec.id {
        case .montagePDF:
            return ExportBridge.montageSteps(for: project).isEmpty ? "Noch keine Montageschritte" : nil
        case .cutListCSV, .materialCSV, .modelSTL:
            return project.parts.isEmpty ? "Keine Bauteile im Projekt" : nil
        default:
            return nil
        }
    }

    // MARK: Erzeugung

    private func handle(_ spec: ExportFormatSpec) {
        if case .inDevelopment(let note) = spec.availability {
            infoText = note
            return
        }
        guard let hint = availabilityHint(spec) else {
            generate(spec)
            return
        }
        problem = hint
    }

    private func generate(_ spec: ExportFormatSpec) {
        isGenerating = true
        defer { isGenerating = false }
        do {
            let input = ExportBridge.input(for: project, generatedAt: Date())
            let data: Data
            let fileName: String
            switch spec.id {
            case .quotePDF:
                let estimate = ExportBridge.materialCostEstimate(for: project)
                let quoteInput = ExportBridge.quotePDFInput(for: project, estimate: estimate,
                                                            generatedAt: input.generatedAt)
                data = QuotePDF.data(for: quoteInput)
                fileName = "Angebot-\(safeFileToken(project.number)).pdf"
            case .drawingPDF:
                data = SheetPDF.data(try TechnicalDrawingBuilder.sheet(for: input, format: sheetFormat))
                fileName = "Zeichnung-\(project.number)-\(sheetFormat.rawValue).pdf"
            case .drawingPNG:
                data = SheetImage.png(try TechnicalDrawingBuilder.sheet(for: input, format: sheetFormat))
                fileName = "Zeichnung-\(project.number)-\(sheetFormat.rawValue).png"
            case .drawingJPEG:
                data = SheetImage.jpeg(try TechnicalDrawingBuilder.sheet(for: input, format: sheetFormat))
                fileName = "Zeichnung-\(project.number)-\(sheetFormat.rawValue).jpg"
            case .drawingSVG:
                data = Data(SheetSVG.render(try TechnicalDrawingBuilder.sheet(for: input, format: sheetFormat)).utf8)
                fileName = "Zeichnung-\(project.number)-\(sheetFormat.rawValue).svg"
            case .drawingDXF:
                data = Data(SheetDXF.render(try TechnicalDrawingBuilder.sheet(for: input, format: sheetFormat)).utf8)
                fileName = "Zeichnung-\(project.number)-\(sheetFormat.rawValue).dxf"
            case .montagePDF:
                data = MontagePDF.data(steps: ExportBridge.montageSteps(for: project),
                                       projectName: project.name, projectNumber: project.number,
                                       generatedAt: Date())
                fileName = "Montage-\(project.number).pdf"
            case .weldingPDF:
                let entries = WeldProtocolBuilder.entries(
                    parts: project.parts.map { WeldPartInput(id: $0.id, name: $0.name, positionNumber: $0.positionNumber) },
                    welds: ExportBridge.weldRecords(for: project))
                data = WeldProtocolPDF.data(entries: entries, projectName: project.name,
                                            projectNumber: project.number, materialGrade: project.materialGrade,
                                            generatedAt: Date())
                fileName = "Schweißprotokoll-\(project.number).pdf"
            case .worksiteSurveyPDF:
                let surveyInput = ExportBridge.worksiteSurveyPDFInput(for: project, generatedAt: input.generatedAt)
                data = WorksiteSurveyPDF.data(for: surveyInput)
                fileName = "Baustellen-Aufmass-\(safeFileToken(project.number)).pdf"
            case .cutListCSV:
                let entries = ExportBridge.cutEntries(for: project)
                let plans = try CuttingOptimizer.plans(for: CuttingJob(
                    pieces: entries.flatMap { entry in
                        (0..<entry.quantity).map { index in
                            CuttingPiece(id: "\(entry.id)-\(index)", entryID: entry.id,
                                         positionNumber: entry.positionNumber, lengthMm: entry.lengthMm,
                                         profileLabel: entry.displayLabel)
                        }
                    }, stockLengthMm: 6000))
                data = Data(CutListCSV.export(entries: entries, plan: plans.first, stockLengthMm: 6000).utf8)
                fileName = "Zuschnittliste-\(project.number).csv"
            case .materialCSV:
                data = Data(MaterialListCSV.export(rows: ExportBridge.materialRows(for: project),
                                                   projectName: project.name, projectNumber: project.number,
                                                   generatedAt: Date()).utf8)
                fileName = "Materialliste-\(project.number).csv"
            case .modelSTL:
                let parts = try ExportBridge.stlParts(for: project)
                guard !parts.isEmpty else {
                    problem = "Keine platzierbaren Bauteile (Rollen fehlen)."
                    return
                }
                data = Data(STLExporter.ascii(parts: parts, modelName: project.name).utf8)
                fileName = "Modell-\(project.number).stl"
            case .modelSTEP:
                return
            }
            let url = try ExportFiles.write(data, fileName: fileName)
            try store.recordExport(project, title: spec.title)
            shareFile = ShareFile(url: url)
        } catch {
            problem = "Der Export konnte nicht erzeugt werden: \(error.localizedDescription)"
        }
    }

    private func safeFileToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let token = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        return token.trimmingCharacters(in: CharacterSet(charactersIn: "-_")).isEmpty ? "Projekt" : token
    }
}

/// Teilen-Blatt für erzeugte Exportdateien.
private struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
