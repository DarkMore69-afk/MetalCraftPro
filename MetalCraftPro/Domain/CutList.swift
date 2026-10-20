//
//  CutList.swift
//  MetalCraftPro
//
//  Zuschnittliste und Schnittoptimierung als reine, deterministische Domäne:
//  Liste aus dem parametrischen Modell, Packstrategien pro Profil, CSV-Export.
//

import Foundation

// MARK: - Zuschnittliste

/// Unveränderlicher Eingabeschnappschuss eines Bauteils für die Zuschnittliste.
public struct CutListPartInput: Sendable {
    public var id: UUID
    public var name: String
    public var positionNumber: Int
    public var quantity: Int
    public var lengthMm: Double
    public var profile: ProfileSpec?
    public var isReference: Bool
    public var remark: String

    public init(id: UUID, name: String, positionNumber: Int, quantity: Int,
                lengthMm: Double, profile: ProfileSpec?, isReference: Bool, remark: String) {
        self.id = id; self.name = name; self.positionNumber = positionNumber
        self.quantity = quantity; self.lengthMm = lengthMm; self.profile = profile
        self.isReference = isReference; self.remark = remark
    }
}

/// Schnittwinkel und Bearbeitungen aus den gespeicherten Zuschnitt-Einträgen.
public struct CutListCutInput: Sendable {
    public var partID: UUID?
    public var angleADeg: Double
    public var angleBDeg: Double
    public var machining: String
    public var remark: String

    public init(partID: UUID?, angleADeg: Double, angleBDeg: Double, machining: String, remark: String) {
        self.partID = partID; self.angleADeg = angleADeg; self.angleBDeg = angleBDeg
        self.machining = machining; self.remark = remark
    }
}

/// Eine Zeile der Zuschnittliste: immer abgeleitet, nie gespeichert.
public struct CutListEntry: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var positionNumber: Int
    public var name: String
    public var profile: ProfileSpec
    public var materialGrade: String
    public var quantity: Int
    public var lengthMm: Double
    public var angleADeg: Double
    public var angleBDeg: Double
    public var machiningNotes: [String]
    public var remark: String

    public var pieceWeightKg: Double { (try? CalculationEngine.profileWeight(lengthMm: lengthMm, profile: profile)) ?? 0 }
    public var totalWeightKg: Double { pieceWeightKg * Double(quantity) }

    /// Rohre zeigen die Dimensionskette, Flach- und Blechmaterial auch den Profiltyp.
    public var displayLabel: String {
        switch profile.type {
        case .flachstahl, .blech: return "\(profile.type.displayName) \(profile.dimensionLabel)"
        default: return profile.dimensionLabel
        }
    }

    public var angleLabel: String {
        func n(_ value: Double) -> String { value.isFinite ? "\(Int(value.rounded()))°" : "–" }
        return "\(n(angleADeg)) / \(n(angleBDeg))"
    }
}

/// Aggregierte Bemerkungen (z. B. „Bohrung Ø10 an Pos 3") für die Hinweiskarten.
public struct CutListRemark: Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
}

public struct CutListSummary: Equatable, Sendable {
    public var pieceCount: Int
    public var totalLengthMm: Double
    public var totalWeightKg: Double
}

public enum CutListBuilder {

    /// Die Liste entsteht vollständig aus den Bauteilen und Zuschnitt-Einträgen;
    /// Zukaufteile ohne Profil und Länge erscheinen bewusst nicht.
    public static func entries(materialGrade: String, parts: [CutListPartInput], cuts: [CutListCutInput]) -> [CutListEntry] {
        let cutsByPart = Dictionary(grouping: cuts.compactMap { cut in cut.partID.map { ($0, cut) } },
                                    by: { $0.0 })
        return parts
            .filter { !$0.isReference && $0.lengthMm.isFinite && $0.lengthMm > 0 && $0.profile != nil }
            .sorted { ($0.positionNumber, $0.name) < ($1.positionNumber, $1.name) }
            .map { part -> CutListEntry in
                let partCuts = (cutsByPart[part.id] ?? []).map(\.1)
                let firstCut = partCuts.first
                var notes: [String] = []
                var seenNotes = Set<String>()
                for cut in partCuts {
                    let machining = cut.machining.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !machining.isEmpty, seenNotes.insert(machining).inserted { notes.append(machining) }
                }
                let remarks = partCuts.map(\.remark)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                return CutListEntry(id: part.id, positionNumber: part.positionNumber, name: part.name,
                                    profile: part.profile!, materialGrade: materialGrade,
                                    quantity: max(1, part.quantity), lengthMm: part.lengthMm,
                                    angleADeg: firstCut?.angleADeg ?? 90, angleBDeg: firstCut?.angleBDeg ?? 90,
                                    machiningNotes: notes, remark: remarks.joined(separator: " · "))
            }
    }

    public static func remarks(for entries: [CutListEntry]) -> [CutListRemark] {
        entries.flatMap { entry -> [CutListRemark] in
            let notes = entry.machiningNotes + (entry.remark.isEmpty ? [] : [entry.remark])
            return notes.map { note in
                CutListRemark(id: "\(entry.positionNumber)|\(note)", text: "\(note) an Pos \(entry.positionNumber)")
            }
        }
    }

    public static func summary(entries: [CutListEntry]) -> CutListSummary {
        CutListSummary(pieceCount: entries.reduce(0) { $0 + $1.quantity },
                       totalLengthMm: entries.reduce(0) { $0 + Double($1.quantity) * $1.lengthMm },
                       totalWeightKg: entries.reduce(0) { $0 + $1.totalWeightKg })
    }
}

// MARK: - Schnittoptimierung

/// Ein zu schneidendes Stück; Instanzen gleicher Position erscheinen einzeln.
public struct CuttingPiece: Equatable, Sendable, Identifiable {
    public var id: String
    public var entryID: UUID
    public var positionNumber: Int
    public var lengthMm: Double
    public var profileLabel: String

    public init(id: String, entryID: UUID, positionNumber: Int, lengthMm: Double, profileLabel: String) {
        self.id = id; self.entryID = entryID; self.positionNumber = positionNumber
        self.lengthMm = lengthMm; self.profileLabel = profileLabel
    }
}

public struct CuttingJob: Equatable, Sendable {
    public var pieces: [CuttingPiece]
    public var stockLengthMm: Double
    /// Sägeblattbreite, die jeder Schnitt verbraucht.
    public var kerfMm: Double
    /// Reststücke ab dieser Länge gelten als verwertbar, darunter als Verschnitt.
    public var minimumOffcutMm: Double

    public init(pieces: [CuttingPiece], stockLengthMm: Double, kerfMm: Double = 3, minimumOffcutMm: Double = 200) {
        self.pieces = pieces; self.stockLengthMm = stockLengthMm
        self.kerfMm = kerfMm; self.minimumOffcutMm = minimumOffcutMm
    }
}

/// Eine angebrochene Stange mit ihrer Schnittreihenfolge.
public struct CutBar: Equatable, Sendable, Identifiable {
    public var id: Int
    public var profileLabel: String
    public var pieces: [CuttingPiece]
    public var usedMm: Double
    /// Verwertbares Reststück (≥ Minimum), sonst 0.
    public var offcutMm: Double
    /// Verschnitt (nicht verwertbarer Rest), sonst 0.
    public var wasteMm: Double
}

/// Ein vollständiger Schnittplan einer Strategie über alle Profile.
public struct CuttingPlan: Equatable, Sendable, Identifiable {
    public var id: String
    public var strategyName: String
    public var bars: [CutBar]
    /// Stücke, die auf keine Stange passen – werden gemeldet, nie verworfen.
    public var overlongPieces: [CuttingPiece]
    public var stockLengthMm: Double

    public var barCount: Int { bars.count }
    public var totalWasteMm: Double { bars.reduce(0) { $0 + $1.wasteMm } }
    public var totalOffcutMm: Double { bars.reduce(0) { $0 + $1.offcutMm } }
    public var offcutCount: Int { bars.filter { $0.offcutMm > 0 }.count }
    public var sequenceDescription: String {
        bars.map { bar in bar.pieces.map { DeFormat.number($0.lengthMm) }.joined(separator: " · ") }
            .joined(separator: " | ")
    }
}

public enum CuttingOptimizer {

    public static let strategies = ["Absteigend sortiert", "Bester Platz", "Reihenfolge der Liste"]

    /// Packt jede Profilgruppe getrennt (unterschiedliche Profile teilen keine Stange)
    /// und liefert die Strategien aufsteigend nach Verschnitt sortiert.
    public static func plans(for job: CuttingJob) throws -> [CuttingPlan] {
        try Geometry2D.positive(job.stockLengthMm)
        guard job.kerfMm.isFinite, job.kerfMm >= 0, job.minimumOffcutMm.isFinite, job.minimumOffcutMm >= 0 else {
            throw GeometryError.negativeValue
        }
        let groups = Dictionary(grouping: job.pieces.filter { $0.lengthMm.isFinite && $0.lengthMm > 0 },
                                by: { $0.profileLabel })
        return strategies.map { strategy -> CuttingPlan in
            var bars: [CutBar] = []
            var overlong: [CuttingPiece] = []
            for label in groups.keys.sorted() {
                let pieces = ordered(groups[label] ?? [], strategy: strategy)
                let packed = pack(pieces, profileLabel: label, stock: job.stockLengthMm,
                                  kerf: job.kerfMm, minimumOffcut: job.minimumOffcutMm,
                                  startIndex: bars.count, strategy: strategy)
                bars += packed.bars
                overlong += packed.overlong
            }
            return CuttingPlan(id: strategy, strategyName: strategy, bars: bars,
                               overlongPieces: overlong, stockLengthMm: job.stockLengthMm)
        }
        .sorted { lhs, rhs in
            if lhs.totalWasteMm != rhs.totalWasteMm { return lhs.totalWasteMm < rhs.totalWasteMm }
            if lhs.barCount != rhs.barCount { return lhs.barCount < rhs.barCount }
            return strategies.firstIndex(of: lhs.id) ?? 0 < strategies.firstIndex(of: rhs.id) ?? 0
        }
    }

    private static func ordered(_ pieces: [CuttingPiece], strategy: String) -> [CuttingPiece] {
        switch strategy {
        case "Reihenfolge der Liste":
            return pieces.sorted { ($0.positionNumber, $0.id) < ($1.positionNumber, $1.id) }
        default:
            return pieces.sorted { ($0.lengthMm, $0.positionNumber, $0.id) > ($1.lengthMm, $1.positionNumber, $1.id) }
        }
    }

    private static func pack(_ pieces: [CuttingPiece], profileLabel: String, stock: Double,
                             kerf: Double, minimumOffcut: Double, startIndex: Int,
                             strategy: String) -> (bars: [CutBar], overlong: [CuttingPiece]) {
        var bars: [(pieces: [CuttingPiece], used: Double)] = []
        var overlong: [CuttingPiece] = []
        for piece in pieces {
            // Jeder Schnitt verbraucht Sägeblattbreite; ein Stück, das auf keine
            // Stangenlänge passt, wird gemeldet statt still verworfen.
            guard piece.lengthMm + kerf <= stock else { overlong.append(piece); continue }
            var target: Int?
            if strategy == "Bester Platz" {
                var bestRemaining = Double.infinity
                for (index, bar) in bars.enumerated() {
                    let remaining = stock - (bar.used + kerf + piece.lengthMm)
                    if remaining >= 0, remaining < bestRemaining {
                        bestRemaining = remaining
                        target = index
                    }
                }
            } else {
                target = bars.firstIndex { $0.used + kerf + piece.lengthMm <= stock }
            }
            if let index = target {
                bars[index].pieces.append(piece)
                bars[index].used += kerf + piece.lengthMm
            } else {
                bars.append(([piece], kerf + piece.lengthMm))
            }
        }
        let finished = bars.enumerated().map { index, bar -> CutBar in
            let remaining = stock - bar.used
            if remaining >= minimumOffcut {
                return CutBar(id: startIndex + index, profileLabel: profileLabel, pieces: bar.pieces,
                              usedMm: bar.used, offcutMm: remaining, wasteMm: 0)
            }
            return CutBar(id: startIndex + index, profileLabel: profileLabel, pieces: bar.pieces,
                          usedMm: bar.used, offcutMm: 0, wasteMm: max(0, remaining))
        }
        return (finished, overlong)
    }
}

// MARK: - CSV-Export

public enum CutListCSV {

    /// Deutsches CSV (Semikolon, Dezimalkomma) für Excel und die Werkstatt.
    public static func export(entries: [CutListEntry], plan: CuttingPlan?, stockLengthMm: Double) -> String {
        var lines = ["Pos;Bezeichnung;Profil;Werkstoff;Länge (mm);Stück;Schnittwinkel A (°);Schnittwinkel B (°);Bearbeitung;Bemerkung"]
        for entry in entries {
            let machining = entry.machiningNotes.joined(separator: " / ")
            lines.append([
                "\(entry.positionNumber)", entry.name, entry.displayLabel, entry.materialGrade,
                DeFormat.number(entry.lengthMm), "\(entry.quantity)",
                "\(Int(entry.angleADeg.rounded()))", "\(Int(entry.angleBDeg.rounded()))",
                machining, entry.remark,
            ].joined(separator: ";"))
        }
        if let plan {
            lines.append("")
            lines.append("Schnittplan;\(plan.strategyName);Stangenlänge;\(DeFormat.number(stockLengthMm)) mm")
            for bar in plan.bars {
                let order = bar.pieces.map { DeFormat.number($0.lengthMm) }.joined(separator: " · ")
                var line = "Stange \(bar.id + 1);\(bar.profileLabel);\(order)"
                if bar.offcutMm > 0 { line += ";Reststück \(DeFormat.number(bar.offcutMm)) mm" }
                if bar.wasteMm > 0 { line += ";Verschnitt \(DeFormat.number(bar.wasteMm)) mm" }
                lines.append(line)
            }
            if !plan.overlongPieces.isEmpty {
                let overlong = plan.overlongPieces.map { "Pos \($0.positionNumber): \(DeFormat.number($0.lengthMm)) mm" }
                    .joined(separator: " · ")
                lines.append("Achtung;zu lang für die Stangenlänge;\(overlong)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
