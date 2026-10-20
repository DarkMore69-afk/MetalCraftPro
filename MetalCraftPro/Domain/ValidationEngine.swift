//
//  ValidationEngine.swift
//  MetalCraftPro
//
//  Zentrale, deterministische Validierungs-Engine (Maßkontrolle).
//  Reine Werttypen: keine UI-, Speicher- oder Actor-Abhängigkeiten.
//

import Foundation

/// Ein Fund der Maßkontrolle: was, wo, erwarteter und vorhandener Wert,
/// optional mit einer deterministisch anwendbaren Korrektur.
public struct ValidationIssue: Identifiable, Equatable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case missingDimension, conflictingDimension, invalidGeometry, impossibleProfile
        case collidingParts, disconnectedAssembly, badCutAngle, nonFiniteValue

        public var title: String {
            switch self {
            case .missingDimension: return "Fehlendes Maß"
            case .conflictingDimension: return "Widersprüchliches Maß"
            case .invalidGeometry: return "Ungültige Geometrie"
            case .impossibleProfile: return "Unmögliches Profil"
            case .collidingParts: return "Kollidierende Teile"
            case .disconnectedAssembly: return "Nicht verbundene Baugruppe"
            case .badCutAngle: return "Fehlerhafter Schnittwinkel"
            case .nonFiniteValue: return "Ungültiger Zahlenwert"
            }
        }

        public var symbol: String {
            switch self {
            case .missingDimension: return "questionmark.circle"
            case .conflictingDimension: return "arrow.left.arrow.right"
            case .invalidGeometry: return "triangle.exclamation"
            case .impossibleProfile: return "square.slash"
            case .collidingParts: return "arrow.collide"
            case .disconnectedAssembly: return "link.badge.plus"
            case .badCutAngle: return "angle"
            case .nonFiniteValue: return "number.square"
            }
        }
    }

    public enum Severity: String, Sendable { case error, warning }

    public enum Fix: Equatable, Sendable {
        /// Projektparameter (Breite/Höhe) auf den erwarteten Wert setzen.
        case parameter(key: String, valueMm: Double)
        /// Bauteillänge auf den erwarteten Wert setzen.
        case partLength(partID: UUID, valueMm: Double)
        /// Ungültigen Geometrie-Eintrag entfernen.
        case removeGeometryRecord(recordID: UUID)
        /// Ungültiges CAD-Element entfernen.
        case removeCADElement(elementID: UUID)
    }

    public var id: UUID
    public var category: Category
    public var severity: Severity
    public var title: String
    public var detail: String
    /// Erwarteter Wert (Korrekturvorschlag), formatiert.
    public var expected: String?
    /// Vorhandener Wert, formatiert.
    public var actual: String?
    /// Wo wurde gefunden (Parameter, Pos. 2 · Rahmen unten, …).
    public var reference: String?
    public var fix: Fix?

    init(id: UUID = UUID(), category: Category, severity: Severity, title: String, detail: String,
         expected: String? = nil, actual: String? = nil, reference: String? = nil, fix: Fix? = nil) {
        self.id = id; self.category = category; self.severity = severity
        self.title = title; self.detail = detail
        self.expected = expected; self.actual = actual; self.reference = reference; self.fix = fix
    }
}

/// Eine geprüfte Rechenvorschrift der Rahmenkontrolle (z. B. 1200 − 40 − 40 = 1120).
public struct ValidationCheck: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var formula: String
    public var expectedMm: Double?
    /// Vorhandener Wert bei Konflikt (sonst nil).
    public var actualMm: Double?
    public var passes: Bool
    public var reference: String?

    public init(id: String, title: String, formula: String, expectedMm: Double?,
                actualMm: Double? = nil, passes: Bool, reference: String? = nil) {
        self.id = id; self.title = title; self.formula = formula
        self.expectedMm = expectedMm; self.actualMm = actualMm
        self.passes = passes; self.reference = reference
    }
}

public struct ValidationReport: Equatable, Sendable {
    public var checks: [ValidationCheck]
    public var issues: [ValidationIssue]

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    /// Nur Fehler blockieren die Freigabe; Warnungen sind Hinweise.
    public var hasErrors: Bool { errorCount > 0 }
    public var isClean: Bool { issues.isEmpty }
}

/// Eingabeschnappschuss des Projekts – bewusst frei von SwiftData-Objekten,
/// damit die Engine rein und ohne Actor-Bezug testbar bleibt.
public struct ValidationInput: Sendable {
    public struct PartSnapshot: Sendable {
        public var id: UUID
        public var name: String
        public var positionNumber: Int
        public var quantity: Int
        public var lengthMm: Double
        public var role: String?
        public var isParametric: Bool
        public init(id: UUID, name: String, positionNumber: Int, quantity: Int,
                    lengthMm: Double, role: String?, isParametric: Bool) {
            self.id = id; self.name = name; self.positionNumber = positionNumber
            self.quantity = quantity; self.lengthMm = lengthMm
            self.role = role; self.isParametric = isParametric
        }
    }

    public struct CutSnapshot: Sendable {
        public var id: UUID
        public var positionNumber: Int
        public var profileName: String
        public var lengthMm: Double
        public var angleADeg: Double
        public var angleBDeg: Double
        public init(id: UUID, positionNumber: Int, profileName: String, lengthMm: Double,
                    angleADeg: Double, angleBDeg: Double) {
            self.id = id; self.positionNumber = positionNumber; self.profileName = profileName
            self.lengthMm = lengthMm; self.angleADeg = angleADeg; self.angleBDeg = angleBDeg
        }
    }

    public struct AssemblySnapshot: Sendable {
        public var id: UUID
        public var name: String
        public var partIDs: [UUID]
        public var childAssemblyIDs: [UUID]
        public var parentAssemblyID: UUID?
        public var stepPartIDs: [UUID]
        public init(id: UUID, name: String, partIDs: [UUID], childAssemblyIDs: [UUID] = [],
                    parentAssemblyID: UUID?, stepPartIDs: [UUID]) {
            self.id = id; self.name = name; self.partIDs = partIDs
            self.childAssemblyIDs = childAssemblyIDs
            self.parentAssemblyID = parentAssemblyID; self.stepPartIDs = stepPartIDs
        }
    }

    public struct GeometryRecordSnapshot: Sendable {
        public var id: UUID
        public var label: String
        public var payload: Data
        public init(id: UUID, label: String, payload: Data) {
            self.id = id; self.label = label; self.payload = payload
        }
    }

    public var widthMm: Double
    public var heightMm: Double
    public var profile: ProfileSpec?
    public var parts: [PartSnapshot]
    public var cuts: [CutSnapshot]
    public var assemblies: [AssemblySnapshot]
    public var geometryRecords: [GeometryRecordSnapshot]
    public var cadElements: [CADElement]

    public init(widthMm: Double, heightMm: Double, profile: ProfileSpec?,
                parts: [PartSnapshot] = [], cuts: [CutSnapshot] = [], assemblies: [AssemblySnapshot] = [],
                geometryRecords: [GeometryRecordSnapshot] = [], cadElements: [CADElement] = []) {
        self.widthMm = widthMm; self.heightMm = heightMm; self.profile = profile
        self.parts = parts; self.cuts = cuts; self.assemblies = assemblies
        self.geometryRecords = geometryRecords; self.cadElements = cadElements
    }
}

public enum ValidationEngine {

    /// Führt alle Prüfungen deterministisch aus. Fehler erscheinen vor Warnungen.
    public static func run(_ input: ValidationInput) -> ValidationReport {
        var checks: [ValidationCheck] = []
        var issues: [ValidationIssue] = []

        // MARK: Projektparameter

        let width = input.widthMm, height = input.heightMm
        let parametersUsable = width.isFinite && height.isFinite && width > 0 && height > 0

        if !width.isFinite || !height.isFinite {
            issues.append(.init(category: .nonFiniteValue, severity: .error,
                                title: "Ungültiger Projektparameter",
                                detail: "Breite oder Höhe ist nicht endlich (NaN/Unendlich). Korrigiere die Parameter, bevor weitergearbeitet wird.",
                                reference: "Projektparameter"))
        } else if width <= 0 {
            issues.append(.init(category: .missingDimension, severity: .error,
                                title: "Breite fehlt oder ist null",
                                detail: "Ohne gültige Breite entsteht keine Geometrie. Trage ein Maß größer null ein.",
                                actual: DeFormat.number(width), reference: "Projektparameter · Breite"))
        } else if height <= 0 {
            issues.append(.init(category: .missingDimension, severity: .error,
                                title: "Höhe fehlt oder ist null",
                                detail: "Ohne gültige Höhe entsteht keine Geometrie. Trage ein Maß größer null ein.",
                                actual: DeFormat.number(height), reference: "Projektparameter · Höhe"))
        }

        // MARK: Profil

        var profileUsable = false
        var profileWidth = 0.0
        if let profile = input.profile {
            do {
                try profile.validate()
                profileUsable = true
                profileWidth = profile.widthMm
            } catch {
                issues.append(.init(category: .impossibleProfile, severity: .error,
                                    title: "Unmögliches Profil",
                                    detail: "Profil „\(profile.name)“ ist geometrisch nicht ausführbar: \(error.localizedDescription)",
                                    reference: "Projektprofil"))
            }
        } else {
            issues.append(.init(category: .missingDimension, severity: .error,
                                title: "Profil fehlt oder ist unlesbar",
                                detail: "Ohne Profilquerschnitt sind Innenmaße, Gewicht und Zuschnitt nicht bestimmbar.",
                                reference: "Projektprofil"))
        }

        // MARK: Rahmenprüfung (Außenmaß − Profil − Profil = Innenmaß)

        if parametersUsable && profileUsable {
            let t = profileWidth
            let innerWidth = width - 2 * t
            let innerHeight = height - 2 * t

            checks.append(.init(id: "inner-width", title: "Innenmaß Breite",
                                formula: "\(DeFormat.number(width)) − \(DeFormat.number(t)) − \(DeFormat.number(t))",
                                expectedMm: innerWidth, passes: innerWidth > 0,
                                reference: innerWidth > 0 ? nil : "Breite zu klein für dieses Profil"))

            checks.append(.init(id: "inner-height", title: "Innenmaß Höhe",
                                formula: "\(DeFormat.number(height)) − \(DeFormat.number(t)) − \(DeFormat.number(t))",
                                expectedMm: innerHeight, passes: innerHeight > 0,
                                reference: innerHeight > 0 ? nil : "Höhe zu klein für dieses Profil"))

            if innerWidth <= 0 || innerHeight <= 0 {
                issues.append(.init(category: .impossibleProfile, severity: .error,
                                    title: "Rahmen mit diesem Profil unmöglich",
                                    detail: "Das Außenmaß muss größer als zwei Profilbreiten sein.",
                                    expected: "> \(DeFormat.number(2 * t)) mm",
                                    actual: "\(DeFormat.number(width)) × \(DeFormat.number(height)) mm",
                                    reference: "Projektparameter"))
            } else if let diagonal = try? Geometry2D.rectangleDiagonal(width: width, height: height) {
                checks.append(.init(id: "diagonal", title: "Kontroll-Diagonale",
                                    formula: "√(\(DeFormat.number(width))² + \(DeFormat.number(height))²)",
                                    expectedMm: diagonal, passes: true,
                                    reference: "Winkelprüfung beim Zusammenbau"))
            }
        }

        // MARK: Bauteile

        func roleLabel(_ role: String) -> String {
            switch role {
            case "rahmen_oben": return "Rahmen oben"
            case "rahmen_unten": return "Rahmen unten"
            case "rahmen_links": return "Rahmen links"
            case "rahmen_rechts": return "Rahmen rechts"
            case "querstrebe": return "Querstrebe"
            default: return role
            }
        }
        /// Soll-Länge einer Rahmenrolle (entspricht FrameParameters.length(for:)).
        func expectedLength(for role: String) -> Double? {
            guard parametersUsable, profileUsable else { return nil }
            let innerHeight = height - 2 * profileWidth
            switch role {
            case "rahmen_oben", "rahmen_unten": return width
            case "rahmen_links", "rahmen_rechts": return innerHeight
            default: return nil
            }
        }

        for part in input.parts {
            let reference = "Pos. \(part.positionNumber) · \(part.name)"
            guard part.lengthMm.isFinite else {
                issues.append(.init(category: .nonFiniteValue, severity: .error,
                                    title: "Ungültige Bauteillänge",
                                    detail: "Die Länge ist nicht endlich (NaN/Unendlich).",
                                    reference: reference))
                continue
            }
            // Referenz-/Zukaufbauteile (z. B. Scharniere, Schlösser) haben keine Fertigungslänge.
            if part.role == "hardware" { continue }
            guard part.lengthMm > 0 else {
                issues.append(.init(category: .missingDimension, severity: .error,
                                    title: "Bauteillänge fehlt oder ist null",
                                    detail: "Ohne Länge kein Zuschnitt. Trage die Fertigungslänge ein.",
                                    actual: DeFormat.number(part.lengthMm), reference: reference))
                continue
            }

            // Querstrebe: kürzer als der Innenraum ist zulässig, länger kollidiert.
            if let role = part.role, role == "querstrebe", !part.isParametric,
               parametersUsable, profileUsable {
                let innerWidth = width - 2 * profileWidth
                if part.lengthMm > innerWidth + 0.5 {
                    issues.append(.init(category: .collidingParts, severity: .error,
                                        title: "Querstrebe kollidiert mit dem Rahmen",
                                        detail: "Pos. \(part.positionNumber) ist länger als der freie Innenraum zwischen den Rahmenprofilen.",
                                        expected: "≤ \(DeFormat.number(innerWidth)) mm",
                                        actual: DeFormat.number(part.lengthMm),
                                        reference: reference,
                                        fix: .partLength(partID: part.id, valueMm: innerWidth)))
                }
                continue
            }

            if let role = part.role, !part.isParametric, let expected = expectedLength(for: role),
               abs(expected - part.lengthMm) > 0.5 {
                issues.append(.init(category: .conflictingDimension, severity: .error,
                                    title: "Bauteillänge widerspricht dem parametrischen Modell",
                                    detail: "„\(roleLabel(role))“ folgt dem Außenmaß. Erwartet: \(DeFormat.number(expected)) mm.",
                                    expected: DeFormat.number(expected),
                                    actual: DeFormat.number(part.lengthMm),
                                    reference: reference,
                                    fix: .partLength(partID: part.id, valueMm: expected)))
                checks.append(.init(id: "part-\(part.id.uuidString)", title: "Pos. \(part.positionNumber) · \(part.name)",
                                    formula: "Soll: \(DeFormat.number(expected)) mm (\(roleLabel(role)))",
                                    expectedMm: expected, actualMm: part.lengthMm, passes: false,
                                    reference: reference))
            }
        }

        // MARK: Zuschnitt & Schnittwinkel

        for cut in input.cuts {
            let reference = "Zuschnitt Pos. \(cut.positionNumber) · \(cut.profileName)"
            if !(cut.lengthMm.isFinite && cut.lengthMm > 0) {
                issues.append(.init(category: .missingDimension, severity: .error,
                                    title: "Zuschnittlänge fehlt oder ist null",
                                    detail: "Ohne Länge kein Schnittplan.",
                                    reference: reference))
            }
            for (side, angle) in [("A", cut.angleADeg), ("B", cut.angleBDeg)] {
                guard angle.isFinite else {
                    issues.append(.init(category: .badCutAngle, severity: .error,
                                        title: "Schnittwinkel nicht endlich",
                                        detail: "Winkel \(side) ist NaN/Unendlich.",
                                        reference: reference))
                    continue
                }
                guard angle >= 0, angle <= 180 else {
                    issues.append(.init(category: .badCutAngle, severity: .error,
                                        title: "Schnittwinkel außerhalb 0–180°",
                                        detail: "Winkel \(side) = \(DeFormat.number(angle))° ist nicht ausführbar.",
                                        actual: "\(DeFormat.number(angle))°", reference: reference))
                    continue
                }
                if angle <= 1e-9 || abs(angle - 180) <= 1e-9 {
                    issues.append(.init(category: .badCutAngle, severity: .warning,
                                        title: "Schnittwinkel ergibt keinen Schnitt",
                                        detail: "Winkel \(side) = 0°/180° trennt das Material nicht. Prüfe Gehrung oder Stirnschnitt.",
                                        actual: "\(DeFormat.number(angle))°", reference: reference))
                }
            }
        }

        // MARK: Gespeicherte Geometrie (Skizzenübernahme)

        for record in input.geometryRecords {
            guard let element = try? JSONDecoder().decode(GeometryElement2D.self, from: record.payload) else {
                issues.append(.init(category: .invalidGeometry, severity: .error,
                                    title: "Geometrie-Eintrag unlesbar",
                                    detail: "Die gespeicherten Daten passen nicht zum Datenmodell.",
                                    reference: record.label,
                                    fix: .removeGeometryRecord(recordID: record.id)))
                continue
            }
            do {
                try element.validate()
            } catch {
                issues.append(.init(category: .invalidGeometry, severity: .error,
                                    title: "Ungültige Geometrie",
                                    detail: "\(record.label): \(error.localizedDescription)",
                                    reference: record.label,
                                    fix: .removeGeometryRecord(recordID: record.id)))
            }
        }

        // MARK: CAD-Dokument

        for element in input.cadElements {
            do {
                try CADDrawing.validate(element)
            } catch {
                issues.append(.init(category: .invalidGeometry, severity: .error,
                                    title: "Ungültiges CAD-Element",
                                    detail: "\(CADKindTitle.title(element.kind)): \(error.localizedDescription)",
                                    reference: "2D-CAD",
                                    fix: .removeCADElement(elementID: element.id)))
            }
        }

        // MARK: Baugruppen

        let partIDs = Set(input.parts.map(\.id))
        let assemblyIDs = Set(input.assemblies.map(\.id))
        for assembly in input.assemblies {
            var dangling = assembly.partIDs.filter { !partIDs.contains($0) }
            dangling.append(contentsOf: assembly.childAssemblyIDs.filter { !assemblyIDs.contains($0) })
            dangling.append(contentsOf: assembly.stepPartIDs.filter { !partIDs.contains($0) })
            var missingParent = false
            if let parent = assembly.parentAssemblyID, !assemblyIDs.contains(parent) { missingParent = true }

            if !dangling.isEmpty || missingParent {
                issues.append(.init(category: .disconnectedAssembly, severity: .error,
                                    title: "Baugruppe verweist auf Fehlendes",
                                    detail: "„\(assembly.name)“: \(dangling.count) Verweise\(missingParent ? " und ein übergeordneter Baugruppenverweis" : "") existieren nicht.",
                                    actual: "\(dangling.count + (missingParent ? 1 : 0)) fehlende Verweise",
                                    reference: "Baugruppe · \(assembly.name)"))
            }
            if assembly.partIDs.isEmpty && assembly.childAssemblyIDs.isEmpty && assembly.stepPartIDs.isEmpty {
                issues.append(.init(category: .disconnectedAssembly, severity: .warning,
                                    title: "Leere Baugruppe",
                                    detail: "„\(assembly.name)“ enthält weder Bauteile noch Unterbaugruppen oder Montageschritte.",
                                    reference: "Baugruppe · \(assembly.name)"))
            }
        }

        // Zirkuläre Hierarchien würden den Baum nie abschließen.
        for assembly in input.assemblies {
            var visited: Set<UUID> = [assembly.id]
            var current = assembly.parentAssemblyID
            while let parentID = current {
                guard visited.insert(parentID).inserted,
                      let parent = input.assemblies.first(where: { $0.id == parentID }) else {
                    issues.append(.init(category: .disconnectedAssembly, severity: .error,
                                        title: "Zirkuläre Baugruppe",
                                        detail: "Die Hierarchie von „\(assembly.name)“ läuft in einem Kreis. Baugruppen können sich nicht selbst enthalten.",
                                        reference: "Baugruppe · \(assembly.name)"))
                    break
                }
                current = parent.parentAssemblyID
            }
        }

        // Fehler zuerst, innerhalb einer Stufe nach Kategorie.
        let order = ValidationIssue.Category.allCases
        issues.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity == .error }
            let left = order.firstIndex(of: lhs.category) ?? 0
            let right = order.firstIndex(of: rhs.category) ?? 0
            return left < right
        }

        return ValidationReport(checks: checks, issues: issues)
    }
}

/// Deutsche Namen der CAD-Elementarten für Funde und Meldungen.
enum CADKindTitle {
    static func title(_ kind: CADKind) -> String {
        switch kind {
        case .line: return "Linie"
        case .rectangle: return "Rechteck"
        case .circle: return "Kreis"
        case .arc: return "Bogen"
        case .profile: return "Profil"
        case .hole: return "Bohrung"
        case .construction: return "Hilfslinie"
        case .text: return "Text"
        case .dimension: return "Maß"
        case .angle: return "Winkel"
        }
    }
}
