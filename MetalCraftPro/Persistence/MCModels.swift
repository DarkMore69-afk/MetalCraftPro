//
//  MCModels.swift
//  MetalCraftPro
//
//  Lokales SwiftData-Datenmodell mit stabilen UUIDs.
//  Alles bleibt standardmäßig lokal auf dem Gerät (kein Cloud-Zwang).
//

import Foundation
import SwiftData

// MARK: - Projekt

@Model
final class MCProject {
    var id: UUID = UUID()
    var name: String = ""
    var number: String = ""
    var projectDescription: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // Parametrische Kernmaße – führend für alle abgeleiteten Daten
    var widthMm: Double = 1000
    var heightMm: Double = 1000
    var profileSpecData: Data = Data()
    var materialGrade: String = ""
    /// Optional project-wide labor rate, in EUR per hour.
    var laborRateEURPerHour: Double?
    /// Persisted stock cutting settings; nil preserves defaults for existing projects.
    var stockBarLengthMm: Double?
    var sawKerfMm: Double?
    var thumbnailStyle: String = "none"
    /// Catalogue relationship; profileSpecData remains a migration-compatible fallback.
    var profile: MCProfile?
    /// 2D-CAD-Dokument des Projekts: eigene Elemente und Anmerkungen. Die Rahmengeometrie
    /// selbst bleibt in widthMm/heightMm/profileSpec – das Dokument verweist nur darauf.
    var cadData: Data?
    /// Explicit confirmation step of the measure-control: set only when the
    /// geometry passed validation without errors; cleared whenever geometry changes.
    var geometryApprovedAt: Date?
    var frameParameters: FrameParameters? {
        try? FrameParameters(width: widthMm, height: heightMm, profile: profileSpec)
    }

    var isGeometryApproved: Bool { geometryApprovedAt != nil }

    var cadDrawing: CADDrawing? {
        get { cadData.flatMap { try? JSONDecoder().decode(CADDrawing.self, from: $0) } }
        set { cadData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    @Relationship(deleteRule: .cascade, inverse: \MCDrawing.project) var drawings: [MCDrawing] = []
    @Relationship(deleteRule: .cascade, inverse: \MCSketch.project) var sketches: [MCSketch] = []
    @Relationship(deleteRule: .cascade, inverse: \MCGeometryRecord.project) var geometryRecords: [MCGeometryRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \MCConstraint.project) var constraints: [MCConstraint] = []
    @Relationship(deleteRule: .cascade, inverse: \MCDimension.project) var dimensions: [MCDimension] = []
    @Relationship(deleteRule: .cascade, inverse: \MCPart.project) var parts: [MCPart] = []
    @Relationship(deleteRule: .cascade, inverse: \MCAssembly.project) var assemblies: [MCAssembly] = []
    @Relationship(deleteRule: .cascade, inverse: \MCCutItem.project) var cutItems: [MCCutItem] = []
    @Relationship(deleteRule: .cascade, inverse: \MCMaterial.project) var materials: [MCMaterial] = []
    @Relationship(deleteRule: .cascade, inverse: \MCWeld.project) var welds: [MCWeld] = []
    @Relationship(deleteRule: .cascade, inverse: \MCMeasurement.project) var measurements: [MCMeasurement] = []
    @Relationship(deleteRule: .cascade, inverse: \MCPhoto.project) var photos: [MCPhoto] = []
    @Relationship(deleteRule: .cascade, inverse: \MCDocument.project) var documents: [MCDocument] = []
    @Relationship(deleteRule: .cascade, inverse: \MCRevision.project) var revisions: [MCRevision] = []
    @Relationship(deleteRule: .cascade, inverse: \MCChecklistItem.project) var checklistItems: [MCChecklistItem] = []

    init(
        name: String,
        number: String,
        projectDescription: String = "",
        widthMm: Double = 1000,
        heightMm: Double = 1000,
        profileSpec: ProfileSpec = ProfileCatalog.squareTube40x40x2,
        materialGrade: String = "S235",
        thumbnailStyle: String = "none"
    ) {
        self.id = UUID()
        self.name = name
        self.number = number
        self.projectDescription = projectDescription
        self.createdAt = Date()
        self.updatedAt = Date()
        self.widthMm = widthMm
        self.heightMm = heightMm
        self.profileSpecData = (try? JSONEncoder().encode(profileSpec)) ?? Data()
        self.materialGrade = materialGrade
        self.thumbnailStyle = thumbnailStyle
    }

    var profileSpec: ProfileSpec {
        get { profile?.spec ?? (try? JSONDecoder().decode(ProfileSpec.self, from: profileSpecData)) ?? ProfileCatalog.squareTube40x40x2 }
        set { profile = nil; profileSpecData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var revisionLabel: String {
        revisions.sorted { $0.createdAt < $1.createdAt }.last?.label ?? "A"
    }

    /// Zusammenfassungszeile für die Projektkarte.
    var summaryLine: String {
        if parts.isEmpty { return "Neu · noch keine Zeichnung" }
        if materialGrade.isEmpty { return "\(parts.count) Bauteile · \(photos.count) Fotos" }
        return "Rahmen \(profileSpec.dimensionLabel) · \(parts.count) Teile · Revision \(revisionLabel)"
    }
}

// MARK: - Zeichnungen & Skizzen

@Model
final class MCDrawing {
    var id: UUID = UUID()
    var title: String = ""
    var scale: String = "1:1"
    var revisionLabel: String = "A"
    var sheetFormat: String = "A4"
    var createdAt: Date = Date()
    var project: MCProject?

    init(title: String, scale: String = "1:1", revisionLabel: String = "A", sheetFormat: String = "A4") {
        self.id = UUID(); self.title = title; self.scale = scale
        self.revisionLabel = revisionLabel; self.sheetFormat = sheetFormat; self.createdAt = Date()
    }
}

@Model
final class MCSketch {
    var id: UUID = UUID()
    var title: String = ""
    /// camera | photo | file | pdf
    var source: String = "photo"
    /// neu | uebernommen
    var status: String = "neu"
    var recognizedCount: Int = 0
    var imageFileName: String?
    /// Strukturierte Erkennungsobjekte (RecognitionResult) der lokalen Analyse.
    var payload: Data?
    var createdAt: Date = Date()
    var project: MCProject?

    init(title: String, source: String) {
        self.id = UUID(); self.title = title; self.source = source; self.createdAt = Date()
    }

    var statusLabel: String { status == "uebernommen" ? "Übernommen" : "Neu" }
    var sourceLabel: String {
        switch source {
        case "camera": return "Kamera"
        case "photo": return "Foto"
        case "file": return "Datei"
        case "pdf": return "PDF"
        default: return source
        }
    }

    var recognition: RecognitionResult? {
        guard let payload else { return nil }
        guard let value = try? JSONDecoder().decode(RecognitionResult.self, from: payload) else { return nil }
        return value
    }
}

// MARK: - Geometrie, Constraints, Maße

@Model
final class MCGeometryRecord {
    var id: UUID = UUID()
    /// Rohdaten eines GeometryElement2D (Codable).
    var payload: Data = Data()
    var label: String = ""
    var createdAt: Date = Date()
    var project: MCProject?

    init(element: GeometryElement2D, label: String) {
        self.id = UUID()
        self.payload = (try? JSONEncoder().encode(element)) ?? Data()
        self.label = label
        self.createdAt = Date()
    }

    /// Non-nil bindings resolve geometry from the project instead of storing a second contour.
    var parameterRole: String?

    var element: GeometryElement2D? {
        if let frame = project?.frameParameters {
            switch parameterRole {
            case "outer": return frame.outerContour
            case "inner": return frame.innerContour
            default: break
            }
        }
        guard let value = try? JSONDecoder().decode(GeometryElement2D.self, from: payload),
              (try? value.validate()) != nil else { return nil }
        return value
    }
}

@Model
final class MCConstraint {
    var id: UUID = UUID()
    /// parallel | perpendicular | tangent | symmetric | equalLength | horizontal | vertical
    var kind: String = ""
    var geometryIDs: [UUID] = []
    var note: String = ""
    var createdAt: Date = Date()
    var project: MCProject?

    init(kind: String, note: String = "") {
        self.id = UUID(); self.kind = kind; self.note = note; self.createdAt = Date()
    }
}

@Model
final class MCDimension {
    var id: UUID = UUID()
    var label: String = ""
    @Attribute(originalName: "valueMm") var independentValueMm: Double = 0
    var parameterKey: String?
    var valueMm: Double {
        get {
            guard let frame = project?.frameParameters else { return independentValueMm }
            switch parameterKey {
            case "width": return frame.width
            case "height": return frame.height
            case "innerWidth": return frame.innerWidth
            case "innerHeight": return frame.innerHeight
            default: return independentValueMm
            }
        }
        set { independentValueMm = newValue }
    }
    var note: String = ""
    var project: MCProject?

    init(label: String, valueMm: Double, note: String = "") {
        self.id = UUID(); self.label = label; self.valueMm = valueMm; self.note = note
    }
}

// MARK: - Bauteile

@Model
final class MCPart {
    var id: UUID = UUID()
    var name: String = ""
    var positionNumber: Int = 0
    var quantity: Int = 1
    @Attribute(originalName: "lengthMm") var independentLengthMm: Double = 0
    var lengthMm: Double {
        get {
            if isParametric, let role, let length = project?.frameParameters?.length(for: role) { return length }
            return independentLengthMm
        }
        set { independentLengthMm = newValue }
    }
    /// Rolle im parametrischen Modell (rahmen_oben, querstrebe, hardware, …)
    var role: String?
    var isParametric: Bool = false
    /// Eigenes Profil (nil → Projektdprofil)
    var profileSpecData: Data?
    /// Optional unit price for a purchased/reference part, in EUR per piece.
    var unitPrice: Double?
    /// Optional direct labor effort for this position, in person-hours.
    var laborHours: Double?
    var remark: String = ""
    var project: MCProject?

    init(
        name: String,
        positionNumber: Int,
        quantity: Int = 1,
        lengthMm: Double = 0,
        role: String? = nil,
        isParametric: Bool = false,
        profileSpec: ProfileSpec? = nil,
        remark: String = ""
    ) {
        self.id = UUID(); self.name = name; self.positionNumber = positionNumber
        self.quantity = quantity; self.lengthMm = lengthMm; self.role = role
        self.isParametric = isParametric
        self.profileSpecData = profileSpec.flatMap { try? JSONEncoder().encode($0) }
        self.remark = remark
    }

    var profileSpec: ProfileSpec? {
        profileSpecData.flatMap { try? JSONDecoder().decode(ProfileSpec.self, from: $0) }
    }

    var profileName: String {
        profileSpec?.dimensionLabel ?? project?.profileSpec.dimensionLabel ?? "–"
    }

    /// Zukauf-/Referenzbauteil (z. B. Scharnier, Schloss): kein Fertigungsprofil,
    /// wird nur in Stückliste und Baugruppe referenziert.
    var isReference: Bool { role == "hardware" }
}

// MARK: - Baugruppen

@Model
final class MCAssembly {
    var id: UUID = UUID()
    var name: String = ""
    /// Positionsnummer auf ihrer Hierarchie-Ebene.
    var positionNumber: Int = 1
    /// Stückzahl dieser Baugruppe im übergeordneten Kontext.
    var quantity: Int = 1
    var createdAt: Date = Date()
    /// Reihenfolge der direkt enthaltenen Bauteile.
    var partIDs: [UUID] = []
    /// Reihenfolge der direkt enthaltenen Unterbaugruppen.
    var childAssemblyIDs: [UUID] = []
    var parentAssemblyID: UUID?
    @Relationship(deleteRule: .cascade, inverse: \MCAssemblyStep.assembly) var steps: [MCAssemblyStep] = []
    var project: MCProject?

    init(name: String, positionNumber: Int = 1, quantity: Int = 1) {
        self.id = UUID(); self.name = name; self.positionNumber = positionNumber
        self.quantity = quantity; self.createdAt = Date()
    }

    var orderedSteps: [MCAssemblyStep] {
        steps.sorted { $0.orderIndex < $1.orderIndex }
    }
}

@Model
final class MCAssemblyStep {
    var id: UUID = UUID()
    var orderIndex: Int = 0
    var title: String = ""
    var partID: UUID?
    var partName: String = ""
    /// ablegen | ansetzen | aufsetzen | einschieben | montieren
    var movement: String = "ansetzen"
    var connection: String = ""
    var tool: String = ""
    var lengthMm: Double = 0
    var positionNote: String = ""
    var note: String = ""
    /// Zusammengefasste Schritte: zusätzliche Bauteile neben `partID`.
    var extraPartIDs: [UUID] = []
    var assembly: MCAssembly?

    var allPartIDs: [UUID] { [partID].compactMap { $0 } + extraPartIDs }

    init(
        orderIndex: Int,
        title: String,
        partID: UUID? = nil,
        partName: String = "",
        movement: String = "ansetzen",
        connection: String = "",
        tool: String = "",
        lengthMm: Double = 0,
        positionNote: String = "",
        note: String = ""
    ) {
        self.id = UUID(); self.orderIndex = orderIndex; self.title = title
        self.partID = partID; self.partName = partName; self.movement = movement
        self.connection = connection; self.tool = tool; self.lengthMm = lengthMm
        self.positionNote = positionNote; self.note = note
    }
}

// MARK: - Zuschnitt & Material

@Model
final class MCCutItem {
    var id: UUID = UUID()
    var positionNumber: Int = 0
    var profileName: String = ""
    var lengthMm: Double = 0
    var angleADeg: Double = 90
    var angleBDeg: Double = 90
    var quantity: Int = 1
    var machining: String = ""
    var remark: String = ""
    var partID: UUID?
    var project: MCProject?

    init(
        positionNumber: Int,
        profileName: String,
        lengthMm: Double,
        angleADeg: Double = 90,
        angleBDeg: Double = 90,
        quantity: Int = 1,
        machining: String = "",
        remark: String = "",
        partID: UUID? = nil
    ) {
        self.id = UUID(); self.positionNumber = positionNumber; self.profileName = profileName
        self.lengthMm = lengthMm; self.angleADeg = angleADeg; self.angleBDeg = angleBDeg
        self.quantity = quantity; self.machining = machining; self.remark = remark
        self.partID = partID
    }
}

@Model
final class MCMaterial {
    var id: UUID = UUID()
    var name: String = ""
    var grade: String = ""
    var profileTypeName: String = ""
    var weightPerMeterKg: Double = 0
    var usesProjectProfile: Bool = false
    var resolvedName: String { usesProjectProfile ? "\(project?.profileSpec.type.displayName ?? "Profil") \(project?.profileSpec.dimensionLabel ?? "")" : name }
    var resolvedGrade: String { usesProjectProfile ? project?.materialGrade ?? grade : grade }
    var resolvedWeightPerMeter: Double { usesProjectProfile ? project?.profileSpec.weightPerMeterKg ?? weightPerMeterKg : weightPerMeterKg }
    var pricePerKg: Double?
    var surface: String = ""
    var note: String = ""
    var project: MCProject?

    init(name: String, grade: String, profileTypeName: String, weightPerMeterKg: Double, surface: String = "", note: String = "") {
        self.id = UUID(); self.name = name; self.grade = grade
        self.profileTypeName = profileTypeName; self.weightPerMeterKg = weightPerMeterKg
        self.surface = surface; self.note = note
    }
}

// MARK: - Schweißen & Messungen

@Model
final class MCWeld {
    var id: UUID = UUID()
    /// Bezeichnung der Naht, z. B. „Rahmen links unten“.
    var label: String = ""
    /// mig | wig | ehand
    var method: String = "mig"
    var material: String = ""
    var thicknessMm: Double = 0
    var filler: String = ""
    var gas: String = ""
    var currentA: Double = 0
    var voltageV: Double = 0
    var wireFeedMMin: Double = 0
    var position: String = ""
    var seamType: String = ""
    var sequence: String = ""
    var note: String = ""
    /// Zugeordnetes Bauteil (Schweißprotokoll je Projekt und Bauteil).
    var partID: UUID?
    var createdAt: Date = Date()
    var project: MCProject?

    init(method: String, material: String, thicknessMm: Double, filler: String, gas: String,
         currentA: Double, voltageV: Double, wireFeedMMin: Double, position: String, seamType: String,
         sequence: String, label: String = "", partID: UUID? = nil, note: String = "") {
        self.id = UUID(); self.label = label; self.method = method; self.material = material
        self.thicknessMm = thicknessMm; self.filler = filler; self.gas = gas
        self.currentA = currentA; self.voltageV = voltageV; self.wireFeedMMin = wireFeedMMin
        self.position = position; self.seamType = seamType; self.sequence = sequence
        self.note = note; self.partID = partID; self.createdAt = Date()
    }

    var methodLabel: String {
        switch method {
        case "wig": return "WIG"
        case "ehand": return "E-Hand"
        default: return "MIG/MAG"
        }
    }
}

@Model
final class MCMeasurement {
    var id: UUID = UUID()
    /// angle | level | plumb | ar | photo
    var kind: String = "angle"
    var value: Double = 0
    var unit: String = "mm"
    var tolerance: Double = 0
    var targetName: String = ""
    /// Optional site-survey fields; optional storage keeps older montage measurements readable.
    var label: String?
    var note: String?
    /// Optional site-survey check data; nil values mean no target has been entered.
    var targetValue: Double?
    var targetTolerance: Double?
    @Relationship(deleteRule: .nullify, inverse: \MCPhoto.measurements) var photos: [MCPhoto] = []
    var partID: UUID?
    var createdAt: Date = Date()
    
    var worksiteCheckWithinTolerance: Bool? {
        guard kind == "worksite", let targetValue, let targetTolerance,
              value.isFinite, targetValue.isFinite, targetTolerance.isFinite,
              targetTolerance >= 0 else { return nil }
        return abs(value - targetValue) <= targetTolerance
    }

    var worksiteCheckSummary: String? {
        guard kind == "worksite", let targetValue, let targetTolerance else { return nil }
        let outcome = worksiteCheckWithinTolerance == true ? "Innerhalb der Toleranz" : "Außerhalb der Toleranz"
        return "Soll \(DeFormat.number(targetValue)) \(unit) · ±\(DeFormat.number(targetTolerance)) \(unit) · \(outcome)"
    }

    var project: MCProject?

    init(kind: String, value: Double, unit: String, tolerance: Double, targetName: String,
         label: String? = nil, note: String? = nil, partID: UUID? = nil) {
        self.id = UUID(); self.kind = kind; self.value = value; self.unit = unit
        self.tolerance = tolerance; self.targetName = targetName
        self.label = label; self.note = note; self.partID = partID; self.createdAt = Date()
    }

    var displayLabel: String { label?.isEmpty == false ? label! : targetName }
}

// MARK: - Fotos, Dokumente, Revisionen

enum PhotoCategory: String, CaseIterable, Identifiable {
    case vorher, geheftet, geschweisst, geschliffen, lackiert, fertig, aufmass

    var id: String { rawValue }
    var label: String {
        switch self {
        case .vorher: return "Vorher"
        case .geheftet: return "Geheftet"
        case .geschweisst: return "Geschweißt"
        case .geschliffen: return "Geschliffen"
        case .lackiert: return "Lackiert"
        case .fertig: return "Fertig"
        case .aufmass: return "Aufmaß"
        }
    }
    var symbol: String {
        switch self {
        case .vorher: return "camera"
        case .geheftet: return "pin"
        case .geschweisst: return "flame"
        case .geschliffen: return "sparkles"
        case .lackiert: return "paintbrush"
        case .fertig: return "checkmark.seal"
        case .aufmass: return "ruler"
        }
    }
}

@Model
final class MCPhoto {
    var id: UUID = UUID()
    /// vorher | geheftet | geschweisst | geschliffen | lackiert | fertig | montage
    var category: String = "vorher"
    var caption: String = ""
    var imageFileName: String?
    /// Optional link to a project part; nil means general project documentation.
    var partID: UUID?
    var createdAt: Date = Date()
    var measurements: [MCMeasurement] = []
    var project: MCProject?

    init(category: String, caption: String = "", imageFileName: String? = nil, partID: UUID? = nil) {
        self.id = UUID(); self.category = category; self.caption = caption
        self.imageFileName = imageFileName; self.partID = partID; self.createdAt = Date()
    }

    var categoryLabel: String {
        switch PhotoCategory(rawValue: category) {
        case .some(let category): return category.label
        case nil where category == "montage": return "Montage"
        case nil: return category
        }
    }
}

@Model
final class MCDocument {
    var id: UUID = UUID()
    var title: String = ""
    var fileName: String = ""
    var createdAt: Date = Date()
    var project: MCProject?

    init(title: String, fileName: String) {
        self.id = UUID(); self.title = title; self.fileName = fileName; self.createdAt = Date()
    }
}

@Model
final class MCRevision {
    var id: UUID = UUID()
    var label: String = "A"
    var note: String = ""
    var createdAt: Date = Date()
    var project: MCProject?

    init(label: String, note: String) {
        self.id = UUID(); self.label = label; self.note = note; self.createdAt = Date()
    }
}


@Model
final class MCChecklistItem {
    /// Project-qualified identity of the source cut position, assembly step, or seam.
    @Attribute(.unique) var sourceKey: String
    /// zuschnitt | montage | pruefung | schweissen
    var kind: String
    var title: String
    var detail: String
    var completedAt: Date?
    var project: MCProject?

    init(sourceKey: String, kind: String, title: String, detail: String) {
        self.sourceKey = sourceKey
        self.kind = kind
        self.title = title
        self.detail = detail
        self.completedAt = nil
    }

    var kindLabel: String {
        switch kind {
        case "zuschnitt": return "Schneiden"
        case "montage": return "Montieren"
        case "pruefung": return "Prüfung"
        case "schweissen": return "Schweißen"
        default: return "Fertigung"
        }
    }
}

// MARK: - Catalogue and installation metadata

/// The persistent Profile entity. Values are immutable catalogue entries;
/// projects reference an entry rather than keeping a mutable copy.
@Model
final class MCProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var typeName: String
    var isCustom: Bool
    var specification: Data
    init(spec: ProfileSpec) throws {
        try spec.validate()
        id = spec.id; name = spec.name; typeName = spec.type.rawValue
        isCustom = spec.isCustom
        specification = try JSONEncoder().encode(spec)
    }
    var spec: ProfileSpec? {
        guard let value = try? JSONDecoder().decode(ProfileSpec.self, from: specification),
              (try? value.validate()) != nil else { return nil }
        return value
    }
}

/// Persisted in the same transaction as seeding, so deleting all projects never re-seeds.
@Model
final class MCStoreState {
    @Attribute(.unique) var key: String
    var version: Int
    init(key: String = "initial-content", version: Int = 1) { self.key = key; self.version = version }
}
