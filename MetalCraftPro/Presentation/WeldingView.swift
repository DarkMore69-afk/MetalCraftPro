//
//  WeldingView.swift
//  MetalCraftPro
//
//  Schweißmodul: Nähte je Bauteil dokumentieren (MIG/MAG, WIG, E-Hand) und
//  Schweißprotokoll je Bauteil oder Projekt als PDF erzeugen.
//

import SwiftUI
import UIKit

struct WeldingView: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject

    @State private var selectedPartID: UUID?
    @State private var process = "wig"
    @State private var selectedWeldID: UUID?
    @State private var formWeld: MCWeld?
    @State private var showForm = false
    @State private var showPartPicker = false
    @State private var shareURL: URL?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 12) {
            topBar
            processTabs
            if weldParts.isEmpty {
                emptyCard
            } else {
                parameterCard
                seamList
                SeamSpacer()
                documentButton
                pdfButton
            }
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
        .background(Theme.appBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if selectedPartID == nil { selectedPartID = defaultPart?.id } }
        .onChange(of: process) { _, _ in selectedWeldID = nil }
        .sheet(isPresented: $showForm) {
            WeldFormSheet(project: project, part: selectedPart, weld: formWeld, initialMethod: process)
        }
        .sheet(isPresented: $showPartPicker) {
            PartPickerSheet(parts: weldParts, selectedID: $selectedPartID)
        }
        .sheet(item: shareItem) { item in
            ActivityView(url: item.url)
        }
        .alert("Nicht gespeichert", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    private struct SeamSpacer: View {
        var body: some View { Spacer().frame(minHeight: 2) }
    }

    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }
    private var shareItem: Binding<ShareItem?> {
        Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })
    }

    // MARK: Daten

    private var weldParts: [MCPart] {
        project.parts.filter { !$0.isReference }
    }
    private var defaultPart: MCPart? {
        weldParts.first { $0.role == "strebe" } ?? weldParts.first
    }
    private var selectedPart: MCPart? {
        weldParts.first { $0.id == selectedPartID } ?? defaultPart
    }
    private var partWelds: [MCWeld] {
        guard let part = selectedPart else { return [] }
        return project.welds.filter { $0.partID == part.id }
    }
    private var processWelds: [MCWeld] {
        partWelds.filter { $0.method == process }
    }
    private var selectedWeld: MCWeld? {
        processWelds.first { $0.id == selectedWeldID } ?? processWelds.first
    }
    private var emptyCard: some View {
        ContentUnavailableView("Keine Bauteile", systemImage: "cube",
                               description: Text("Lege Bauteile an, um Nähte zu dokumentieren."))
            .frame(maxHeight: .infinity)
    }

    private var subtitle: String {
        guard let part = selectedPart else { return project.name }
        return "\(project.name) · Pos \(part.positionNumber) \(part.name)"
    }

    // MARK: Kopf

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("Zurück")
            VStack(spacing: 2) {
                Text("Schweißen").font(.title3.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity)
            Menu {
                Button("Bauteil wählen", systemImage: "cube") { showPartPicker = true }
                Button("Protokoll je Projekt", systemImage: "doc.text") { exportPDF(scope: .project) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("Aktionen")
        }
    }

    private var processTabs: some View {
        HStack(spacing: 0) {
            processTab("mig", "MIG/MAG")
            processTab("wig", "WIG")
            processTab("ehand", "E-Hand")
        }
        .padding(4)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    private func processTab(_ method: String, _ label: String) -> some View {
        Button { process = method } label: {
            Text(label)
                .font(.subheadline.weight(process == method ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(process == method ? .black : .primary)
                .background {
                    if process == method {
                        Capsule().fill(Theme.accent)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) wählen")
        .accessibilityAddTraits(process == method ? .isSelected : [])
    }

    // MARK: Parameterkarte der gewählten Naht

    @ViewBuilder private var parameterCard: some View {
        if let weld = selectedWeld {
            parameterCard(weld)
        } else {
            VStack(spacing: 6) {
                Text("Noch keine Naht dokumentiert").font(.body.weight(.semibold))
                Text("Lege die erste Naht für \(methodLabel) an – Material, Dicke, Draht/Elektrode, Gas, Strom, Spannung, Position, Nahtart und Schweißfolge.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(20)
            .background(Theme.card(cornerRadius: 22))
        }
    }

    private func parameterCard(_ weld: MCWeld) -> some View {
        let record = Self.record(weld)
        return VStack(spacing: 0) {
            ScrollView(showsIndicators: true) {
                VStack(spacing: 0) {
                    ForEach(record.parameterRows.indices, id: \.self) { index in
                        parameterRow(record.parameterRows[index].0,
                                     record.parameterRows[index].1.isEmpty ? "–" : record.parameterRows[index].1)
                        if index < record.parameterRows.count - 1 {
                            Divider().padding(.horizontal, 17)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(maxHeight: 235)
            .background(Theme.card(cornerRadius: 22))

            Button { openForm(weld) } label: {
                Label("Schweißeinstellungen bearbeiten", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("editWeldParameters")
            .accessibilityHint("Öffnet das Formular mit allen Nahtparametern")
        }
    }

    private var methodLabel: String {
        switch process {
        case "ehand": return "E-Hand"
        case "mig": return "MIG/MAG"
        default: return "WIG"
        }
    }

    private func parameterRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.body).foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            Text(value).font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 17).padding(.vertical, 13)
    }

    // MARK: Nähte-Liste

    private var seamList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nähte").font(.title3.weight(.semibold))
                if processWelds.isEmpty {
                    Text("Keine Naht für \(methodLabel) an diesem Bauteil.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 14)
                }
                ForEach(processWelds.indices, id: \.self) { index in
                    seamRow(processWelds[index], number: index + 1)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private func seamRow(_ weld: MCWeld, number: Int) -> some View {
        let isSelected = selectedWeld?.id == weld.id
        let record = WeldRecord(label: weld.label, method: weld.method, material: weld.material,
                                thicknessMm: weld.thicknessMm, filler: weld.filler, gas: weld.gas,
                                currentA: weld.currentA, voltageV: weld.voltageV,
                                wireFeedMMin: weld.wireFeedMMin, position: weld.position,
                                seamType: weld.seamType, sequence: weld.sequence, note: weld.note)
        return Button { selectedWeldID = weld.id } label: {
            HStack(spacing: 12) {
                Text("\(number)").font(.subheadline.weight(.semibold)).monospacedDigit()
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color(white: 0.2)))
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(isSelected ? Theme.accent.opacity(0.8) : .clear, lineWidth: 1.4))
                Text(weld.label.isEmpty ? "Naht" : weld.label)
                    .font(.body)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(record.currentLabel).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: record.isDocumented ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(record.isDocumented ? .green : Color(white: 0.45))
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).frame(minHeight: 62)
            .background(Theme.card(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Bearbeiten", systemImage: "pencil") { openForm(weld) }
            Button("Löschen", systemImage: "trash", role: .destructive) {
                do { try store.deleteWeld(weld) } catch { problem = error.localizedDescription }
            }
        }
        .accessibilityLabel("Naht \(weld.label.isEmpty ? "ohne Name" : weld.label)")
    }

    private func openForm(_ weld: MCWeld) {
        formWeld = weld
        showForm = true
    }

    // MARK: Aktionen

    private var documentButton: some View {
        Button { formWeld = nil; showForm = true } label: {
            Label("Naht dokumentieren", systemImage: "doc.badge.plus")
                .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
        .disabled(selectedPart == nil)
        .accessibilityIdentifier("documentWeld")
    }

    private var pdfButton: some View {
        Button { exportPDF(scope: .part) } label: {
            Label("Protokoll als PDF", systemImage: "doc")
                .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.glass).tint(.white)
        .disabled(selectedPart == nil)
        .accessibilityIdentifier("weldPDF")
    }

    private enum PDFScope { case part, project }

    private func exportPDF(scope: PDFScope) {
        do {
            let parts: [WeldPartInput]
            let welds: [WeldRecord]
            switch scope {
            case .part:
                guard let part = selectedPart else { return }
                parts = [WeldPartInput(id: part.id, name: part.name, positionNumber: part.positionNumber)]
                welds = project.welds.filter { $0.partID == part.id }.map(Self.record)
            case .project:
                parts = weldParts.map { WeldPartInput(id: $0.id, name: $0.name, positionNumber: $0.positionNumber) }
                welds = project.welds.map(Self.record)
            }
            let entries = WeldProtocolBuilder.entries(parts: parts, welds: welds)
            shareURL = try WeldProtocolPDF.write(entries: entries, projectName: project.name,
                                                 projectNumber: project.number,
                                                 materialGrade: project.materialGrade, generatedAt: Date())
        } catch {
            problem = error.localizedDescription
        }
    }

    private static func record(_ weld: MCWeld) -> WeldRecord {
        WeldRecord(id: weld.id, label: weld.label, method: weld.method, material: weld.material,
                   thicknessMm: weld.thicknessMm, filler: weld.filler, gas: weld.gas,
                   currentA: weld.currentA, voltageV: weld.voltageV, wireFeedMMin: weld.wireFeedMMin,
                   position: weld.position, seamType: weld.seamType, sequence: weld.sequence,
                   note: weld.note, partID: weld.partID)
    }
}

// MARK: - Naht-Formular

private struct WeldFormSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject
    let part: MCPart?
    let weld: MCWeld?
    let initialMethod: String

    @State private var label = ""
    @State private var method = "wig"
    @State private var material = ""
    @State private var thickness = ""
    @State private var filler = ""
    @State private var gas = ""
    @State private var current = ""
    @State private var voltage = ""
    @State private var wireFeed = ""
    @State private var position = ""
    @State private var seamType = ""
    @State private var sequence = ""
    @State private var note = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("z. B. Rahmen links unten", text: $label)
                    Picker("Verfahren", selection: $method) {
                        Text("MIG/MAG").tag("mig")
                        Text("WIG").tag("wig")
                        Text("E-Hand").tag("ehand")
                    }
                } header: { Text("Naht") }
                Section {
                    TextField("z. B. S235", text: $material)
                    field("Dicke (mm)", text: $thickness)
                } header: { Text("Material") }
                Section {
                    TextField(method == "ehand" ? "z. B. E-Hand Ø2,5 · Rutile" : "z. B. WIG Ø2,4 · ER70S-6", text: $filler)
                    TextField("z. B. Argon 4.6 · 10 l/min", text: $gas)
                } header: { Text("Zusatzwerkstoff & Gas") }
                Section {
                    field("Strom (A)", text: $current)
                    field("Spannung (V)", text: $voltage)
                    if method == "mig" {
                        field("Drahtvorschub (m/min)", text: $wireFeed)
                    }
                } header: { Text("Energie") } footer: {
                    Text(method == "mig" ? "Drahtvorschub gilt nur für MIG/MAG." : "WIG und E-Hand haben keinen Drahtvorschub – das Protokoll zeigt dann einen Strich.")
                }
                Section {
                    TextField("z. B. PA (flach)", text: $position)
                    TextField("z. B. Kehlnaht a3", text: $seamType)
                    TextField("z. B. 1 → 2 → 3", text: $sequence)
                } header: { Text("Ausführung") }
                Section("Notiz") {
                    TextField("optional", text: $note, axis: .vertical)
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle(weld == nil ? "Naht dokumentieren" : "Naht bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { save() } }
            }
            .onAppear { populate() }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            TextField(title, text: text).multilineTextAlignment(.trailing).keyboardType(.decimalPad)
        }
    }

    private func populate() {
        guard label.isEmpty else { return }
        method = weld?.method ?? initialMethod
        label = weld?.label ?? ""
        material = weld?.material ?? project.materialGrade
        thickness = weld.map { DeFormat.number($0.thicknessMm, maxFractionDigits: 2) } ?? ""
        filler = weld?.filler ?? ""
        gas = weld?.gas ?? ""
        current = weld.map { DeFormat.number($0.currentA, maxFractionDigits: 0) } ?? ""
        voltage = weld.map { DeFormat.number($0.voltageV, maxFractionDigits: 1) } ?? ""
        wireFeed = (weld?.wireFeedMMin ?? 0) > 0 ? DeFormat.number(weld!.wireFeedMMin, maxFractionDigits: 1) : ""
        position = weld?.position ?? ""
        seamType = weld?.seamType ?? ""
        sequence = weld?.sequence ?? ""
        note = weld?.note ?? ""
    }

    private func save() {
        let thickness = DeFormat.parse(thickness)
        let current = DeFormat.parse(current)
        let voltage = DeFormat.parse(voltage)
        let wireFeed = DeFormat.parse(wireFeed)
        guard let thickness, let current, let voltage else {
            problem = "Bitte gib Dicke, Strom und Spannung als Zahlen ein."; return
        }
        do {
            if let weld {
                try store.updateWeld(weld, label: label, method: method, material: material,
                                     thicknessMm: thickness, filler: filler, gas: gas,
                                     currentA: current, voltageV: voltage,
                                     wireFeedMMin: method == "mig" ? wireFeed : nil,
                                     position: position, seamType: seamType, sequence: sequence, note: note)
            } else {
                try store.addWeld(project, part: part, label: label, method: method, material: material,
                                  thicknessMm: thickness, filler: filler, gas: gas,
                                  currentA: current, voltageV: voltage,
                                  wireFeedMMin: method == "mig" ? wireFeed : nil,
                                  position: position, seamType: seamType, sequence: sequence, note: note)
            }
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Bauteilwahl

private struct PartPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let parts: [MCPart]
    @Binding var selectedID: UUID?

    var body: some View {
        NavigationStack {
            List(parts.sorted { $0.positionNumber < $1.positionNumber }) { part in
                Button {
                    selectedID = part.id
                    dismiss()
                } label: {
                    HStack {
                        Text("Pos \(part.positionNumber) · \(part.name)").font(.body)
                        Spacer()
                        if part.id == selectedID {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .navigationTitle("Bauteil wählen").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Teilen

private struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
