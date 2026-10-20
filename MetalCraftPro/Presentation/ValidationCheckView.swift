//
//  ValidationCheckView.swift
//  MetalCraftPro
//
//  Maßkontrolle: expliziter Prüfschritt zwischen Geometrie und Freigabe.
//

import SwiftUI
import SwiftData

struct ValidationCheckView: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject

    @State private var report: ValidationReport?
    @State private var editing: ValidationIssue?
    @State private var editValue = ""
    @State private var removing: ValidationIssue?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let report {
                    statusBanner(report)
                    frameChecks(report.checks)
                    issueSection(report)
                    approvalSection(report)
                } else {
                    ProgressView("Geometrie wird geprüft …")
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .frame(maxWidth: 800).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.appBackground)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: revalidate)
        .alert("Wert korrigieren", isPresented: Binding(
            get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Neuer Wert (mm)", text: $editValue).keyboardType(.decimalPad)
            Button("Übernehmen") { applyEdit() }
            Button("Abbrechen", role: .cancel) { editing = nil }
        } message: {
            Text(editing?.detail ?? "")
        }
        .confirmationDialog(removing?.title ?? "Element entfernen?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Element entfernen", role: .destructive) { applyRemoval() }
            Button("Abbrechen", role: .cancel) { removing = nil }
        } message: {
            Text("Die Entsorgung wird im Änderungsprotokoll festgehalten.")
        }
        .alert("Nicht gespeichert", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    private func revalidate() {
        report = ValidationEngine.run(ValidationBridge.input(for: project))
    }

    // MARK: Kopf & Status

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("Zurück")
            VStack(alignment: .leading, spacing: 4) {
                Text("Maßkontrolle").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("\(project.name) · Revision \(project.revisionLabel)").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusBanner(_ report: ValidationReport) -> some View {
        let (symbol, color, title, detail): (String, Color, String, String) = {
            if report.hasErrors {
                return ("xmark.octagon.fill", .red,
                        "\(report.errorCount) \(report.errorCount == 1 ? "Fehler" : "Fehler")" + (report.warningCount > 0 ? " · \(report.warningCount) Hinweise" : ""),
                        "Korrigiere die Funde, bevor die Geometrie freigegeben wird.")
            }
            if report.warningCount > 0 {
                return ("exclamationmark.triangle.fill", Theme.accent,
                        "Keine Fehler · \(report.warningCount) Hinweise",
                        "Hinweise blockieren die Freigabe nicht.")
            }
            return ("checkmark.seal.fill", .green, "Alle Prüfungen bestanden",
                    "Geometrie in sich schlüssig und bereit zur Freigabe.")
        }()
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14).background(Theme.card(cornerRadius: 18))
    }

    // MARK: Rahmenprüfung

    private func frameChecks(_ checks: [ValidationCheck]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rahmenprüfung").font(.headline)
            VStack(spacing: 0) {
                ForEach(checks) { check in
                    checkRow(check)
                    if check.id != checks.last?.id { Divider().padding(.horizontal, 17) }
                }
                if checks.isEmpty {
                    Text("Keine Rahmenprüfung möglich – zuerst Parameter und Profil gültig machen.")
                        .font(.footnote).foregroundStyle(.secondary).padding(16)
                }
            }
            .background(Theme.card(cornerRadius: 18))
        }
    }

    private func checkRow(_ check: ValidationCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.passes ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(check.passes ? .green : .red)
                .font(.body.weight(.semibold))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title).font(.subheadline.weight(.medium))
                if let expected = check.expectedMm {
                    Text("\(check.formula) = \(DeFormat.number(expected)) mm")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.primary)
                } else {
                    Text(check.formula).font(.subheadline.monospacedDigit()).foregroundStyle(.primary)
                }
                if !check.passes, let expected = check.expectedMm, let actual = check.actualMm {
                    Text("Erwartet \(DeFormat.number(expected)) mm · Vorhanden \(DeFormat.number(actual)) mm")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.red)
                }
                if let reference = check.reference {
                    Text(reference).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17).padding(.vertical, 13)
    }

    // MARK: Funde

    private func issueSection(_ report: ValidationReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Funde").font(.headline)
            if report.issues.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Keine fehlenden, widersprüchlichen oder ungültigen Daten.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card(cornerRadius: 18))
            } else {
                ForEach(report.issues) { issue in
                    issueCard(issue)
                }
            }
        }
    }

    private func issueCard(_ issue: ValidationIssue) -> some View {
        let color = issue.severity == .error ? Color.red : Theme.accent
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.category.symbol).font(.body.weight(.semibold)).foregroundStyle(color).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                    Text(issue.detail).font(.footnote).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reference = issue.reference {
                        Text(reference).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if issue.expected != nil || issue.actual != nil {
                HStack(spacing: 14) {
                    if let expected = issue.expected {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Erwartet").font(.caption2).foregroundStyle(.secondary)
                            Text(expected).font(.footnote.monospacedDigit()).foregroundStyle(.green)
                        }
                    }
                    if let actual = issue.actual {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vorhanden").font(.caption2).foregroundStyle(.secondary)
                            Text(actual).font(.footnote.monospacedDigit()).foregroundStyle(color)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if issue.fix != nil {
                Button {
                    presentFix(issue)
                } label: {
                    Label(issue.isRemoval ? "Element entfernen" : "Auf erwarteten Wert korrigieren", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.glass).tint(color)
            }
        }
        .padding(14).background(Theme.card(cornerRadius: 18))
    }

    private func presentFix(_ issue: ValidationIssue) {
        switch issue.fix {
        case .parameter, .partLength:
            editValue = issue.expectedNumber ?? ""
            editing = issue
        case .removeGeometryRecord, .removeCADElement:
            removing = issue
        case nil:
            break
        }
    }

    private func applyEdit() {
        defer { editing = nil }
        guard let issue = editing, let fix = issue.fix,
              let value = DeFormat.parse(editValue) else {
            problem = "Bitte gib einen gültigen Wert in Millimetern ein."
            return
        }
        do {
            switch fix {
            case .parameter(let key, _):
                try store.setFrameParameter(project, key: key, value: value)
            case .partLength(let partID, _):
                guard let part = project.parts.first(where: { $0.id == partID }) else { return }
                try store.fixPartLength(part, to: value)
            case .removeGeometryRecord, .removeCADElement:
                break
            }
            revalidate()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func applyRemoval() {
        defer { removing = nil }
        guard let issue = removing, let fix = issue.fix else { return }
        do {
            switch fix {
            case .removeGeometryRecord(let recordID):
                try store.removeGeometryRecord(project, recordID: recordID)
            case .removeCADElement(let elementID):
                try store.removeCADElement(project, elementID: elementID)
            case .parameter, .partLength:
                break
            }
            revalidate()
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Freigabe

    @ViewBuilder private func approvalSection(_ report: ValidationReport) -> some View {
        if report.hasErrors {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text("Die Freigabe ist erst möglich, wenn alle Fehler korrigiert sind.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card(cornerRadius: 18))
        } else if project.isGeometryApproved {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Geometrie freigegeben").font(.headline)
                        Text(project.geometryApprovedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button {
                    do { try store.revokeGeometryApproval(project); revalidate() }
                    catch { problem = error.localizedDescription }
                } label: {
                    Text("Freigabe zurücknehmen").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.glass)
            }
            .padding(14).background(Theme.card(cornerRadius: 18))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    do { try store.approveGeometry(project); revalidate() }
                    catch { problem = error.localizedDescription }
                } label: {
                    Label("Geometrie freigeben", systemImage: "checkmark.seal")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                Text("Bestätigt die finale Geometrie als Grundlage für 3D, Zuschnitt und Montage. Jede spätere Geometrieänderung hebt die Freigabe auf und wird protokolliert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private extension ValidationIssue {
    var isRemoval: Bool {
        switch fix {
        case .removeGeometryRecord, .removeCADElement: return true
        default: return false
        }
    }
    /// Maschinenlesbarer erwarteter Wert für das Korrekturfeld.
    var expectedNumber: String? {
        switch fix {
        case .parameter(_, let value), .partLength(_, let value):
            return DeFormat.number(value, maxFractionDigits: 3)
        default: return expected
        }
    }
}
