import Foundation
import SwiftData
import Observation
import SQLite3
import UIKit

/// Injected, main-actor persistence boundary. Each accepted user action is one durable
/// transaction. SQLite WAL recovers interrupted transactions; consistent local snapshots
/// provide a second recovery path without ever replacing a failed store with empty data.
@MainActor @Observable
final class LocalStore {
    var container: ModelContainer?
    var startupProblem: String?
    var notice: String?
    @ObservationIgnored private var configuration: ModelConfiguration?

    static var schema: Schema {
        Schema([MCProject.self, MCDrawing.self, MCSketch.self, MCGeometryRecord.self,
                MCConstraint.self, MCDimension.self, MCPart.self, MCProfile.self,
                MCMaterial.self, MCAssembly.self, MCAssemblyStep.self, MCCutItem.self,
                MCWeld.self, MCMeasurement.self, MCPhoto.self, MCDocument.self,
                MCRevision.self, MCChecklistItem.self, MCStoreState.self])
    }

    func open() {
        guard container == nil else { return }
        startupProblem = nil
        let schema = Self.schema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        configuration = config
        do {
            let opened: ModelContainer
            do {
                let fm = FileManager.default
                let interrupted = fm.fileExists(atPath: config.url.appendingPathExtension("recovery-pending").path)
                let storeExists = fm.fileExists(atPath: config.url.path)
                let hasBackup = SQLiteSnapshot.locations(store: config.url)
                    .contains { fm.fileExists(atPath: $0.path) }
                // A stale marker means a previous snapshot was interrupted, not that
                // the primary store is unreadable. Prefer opening the existing store;
                // force recovery only when the store itself is missing.
                if !storeExists && (interrupted || hasBackup) { throw StoreError.unavailable }
                opened = try ModelContainer(for: schema, configurations: [config])
                if interrupted {
                    notice = "Die Datenbank wurde geöffnet. Die unterbrochene Sicherung wird erneuert."
                }
            } catch {
                opened = try recover(schema: schema, config: config)
                notice = "Aus einer intakten lokalen Sicherung wiederhergestellt. Bitte prüfe den Projektstand."
            }
            opened.mainContext.autosaveEnabled = true
            do {
                try DemoData.seedIfNeeded(context: opened.mainContext)
            } catch {
                opened.mainContext.rollback()
                startupProblem = "Die lokale Datenbank wurde gefunden, konnte aber nicht sicher vorbereitet werden. Deine Projekte und Sicherungen bleiben erhalten. Prüfe den freien Gerätespeicher, starte die App neu und versuche es erneut."
                return
            }
            container = opened
            snapshot()
            #if DEBUG
            // Regression checks are opt-in: never run the entire diagnostic suite as a
            // side effect of opening the user's local database on every debug launch.
            if ProcessInfo.processInfo.arguments.contains("-runCoreRegressionTests") {
                CoreRegressionTests.run()
            }
            #endif
        } catch {
            startupProblem = "Die lokale Datenbank konnte nicht gelesen werden. Deine Projekte und Sicherungen wurden nicht gelöscht. Prüfe den freien Gerätespeicher, starte die App neu und tippe erneut auf „Erneut versuchen“. Wenn der Fehler bleibt, lösche die App nicht, damit lokale Dateien erhalten bleiben."
        }
    }

    enum StoreError: LocalizedError {
        case unavailable, saving, invalidName, invalidNumber, invalidParameters
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Die lokale Datenbank ist noch nicht verfügbar."
            case .saving: return "Nicht gespeichert. Bitte prüfe den freien Gerätespeicher und versuche es erneut."
            case .invalidName: return "Bitte gib einen Projektnamen ein."
            case .invalidNumber: return "Diese Projektnummer wird bereits verwendet."
            case .invalidParameters: return "Breite und Höhe müssen größer als zwei Profilbreiten und höchstens 100.000 mm sein."
            }
        }
    }

    private var context: ModelContext {
        get throws {
            guard let context = container?.mainContext else { throw StoreError.unavailable }
            return context
        }
    }

    func save() throws {
        let context = try context
        do { try context.save() }
        catch { context.rollback(); throw StoreError.saving }
        snapshot()
    }

    func saveOnBackground() {
        guard let context = container?.mainContext, context.hasChanges else { return }
        do { try save() } catch { notice = error.localizedDescription }
    }

    func create(name: String, number: String, description: String, frame: Bool) throws {
        let context = try context
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalidName }
        let projects = try context.fetch(FetchDescriptor<MCProject>())
        let number = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = Calendar.current.component(.year, from: Date())
        var index = 1
        var generated = String(format: "%d-%03d", year, index)
        let used = Set(projects.map(\.number))
        while used.contains(generated) { index += 1; generated = String(format: "%d-%03d", year, index) }
        let finalNumber = number.isEmpty ? generated : number
        guard !used.contains(finalNumber) else { throw StoreError.invalidNumber }
        let project = MCProject(name: name, number: finalNumber, projectDescription: description)
        context.insert(project)
        project.profile = try context.fetch(FetchDescriptor<MCProfile>()).first { $0.id == ProfileCatalog.squareTube40x40x2.id }
        if frame { DemoData.populateFrame(project) }
        else { project.revisions.append(MCRevision(label: "A", note: "Projekt angelegt")) }
        try save()
    }

    func rename(_ project: MCProject, to value: String) throws {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalidName }
        guard project.name != name else { return }
        let previous = project.name
        project.name = name
        record(project, note: "Name: \(previous) → \(name)")
        try save()
    }

    func delete(_ project: MCProject) throws {
        let sketchFiles = project.sketches.map(\.imageFileName)
        let photoFiles = project.photos.map(\.imageFileName)
        try context.delete(project)
        try save()
        for name in sketchFiles { SketchImageStore.delete(name) }
        for name in photoFiles { PhotoImageStore.delete(name) }
    }

    /// Stores the local photo file and its SwiftData record as one user transaction.
    @discardableResult func addPhoto(_ project: MCProject, imageData: Data, category: String,
                                     caption: String, partID: UUID?) throws -> MCPhoto {
        guard PhotoCategory.allCases.contains(where: { $0.rawValue == category }),
              !imageData.isEmpty,
              partID == nil || project.parts.contains(where: { $0.id == partID }) else {
            throw StoreError.invalidParameters
        }
        guard UIImage(data: imageData) != nil else { throw StoreError.invalidParameters }
        let fileName = try PhotoImageStore.save(imageData)
        let photo = MCPhoto(category: category,
                            caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                            imageFileName: fileName, partID: partID)
        project.photos.append(photo)
        let partLabel = partID.flatMap { id in project.parts.first(where: { $0.id == id }) }
            .map { " · Pos. \($0.positionNumber) \($0.name)" } ?? ""
        record(project, note: "Fertigungsfoto hinzugefügt · \(photo.categoryLabel)\(partLabel)")
        do { try save() }
        catch {
            PhotoImageStore.delete(fileName)
            throw error
        }
        return photo
    }

    func updatePhoto(_ photo: MCPhoto, category: String, caption: String, partID: UUID?) throws {
        guard let project = photo.project,
              PhotoCategory.allCases.contains(where: { $0.rawValue == category }),
              partID == nil || project.parts.contains(where: { $0.id == partID }) else {
            throw StoreError.invalidParameters
        }
        let cleanCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard photo.category != category || photo.caption != cleanCaption || photo.partID != partID else { return }
        photo.category = category
        photo.caption = cleanCaption
        photo.partID = partID
        record(project, note: "Fertigungsfoto aktualisiert · \(photo.categoryLabel)")
        try save()
    }

    func deletePhoto(_ photo: MCPhoto) throws {
        guard let project = photo.project else { throw StoreError.unavailable }
        let fileName = photo.imageFileName
        let label = photo.caption.isEmpty ? photo.categoryLabel : photo.caption
        try context.delete(photo)
        record(project, note: "Fertigungsfoto gelöscht · \(label)")
        try save()
        PhotoImageStore.delete(fileName)
    }

    /// Übernahme einer geprüften Skizze: Bild und strukturierte Erkennungsobjekte
    /// werden gespeichert, die akzeptierten Elemente von der Geometrie-Engine
    /// validiert und als Geometrie-Einträge übernommen. Ein Vorgang = eine Transaktion.
    func adoptSketch(_ project: MCProject, source: String, title: String, imageData: Data?, result: RecognitionResult) throws -> String {
        var fileName: String?
        if let imageData { fileName = try SketchImageStore.save(imageData) }
        let sketch = MCSketch(title: title, source: source)
        sketch.imageFileName = fileName
        sketch.payload = try JSONEncoder().encode(result)
        sketch.status = "uebernommen"
        sketch.recognizedCount = result.elements.filter(\.accepted).count
        project.sketches.append(sketch)

        let outcome = SketchAdoption.validatedGeometry(elements: result.elements, mmPerPixel: result.mmPerPixel,
                                                       imageWidthPx: result.imageWidthPx, imageHeightPx: result.imageHeightPx)
        for entry in outcome.geometry {
            project.geometryRecords.append(MCGeometryRecord(element: entry.element, label: "Skizze · \(entry.label)"))
        }
        var note = "Skizze „\(title)“ übernommen: \(outcome.geometry.count) validierte Elemente"
        if !outcome.rejected.isEmpty {
            note += ", \(outcome.rejected.count) ungültig verworfen (\(outcome.rejected.prefix(3).joined(separator: ", ")))"
        }
        invalidateApproval(project)
        record(project, note: note)
        do { try save() }
        catch {
            SketchImageStore.delete(fileName)
            throw error
        }
        return note
    }

    func updateParameters(_ project: MCProject, width: Double, height: Double, profile: MCProfile, material: String) throws {
        guard let spec = profile.spec,
              (try? FrameParameters(width: width, height: height, profile: spec)) != nil,
              !material.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidParameters }
        let old = "\(project.widthMm) × \(project.heightMm) mm, \(project.profileSpec.dimensionLabel), \(project.materialGrade)"
        guard project.widthMm != width || project.heightMm != height || project.profileSpec.id != spec.id || project.materialGrade != material else { return }
        project.widthMm = width; project.heightMm = height
        project.profile = profile
        project.profileSpecData = Data()
        project.materialGrade = material.trimmingCharacters(in: .whitespacesAndNewlines)
        invalidateApproval(project)
        record(project, note: "Parameter: \(old) → \(width) × \(height) mm, \(spec.dimensionLabel), \(project.materialGrade)")
        try save()
    }

    /// CAD-Editor: jedes bestätigte Bearbeitungsergebnis ist eine Transaktion.
    func persistDrawing(_ project: MCProject) throws {
        project.updatedAt = Date()
        invalidateApproval(project)
        try save()
    }

    /// Parametrisches Maß im CAD-Editor: ändert die führenden Projektparameter.
    func setFrameParameter(_ project: MCProject, key: String, value: Double) throws {
        guard key == "width" || key == "height" else { throw StoreError.invalidParameters }
        let width = key == "width" ? value : project.widthMm
        let height = key == "height" ? value : project.heightMm
        guard (try? FrameParameters(width: width, height: height, profile: project.profileSpec)) != nil else {
            throw StoreError.invalidParameters
        }
        let old = key == "width" ? project.widthMm : project.heightMm
        guard abs(old - value) > 1e-9 else { return }
        if key == "width" { project.widthMm = value } else { project.heightMm = value }
        invalidateApproval(project)
        record(project, note: "\(key == "width" ? "Breite" : "Höhe") im CAD-Editor: \(DeFormat.number(old)) → \(DeFormat.number(value)) mm")
        try save()
    }

    // MARK: Maßkontrolle & Freigabe

    /// Expliziter Bestätigungsschritt: nur ohne Fehler möglich; jede Geometrieänderung
    /// hebt die Freigabe wieder auf (Änderungsprotokoll führt beide Ereignisse).
    func approveGeometry(_ project: MCProject) throws {
        guard project.geometryApprovedAt == nil else { return }
        project.geometryApprovedAt = Date()
        record(project, note: "Geometrie freigegeben (Maßkontrolle ohne Fehler bestanden)")
        try save()
    }

    func revokeGeometryApproval(_ project: MCProject) throws {
        guard project.geometryApprovedAt != nil else { return }
        project.geometryApprovedAt = nil
        record(project, note: "Geometriefreigabe zurückgenommen")
        try save()
    }

    private func invalidateApproval(_ project: MCProject) {
        guard project.geometryApprovedAt != nil else { return }
        project.geometryApprovedAt = nil
        record(project, note: "Geometriefreigabe aufgehoben: Geometrie wurde geändert")
    }

    /// Korrektur aus der Maßkontrolle: Bauteillänge auf den erwarteten Wert setzen.
    func fixPartLength(_ part: MCPart, to value: Double) throws {
        try Geometry2D.positive(value)
        guard let project = part.project else { throw StoreError.unavailable }
        let old = part.lengthMm
        guard abs(old - value) > 1e-9 else { return }
        part.lengthMm = value
        part.isParametric = false
        invalidateApproval(project)
        record(project, note: "Bauteil Pos. \(part.positionNumber): Länge \(DeFormat.number(old)) → \(DeFormat.number(value)) mm (Maßkontrolle)")
        try save()
    }

    /// Ungültigen Geometrie-Eintrag (Skizzenübernahme) aus der Maßkontrolle entfernen.
    func removeGeometryRecord(_ project: MCProject, recordID: UUID) throws {
        guard let entry = project.geometryRecords.first(where: { $0.id == recordID }) else { return }
        let label = entry.label
        let context = try context
        context.delete(entry)
        invalidateApproval(project)
        record(project, note: "Ungültiger Geometrie-Eintrag „\(label)“ entfernt (Maßkontrolle)")
        try save()
    }

    /// Ungültiges CAD-Element aus der Maßkontrolle entfernen.
    func removeCADElement(_ project: MCProject, elementID: UUID) throws {
        guard var drawing = project.cadDrawing, drawing.element(with: elementID) != nil else { return }
        drawing.remove(ids: [elementID])
        project.cadDrawing = drawing
        invalidateApproval(project)
        record(project, note: "Ungültiges CAD-Element entfernt (Maßkontrolle)")
        try save()
    }

    // MARK: Baugruppen-Verwaltung

    /// Neue Baugruppe, optional als Unterbaugruppe einer bestehenden.
    @discardableResult func addAssembly(_ project: MCProject, name: String, under parent: MCAssembly? = nil) throws -> MCAssembly {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalidName }
        let assembly = MCAssembly(name: name)
        let siblings = project.assemblies.filter { $0.parentAssemblyID == parent?.id }
        assembly.positionNumber = (siblings.map(\.positionNumber).max() ?? 0) + 1
        project.assemblies.append(assembly)
        if let parent {
            assembly.parentAssemblyID = parent.id
            parent.childAssemblyIDs.append(assembly.id)
        }
        record(project, note: "Baugruppe „\(name)“ angelegt\(parent.map { " in „\($0.name)“" } ?? "")")
        try save()
        return assembly
    }

    func renameAssembly(_ assembly: MCAssembly, to value: String) throws {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalidName }
        guard name != assembly.name else { return }
        let previous = assembly.name
        assembly.name = name
        if let project = assembly.project { record(project, note: "Baugruppe „\(previous)“ umbenannt in „\(name)“") }
        try save()
    }

    /// Baugruppe löschen: Unterbaugruppen werden mitgelöscht, Bauteile bleiben im Projekt
    /// und sind danach nicht mehr zugeordnet.
    func deleteAssembly(_ assembly: MCAssembly) throws {
        guard let project = assembly.project else { throw StoreError.unavailable }
        for childID in assembly.childAssemblyIDs {
            if let child = project.assemblies.first(where: { $0.id == childID }) {
                try deleteAssembly(child)
            }
        }
        let name = assembly.name
        if let parentID = assembly.parentAssemblyID,
           let parent = project.assemblies.first(where: { $0.id == parentID }) {
            parent.childAssemblyIDs.removeAll { $0 == assembly.id }
        }
        assembly.partIDs = []
        let context = try context
        context.delete(assembly)
        record(project, note: "Baugruppe „\(name)“ gelöscht · Bauteile bleiben erhalten")
        try save()
    }

    /// Baugruppe auflösen: Bauteile und Unterbaugruppen wandern eine Ebene nach oben.
    func dissolveAssembly(_ assembly: MCAssembly) throws {
        guard let project = assembly.project else { throw StoreError.unavailable }
        let parent = assembly.parentAssemblyID.flatMap { id in project.assemblies.first { $0.id == id } }
        for childID in assembly.childAssemblyIDs {
            guard let child = project.assemblies.first(where: { $0.id == childID }) else { continue }
            child.parentAssemblyID = parent?.id
            parent?.childAssemblyIDs.append(child.id)
        }
        let partIDs = assembly.partIDs
        parent?.partIDs.append(contentsOf: partIDs)
        assembly.partIDs = []
        assembly.childAssemblyIDs = []
        let name = assembly.name
        let context = try context
        context.delete(assembly)
        record(project, note: "Baugruppe „\(name)“ aufgelöst · Inhalte eine Ebene höher")
        try save()
    }

    /// Bauteil einer Baugruppe zuordnen (oder mit nil herauslösen). Ein Bauteil sitzt
    /// immer in höchstens einer Baugruppe – die Zuordnung bleibt eindeutig.
    func movePart(_ part: MCPart, into assembly: MCAssembly?) throws {
        guard let project = part.project else { throw StoreError.unavailable }
        guard assembly?.project?.id == project.id || assembly == nil else { throw StoreError.invalidParameters }
        for other in project.assemblies { other.partIDs.removeAll { $0 == part.id } }
        assembly?.partIDs.append(part.id)
        let note = assembly.map { "Pos. \(part.positionNumber) · \(part.name) in „\($0.name)“ aufgenommen" }
            ?? "Pos. \(part.positionNumber) · \(part.name) aus der Baugruppe herausgelöst"
        record(project, note: note)
        try save()
    }

    /// Reihenfolge innerhalb einer Baugruppe (Bauteile und Unterbaugruppen getrennt).
    func reorderAssemblyChildren(_ assembly: MCAssembly, partIDs: [UUID], childAssemblyIDs: [UUID]) throws {
        guard assembly.partIDs != partIDs || assembly.childAssemblyIDs != childAssemblyIDs else { return }
        assembly.partIDs = partIDs
        assembly.childAssemblyIDs = childAssemblyIDs
        if let project = assembly.project { record(project, note: "Reihenfolge in „\(assembly.name)“ geändert") }
        try save()
    }

    /// Reihenfolge der Baugruppen auf Wurzelebene (über die Positionsnummern).
    func resequenceRootAssemblies(_ project: MCProject, moving sourceID: UUID, near anchorID: UUID?) throws {
        var ordered = project.assemblies
            .filter { $0.parentAssemblyID == nil }
            .sorted { $0.positionNumber < $1.positionNumber }
            .map(\.id)
        guard ordered.contains(sourceID) else { return }
        ordered.removeAll { $0 == sourceID }
        if let anchorID, let index = ordered.firstIndex(of: anchorID) {
            ordered.insert(sourceID, at: index)
        } else {
            ordered.append(sourceID)
        }
        for (index, id) in ordered.enumerated() {
            project.assemblies.first { $0.id == id }?.positionNumber = index + 1
        }
        record(project, note: "Reihenfolge der Baugruppen geändert")
        try save()
    }

    // MARK: Montage-Builder

    private func rootAssembly(_ project: MCProject) -> MCAssembly? {
        project.assemblies
            .filter { $0.parentAssemblyID == nil }
            .sorted { $0.positionNumber < $1.positionNumber }
            .first ?? project.assemblies.first
    }

    /// Erzeugt die Montageabfolge deterministisch aus der Baugruppe – nur solange
    /// noch keine Schritte existieren; Benutzeränderungen bleiben erhalten.
    func ensureAssemblySteps(_ project: MCProject) throws {
        guard let assembly = rootAssembly(project), assembly.orderedSteps.isEmpty else { return }
        let parts = project.parts.map { part in
            SequencePart(id: part.id, name: part.name, positionNumber: part.positionNumber,
                         quantity: part.quantity, role: part.role, profileName: part.profileName,
                         lengthMm: part.lengthMm)
        }
        let blueprints = AssemblySequenceBuilder.blueprints(widthMm: project.widthMm, heightMm: project.heightMm, parts: parts)
        for (index, blueprint) in blueprints.enumerated() {
            let step = MCAssemblyStep(
                orderIndex: index, title: blueprint.title, partID: blueprint.partIDs.first,
                partName: blueprint.partNames.joined(separator: " · "), movement: blueprint.movement,
                connection: blueprint.connection, tool: blueprint.tool, lengthMm: blueprint.lengthMm,
                positionNote: blueprint.positionNote, note: blueprint.note)
            step.extraPartIDs = Array(blueprint.partIDs.dropFirst())
            assembly.steps.append(step)
        }
        record(project, note: "Montageabfolge automatisch erzeugt (\(blueprints.count) Schritte)")
        try save()
    }

    /// Rebuilds generated checklist rows from the current cut list, root assembly sequence,
    /// and weld records. Stable source keys preserve completion timestamps across edits.
    func synchronizeChecklist(_ project: MCProject) throws {
        try ensureAssemblySteps(project)

        var desired: [String: (kind: String, title: String, detail: String)] = [:]
        let prefix = project.id.uuidString

        for entry in ExportBridge.cutEntries(for: project) {
            let key = "\(prefix):cut:\(entry.id.uuidString)"
            let notes = entry.machiningNotes.isEmpty ? "" : " · \(entry.machiningNotes.joined(separator: " · "))"
            desired[key] = ("zuschnitt", "Pos. \(entry.positionNumber) · Schneiden",
                            "\(entry.quantity) × \(entry.displayLabel) · \(DeFormat.number(entry.lengthMm)) mm · Schnitt \(entry.angleLabel)\(notes)")
        }

        let root = rootAssembly(project)
        let steps = root?.orderedSteps ?? []
        var repeatedStepIdentityCounts: [String: Int] = [:]
        for (index, step) in steps.enumerated() {
            let stepParts = step.allPartIDs.compactMap { id in project.parts.first(where: { $0.id == id }) }
            let hasTop = stepParts.contains { $0.role == "rahmen_oben" }
            let laterHasTop = steps.dropFirst(index + 1).contains { later in
                later.allPartIDs.contains { id in project.parts.first(where: { $0.id == id })?.role == "rahmen_oben" }
            }
            let checkTitle: String?
            let target: Double?
            if hasTop && !laterHasTop {
                checkTitle = "Diagonalen prüfen"
                target = (project.widthMm * project.widthMm + project.heightMm * project.heightMm).squareRoot()
            } else if let length = stepParts.map(\.lengthMm).max(), length.isFinite, length > 0 {
                checkTitle = "Länge prüfen"
                target = length
            } else {
                checkTitle = nil
                target = nil
            }
            let action = checkTitle.map { "Prüfung: \($0) · Soll \(DeFormat.number(target ?? 0)) mm" }
                ?? "Montieren · \(step.movement)"
            let parts = step.partName.isEmpty ? stepParts.map(\.name).joined(separator: " · ") : step.partName
            let connection = step.connection.isEmpty ? "" : " · \(step.connection)"
            let position = step.positionNote.isEmpty ? "" : " · \(step.positionNote)"
            let detail = ["Schritt \(index + 1)", action, parts, "\(step.tool.isEmpty ? "" : step.tool)"]
                .filter { !$0.isEmpty }.joined(separator: " · ") + connection + position
            let stableParts = step.allPartIDs.map(\.uuidString).sorted()
            let baseIdentity = stableParts.isEmpty
                ? "title:\(step.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
                : "parts:\(stableParts.joined(separator: "+"))"
            let occurrence = repeatedStepIdentityCounts[baseIdentity, default: 0]
            repeatedStepIdentityCounts[baseIdentity] = occurrence + 1
            let assemblyID = root?.id.uuidString ?? "none"
            let key = "\(prefix):assembly:\(assemblyID):\(baseIdentity):\(occurrence)"
            desired[key] = (checkTitle == nil ? "montage" : "pruefung", step.title, detail)
        }

        for weld in project.welds {
            let part = weld.partID.flatMap { id in project.parts.first(where: { $0.id == id }) }
                .map { "Pos. \($0.positionNumber) · \($0.name)" } ?? "Projektnaht"
            let seam = weld.seamType.isEmpty ? weld.methodLabel : "\(weld.seamType) · \(weld.methodLabel)"
            let label = weld.label.isEmpty ? "Naht" : weld.label
            let key = "\(prefix):weld:\(weld.id.uuidString)"
            desired[key] = ("schweissen", "Naht schließen · \(label)", "\(part) · \(seam)")
        }

        var existing = Dictionary(project.checklistItems.map { ($0.sourceKey, $0) },
                                  uniquingKeysWith: { first, _ in first })
        var changed = false
        for (key, draft) in desired {
            if let item = existing.removeValue(forKey: key) {
                if item.kind != draft.kind || item.title != draft.title || item.detail != draft.detail {
                    item.kind = draft.kind
                    item.title = draft.title
                    item.detail = draft.detail
                    changed = true
                }
            } else {
                project.checklistItems.append(MCChecklistItem(sourceKey: key, kind: draft.kind,
                                                              title: draft.title, detail: draft.detail))
                changed = true
            }
        }
        if !existing.isEmpty {
            let context = try context
            for item in existing.values { context.delete(item) }
            changed = true
        }
        if changed { try save() }
    }

    /// Check-offs are durable, timestamped, and copied to the project's revision log.
    func setChecklistItem(_ item: MCChecklistItem, completed: Bool) throws {
        guard let project = item.project else { throw StoreError.unavailable }
        guard (item.completedAt != nil) != completed else { return }
        let timestamp = Date()
        item.completedAt = completed ? timestamp : nil
        let state = completed ? "erledigt" : "wieder offen"
        let date = completed ? " · \(timestamp.formatted(date: .numeric, time: .shortened))" : ""
        record(project, note: "Fertigungs-Checkliste · \(item.kindLabel): \(item.title) · \(state)\(date)")
        try save()
    }

    /// Reihenfolge ändern: Zielindex innerhalb der geordneten Schrittliste.
    func moveAssemblyStep(_ project: MCProject, step: MCAssemblyStep, to targetIndex: Int) throws {
        guard let assembly = step.assembly else { throw StoreError.unavailable }
        var ordered = assembly.orderedSteps
        guard let currentIndex = ordered.firstIndex(where: { $0.id == step.id }) else { return }
        let moved = ordered.remove(at: currentIndex)
        ordered.insert(moved, at: max(0, min(targetIndex, ordered.count)))
        for (index, entry) in ordered.enumerated() { entry.orderIndex = index }
        record(project, note: "Montage: „\(moved.title)“ verschoben")
        try save()
    }

    /// Schritt mit dem vorherigen zusammenfassen: dessen Bauteile wandern in den Vorgänger.
    func mergeAssemblyStep(_ project: MCProject, step: MCAssemblyStep) throws {
        guard let assembly = step.assembly else { throw StoreError.unavailable }
        let ordered = assembly.orderedSteps
        guard let index = ordered.firstIndex(where: { $0.id == step.id }), index > 0 else { return }
        let previous = ordered[index - 1]
        let mergedIDs = step.allPartIDs
        if previous.partID == nil {
            previous.partID = mergedIDs.first
            previous.extraPartIDs.append(contentsOf: mergedIDs.dropFirst())
        } else {
            previous.extraPartIDs.append(contentsOf: mergedIDs)
        }
        previous.partName = previous.allPartIDs.compactMap { id in
            project.parts.first(where: { $0.id == id })?.name
        }.joined(separator: " · ")
        let title = step.title
        let context = try context
        context.delete(step)
        for (position, entry) in assembly.orderedSteps.enumerated() { entry.orderIndex = position }
        record(project, note: "Montage: „\(title)“ mit dem vorherigen Schritt zusammengefasst")
        try save()
    }

    /// Automatisch erzeugte Abfolge neu aufbauen (Benutzeränderungen werden ersetzt).
    func regenerateAssemblySteps(_ project: MCProject) throws {
        guard let assembly = rootAssembly(project) else { return }
        let context = try context
        for step in assembly.steps { context.delete(step) }
        assembly.steps = []
        try ensureAssemblySteps(project)
    }

    /// Adds an independently timestamped site-survey measurement and its project-history entry.
    @discardableResult func addWorksiteMeasurement(_ project: MCProject, label: String, value: Double,
                                                    unit: String, part: MCPart?, note: String) throws -> MCMeasurement {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty, cleanLabel.count <= 120,
              value.isFinite, (0...1_000_000_000).contains(value),
              !cleanUnit.isEmpty, cleanUnit.count <= 24,
              cleanNote.count <= 2_000,
              part == nil || part?.project?.id == project.id else {
            throw StoreError.invalidParameters
        }
        let measurement = MCMeasurement(kind: "worksite", value: value, unit: cleanUnit,
                                        tolerance: 0, targetName: cleanLabel,
                                        label: cleanLabel, note: cleanNote.isEmpty ? nil : cleanNote,
                                        partID: part?.id)
        project.measurements.append(measurement)
        let partDescription = part.map { " · Pos. \($0.positionNumber) \($0.name)" } ?? ""
        let noteDescription = cleanNote.isEmpty ? "" : " · Notiz: \(cleanNote)"
        record(project, note: "Baustellen-Aufmaß erfasst: \(cleanLabel) · \(DeFormat.number(value)) \(cleanUnit)\(partDescription)\(noteDescription)")
        try save()
        return measurement
    }

    func deleteWorksiteMeasurement(_ measurement: MCMeasurement) throws {
        guard measurement.kind == "worksite", let project = measurement.project else {
            throw StoreError.invalidParameters
        }
        let context = try context
        context.delete(measurement)
        record(project, note: "Baustellen-Aufmaß gelöscht: \(measurement.displayLabel) · \(DeFormat.number(measurement.value)) \(measurement.unit)")
        try save()
    }

    func associateWorksitePhoto(_ photo: MCPhoto, with measurement: MCMeasurement) throws {
        guard measurement.kind == "worksite", let project = measurement.project,
              photo.project?.id == project.id,
              project.measurements.contains(where: { $0.id == measurement.id }),
              project.photos.contains(where: { $0.id == photo.id }) else {
            throw StoreError.invalidParameters
        }
        guard !measurement.photos.contains(where: { $0.id == photo.id }) else { return }
        measurement.photos.append(photo)
        let label = photo.caption.isEmpty ? photo.categoryLabel : photo.caption
        record(project, note: "Baustellen-Aufmaßfoto zugeordnet: „\(label)“ → „\(measurement.displayLabel)“")
        try save()
    }

    func removeWorksitePhoto(_ photo: MCPhoto, from measurement: MCMeasurement) throws {
        guard measurement.kind == "worksite", let project = measurement.project,
              photo.project?.id == project.id,
              project.measurements.contains(where: { $0.id == measurement.id }) else {
            throw StoreError.invalidParameters
        }
        guard measurement.photos.contains(where: { $0.id == photo.id }) else { return }
        measurement.photos.removeAll { $0.id == photo.id }
        let label = photo.caption.isEmpty ? photo.categoryLabel : photo.caption
        record(project, note: "Baustellen-Aufmaßfoto entfernt: „\(label)“ ← „\(measurement.displayLabel)“ · Projektfoto bleibt erhalten")
        try save()
    }

    @discardableResult func addWorksiteMeasurementPhoto(_ measurement: MCMeasurement, imageData: Data) throws -> MCPhoto {
        guard measurement.kind == "worksite", let project = measurement.project,
              project.measurements.contains(where: { $0.id == measurement.id }),
              !imageData.isEmpty, UIImage(data: imageData) != nil else {
            throw StoreError.invalidParameters
        }
        let fileName = try PhotoImageStore.save(imageData)
        let photo = MCPhoto(category: PhotoCategory.aufmass.rawValue, caption: measurement.displayLabel,
                            imageFileName: fileName, partID: measurement.partID)
        project.photos.append(photo)
        measurement.photos.append(photo)
        record(project, note: "Baustellen-Aufmaßfoto importiert und zugeordnet: „\(photo.caption)“ · \(measurement.displayLabel)")
        do { try save() }
        catch {
            PhotoImageStore.delete(fileName)
            throw error
        }
        return photo
    }

    /// Saves optional expected-value check data; a target and tolerance are always supplied or cleared together.
    func setWorksiteMeasurementCheck(_ measurement: MCMeasurement, targetValue: Double?, tolerance: Double?) throws {
        guard measurement.kind == "worksite", let project = measurement.project,
              project.measurements.contains(where: { $0.id == measurement.id }) else {
            throw StoreError.invalidParameters
        }
        if let targetValue, let tolerance {
            guard targetValue.isFinite, (0...1_000_000_000).contains(targetValue),
                  tolerance.isFinite, (0...1_000_000_000).contains(tolerance) else {
                throw StoreError.invalidParameters
            }
        } else if targetValue != nil || tolerance != nil {
            throw StoreError.invalidParameters
        }
        guard measurement.targetValue != targetValue || measurement.targetTolerance != tolerance else { return }

        let oldDescription: String
        if let oldTarget = measurement.targetValue, let oldTolerance = measurement.targetTolerance {
            oldDescription = "Soll \(DeFormat.number(oldTarget)) ±\(DeFormat.number(oldTolerance)) \(measurement.unit)"
        } else {
            oldDescription = "keine Sollprüfung"
        }
        let newDescription: String
        if let targetValue, let tolerance {
            newDescription = "Soll \(DeFormat.number(targetValue)) ±\(DeFormat.number(tolerance)) \(measurement.unit)"
        } else {
            newDescription = "keine Sollprüfung"
        }
        measurement.targetValue = targetValue
        measurement.targetTolerance = tolerance
        let outcome = measurement.worksiteCheckWithinTolerance.map { $0 ? " · innerhalb der Toleranz" : " · außerhalb der Toleranz" } ?? ""
        record(project, note: "Baustellen-Aufmaß-Prüfung „\(measurement.displayLabel)“: \(oldDescription) → \(newDescription)\(outcome)")
        try save()
    }

    /// Prüfung eines Montageschritts: Messwert wird gespeichert und ins Projektprotokoll geschrieben.
    @discardableResult func recordAssemblyCheck(_ project: MCProject, stepTitle: String, checkTitle: String,
                                                measuredMm: Double, targetMm: Double, toleranceMm: Double) throws -> CheckResult {
        let result = AssemblySequenceBuilder.evaluate(measuredMm: measuredMm, targetMm: targetMm, toleranceMm: toleranceMm)
        guard measuredMm.isFinite, measuredMm > 0 else { throw StoreError.invalidParameters }
        let measurement = MCMeasurement(kind: "montage", value: measuredMm, unit: "mm",
                                        tolerance: toleranceMm, targetName: "\(stepTitle) · \(checkTitle)")
        project.measurements.append(measurement)
        let outcome = result.withinTolerance ? "Innerhalb der definierten Toleranz" : "Außerhalb der Toleranz"
        record(project, note: "Montageprüfung „\(checkTitle)“ (\(stepTitle)): Messwert \(DeFormat.number(measuredMm)) mm, Sollwert \(DeFormat.number(targetMm, maxFractionDigits: 2)) mm, Toleranz ±\(DeFormat.number(toleranceMm)) mm – \(outcome)")
        try save()
        return result
    }

    @discardableResult func addProfile(_ spec: ProfileSpec) throws -> MCProfile {
        try spec.validate()
        let profile = try MCProfile(spec: spec)
        try context.insert(profile)
        try save()
        return profile
    }

    // MARK: Materialdatenbank (projektbezogen, lokal)

    func addMaterial(_ project: MCProject, name: String, grade: String, surface: String,
                     pricePerKg: Double?) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalidName }
        let grade = grade.trimmingCharacters(in: .whitespacesAndNewlines)
        let surface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pricePerKg { guard pricePerKg.isFinite, pricePerKg >= 0 else { throw StoreError.invalidParameters } }
        let material = MCMaterial(name: name, grade: grade, profileTypeName: "", weightPerMeterKg: 0,
                                  surface: surface, note: "")
        material.usesProjectProfile = true
        material.pricePerKg = pricePerKg
        project.materials.append(material)
        record(project, note: "Material „\(name)“ in der Materialdatenbank hinzugefügt")
        try save()
    }

    func setMaterialPrice(_ material: MCMaterial, pricePerKg: Double?) throws {
        guard let project = material.project else { throw StoreError.unavailable }
        if let pricePerKg { guard pricePerKg.isFinite, pricePerKg >= 0 else { throw StoreError.invalidParameters } }
        guard material.pricePerKg != pricePerKg else { return }
        let old = material.pricePerKg.map { "\(DeFormat.number($0, maxFractionDigits: 2)) €/kg" } ?? "kein Preis"
        let new = pricePerKg.map { "\(DeFormat.number($0, maxFractionDigits: 2)) €/kg" } ?? "kein Preis"
        material.pricePerKg = pricePerKg
        record(project, note: "Materialpreis „\(material.name)“: \(old) → \(new)")
        try save()
    }

    func setPurchasedPartPrice(_ part: MCPart, unitPrice: Double?) throws {
        guard part.isReference, let project = part.project else { throw StoreError.invalidParameters }
        if let unitPrice { guard unitPrice.isFinite, unitPrice >= 0 else { throw StoreError.invalidParameters } }
        guard part.unitPrice != unitPrice else { return }
        let old = part.unitPrice.map { "\(DeFormat.number($0, maxFractionDigits: 2)) € / Stück" } ?? "kein Stückpreis"
        let new = unitPrice.map { "\(DeFormat.number($0, maxFractionDigits: 2)) € / Stück" } ?? "kein Stückpreis"
        part.unitPrice = unitPrice
        record(project, note: "Zukaufteil Pos. \(part.positionNumber) „\(part.name)“: \(old) → \(new)")
        try save()
    }

    func setCuttingSettings(_ project: MCProject, stockLengthMm: Double, kerfMm: Double) throws {
        guard stockLengthMm.isFinite, (100...100_000).contains(stockLengthMm),
              kerfMm.isFinite, (0...50).contains(kerfMm), kerfMm < stockLengthMm else {
            throw StoreError.invalidParameters
        }
        let oldStock = project.stockBarLengthMm ?? 6000
        let oldKerf = project.sawKerfMm ?? 3
        guard oldStock != stockLengthMm || oldKerf != kerfMm else { return }
        project.stockBarLengthMm = stockLengthMm
        project.sawKerfMm = kerfMm
        record(project, note: "Schnittparameter geändert: Stangenlänge \(DeFormat.number(oldStock)) → \(DeFormat.number(stockLengthMm)) mm, Schnittfuge \(DeFormat.number(oldKerf)) → \(DeFormat.number(kerfMm)) mm")
        try save()
    }

    func setLaborRate(_ project: MCProject, eurosPerHour: Double?) throws {
        if let eurosPerHour {
            guard eurosPerHour.isFinite, (0...1_000_000).contains(eurosPerHour) else {
                throw StoreError.invalidParameters
            }
        }
        guard project.laborRateEURPerHour != eurosPerHour else { return }
        let old = project.laborRateEURPerHour.map { "\(DeFormat.number($0, maxFractionDigits: 2)) €/h" } ?? "kein Stundensatz"
        let new = eurosPerHour.map { "\(DeFormat.number($0, maxFractionDigits: 2)) €/h" } ?? "kein Stundensatz"
        project.laborRateEURPerHour = eurosPerHour
        record(project, note: "Stundensatz geändert: \(old) → \(new)")
        try save()
    }

    func setLaborHours(_ part: MCPart, hours: Double?) throws {
        guard let project = part.project,
              project.parts.contains(where: { $0.id == part.id }) else { throw StoreError.invalidParameters }
        if let hours {
            guard hours.isFinite, (0...1_000_000).contains(hours) else { throw StoreError.invalidParameters }
        }
        guard part.laborHours != hours else { return }
        let old = part.laborHours.map { "\(DeFormat.number($0, maxFractionDigits: 2)) h" } ?? "keine Arbeitszeit"
        let new = hours.map { "\(DeFormat.number($0, maxFractionDigits: 2)) h" } ?? "keine Arbeitszeit"
        part.laborHours = hours
        record(project, note: "Arbeitszeit Pos. \(part.positionNumber) „\(part.name)“: \(old) → \(new)")
        try save()
    }

    func removeMaterial(_ material: MCMaterial) throws {
        guard let project = material.project else { throw StoreError.unavailable }
        let name = material.name
        let context = try context
        context.delete(material)
        record(project, note: "Material „\(name)“ aus der Materialdatenbank entfernt")
        try save()
    }

    // MARK: Export

    /// Jeder Export wird als Transaktion im Änderungsprotokoll dokumentiert.
    func recordExport(_ project: MCProject, title: String) throws {
        record(project, note: "Export erstellt: \(title)")
        try save()
    }

    // MARK: Schweißen (MIG/MAG, WIG, E-Hand)

    /// Prüft die Nahtdaten: Pflichtfelder Bezeichnung, Verfahren, Werkstoff,
    /// Dicke, Strom und Spannung; Drahtvorschub ist optional (0 = nicht angegeben).
    private func validatedWeld(label: String, method: String, material: String, thicknessMm: Double,
                               filler: String, gas: String, currentA: Double, voltageV: Double,
                               wireFeedMMin: Double?, position: String, seamType: String,
                               sequence: String, note: String) throws -> WeldRecord {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw StoreError.invalidName }
        guard WeldRecord.methods.contains(method) else { throw StoreError.invalidParameters }
        let material = material.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !material.isEmpty else { throw StoreError.invalidParameters }
        try Geometry2D.positive(thicknessMm)
        try Geometry2D.positive(currentA)
        try Geometry2D.positive(voltageV)
        if let wireFeedMMin {
            guard wireFeedMMin.isFinite, wireFeedMMin >= 0 else { throw StoreError.invalidParameters }
        }
        return WeldRecord(label: label, method: method, material: material, thicknessMm: thicknessMm,
                          filler: filler.trimmingCharacters(in: .whitespacesAndNewlines),
                          gas: gas.trimmingCharacters(in: .whitespacesAndNewlines),
                          currentA: currentA, voltageV: voltageV,
                          wireFeedMMin: wireFeedMMin ?? 0,
                          position: position.trimmingCharacters(in: .whitespacesAndNewlines),
                          seamType: seamType.trimmingCharacters(in: .whitespacesAndNewlines),
                          sequence: sequence.trimmingCharacters(in: .whitespacesAndNewlines),
                          note: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Neue Naht dokumentieren: ein Vorgang = eine Transaktion mit Protokolleintrag.
    @discardableResult func addWeld(_ project: MCProject, part: MCPart?, label: String, method: String,
                                    material: String, thicknessMm: Double, filler: String, gas: String,
                                    currentA: Double, voltageV: Double, wireFeedMMin: Double?,
                                    position: String, seamType: String, sequence: String,
                                    note: String = "") throws -> MCWeld {
        let weldRecord = try validatedWeld(label: label, method: method, material: material,
                                           thicknessMm: thicknessMm, filler: filler, gas: gas,
                                           currentA: currentA, voltageV: voltageV,
                                           wireFeedMMin: wireFeedMMin, position: position,
                                           seamType: seamType, sequence: sequence, note: note)
        guard part == nil || part?.project?.id == project.id else { throw StoreError.invalidParameters }
        let weld = MCWeld(method: weldRecord.method, material: weldRecord.material,
                          thicknessMm: weldRecord.thicknessMm, filler: weldRecord.filler,
                          gas: weldRecord.gas, currentA: weldRecord.currentA, voltageV: weldRecord.voltageV,
                          wireFeedMMin: weldRecord.wireFeedMMin, position: weldRecord.position,
                          seamType: weldRecord.seamType, sequence: weldRecord.sequence,
                          label: weldRecord.label, partID: part?.id, note: weldRecord.note)
        project.welds.append(weld)
        record(project, note: "Naht „\(weldRecord.label)“ dokumentiert (\(weldRecord.methodLabel))")
        try save()
        return weld
    }

    /// Bestehende Naht korrigieren.
    func updateWeld(_ weld: MCWeld, label: String, method: String, material: String, thicknessMm: Double,
                    filler: String, gas: String, currentA: Double, voltageV: Double, wireFeedMMin: Double?,
                    position: String, seamType: String, sequence: String, note: String = "") throws {
        guard let project = weld.project else { throw StoreError.unavailable }
        let weldRecord = try validatedWeld(label: label, method: method, material: material,
                                           thicknessMm: thicknessMm, filler: filler, gas: gas,
                                           currentA: currentA, voltageV: voltageV,
                                           wireFeedMMin: wireFeedMMin, position: position,
                                           seamType: seamType, sequence: sequence, note: note)
        weld.label = weldRecord.label; weld.method = weldRecord.method; weld.material = weldRecord.material
        weld.thicknessMm = weldRecord.thicknessMm; weld.filler = weldRecord.filler; weld.gas = weldRecord.gas
        weld.currentA = weldRecord.currentA; weld.voltageV = weldRecord.voltageV
        weld.wireFeedMMin = weldRecord.wireFeedMMin; weld.position = weldRecord.position
        weld.seamType = weldRecord.seamType; weld.sequence = weldRecord.sequence; weld.note = weldRecord.note
        record(project, note: "Naht „\(weldRecord.label)“ aktualisiert (\(weldRecord.methodLabel))")
        try save()
    }

    func deleteWeld(_ weld: MCWeld) throws {
        guard let project = weld.project else { throw StoreError.unavailable }
        let label = weld.label
        let context = try context
        context.delete(weld)
        record(project, note: "Naht „\(label)“ gelöscht")
        try save()
    }

    // MARK: KI-Assistent (lokal, austauschbare Service-Schnittstelle)

    /// Wendet eine bestätigte Assistenten-Aktion an. Jede Aktion wurde vorher von der
    /// Geometrie-Engine validiert (AssistantValidator); nichts läuft ungeprüft in das Modell.
    @discardableResult func applyAssistant(_ project: MCProject, action: AssistantAction) throws -> String {
        let note: String
        switch action {
        case .changeParameter(let key, let value, let profile):
            switch key {
            case "breite":
                try Geometry2D.positive(value)
                guard (try? FrameParameters(width: value, height: project.heightMm, profile: project.profileSpec)) != nil else {
                    throw StoreError.invalidParameters
                }
                let old = project.widthMm
                guard abs(old - value) > 1e-9 else { return "Breite ist bereits \(DeFormat.number(value)) mm." }
                project.widthMm = value
                note = "KI-Assistent: Breite \(DeFormat.number(old)) → \(DeFormat.number(value)) mm"
            case "hoehe":
                try Geometry2D.positive(value)
                guard (try? FrameParameters(width: project.widthMm, height: value, profile: project.profileSpec)) != nil else {
                    throw StoreError.invalidParameters
                }
                let old = project.heightMm
                guard abs(old - value) > 1e-9 else { return "Höhe ist bereits \(DeFormat.number(value)) mm." }
                project.heightMm = value
                note = "KI-Assistent: Höhe \(DeFormat.number(old)) → \(DeFormat.number(value)) mm"
            case "profil":
                guard let spec = profile else { throw StoreError.invalidParameters }
                try spec.validate()
                guard (try? FrameParameters(width: project.widthMm, height: project.heightMm, profile: spec)) != nil else {
                    throw StoreError.invalidParameters
                }
                let old = project.profileSpec
                guard old != spec else { return "Profil ist bereits \(spec.dimensionLabel)." }
                project.profileSpec = spec
                note = "KI-Assistent: Profil \(old.dimensionLabel) → \(spec.dimensionLabel)"
            default:
                throw StoreError.invalidParameters
            }
        case .addPart(let name, let role, let profile, let length, let quantity, let remark):
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty else { throw StoreError.invalidName }
            guard quantity >= 1 else { throw StoreError.invalidParameters }
            var resolvedLength = length ?? 0
            var isParametric = false
            if resolvedLength == 0, let role, let parametric = project.frameParameters?.length(for: role) {
                resolvedLength = parametric
                isParametric = true
            }
            if !isParametric { try Geometry2D.positive(resolvedLength) }
            let positionNumber = (project.parts.map(\.positionNumber).max() ?? 0) + 1
            let part = MCPart(name: cleanName, positionNumber: positionNumber, quantity: quantity,
                              lengthMm: resolvedLength, role: role, isParametric: isParametric,
                              profileSpec: profile, remark: remark)
            project.parts.append(part)
            if let assembly = rootAssembly(project) { assembly.partIDs.append(part.id) }
            if !part.isReference && resolvedLength > 0 {
                project.cutItems.append(MCCutItem(positionNumber: positionNumber,
                                                  profileName: part.profileName, lengthMm: resolvedLength,
                                                  quantity: quantity, partID: part.id))
            }
            invalidateApproval(project)
            note = "KI-Assistent: Bauteil „\(cleanName)“ hinzugefügt (Pos. \(positionNumber), \(quantity) Stück)"
        case .removePart(let positionNumber, let name):
            guard let part = Self.resolvePart(in: project, positionNumber: positionNumber, name: name) else {
                throw StoreError.invalidParameters
            }
            let label = "Pos. \(part.positionNumber) · \(part.name)"
            let context = try context
            for cut in project.cutItems where cut.partID == part.id { context.delete(cut) }
            for assembly in project.assemblies {
                assembly.partIDs.removeAll { $0 == part.id }
                for step in assembly.steps {
                    step.extraPartIDs.removeAll { $0 == part.id }
                    if step.partID == part.id {
                        step.partID = step.extraPartIDs.first
                        if step.partID != nil { step.extraPartIDs.removeFirst() }
                    }
                }
                let doomed = assembly.steps.filter { $0.partID == nil && $0.extraPartIDs.isEmpty }
                for step in doomed {
                    context.delete(step)
                    assembly.steps.removeAll { $0.id == step.id }
                }
                for (index, step) in assembly.orderedSteps.enumerated() { step.orderIndex = index }
            }
            context.delete(part)
            invalidateApproval(project)
            note = "KI-Assistent: Bauteil \(label) entfernt"
        case .addHole(let diameter, let positionNumber):
            try Geometry2D.positive(diameter)
            guard let part = positionNumber.flatMap({ pos in project.parts.first(where: { $0.positionNumber == pos }) }) else {
                throw StoreError.invalidParameters
            }
            let machining = "Bohrung Ø\(DeFormat.number(diameter))"
            if let cut = project.cutItems.first(where: { $0.partID == part.id }) {
                guard !cut.machining.contains(machining) else {
                    return "Die Bohrung ist bereits an Pos. \(part.positionNumber) hinterlegt."
                }
                cut.machining = cut.machining.isEmpty ? machining : "\(cut.machining) · \(machining)"
            } else {
                project.cutItems.append(MCCutItem(positionNumber: part.positionNumber, profileName: part.profileName,
                                                  lengthMm: part.lengthMm, quantity: part.quantity,
                                                  machining: machining, partID: part.id))
            }
            note = "KI-Assistent: \(machining) an Pos. \(part.positionNumber)"
        case .changeDimension(let label, let value):
            try Geometry2D.positive(value)
            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let dimension = project.dimensions.first(where: {
                $0.label.localizedCaseInsensitiveCompare(cleanLabel) == .orderedSame
            }) else { throw StoreError.invalidParameters }
            let old = dimension.independentValueMm
            guard abs(old - value) > 1e-9 else { return "Maß „\(cleanLabel)“ ist bereits \(DeFormat.number(value)) mm." }
            dimension.independentValueMm = value
            note = "KI-Assistent: Maß „\(cleanLabel)“ \(DeFormat.number(old)) → \(DeFormat.number(value)) mm"
        case .createAssemblyStep(let title, let positionNumber):
            guard let assembly = rootAssembly(project) else { throw StoreError.unavailable }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { throw StoreError.invalidName }
            let part = positionNumber.flatMap { pos in project.parts.first(where: { $0.positionNumber == pos }) }
            let step = MCAssemblyStep(orderIndex: assembly.orderedSteps.count, title: cleanTitle,
                                      partID: part?.id, partName: part?.name ?? "",
                                      positionNote: part.map { "Pos. \($0.positionNumber)" } ?? "")
            assembly.steps.append(step)
            note = "KI-Assistent: Montageschritt „\(cleanTitle)“ ergänzt"
        case .report:
            return "Nur Anzeige – es wurde nichts geändert."
        }
        record(project, note: note)
        try save()
        return note
    }

    private static func resolvePart(in project: MCProject, positionNumber: Int?, name: String?) -> MCPart? {
        if let positionNumber {
            return project.parts.first(where: { $0.positionNumber == positionNumber })
        }
        guard let name else { return nil }
        let clean = name.lowercased()
        let matches = project.parts.filter { $0.name.lowercased().contains(clean) }
        return matches.count == 1 ? matches[0] : nil
    }

    private func record(_ project: MCProject, note: String) {
        project.updatedAt = Date()
        project.revisions.append(MCRevision(label: "R\(project.revisions.count + 1)", note: note))
    }

    private func snapshot() {
        guard let url = configuration?.url else { return }
        let pending = url.appendingPathExtension("recovery-pending")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: pending.path) {
                FileManager.default.createFile(atPath: pending.path, contents: nil)
            }
            try SQLiteSnapshot.capture(store: url)
            try FileManager.default.removeItem(at: pending)
        } catch {
            notice = "Der aktuelle Stand ist gespeichert, die zusätzliche lokale Sicherung konnte jedoch nicht erneuert werden. Bitte prüfe den freien Gerätespeicher."
        }
    }

    private func recover(schema: Schema, config: ModelConfiguration) throws -> ModelContainer {
        let fm = FileManager.default
        let original = config.url
        let backups = SQLiteSnapshot.locations(store: original)
        guard backups.contains(where: { fm.fileExists(atPath: $0.path) }) else { throw StoreError.unavailable }
        let archive = original.deletingLastPathComponent().appendingPathComponent("Recovery-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let suffixes = ["", "-wal", "-shm"]
        // Copy before touching the original; an interrupted recovery still leaves an archive.
        for suffix in suffixes {
            let source = URL(fileURLWithPath: original.path + suffix)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: archive.appendingPathComponent(original.lastPathComponent + suffix))
            }
        }
        for backup in backups where fm.fileExists(atPath: backup.path) {
            do {
                try SQLiteSnapshot.verify(backup)
                for suffix in suffixes {
                    let path = original.path + suffix
                    if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
                }
                try fm.copyItem(at: backup, to: original)
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                // A valid SQLite snapshot may still be incompatible with the current model.
                // Never discard it here: keep both generations for a future recovery attempt.
                continue
            }
        }
        // Neither snapshot opened. Preserve the original database and refuse a blank fallback.
        for suffix in suffixes {
            let destination = URL(fileURLWithPath: original.path + suffix)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            let source = archive.appendingPathComponent(original.lastPathComponent + suffix)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: destination) }
        }
        throw StoreError.unavailable
    }
}

/// SQLite's online backup API includes committed WAL pages. Copying a live .store file
/// alone is NOT a valid backup. Rotation is atomic and the previous generation is retained.
enum SQLiteSnapshot {
    enum Failure: Error { case database }
    static func locations(store: URL) -> [URL] {
        [store.appendingPathExtension("recovery"), store.appendingPathExtension("previous")]
    }
    static func capture(store: URL) throws {
        let fm = FileManager.default
        let urls = locations(store: store)
        let temporary = store.appendingPathExtension("\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        try copyDatabase(from: store, to: temporary)
        try verify(temporary)
        if fm.fileExists(atPath: urls[0].path) {
            try Data(contentsOf: urls[0]).write(to: urls[1], options: .atomic)
        }
        try Data(contentsOf: temporary).write(to: urls[0], options: .atomic)
        for url in urls where fm.fileExists(atPath: url.path) {
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
    }
    private static func copyDatabase(from source: URL, to destination: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        defer { sqlite3_close(input); sqlite3_close(output) }
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw Failure.database }
        sqlite3_busy_timeout(input, 2000); sqlite3_busy_timeout(output, 2000)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw Failure.database }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw Failure.database }
    }
    static func verify(_ url: URL) throws {
        var database: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0), String(cString: text) == "ok" else { throw Failure.database }
    }
}


/// Brücke zwischen SwiftData-Projekt und reiner Validierungs-Engine:
/// baut den unveränderlichen Eingabeschnappschuss für die Maßkontrolle.
@MainActor enum ValidationBridge {
    static func input(for project: MCProject) -> ValidationInput {
        let profile = project.profileSpec
        let parts = project.parts.map { part in
            ValidationInput.PartSnapshot(id: part.id, name: part.name, positionNumber: part.positionNumber,
                                         quantity: part.quantity, lengthMm: part.lengthMm,
                                         role: part.role, isParametric: part.isParametric)
        }
        let cuts = project.cutItems.map { cut in
            ValidationInput.CutSnapshot(id: cut.id, positionNumber: cut.positionNumber, profileName: cut.profileName,
                                        lengthMm: cut.lengthMm, angleADeg: cut.angleADeg, angleBDeg: cut.angleBDeg)
        }
        let assemblies = project.assemblies.map { assembly in
            ValidationInput.AssemblySnapshot(id: assembly.id, name: assembly.name, partIDs: assembly.partIDs,
                                             childAssemblyIDs: assembly.childAssemblyIDs,
                                             parentAssemblyID: assembly.parentAssemblyID,
                                             stepPartIDs: assembly.steps.compactMap(\.partID))
        }
        let records = project.geometryRecords.map { record in
            ValidationInput.GeometryRecordSnapshot(id: record.id, label: record.label, payload: record.payload)
        }
        return ValidationInput(widthMm: project.widthMm, heightMm: project.heightMm, profile: profile,
                               parts: parts, cuts: cuts, assemblies: assemblies,
                               geometryRecords: records, cadElements: project.cadDrawing?.elements ?? [])
    }
}

/// Brücke für die Export-Engine: unveränderliche Schnappschüsse aus dem Projekt.
@MainActor enum ExportBridge {
    static func input(for project: MCProject, generatedAt: Date) -> ExportInput {
        let parts = project.parts.sorted { $0.positionNumber < $1.positionNumber }.map { part in
            ExportPartInput(id: part.id, name: part.name, positionNumber: part.positionNumber,
                            quantity: part.quantity, lengthMm: part.lengthMm, role: part.role,
                            profile: part.profileSpec ?? project.profileSpec, isReference: part.isReference)
        }
        return ExportInput(projectName: project.name, projectNumber: project.number,
                           materialGrade: project.materialGrade, revisionLabel: project.revisionLabel,
                           widthMm: project.widthMm, heightMm: project.heightMm,
                           profile: project.profileSpec, parts: parts,
                           drawing: project.cadDrawing ?? CADDrawing(),
                           approved: project.isGeometryApproved, generatedAt: generatedAt)
    }

    static func weldRecords(for project: MCProject) -> [WeldRecord] {
        project.welds.map { weld in
            WeldRecord(label: weld.label, method: weld.method, material: weld.material,
                       thicknessMm: weld.thicknessMm, filler: weld.filler, gas: weld.gas,
                       currentA: weld.currentA, voltageV: weld.voltageV, wireFeedMMin: weld.wireFeedMMin,
                       position: weld.position, seamType: weld.seamType, sequence: weld.sequence,
                       note: weld.note, partID: weld.partID)
        }
    }

    static func cutEntries(for project: MCProject) -> [CutListEntry] {
        let parts = project.parts.map { part in
            CutListPartInput(id: part.id, name: part.name, positionNumber: part.positionNumber,
                             quantity: part.quantity, lengthMm: part.lengthMm,
                             profile: part.isReference ? nil : (part.profileSpec ?? project.profileSpec),
                             isReference: part.isReference, remark: part.remark)
        }
        var cuts = project.cutItems.map { cut in
            CutListCutInput(partID: cut.partID, angleADeg: cut.angleADeg, angleBDeg: cut.angleBDeg,
                            machining: cut.machining, remark: cut.remark)
        }
        let modelInput = ThreeDInput(widthMm: project.widthMm, heightMm: project.heightMm,
                                     profile: project.profileSpec,
                                     parts: project.parts.map { part in
                                         ThreeDPartInput(id: part.id, name: part.name,
                                                         positionNumber: part.positionNumber,
                                                         quantity: part.quantity, role: part.role,
                                                         profile: part.profileSpec ?? project.profileSpec)
                                     })
        cuts.append(contentsOf: ThreeDModelBuilder.drillingCuts(
            drawing: project.cadDrawing ?? CADDrawing(), for: modelInput))
        return CutListBuilder.entries(materialGrade: project.materialGrade, parts: parts, cuts: cuts)
    }

    static func materialCostEstimate(for project: MCProject) -> MaterialCostEstimate {
        MaterialCostBuilder.estimate(
            entries: cutEntries(for: project),
            materialPrices: project.materials.compactMap { material in
                material.pricePerKg.map { MaterialPriceInput(grade: material.resolvedGrade, pricePerKg: $0) }
            },
            purchasedParts: project.parts.filter(\.isReference).map { part in
                PurchasedPartPriceInput(id: part.id, positionNumber: part.positionNumber,
                                        name: part.name, quantity: part.quantity, unitPrice: part.unitPrice,
                                        laborHours: part.laborHours)
            },
            laborRateEURPerHour: project.laborRateEURPerHour,
            laborHoursByPosition: Dictionary(project.parts.compactMap { part in
                part.laborHours.map { (part.id, $0) }
            }, uniquingKeysWith: { first, _ in first }),
            stockLengthMm: project.stockBarLengthMm ?? CuttingCostBuilder.defaultStockLengthMm,
            kerfMm: project.sawKerfMm ?? CuttingCostBuilder.defaultKerfMm)
    }

    static func quotePDFInput(for project: MCProject, estimate: MaterialCostEstimate,
                              generatedAt: Date) -> QuotePDFInput {
        QuotePDFInput(projectName: project.name, projectNumber: project.number,
                      revisionLabel: project.revisionLabel, projectDescription: project.projectDescription,
                      widthMm: project.widthMm, heightMm: project.heightMm,
                      profileLabel: project.profileSpec.dimensionLabel,
                      materialGrade: project.materialGrade, estimate: estimate, generatedAt: generatedAt)
    }

    static func materialRows(for project: MCProject) -> [MaterialRow] {
        var rows: [MaterialRow] = []
        let entries = cutEntries(for: project)
        for entry in entries {
            rows.append(MaterialRow(positionNumber: entry.positionNumber, name: entry.name,
                                    profileLabel: entry.displayLabel, grade: entry.materialGrade,
                                    quantity: entry.quantity,
                                    totalLengthMm: Double(entry.quantity) * entry.lengthMm,
                                    isReference: false))
        }
        let exportedPositions = Set(entries.map(\.positionNumber))
        for part in project.parts.sorted(by: { $0.positionNumber < $1.positionNumber })
        where part.isReference && !exportedPositions.contains(part.positionNumber) {
            rows.append(MaterialRow(positionNumber: part.positionNumber, name: part.name,
                                    profileLabel: "Zukaufteil", grade: "–",
                                    quantity: max(1, part.quantity), totalLengthMm: 0, isReference: true))
        }
        return rows
    }

    static func montageSteps(for project: MCProject) -> [MontageStepInput] {
        let steps = project.assemblies
            .flatMap { $0.orderedSteps }
            .sorted { $0.orderIndex < $1.orderIndex }
        return steps.enumerated().map { index, step in
            MontageStepInput(index: index + 1, title: step.title, parts: step.partName,
                             movement: step.movement, connection: step.connection, tool: step.tool,
                             lengthMm: step.lengthMm, positionNote: step.positionNote, note: step.note)
        }
    }

    static func worksiteSurveyPDFInput(for project: MCProject, generatedAt: Date) -> WorksiteSurveyPDFInput {
        let entries = project.measurements
            .filter { $0.kind == "worksite" }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { measurement in
                let partLabel = measurement.partID.flatMap { partID in
                    project.parts.first(where: { $0.id == partID })
                }.map { "Pos. \($0.positionNumber) · \($0.name)" }
                return WorksiteSurveyPDFEntry(
                    id: measurement.id, label: measurement.displayLabel, value: measurement.value,
                    unit: measurement.unit, partLabel: partLabel,
                    note: measurement.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? measurement.note?.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                    measuredAt: measurement.createdAt)
            }
        return WorksiteSurveyPDFInput(projectName: project.name, projectNumber: project.number,
                                      revisionLabel: project.revisionLabel,
                                      projectDescription: project.projectDescription,
                                      widthMm: project.widthMm, heightMm: project.heightMm,
                                      profileLabel: project.profileSpec.dimensionLabel,
                                      materialGrade: project.materialGrade,
                                      entries: entries, generatedAt: generatedAt)
    }

    static func stlParts(for project: MCProject) throws -> [BuiltPart] {
        try STLExporter.buildParts(
            widthMm: project.widthMm, heightMm: project.heightMm, profile: project.profileSpec,
            parts: project.parts.map { part in
                ThreeDPartInput(id: part.id, name: part.name, positionNumber: part.positionNumber,
                                quantity: part.quantity, role: part.role,
                                profile: part.profileSpec ?? project.profileSpec)
            })
    }
}
