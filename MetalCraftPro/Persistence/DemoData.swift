import Foundation
import SwiftData

/// Real, editable example data only. No fictitious photos, imported sketches or exports.
@MainActor
enum DemoData {
    static func seedIfNeeded(context: ModelContext) throws {
        let profiles = try context.fetch(FetchDescriptor<MCProfile>())
        let existingIDs = Set(profiles.map(\.id))
        for spec in ProfileCatalog.standardCatalog() where !existingIDs.contains(spec.id) {
            context.insert(try MCProfile(spec: spec))
        }
        // Migrationen: Bestehende Demo-Projekte erhalten Querstreben, die Baugruppe,
        // die Zuschnitt-Einträge (Schnittwinkel, Bearbeitungen) und Beispiel-Nähte.
        let states = try context.fetch(FetchDescriptor<MCStoreState>())
        if let state = states.first, state.version < 5 {
            for project in try context.fetch(FetchDescriptor<MCProject>()) {
                addMissingBars(to: project)
                addMissingAssembly(to: project)
                addMissingCutItems(to: project)
                addMissingWelds(to: project)
            }
            state.version = 5
        }
        guard states.isEmpty else {
            try context.save()
            return
        }
        if try context.fetchCount(FetchDescriptor<MCProject>()) == 0 {
            let project = MCProject(
                name: "Gartentor 1200 × 800", number: "2024-001",
                projectDescription: "Demo: Gartentor 1200×800 aus 40×40×2. Vier stumpf gestoßene Rahmenprofile; horizontale Teile durchgehend, vertikale Teile dazwischen; sechs Rundstahl-Querstreben Ø12 im Innenmaß. Baugruppe: Gartentor → Rahmen, Querstrebe, Scharniere, Schloss. Idealisiertes Profil ohne Eckradien.",
                widthMm: 1200, heightMm: 800, thumbnailStyle: "frame"
            )
            context.insert(project)
            project.profile = try context.fetch(FetchDescriptor<MCProfile>()).first { $0.id == ProfileCatalog.squareTube40x40x2.id }
            populateFrame(project)
        }
        context.insert(MCStoreState(version: 5))
        try context.save()
    }

    /// Schnittwinkel und Bearbeitungen je Bauteil als Zuschnitt-Einträge.
    /// Basis: 90°-Stiche; die Querstreben erhalten exemplarisch die Bohrung Ø10.
    static func addMissingCutItems(to project: MCProject) {
        guard project.cutItems.isEmpty else { return }
        for part in project.parts.sorted(by: { $0.positionNumber < $1.positionNumber }) {
            guard part.role != "hardware", part.lengthMm > 0 else { continue }
            project.cutItems.append(MCCutItem(
                positionNumber: part.positionNumber, profileName: part.profileName,
                lengthMm: part.lengthMm, angleADeg: 90, angleBDeg: 90, quantity: part.quantity,
                machining: part.role == "strebe" ? "Bohrung Ø10" : "", partID: part.id))
        }
    }

    /// Beispiel-Nähte an der Querstrebe: WIG mit den Parametern des Mockups,
    /// als Ausgangspunkt für das Schweißprotokoll je Bauteil.
    static func addMissingWelds(to project: MCProject) {
        guard project.welds.isEmpty else { return }
        guard let bar = project.parts.first(where: { $0.role == "strebe" }) else { return }
        for label in ["Rahmen links unten", "Querstrebe Mitte", "Rahmen rechts unten"] {
            let weld = MCWeld(method: "wig", material: project.materialGrade,
                              thicknessMm: project.profileSpec.thicknessMm,
                              filler: "WIG Ø2,4 · ER70S-6", gas: "Argon 4.6 · 10 l/min",
                              currentA: 95, voltageV: 12.5, wireFeedMMin: 0,
                              position: "PA (flach)", seamType: "Kehlnaht a3",
                              sequence: "1 → 2 → 3", label: label, partID: bar.id)
            project.welds.append(weld)
        }
    }

    /// Pos. 5: sechs vertikale Rundstahl-Streben, parametrisch über das Innenmaß.
    static func addMissingBars(to project: MCProject) {
        let hasFrame = project.parts.contains { $0.role == "rahmen_oben" }
        let hasBars = project.parts.contains { $0.role == "strebe" }
        guard hasFrame, !hasBars, let barProfile = ProfileCatalog.spec(named: "Ø12") else { return }
        let nextPosition = (project.parts.map(\.positionNumber).max() ?? 0) + 1
        project.parts.append(MCPart(name: "Querstrebe", positionNumber: nextPosition, quantity: 6,
                                    role: "strebe", isParametric: true, profileSpec: barProfile,
                                    remark: "Gleichmäßig im Innenmaß verteilt · Schnitt 90°"))
    }

    /// Baugruppe Gartentor → Rahmen (Pos. 1–4), Querstrebe (5), Scharnier 1 (6),
    /// Scharnier 2 (7), Schloss (8). Unterbau-Gerüst für jede Baugruppenansicht.
    static func addMissingAssembly(to project: MCProject) {
        let frameRoles: Set<String> = ["rahmen_oben", "rahmen_unten", "rahmen_links", "rahmen_rechts"]
        guard project.parts.contains(where: { $0.role.map(frameRoles.contains) == true }) else { return }
        guard !project.assemblies.contains(where: { $0.name == "Gartentor" }) else { return }

        if !project.parts.contains(where: { $0.role == "hardware" }) {
            var nextPosition = (project.parts.map(\.positionNumber).max() ?? 0) + 1
            for hardware in ["Scharnier 1", "Scharnier 2", "Schloss"] {
                project.parts.append(MCPart(name: hardware, positionNumber: nextPosition, quantity: 1,
                                            role: "hardware", remark: "Zukaufteil (Referenz)"))
                nextPosition += 1
            }
        }

        let framePartIDs = project.parts.filter { $0.role.map(frameRoles.contains) == true }.map(\.id)
        let gate = MCAssembly(name: "Gartentor", positionNumber: 1)
        let frame = MCAssembly(name: "Rahmen", positionNumber: 1)
        frame.partIDs = framePartIDs
        frame.parentAssemblyID = gate.id
        gate.childAssemblyIDs = [frame.id]
        gate.partIDs = project.parts.filter { !framePartIDs.contains($0.id) }.map(\.id)
        project.assemblies.append(gate)
        project.assemblies.append(frame)
    }

    static func populateFrame(_ project: MCProject) {
        project.thumbnailStyle = "frame"
        project.drawings.append(MCDrawing(title: "Vorderansicht Rahmen", scale: "1:5"))
        for (role, label) in [("outer", "Rahmenkontur außen"), ("inner", "Rahmenkontur innen")] {
            let record = MCGeometryRecord(element: .point(.zero), label: label)
            record.payload = Data()
            record.parameterRole = role
            project.geometryRecords.append(record)
        }
        for (key, label) in [("width", "Breite außen"), ("height", "Höhe außen"), ("innerWidth", "Innenmaß Breite"), ("innerHeight", "Innenmaß Höhe")] {
            let dimension = MCDimension(label: label, valueMm: 0)
            dimension.parameterKey = key
            project.dimensions.append(dimension)
        }
        let corners = MCConstraint(kind: "perpendicular", note: "Rechteckkontur: vier rechte Winkel")
        corners.geometryIDs = project.geometryRecords.map(\.id)
        project.constraints.append(corners)
        let parallel = MCConstraint(kind: "parallel", note: "Gegenüberliegende Rechteckseiten parallel")
        parallel.geometryIDs = project.geometryRecords.map(\.id)
        project.constraints.append(parallel)
        for (index, entry) in [("Rahmen oben", "rahmen_oben"), ("Rahmen unten", "rahmen_unten"), ("Rahmen links", "rahmen_links"), ("Rahmen rechts", "rahmen_rechts")].enumerated() {
            project.parts.append(MCPart(name: entry.0, positionNumber: index + 1, role: entry.1, isParametric: true, remark: "Stumpfer Stoß · Schnitt 90°"))
        }
        addMissingBars(to: project)
        addMissingAssembly(to: project)
        addMissingCutItems(to: project)
        addMissingWelds(to: project)
        let material = MCMaterial(name: "Rahmenprofil", grade: "", profileTypeName: "", weightPerMeterKg: 0)
        material.usesProjectProfile = true
        project.materials.append(material)
        project.revisions.append(MCRevision(label: "A", note: "Projekt angelegt"))
    }
}
