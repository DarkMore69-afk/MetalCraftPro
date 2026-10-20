//
//  AssemblySequence.swift
//  MetalCraftPro
//
//  Montage-Builder als reine, deterministische Domäne: Aus der Baugruppe entsteht
//  eine Schritt-für-Schritt-Abfolge (Basis → Seiten → Streben → Rahmenabschluss →
//  Übrige → Zukaufteile) mit Bewegung, Verbindung, Werkzeug, Position, Maß und
//  Prüfkategorie (Diagonalen beim Rahmenabschluss, sonst Länge). Kein UI, kein Storage.
//

import Foundation

public struct SequencePart: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var positionNumber: Int
    public var quantity: Int
    public var role: String?
    public var profileName: String?
    public var lengthMm: Double

    public init(id: UUID, name: String, positionNumber: Int, quantity: Int,
                role: String?, profileName: String?, lengthMm: Double) {
        self.id = id; self.name = name; self.positionNumber = positionNumber
        self.quantity = quantity; self.role = role
        self.profileName = profileName; self.lengthMm = lengthMm
    }
}

/// Sollwert-Prüfung eines Schritts (z. B. Diagonalen oder Länge).
public struct StepCheck: Sendable, Equatable {
    public var title: String
    public var targetMm: Double
    public var toleranceMm: Double

    public init(title: String, targetMm: Double, toleranceMm: Double) {
        self.title = title; self.targetMm = targetMm; self.toleranceMm = toleranceMm
    }
}

public struct StepBlueprint: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var partIDs: [UUID]
    public var partNames: [String]
    /// ablegen | ansetzen | aufsetzen | einschieben | montieren
    public var movement: String
    public var connection: String
    public var tool: String
    public var lengthMm: Double
    public var positionNote: String
    public var note: String
    public var check: StepCheck?
}

public struct CheckResult: Equatable, Sendable {
    public var withinTolerance: Bool
    public var deviationMm: Double
}

public enum AssemblySequenceBuilder {

    static let weldRoles: Set<String> = ["rahmen_oben", "rahmen_unten", "rahmen_links", "rahmen_rechts", "strebe", "querstrebe"]

    /// Deterministische Montageabfolge aus den Bauteilen (Rollen und Positionsnummern).
    public static func blueprints(widthMm: Double, heightMm: Double, parts: [SequencePart]) -> [StepBlueprint] {
        let sorted = parts.sorted { ($0.positionNumber, $0.name) < ($1.positionNumber, $1.name) }
        let base = sorted.filter { $0.role == "rahmen_unten" }
        let sides = sorted.filter { $0.role == "rahmen_links" || $0.role == "rahmen_rechts" }
        let bars = sorted.filter { $0.role == "strebe" || $0.role == "querstrebe" }
        let top = sorted.filter { $0.role == "rahmen_oben" }
        let hardware = sorted.filter { $0.role == "hardware" }
        let others = sorted.filter { part in
            guard let role = part.role else { return true }
            return !weldRoles.contains(role) && role != "hardware"
        }

        func weld(_ title: String, _ group: [SequencePart], position: String, note: String) -> StepBlueprint {
            StepBlueprint(id: UUID(), title: title, partIDs: group.map(\.id), partNames: group.map(\.name),
                          movement: "ansetzen", connection: "Anschweißen, Naht a3", tool: "WIG-Inverter, Winkel 90°",
                          lengthMm: group.reduce(0) { $0 + $1.lengthMm },
                          positionNote: position, note: note, check: nil)
        }

        var steps: [StepBlueprint] = []
        for part in base {
            steps.append(weld("\(part.name) einsetzen", [part],
                              position: positionNote(for: part.role, quantity: part.quantity, heightMm: heightMm),
                              note: "Erstes Teil legt die Bezugskante fest."))
        }
        if !sides.isEmpty {
            steps.append(weld(sides.count == 1 ? "\(sides[0].name) einsetzen" : "Seitenprofile einsetzen", sides,
                              position: "links und rechts zwischen den horizontalen Profilen",
                              note: "Beide Seiten auf das Innenmaß ausrichten."))
        }
        if !bars.isEmpty {
            steps.append(weld(bars.count == 1 ? "\(bars[0].name) einsetzen" : "Querstreben einsetzen", bars,
                              position: positionNote(for: bars[0].role, quantity: bars[0].quantity, heightMm: heightMm),
                              note: "Gleichmäßig verteilen, Schweißfolge von innen nach außen."))
        }
        for part in top {
            steps.append(weld("\(part.name) einsetzen", [part],
                              position: positionNote(for: part.role, quantity: part.quantity, heightMm: heightMm),
                              note: "Der Rahmen schließt das Profil – danach die Diagonalen prüfen."))
        }
        for part in others {
            steps.append(weld("\(part.name) einsetzen", [part],
                              position: positionNote(for: part.role, quantity: part.quantity, heightMm: heightMm),
                              note: ""))
        }
        for part in hardware {
            steps.append(StepBlueprint(
                id: UUID(), title: "\(part.name) montieren", partIDs: [part.id], partNames: [part.name],
                movement: "montieren", connection: "Verschrauben, M10", tool: "Schraubendreher SW13",
                lengthMm: 0, positionNote: "wie Zeichnung",
                note: "Zukaufteil – Sitz und Spiel prüfen.", check: nil))
        }

        // Prüfkategorien: Diagonalen auf dem Schritt, der das Rahmenprofil schließt;
        // jeder weitere Schweißschritt prüft seine Länge.
        let topIDs = Set(top.map(\.id))
        if let closeIndex = steps.lastIndex(where: { $0.partIDs.contains(where: { topIDs.contains($0) }) }) {
            let diagonal = (widthMm * widthMm + heightMm * heightMm).squareRoot()
            steps[closeIndex].check = StepCheck(title: "Diagonalen prüfen", targetMm: diagonal, toleranceMm: 1.0)
        }
        for index in steps.indices where steps[index].check == nil && steps[index].movement == "ansetzen" {
            let target = steps[index].lengthMm
            if target > 0 {
                steps[index].check = StepCheck(title: "Länge prüfen", targetMm: target, toleranceMm: 1.0)
            }
        }
        return steps
    }

    /// Positionstext je Rolle, abgeleitet aus dem parametrischen Modell.
    public static func positionNote(for role: String?, quantity: Int, heightMm: Double) -> String {
        switch role {
        case "rahmen_oben": return "oben, bündig mit der Außenkante"
        case "rahmen_unten": return "unten, bündig mit der Außenkante"
        case "rahmen_links": return "links, zwischen den horizontalen Profilen"
        case "rahmen_rechts": return "rechts, zwischen den horizontalen Profilen"
        case "strebe": return "gleichmäßig im Innenmaß verteilt (\(max(1, quantity)) Stück)"
        case "querstrebe": return "Mitte, Höhe \(DeFormat.number(heightMm / 2, maxFractionDigits: 0)) mm"
        default: return "wie Zeichnung"
        }
    }

    /// Toleranzbewertung einer Messung: Ergebnis plus Abweichung, ohne stillen Ausgleich.
    public static func evaluate(measuredMm: Double, targetMm: Double, toleranceMm: Double) -> CheckResult {
        guard measuredMm.isFinite, targetMm.isFinite, toleranceMm.isFinite, toleranceMm >= 0 else {
            return CheckResult(withinTolerance: false, deviationMm: .infinity)
        }
        let deviation = (measuredMm - targetMm).magnitude
        return CheckResult(withinTolerance: deviation <= toleranceMm + 1e-9, deviationMm: deviation)
    }
}
