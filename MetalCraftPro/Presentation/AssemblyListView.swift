//
//  AssemblyListView.swift
//  MetalCraftPro
//
//  Baugruppen-Verwaltung: hierarchischer Bauteil-Baum mit Drag-Reihenfolge,
//  abgeleiteter Stückliste und Prüf-Integration (Kollision & Verbundenheit).
//

import SwiftUI

struct AssemblyListView: View {
    @Environment(LocalStore.self) private var store
    let project: MCProject

    @State private var expanded: Set<String> = []
    @State private var showBOM = false
    @State private var showNewAssembly = false
    @State private var newAssemblyName = ""
    @State private var newAssemblyParent: MCAssembly?
    @State private var partToGroup: MCPart?
    @State private var renaming: MCAssembly?
    @State private var renameText = ""
    @State private var confirmingDelete: MCAssembly?
    @State private var problem: String?
    @Environment(\.editMode) private var editMode

    var body: some View {
        List {
            validationSection
            Section {
                Picker("Ansicht", selection: $showBOM) {
                    Text("Baum").tag(false)
                    Text("Stückliste").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .padding(.vertical, 2)
                if showBOM {
                    bomRows
                } else {
                    treeRows
                }
            } header: {
                Text(showBOM ? "Abgeleitet aus dem parametrischen Modell" : "Hierarchie")
            } footer: {
                Text(showBOM
                     ? "Mengen multiplizieren sich über alle Ebenen, Längen folgen direkt Breite, Höhe und Profil."
                     : "Im Bearbeiten-Modus lassen sich Zeilen per Ziehen innerhalb ihrer Ebene umordnen.")
            }
            Section {
                Button {
                    newAssemblyParent = nil
                    partToGroup = nil
                    newAssemblyName = ""
                    showNewAssembly = true
                } label: {
                    Label("Neue Baugruppe", systemImage: "plus.circle.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 40)
                }
                .tint(Theme.accent)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.appBackground)
        .navigationTitle("Baugruppen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .alert("Neue Baugruppe", isPresented: $showNewAssembly) {
            TextField("Name", text: $newAssemblyName)
            Button("Anlegen") { createAssembly() }
            Button("Abbrechen", role: .cancel) { partToGroup = nil }
        } message: {
            Text(newAssemblyParent.map { "Unterbaugruppe von „\($0.name)“" } ?? "Auf der obersten Ebene")
        }
        .alert("Baugruppe umbenennen", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Speichern") {
                guard let assembly = renaming else { return }
                do { try store.renameAssembly(assembly, to: renameText) } catch { problem = error.localizedDescription }
                renaming = nil
            }
            Button("Abbrechen", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Baugruppe löschen?", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }), titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                guard let assembly = confirmingDelete else { return }
                do { try store.deleteAssembly(assembly) } catch { problem = error.localizedDescription }
                confirmingDelete = nil
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Unterbaugruppen werden mitgelöscht. Bauteile bleiben im Projekt und sind danach nicht mehr zugeordnet.")
        }
        .alert("Nicht gespeichert", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    // MARK: Daten (jede Darstellung frisch aus dem parametrischen Modell abgeleitet)

    private var input: AssemblyTreeInput {
        AssemblyTreeInput(
            parts: project.parts.map { part in
                AssemblyPartSnapshot(id: part.id, name: part.name, positionNumber: part.positionNumber,
                                     quantity: part.quantity, role: part.role,
                                     profileName: part.isReference ? nil : part.profileName,
                                     lengthMm: part.isReference ? nil : part.lengthMm)
            },
            assemblies: project.assemblies.map { assembly in
                AssemblySnapshot(id: assembly.id, name: assembly.name, positionNumber: assembly.positionNumber,
                                 quantity: assembly.quantity, parentAssemblyID: assembly.parentAssemblyID,
                                 partIDs: assembly.partIDs, childAssemblyIDs: assembly.childAssemblyIDs)
            })
    }

    private var tree: [AssemblyNode] { AssemblyTreeBuilder.build(input) }
    private var bom: [BOMRow] { AssemblyTreeBuilder.billOfMaterials(tree) }
    private var assemblyIssues: [ValidationIssue] {
        ValidationEngine.run(ValidationBridge.input(for: project)).issues
            .filter { $0.category == .disconnectedAssembly || $0.category == .collidingParts }
    }

    // MARK: Baum

    private struct Row: Identifiable {
        let node: AssemblyNode
        let depth: Int
        var id: String { node.id }
    }

    private var rows: [Row] { flatten(tree, depth: 0) }

    private func flatten(_ nodes: [AssemblyNode], depth: Int) -> [Row] {
        nodes.flatMap { node -> [Row] in
            var result = [Row(node: node, depth: depth)]
            if node.isAssembly && expanded.contains(node.id) {
                result += flatten(node.children, depth: depth + 1)
            }
            return result
        }
    }

    private func listRow(_ row: Row) -> some View {
        rowView(row)
            .contextMenu { contextMenu(for: row) }
    }

    /// Explizit typisierte ForEach-Kette, um den Typ-Checker zu entlasten.
    private var treeRows: some View {
        let currentRows = rows
        return ForEach(currentRows, id: \.id) { (row: Row) -> AnyView in
            AnyView(listRow(row))
        }
        .onMove { sources, destination in
            guard let source = sources.first else { return }
            moveRow(from: source, to: destination)
        }
    }

    private func rowView(_ row: Row) -> some View {
        let node = row.node
        let badgeColor: Color = node.isAssembly ? Theme.accent.opacity(0.16) : Color(white: 0.14)
        let badgeText: Color = node.isAssembly ? Theme.accent : Color(white: 0.65)
        return HStack(spacing: 10) {
            expandButton(for: node)
            kindIcon(for: node)
            Text("Pos. \(node.positionNumber)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(node.name).font(node.isAssembly ? Font.body.weight(.semibold) : Font.body)
            if node.quantity > 1 {
                Text("× \(node.quantity)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if let length = node.lengthMm {
                Text("\(DeFormat.number(length)) mm")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(node.kind.label).font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(badgeColor, in: Capsule())
                .foregroundStyle(badgeText)
        }
        .padding(.leading, CGFloat(row.depth) * 18)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func expandButton(for node: AssemblyNode) -> some View {
        if node.isAssembly {
            Button {
                if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
            } label: {
                Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded.contains(node.id) ? "Einklappen" : "Ausklappen")
        } else {
            Color.clear.frame(width: 16)
        }
    }

    @ViewBuilder private func kindIcon(for node: AssemblyNode) -> some View {
        if node.isAssembly {
            Image(systemName: "flowchart")
                .font(.system(size: 15, weight: .light)).foregroundStyle(Theme.accent).frame(width: 22)
        } else if node.kind == .referencePart {
            Image(systemName: "shippingbox")
                .font(.system(size: 15, weight: .light)).foregroundStyle(Color(white: 0.7)).frame(width: 22)
        } else {
            Image(systemName: "cube")
                .font(.system(size: 15, weight: .light)).foregroundStyle(Color(white: 0.7)).frame(width: 22)
        }
    }

    @ViewBuilder private func contextMenu(for row: Row) -> some View {
        let node = row.node
        if node.isAssembly, let assembly = project.assemblies.first(where: { $0.id == node.assemblyID }) {
            Button {
                newAssemblyParent = assembly
                partToGroup = nil
                newAssemblyName = ""
                showNewAssembly = true
            } label: { Label("Unterbaugruppe hinzufügen", systemImage: "plus.square.on.square") }
            Button {
                renameText = assembly.name
                renaming = assembly
            } label: { Label("Umbenennen", systemImage: "pencil") }
            Button {
                do { try store.dissolveAssembly(assembly) } catch { problem = error.localizedDescription }
            } label: { Label("Auflösen · Inhalte eine Ebene höher", systemImage: "arrow.up.to.line") }
            Button(role: .destructive) { confirmingDelete = assembly } label: {
                Label("Löschen", systemImage: "trash")
            }
        } else if let part = project.parts.first(where: { $0.id == node.partID }) {
            Button {
                newAssemblyParent = project.assemblies.first { $0.id == node.assemblyID }
                partToGroup = part
                newAssemblyName = ""
                showNewAssembly = true
            } label: { Label("In neue Unterbaugruppe gruppieren", systemImage: "square.stack.3d.up") }
            if node.assemblyID != nil {
                Button {
                    do { try store.movePart(part, into: nil) } catch { problem = error.localizedDescription }
                } label: { Label("Herauslösen", systemImage: "arrow.up.right") }
            }
        }
    }

    private func createAssembly() {
        do {
            let assembly = try store.addAssembly(project, name: newAssemblyName, under: newAssemblyParent)
            if let part = partToGroup { try store.movePart(part, into: assembly) }
            if let parent = newAssemblyParent { expanded.insert("a:\(parent.id.uuidString)") }
            expanded.insert("a:\(assembly.id.uuidString)")
        } catch { problem = error.localizedDescription }
        partToGroup = nil
    }

    // MARK: Drag-Reihenfolge

    private func moveRow(from source: Int, to destination: Int) {
        var rows = self.rows
        guard rows.indices.contains(source), source != destination else { return }
        let sourceRow = rows.remove(at: source)
        let targetIndex = max(0, min(destination, rows.count))
        guard let anchor = targetIndex < rows.count ? rows[targetIndex] : rows.last else { return }

        do {
            switch sourceRow.node.kind {
            case .assembly:
                guard let sourceID = sourceRow.node.assemblyID, let anchorAssemblyID = anchor.node.assemblyID else { return }
                let sourceParent = project.assemblies.first { $0.id == sourceID }?.parentAssemblyID
                let anchorParent = project.assemblies.first { $0.id == anchorAssemblyID }?.parentAssemblyID
                guard sourceParent == anchorParent else { return }
                if let sourceParent, let parent = project.assemblies.first(where: { $0.id == sourceParent }) {
                    var ids = parent.childAssemblyIDs
                    ids.removeAll { $0 == sourceID }
                    if let insertAt = ids.firstIndex(of: anchorAssemblyID) {
                        ids.insert(sourceID, at: insertAt)
                    } else {
                        ids.append(sourceID)
                    }
                    try store.reorderAssemblyChildren(parent, partIDs: parent.partIDs, childAssemblyIDs: ids)
                } else {
                    try store.resequenceRootAssemblies(project, moving: sourceID, near: anchorAssemblyID)
                }
            case .ownPart, .referencePart:
                guard let partID = sourceRow.node.partID, let anchorPartID = anchor.node.partID else { return }
                guard let parent = project.assemblies.first(where: { $0.partIDs.contains(partID) }),
                      parent.partIDs.contains(anchorPartID), parent.partIDs.contains(partID) else { return }
                var ids = parent.partIDs
                ids.removeAll { $0 == partID }
                if let insertAt = ids.firstIndex(of: anchorPartID) {
                    ids.insert(partID, at: insertAt)
                } else {
                    ids.append(partID)
                }
                try store.reorderAssemblyChildren(parent, partIDs: ids, childAssemblyIDs: parent.childAssemblyIDs)
            }
        } catch { problem = error.localizedDescription }
    }

    // MARK: Stückliste

    @ViewBuilder private var bomRows: some View {
        if bom.isEmpty {
            Text("Keine Bauteile zugeordnet.").font(.subheadline).foregroundStyle(.secondary)
        } else {
            ForEach(bom) { row in
                HStack(spacing: 10) {
                    Text("Pos. \(row.positionNumber)").font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.subheadline.weight(.medium))
                        Text(row.isReference ? "Referenzteil (Zukauf)" : row.profileName ?? "Profil")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let length = row.unitLengthMm {
                        Text("\(DeFormat.number(length)) mm").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("\(row.totalQuantity)×").font(.subheadline.monospacedDigit().weight(.semibold))
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Kollision & Verbundenheit

    private var validationSection: some View {
        Section {
            let issues = assemblyIssues
            if issues.isEmpty {
                Label("Kollision & Verbundenheit geprüft · keine Funde", systemImage: "checkmark.seal.fill")
                    .font(.subheadline).foregroundStyle(.green)
            } else {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: issue.category.symbol)
                            .foregroundStyle(issue.severity == .error ? .red : Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).font(.subheadline.weight(.semibold))
                            if let reference = issue.reference {
                                Text(reference).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            }
                            Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink {
                    ValidationCheckView(project: project)
                } label: {
                    Label("In der Maßkontrolle korrigieren", systemImage: "arrow.right.circle")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Prüfung")
        }
    }
}
