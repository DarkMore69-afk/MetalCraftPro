import SwiftUI

struct ManufacturingChecklistView: View {
    @Environment(LocalStore.self) private var store
    let project: MCProject

    @State private var problem: String?
    @State private var isSynchronizing = false

    private let sectionOrder = ["zuschnitt", "montage", "pruefung", "schweissen"]

    private var orderedItems: [MCChecklistItem] {
        project.checklistItems.sorted { lhs, rhs in
            let left = sectionOrder.firstIndex(of: lhs.kind) ?? sectionOrder.count
            let right = sectionOrder.firstIndex(of: rhs.kind) ?? sectionOrder.count
            if left != right { return left < right }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private var completedCount: Int { orderedItems.filter { $0.completedAt != nil }.count }
    private var progress: Double {
        orderedItems.isEmpty ? 0 : Double(completedCount) / Double(orderedItems.count)
    }

    private var sourceSignature: String {
        let parts = project.parts.sorted { $0.positionNumber < $1.positionNumber }
            .map { "\($0.id)|\($0.positionNumber)|\($0.name)|\($0.quantity)|\($0.lengthMm)|\($0.profileName)|\($0.role ?? "")" }
            .joined(separator: ";")
        let cuts = project.cutItems
            .map { "\($0.id)|\($0.partID?.uuidString ?? "")|\($0.angleADeg)|\($0.angleBDeg)|\($0.quantity)|\($0.machining)|\($0.remark)" }
            .joined(separator: ";")
        let steps = project.assemblies.flatMap { assembly in
            assembly.orderedSteps.map { "\(assembly.id)|\($0.id)|\($0.orderIndex)|\($0.title)|\($0.partName)|\($0.allPartIDs.map(\.uuidString).joined(separator: ","))|\($0.movement)|\($0.connection)|\($0.tool)|\($0.positionNote)" }
        }.joined(separator: ";")
        let welds = project.welds
            .map { "\($0.id)|\($0.label)|\($0.method)|\($0.seamType)|\($0.partID?.uuidString ?? "")" }
            .joined(separator: ";")
        return "\(project.widthMm)|\(project.heightMm)|\(project.profileSpec.dimensionLabel)|\(parts)|\(cuts)|\(steps)|\(welds)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                progressCard
                if orderedItems.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Fertigungsaufgaben",
                        systemImage: "checklist",
                        description: Text("Zuschnitt, Montage und dokumentierte Nähte erscheinen hier automatisch aus dem Projektmodell.")
                    )
                    .frame(minHeight: 260)
                } else {
                    ForEach(sectionOrder, id: \.self) { kind in
                        let items = orderedItems.filter { $0.kind == kind }
                        if !items.isEmpty {
                            checklistSection(kind: kind, items: items)
                        }
                    }
                }
                Label("Abhaken und Änderungen werden mit Zeitstempel im Projektprotokoll gespeichert.", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.appBackground)
        .navigationTitle("Fertigungs-Checkliste")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { synchronize() }
        .onChange(of: sourceSignature) { _, _ in synchronize() }
        .alert("Änderung nicht gespeichert", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.headline)
                    Text("\(project.number) · Fertigungsfortschritt")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(completedCount) / \(orderedItems.count)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("\(completedCount) von \(orderedItems.count) Aufgaben erledigt")
            }
            ProgressView(value: progress)
                .tint(Theme.accent)
                .accessibilityLabel("Fertigungsfortschritt")
            HStack {
                Text(orderedItems.isEmpty ? "Wird aus dem Projektmodell abgeleitet" : "\(Int((progress * 100).rounded())) % erledigt")
                Spacer()
                if isSynchronizing { ProgressView().controlSize(.small) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Theme.card())
    }

    private func checklistSection(kind: String, items: [MCChecklistItem]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: kind))
                    .foregroundStyle(Theme.accent)
                Text(title(for: kind))
                    .font(.headline)
                Spacer()
                Text("\(items.filter { $0.completedAt != nil }.count) / \(items.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 1) {
                ForEach(items) { item in
                    checklistRow(item)
                    if item.id != items.last?.id {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .background(Theme.card())
        }
    }

    private func checklistRow(_ item: MCChecklistItem) -> some View {
        let done = item.completedAt != nil
        return Button {
            do { try store.setChecklistItem(item, completed: !done) }
            catch { problem = error.localizedDescription }
        } label: {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(done ? Theme.accent : Color(white: 0.52))
                    .frame(width: 34, height: 40)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(done ? .secondary : .primary)
                        .strikethrough(done, color: .secondary)
                        .multilineTextAlignment(.leading)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let completedAt = item.completedAt {
                        Text("Erledigt · \(completedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.accent.opacity(0.9))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(done ? "Erledigt" : "Offen"): \(item.kindLabel), \(item.title)")
        .accessibilityHint(done ? "Tippen, um wieder zu öffnen" : "Tippen, um als erledigt zu markieren")
    }

    private func synchronize() {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        do {
            try store.synchronizeChecklist(project)
            isSynchronizing = false
        } catch {
            isSynchronizing = false
            problem = error.localizedDescription
        }
    }

    private func title(for kind: String) -> String {
        switch kind {
        case "zuschnitt": return "Zuschnitt"
        case "montage": return "Montage"
        case "pruefung": return "Prüfungen"
        case "schweissen": return "Schweißen"
        default: return "Fertigung"
        }
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "zuschnitt": return "sawblade"
        case "montage": return "wrench.and.screwdriver"
        case "pruefung": return "ruler"
        case "schweissen": return "flame"
        default: return "checklist"
        }
    }
}
