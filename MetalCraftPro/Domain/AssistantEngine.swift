//
//  AssistantEngine.swift
//  MetalCraftPro
//
//  Lokaler KI-Assistent: austauschbare Service-Schnittstelle, vollständig offline.
//  Erzeugt ausschließlich strukturierte Aktionen, die vor der Anwendung von der
//  Geometrie-Engine validiert werden – nichts verändert die CAD-Geometrie ungeprüft.
//

import Foundation

// MARK: - Strukturierte Aktionen

public enum AssistantActionKind: String, CaseIterable, Sendable {
    case addPart = "ADD_PART"
    case removePart = "REMOVE_PART"
    case changeParameter = "CHANGE_PARAMETER"
    case addHole = "ADD_HOLE"
    case changeDimension = "CHANGE_DIMENSION"
    case createAssemblyStep = "CREATE_ASSEMBLY_STEP"
    /// Reine Anzeige (z. B. Zuschnittliste) – keine Speicherung, keine Bestätigung nötig.
    case report = "REPORT"
}

public enum AssistantAction: Equatable, Sendable {
    case addPart(name: String, role: String?, profile: ProfileSpec?, lengthMm: Double?, quantity: Int, remark: String)
    case removePart(positionNumber: Int?, name: String?)
    /// key: breite | hoehe | profil (nur bei profil wird `profile` verwendet).
    case changeParameter(key: String, valueMm: Double, profile: ProfileSpec?)
    case addHole(diameterMm: Double, positionNumber: Int?)
    case changeDimension(label: String, valueMm: Double)
    case createAssemblyStep(title: String, positionNumber: Int?)
    case report(kind: String)
}

// MARK: - Kontext: unveränderlicher Schnappschuss des Projektstands

public struct AssistantPartContext: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var positionNumber: Int
    public var role: String?
    public var lengthMm: Double
    public var quantity: Int
    public var isReference: Bool
    public var weightPerMeterKg: Double

    public init(id: UUID, name: String, positionNumber: Int, role: String?, lengthMm: Double,
                quantity: Int, isReference: Bool, weightPerMeterKg: Double) {
        self.id = id; self.name = name; self.positionNumber = positionNumber; self.role = role
        self.lengthMm = lengthMm; self.quantity = quantity; self.isReference = isReference
        self.weightPerMeterKg = weightPerMeterKg
    }
}

public struct AssistantDimensionContext: Equatable, Sendable {
    public var label: String
    public var valueMm: Double
    public var isParametric: Bool

    public init(label: String, valueMm: Double, isParametric: Bool) {
        self.label = label; self.valueMm = valueMm; self.isParametric = isParametric
    }
}

public struct AssistantContext: Sendable {
    public var widthMm: Double
    public var heightMm: Double
    public var profile: ProfileSpec
    public var parts: [AssistantPartContext]
    public var dimensions: [AssistantDimensionContext]
    public var assemblyStepCount: Int
    public var hasAssembly: Bool

    public init(widthMm: Double, heightMm: Double, profile: ProfileSpec, parts: [AssistantPartContext],
                dimensions: [AssistantDimensionContext], assemblyStepCount: Int, hasAssembly: Bool) {
        self.widthMm = widthMm; self.heightMm = heightMm; self.profile = profile
        self.parts = parts; self.dimensions = dimensions
        self.assemblyStepCount = assemblyStepCount; self.hasAssembly = hasAssembly
    }

    /// Die Geometrie-Engine selbst: jeder Vorschlag wird gegen diese Parameter geprüft.
    public var frame: FrameParameters? {
        try? FrameParameters(width: widthMm, height: heightMm, profile: profile)
    }

    public func part(at positionNumber: Int) -> AssistantPartContext? {
        parts.first { $0.positionNumber == positionNumber }
    }
}

// MARK: - Vorschau & Antwort

public struct AssistantProposal: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: AssistantActionKind
    public var action: AssistantAction
    public var title: String
    public var summary: String
    public var details: [String]
    public var isValid: Bool
    public var problem: String?
    public var isReport: Bool

    public init(id: UUID = UUID(), kind: AssistantActionKind, action: AssistantAction, title: String,
                summary: String, details: [String], isValid: Bool, problem: String? = nil, isReport: Bool = false) {
        self.id = id; self.kind = kind; self.action = action; self.title = title
        self.summary = summary; self.details = details; self.isValid = isValid
        self.problem = problem; self.isReport = isReport
    }
}

public struct AssistantResponse: Equatable, Sendable {
    public var message: String
    public var proposals: [AssistantProposal]

    public init(message: String, proposals: [AssistantProposal]) {
        self.message = message; self.proposals = proposals
    }
}

/// Austauschbare Service-Schnittstelle: die App kennt nur dieses Protokoll.
/// Die mitgelieferte Implementierung läuft vollständig lokal und deterministisch;
/// eine spätere cloud- oder modellbasierte Engine kann sie ersetzen, ohne die UI zu ändern.
public protocol AssistantService: Sendable {
    func respond(to text: String, context: AssistantContext) throws -> AssistantResponse
}

// MARK: - Validierung gegen die Geometrie-Engine

public enum AssistantValidator {

    /// Baut die Vorschau einer Aktion: validiert gegen die Geometrie-Engine und
    /// beschreibt die Folgeänderungen (Zeichnung, 3D, Zuschnitt).
    public static func validate(_ action: AssistantAction, context: AssistantContext) -> AssistantProposal {
        switch action {
        case .changeParameter(let key, let value, let profile):
            return parameterProposal(key: key, value: value, profile: profile, context: context)
        case .addPart(let name, let role, let profile, let length, let quantity, let remark):
            return addPartProposal(name: name, role: role, profile: profile, length: length,
                                   quantity: quantity, remark: remark, context: context)
        case .removePart(let positionNumber, let name):
            return removePartProposal(positionNumber: positionNumber, name: name, context: context)
        case .addHole(let diameter, let positionNumber):
            return addHoleProposal(diameter: diameter, positionNumber: positionNumber, context: context)
        case .changeDimension(let label, let value):
            return dimensionProposal(label: label, value: value, context: context)
        case .createAssemblyStep(let title, let positionNumber):
            return stepProposal(title: title, positionNumber: positionNumber, context: context)
        case .report(let kind):
            return AssistantProposal(kind: .report, action: action,
                                     title: kind == "zuschnittliste" ? "Zuschnittliste" : "Übersicht",
                                     summary: cutListSummary(context), details: [],
                                     isValid: true, isReport: true)
        }
    }

    private static func parameterProposal(key: String, value: Double, profile: ProfileSpec?,
                                          context: AssistantContext) -> AssistantProposal {
        var title = "Parameter ändern"
        var summary = ""
        var details: [String] = []
        var problem: String?
        guard let frame = context.frame else {
            return AssistantProposal(kind: .changeParameter,
                                     action: .changeParameter(key: key, valueMm: value, profile: profile),
                                     title: title, summary: "", details: [], isValid: false,
                                     problem: "Die aktuelle Geometrie ist ungültig – bitte zuerst Breite, Höhe und Profil prüfen.")
        }
        let standard = ["Zeichnung & 3D: Der Rahmen wird auf die neuen Maße neu aufgebaut.",
                        "Zuschnittliste: Längen parametrischer Bauteile folgen automatisch.",
                        "Maßkontrolle: Die Freigabe wird zurückgesetzt und muss neu bestätigt werden."]
        switch key {
        case "breite":
            title = "Breite ändern"
            summary = "Breite: \(DeFormat.number(context.widthMm)) mm → \(DeFormat.number(value)) mm"
            guard let proposed = try? FrameParameters(width: value, height: context.heightMm, profile: context.profile) else {
                problem = "Diese Breite ergibt keine gültige Geometrie – sie muss größer als zwei Profilbreiten (\(DeFormat.number(2 * context.profile.widthMm)) mm) und höchstens 100.000 mm sein."
                break
            }
            guard abs(context.widthMm - value) > 1e-9 else {
                problem = "Die Breite beträgt bereits \(DeFormat.number(value)) mm."
                break
            }
            details.append("Innenmaß (Breite): \(DeFormat.number(frame.innerWidth)) mm → \(DeFormat.number(proposed.innerWidth)) mm")
            details.append(contentsOf: lengthChanges(context: context, widthFrom: context.widthMm, widthTo: value,
                                                     heightFrom: context.heightMm, heightTo: context.heightMm))
            details.append(contentsOf: standard)
        case "hoehe":
            title = "Höhe ändern"
            summary = "Höhe: \(DeFormat.number(context.heightMm)) mm → \(DeFormat.number(value)) mm"
            guard let proposed = try? FrameParameters(width: context.widthMm, height: value, profile: context.profile) else {
                problem = "Diese Höhe ergibt keine gültige Geometrie – sie muss größer als zwei Profilbreiten (\(DeFormat.number(2 * context.profile.widthMm)) mm) und höchstens 100.000 mm sein."
                break
            }
            guard abs(context.heightMm - value) > 1e-9 else {
                problem = "Die Höhe beträgt bereits \(DeFormat.number(value)) mm."
                break
            }
            details.append("Innenmaß (Höhe): \(DeFormat.number(frame.innerHeight)) mm → \(DeFormat.number(proposed.innerHeight)) mm")
            details.append(contentsOf: lengthChanges(context: context, widthFrom: context.widthMm, widthTo: context.widthMm,
                                                     heightFrom: context.heightMm, heightTo: value))
            details.append(contentsOf: standard)
        case "profil":
            title = "Profil ändern"
            guard let profile else {
                problem = "Profil nicht erkannt – z. B. „Ändere das Profil auf 40x40x3“."
                break
            }
            summary = "Profil: \(context.profile.dimensionLabel) → \(profile.dimensionLabel)"
            if (try? profile.validate()) == nil {
                problem = "Diese Profilabmessungen ergeben keinen gültigen Querschnitt."
                break
            }
            guard (try? FrameParameters(width: context.widthMm, height: context.heightMm, profile: profile)) != nil else {
                problem = "Mit diesem Profil ergeben Breite und Höhe keine gültige Geometrie."
                break
            }
            guard profile != context.profile else {
                problem = "Das Profil ist bereits \(profile.dimensionLabel)."
                break
            }
            details.append("Gewicht pro Meter: \(DeFormat.number(context.profile.weightPerMeterKg, maxFractionDigits: 2)) kg → \(DeFormat.number(profile.weightPerMeterKg, maxFractionDigits: 2)) kg")
            details.append("Innenmaß: \(DeFormat.number(frame.innerWidth)) × \(DeFormat.number(frame.innerHeight)) mm → \(DeFormat.number(context.widthMm - 2 * profile.widthMm)) × \(DeFormat.number(context.heightMm - 2 * profile.widthMm)) mm")
            details.append(contentsOf: standard)
        default:
            problem = "Unbekannter Parameter."
        }
        return AssistantProposal(kind: .changeParameter,
                                 action: .changeParameter(key: key, valueMm: value, profile: profile),
                                 title: title, summary: summary, details: details,
                                 isValid: problem == nil, problem: problem)
    }

    /// Konkrete Längenänderungen parametrischer Bauteile als Vorschau.
    private static func lengthChanges(context: AssistantContext, widthFrom: Double, widthTo: Double,
                                      heightFrom: Double, heightTo: Double) -> [String] {
        guard let oldFrame = try? FrameParameters(width: widthFrom, height: heightFrom, profile: context.profile),
              let newFrame = try? FrameParameters(width: widthTo, height: heightTo, profile: context.profile) else { return [] }
        var lines: [String] = []
        for part in context.parts where !part.isReference {
            guard let role = part.role, let old = oldFrame.length(for: role),
                  let new = newFrame.length(for: role), abs(old - new) > 1e-9 else { continue }
            lines.append("Pos. \(part.positionNumber) · \(part.name): \(DeFormat.number(old)) → \(DeFormat.number(new)) mm")
        }
        if lines.isEmpty { lines.append("Bauteillängen bleiben unverändert.") }
        return lines
    }

    private static func addPartProposal(name: String, role: String?, profile: ProfileSpec?, length: Double?,
                                        quantity: Int, remark: String, context: AssistantContext) -> AssistantProposal {
        func reject(_ problemText: String) -> AssistantProposal {
            AssistantProposal(kind: .addPart,
                              action: .addPart(name: name, role: role, profile: profile,
                                               lengthMm: length, quantity: quantity, remark: remark),
                              title: "Bauteil hinzufügen", summary: "", details: [],
                              isValid: false, problem: problemText)
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            return reject("Bitte nenne das Bauteil, z. B. „Füge eine Querstrebe hinzu“.")
        }
        guard quantity >= 1, quantity <= 999 else {
            return reject("Die Stückzahl muss zwischen 1 und 999 liegen.")
        }
        var problem: String?
        var details: [String] = []
        var resolved: Double = 0
        var isParametric = false
        if let length {
            if (try? Geometry2D.positive(length)) == nil {
                problem = "Die Länge muss größer als null sein."
            } else {
                resolved = length
            }
        } else if let role, let parametric = context.frame?.length(for: role) {
            resolved = parametric
            isParametric = true
        } else if role != "hardware" {
            problem = "Bitte gib eine Länge an, z. B. „Füge ein Bauteil Halter, 300 mm, hinzu.“ – oder verwende eine parametrische Rolle wie Querstrebe."
        }
        if problem == nil {
            details.append("Pos. \(nextPosition(in: context)) · „\(cleanName)“ · \(quantity) Stück")
            if isParametric {
                details.append("Länge folgt dem parametrischen Modell: \(DeFormat.number(resolved)) mm")
            } else if resolved > 0 {
                details.append("Länge: \(DeFormat.number(resolved)) mm (fest)")
            } else {
                details.append("Zukaufteil ohne Fertigungslänge (Referenz in Stückliste und Baugruppe)")
            }
            if !remark.isEmpty { details.append("Lage: \(remark)") }
            if role != "hardware" {
                details.append("Zuschnittliste: Neue Position mit \(quantity) Schnitt(en)")
            }
            details.append("Baugruppe: Das Bauteil wird der Baugruppe auf Wurzelebene aufgenommen.")
            details.append("Maßkontrolle: Die Freigabe wird zurückgesetzt und muss neu bestätigt werden.")
        }
        let summary = problem == nil
            ? "\(cleanName) · \(quantity) Stück\(resolved > 0 ? " · \(DeFormat.number(resolved)) mm" : "")"
            : ""
        return AssistantProposal(kind: .addPart,
                                 action: .addPart(name: cleanName, role: role, profile: profile,
                                                  lengthMm: length, quantity: quantity, remark: remark),
                                 title: "Bauteil hinzufügen", summary: summary, details: details,
                                 isValid: problem == nil, problem: problem)
    }

    private static func nextPosition(in context: AssistantContext) -> Int {
        (context.parts.map(\.positionNumber).max() ?? 0) + 1
    }

    private static func removePartProposal(positionNumber: Int?, name: String?, context: AssistantContext) -> AssistantProposal {
        var problem: String?
        var target: AssistantPartContext?
        if let positionNumber {
            target = context.part(at: positionNumber)
            if target == nil { problem = "Kein Bauteil mit der Positionsnummer \(positionNumber) gefunden." }
        } else if let name {
            let clean = name.lowercased()
            let matches = context.parts.filter { $0.name.lowercased().contains(clean) }
            if matches.count == 1 { target = matches[0] }
            else if matches.isEmpty { problem = "Kein Bauteil mit dieser Bezeichnung gefunden." }
            else { problem = "Die Bezeichnung passt auf \(matches.count) Bauteile – bitte nenne die Positionsnummer, z. B. „Entferne Pos \(matches[0].positionNumber)“." }
        } else {
            problem = "Bitte nenne das Bauteil oder die Positionsnummer, z. B. „Entferne Pos 3“."
        }
        var details: [String] = []
        if let target {
            details.append("Pos. \(target.positionNumber) · \(target.name) (\(target.quantity) Stück) wird entfernt.")
            if !target.isReference { details.append("Zuschnittliste: Die Position entfällt.") }
            details.append("Baugruppe: Das Bauteil wird aus allen Baugruppen und Schritten entfernt.")
            details.append("Maßkontrolle: Die Freigabe wird zurückgesetzt und muss neu bestätigt werden.")
        }
        return AssistantProposal(kind: .removePart,
                                 action: .removePart(positionNumber: positionNumber, name: name),
                                 title: "Bauteil entfernen",
                                 summary: target.map { "Pos. \($0.positionNumber) · \($0.name)" } ?? "",
                                 details: details, isValid: problem == nil, problem: problem)
    }

    private static func addHoleProposal(diameter: Double, positionNumber: Int?, context: AssistantContext) -> AssistantProposal {
        var problem: String?
        if (try? Geometry2D.positive(diameter)) == nil {
            problem = "Der Durchmesser muss größer als null sein."
        } else if diameter >= min(context.profile.widthMm, context.profile.heightMm) {
            problem = "Eine Bohrung Ø\(DeFormat.number(diameter)) passt nicht in das Profil \(context.profile.dimensionLabel)."
        } else if positionNumber == nil {
            problem = "Bitte gib an, an welcher Position gebohrt wird, z. B. „Bohre ein Loch Ø10 in Pos 3“."
        } else if context.part(at: positionNumber!) == nil {
            problem = "Kein Bauteil mit der Positionsnummer \(positionNumber!) gefunden."
        }
        var details: [String] = []
        if problem == nil, let positionNumber, let part = context.part(at: positionNumber) {
            details.append("Bearbeitung an Pos. \(positionNumber) · \(part.name): Bohrung Ø\(DeFormat.number(diameter))")
            details.append("Zuschnittliste: Die Bemerkung zur Bearbeitung wird ergänzt.")
            details.append("Maßkontrolle: Die Freigabe wird zurückgesetzt und muss neu bestätigt werden.")
        }
        return AssistantProposal(kind: .addHole,
                                 action: .addHole(diameterMm: diameter, positionNumber: positionNumber),
                                 title: "Bohrung hinzufügen",
                                 summary: positionNumber.flatMap { context.part(at: $0) }
                                     .map { "Bohrung Ø\(DeFormat.number(diameter)) an Pos. \($0.positionNumber)" } ?? "",
                                 details: details, isValid: problem == nil, problem: problem)
    }

    private static func dimensionProposal(label: String, value: Double, context: AssistantContext) -> AssistantProposal {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = context.dimensions.first {
            $0.label.localizedCaseInsensitiveCompare(clean) == .orderedSame
                || ($0.label.lowercased().contains(clean.lowercased()) && clean.count >= 4)
        }
        var problem: String?
        var details: [String] = []
        var summary = ""
        if (try? Geometry2D.positive(value)) == nil {
            problem = "Der Maßwert muss größer als null sein."
        } else if let match {
            if match.isParametric {
                if match.label.lowercased().contains("breite") {
                    return parameterProposal(key: "breite", value: value, profile: nil, context: context)
                }
                if match.label.lowercased().contains("höhe") || match.label.lowercased().contains("hoehe") {
                    return parameterProposal(key: "hoehe", value: value, profile: nil, context: context)
                }
                problem = "Das Maß „\(match.label)“ folgt dem parametrischen Modell und kann nicht frei gesetzt werden."
            } else {
                summary = "Maß „\(match.label)“: \(DeFormat.number(match.valueMm)) mm → \(DeFormat.number(value)) mm"
                if abs(match.valueMm - value) <= 1e-9 {
                    problem = "Das Maß beträgt bereits \(DeFormat.number(value)) mm."
                } else {
                    details.append("Maßkontrolle: Die Freigabe wird zurückgesetzt und muss neu bestätigt werden.")
                }
            }
        } else {
            problem = "Kein Maß mit dieser Bezeichnung gefunden – vorhandene Maße: \(context.dimensions.map(\.label).prefix(4).joined(separator: ", "))."
        }
        return AssistantProposal(kind: .changeDimension,
                                 action: .changeDimension(label: clean, valueMm: value),
                                 title: "Maß setzen", summary: summary, details: details,
                                 isValid: problem == nil, problem: problem)
    }

    private static func stepProposal(title: String, positionNumber: Int?, context: AssistantContext) -> AssistantProposal {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var problem: String?
        var details: [String] = []
        if clean.isEmpty {
            problem = "Bitte gib dem Schritt eine Bezeichnung."
        } else if !context.hasAssembly {
            problem = "Es existiert noch keine Baugruppe."
        } else if let positionNumber, context.part(at: positionNumber) == nil {
            problem = "Kein Bauteil mit der Positionsnummer \(positionNumber) gefunden."
        } else {
            if let positionNumber, let part = context.part(at: positionNumber) {
                details.append("Bauteil: Pos. \(part.positionNumber) · \(part.name)")
            }
            details.append("Der Schritt „\(clean)“ wird am Ende der Montageabfolge ergänzt (aktuell \(context.assemblyStepCount) Schritte).")
        }
        return AssistantProposal(kind: .createAssemblyStep,
                                 action: .createAssemblyStep(title: clean, positionNumber: positionNumber),
                                 title: "Montageschritt ergänzen", summary: clean, details: details,
                                 isValid: problem == nil, problem: problem)
    }

    static func cutListSummary(_ context: AssistantContext) -> String {
        let production = context.parts.filter { !$0.isReference && $0.lengthMm > 0 }
        guard !production.isEmpty else {
            return "Noch keine Zuschnittteile – lege zuerst Bauteile an, z. B. „Füge eine Querstrebe in der Mitte hinzu“."
        }
        let pieces = production.reduce(0) { $0 + $1.quantity }
        let meters = production.reduce(0.0) { $0 + Double($1.quantity) * $1.lengthMm / 1000 }
        let weight = production.reduce(0.0) { $0 + Double($1.quantity) * $1.lengthMm / 1000 * $1.weightPerMeterKg }
        return "Zuschnittliste: \(pieces) Teile · \(DeFormat.number(meters, maxFractionDigits: 2)) m · ca. \(DeFormat.number(weight, maxFractionDigits: 1)) kg. Die optimierte Schnittfolge steht in der Zuschnittliste des Projekts."
    }
}

// MARK: - Lokale Regel-Engine (offline, deterministisch)

public struct LocalRuleAssistant: AssistantService {

    public init() {}

    public static let exampleCommands = [
        "Erstelle einen Rahmen 1200x800 aus 40x40x2",
        "Ändere die Höhe auf 900 mm",
        "Füge eine Querstrebe in der Mitte hinzu",
        "Bohre ein Loch Ø10 in Pos 3",
        "Entferne Pos 3",
        "Füge einen Montageschritt für Pos 2 hinzu",
        "Erstelle die Zuschnittliste"
    ]

    public func respond(to text: String, context: AssistantContext) throws -> AssistantResponse {
        Self.parse(text, context: context)
    }

    private static let previewMessage = "Vorschau bereit – bitte prüfe die Folgeänderungen und bestätige. Nichts wird ohne deine Zustimmung geändert."

    // MARK: Parser (deterministisch, rein lokal)

    static func parse(_ text: String, context: AssistantContext) -> AssistantResponse {
        let normalized = normalize(text)

        // 1 · Zuschnittliste (reine Anzeige)
        if normalized.contains("zuschnittliste")
            || (normalized.contains("zuschnitt")
                && (normalized.contains("erstelle") || normalized.contains("erzeuge")
                    || normalized.contains("zeig") || normalized.contains("gib"))) {
            let proposal = AssistantValidator.validate(.report(kind: "zuschnittliste"), context: context)
            return AssistantResponse(message: proposal.summary, proposals: [proposal])
        }

        // 2 · Rahmen erstellen: Parameter setzen (Breite, Höhe, Profil)
        if normalized.contains("rahmen"), let pair = firstMatch("(\\d+(?:[.,]\\d+)?)\\s*x\\s*(\\d+(?:[.,]\\d+)?)", in: normalized) {
            let width = pair[0]
            let height = pair.count > 1 ? pair[1] : width
            var profile: ProfileSpec?
            if let triple = profileTriple(in: normalized) {
                profile = profileSpec(height: triple[0], width: triple[1], thickness: triple[2], hint: normalized)
            }
            var proposals = [AssistantValidator.validate(.changeParameter(key: "breite", valueMm: width, profile: nil), context: context)]
            if abs(height - width) > 1e-9 {
                proposals.append(AssistantValidator.validate(.changeParameter(key: "hoehe", valueMm: height, profile: nil), context: context))
            }
            if let profile, profile != context.profile {
                proposals.append(AssistantValidator.validate(.changeParameter(key: "profil", valueMm: 0, profile: profile), context: context))
            }
            return AssistantResponse(message: "Verstanden – \(proposals.count) Änderung(en) am parametrischen Rahmen. Bitte prüfe die Vorschau; nichts wird ohne Bestätigung geändert.", proposals: proposals)
        }

        // 3 · Bohrung
        if normalized.contains("bohrung") || normalized.contains("bohre") || normalized.contains("loch") {
            guard let diameter = (firstMatch("ø\\s*(\\d+(?:[.,]\\d+)?)", in: normalized)
                ?? firstMatch("durchmesser\\s*(\\d+(?:[.,]\\d+)?)", in: normalized))?.first else {
                return AssistantResponse(message: "Bitte nenne den Durchmesser, z. B. „Bohre ein Loch Ø10 in Pos 3“.", proposals: [])
            }
            let position = firstMatch("pos\\.?\\s*(\\d+)", in: normalized).flatMap { Int($0[0]) }
            let proposal = AssistantValidator.validate(.addHole(diameterMm: diameter, positionNumber: position), context: context)
            return AssistantResponse(message: previewMessage, proposals: [proposal])
        }

        // 4 · Bauteil entfernen
        if normalized.contains("entferne") || normalized.contains("lösche") || normalized.contains("loesche") {
            let position = firstMatch("pos\\.?\\s*(\\d+)", in: normalized).flatMap { Int($0[0]) }
            let name = longestPartName(in: normalized, context: context)
            let proposal = AssistantValidator.validate(.removePart(positionNumber: position, name: name), context: context)
            return AssistantResponse(message: previewMessage, proposals: [proposal])
        }

        // 5 · Montageschritt ergänzen
        if normalized.contains("montageschritt") || (normalized.contains("schritt") && normalized.contains("montage")) {
            let position = firstMatch("pos\\.?\\s*(\\d+)", in: normalized).flatMap { Int($0[0]) }
            let proposal = AssistantValidator.validate(.createAssemblyStep(title: "Montageschritt", positionNumber: position), context: context)
            return AssistantResponse(message: previewMessage, proposals: [proposal])
        }

        // 6 · Bauteil hinzufügen
        if normalized.contains("füge") || normalized.contains("fuege") || normalized.contains("ergänze")
            || normalized.contains("hinzufü") || normalized.contains("lege an") {
            let quantity = quantity(in: normalized)
            var role: String?
            var name = "Bauteil"
            if normalized.contains("querstreb") { role = "querstrebe"; name = "Querstrebe" }
            else if normalized.contains("scharnier") { role = "hardware"; name = "Scharnier" }
            else if normalized.contains("schloss") { role = "hardware"; name = "Schloss" }
            else if normalized.contains("rahmenprofil") { role = "rahmen_oben"; name = "Rahmenprofil" }
            let length = firstMatch("(\\d+(?:[.,]\\d+)?)\\s*mm", in: normalized).map { $0[0] }
            let remark = normalized.contains("mitte") ? "Mitte" : ""
            let profile = profileTriple(in: normalized)
                .flatMap { profileSpec(height: $0[0], width: $0[1], thickness: $0[2], hint: normalized) }
            let proposal = AssistantValidator.validate(.addPart(name: name, role: role, profile: profile,
                                                                lengthMm: length, quantity: quantity, remark: remark),
                                                       context: context)
            return AssistantResponse(message: previewMessage, proposals: [proposal])
        }

        // 7 · Maß setzen (freie Maße; parametrische Maße werden umgeleitet)
        if normalized.contains("maß") || normalized.contains("mass") {
            if let value = firstMatch("auf\\s*(\\d+(?:[.,]\\d+)?)", in: normalized)?.first {
                let label = dimensionLabel(in: normalized, context: context) ?? ""
                let proposal = AssistantValidator.validate(.changeDimension(label: label, valueMm: value), context: context)
                return AssistantResponse(message: previewMessage, proposals: [proposal])
            }
            return AssistantResponse(message: "Bitte gib an, auf welchen Wert das Maß gesetzt werden soll, z. B. „Setze das Maß Diagonale auf 1442 mm“.", proposals: [])
        }

        // 8 · Höhe, Breite oder Profil ändern
        if normalized.contains("höhe") || normalized.contains("hoehe") || normalized.contains("breite") || normalized.contains("profil") {
            if let value = firstMatch("auf\\s*(\\d+(?:[.,]\\d+)?)", in: normalized)?.first {
                let isHeight = normalized.contains("höhe") || normalized.contains("hoehe") || !normalized.contains("breite")
                let proposal = AssistantValidator.validate(.changeParameter(key: isHeight ? "hoehe" : "breite",
                                                                            valueMm: value, profile: nil), context: context)
                return AssistantResponse(message: previewMessage, proposals: [proposal])
            }
            if normalized.contains("profil"), let triple = profileTriple(in: normalized) {
                let profile = profileSpec(height: triple[0], width: triple[1], thickness: triple[2], hint: normalized)
                let proposal = AssistantValidator.validate(.changeParameter(key: "profil", valueMm: 0, profile: profile), context: context)
                return AssistantResponse(message: previewMessage, proposals: [proposal])
            }
            return AssistantResponse(message: "Bitte gib an, auf welchen Wert geändert werden soll, z. B. „Ändere die Höhe auf 900 mm“.", proposals: [])
        }

        // 9 · Unbekannt: ehrlich bleiben, nichts erfinden
        return AssistantResponse(message: "Das habe ich nicht verstanden. Ich verstehe z. B.: „Erstelle einen Rahmen 1200x800 aus 40x40x2“, „Ändere die Höhe auf 900 mm“, „Füge eine Querstrebe in der Mitte hinzu“, „Bohre ein Loch Ø10 in Pos 3“, „Entferne Pos 3“, „Füge einen Montageschritt für Pos 2 hinzu“, „Erstelle die Zuschnittliste“.", proposals: [])
    }

    // MARK: Hilfsfunktionen

    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "×", with: "x")
    }

    static func firstMatch(_ pattern: String, in text: String) -> [Double]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var values: [Double] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: text) else { continue }
            guard let value = Double(text[range].replacingOccurrences(of: ",", with: ".")) else { continue }
            values.append(value)
        }
        return values.isEmpty ? nil : values
    }

    static func profileTriple(in text: String) -> [Double]? {
        firstMatch("(\\d+(?:[.,]\\d+)?)\\s*x\\s*(\\d+(?:[.,]\\d+)?)\\s*x\\s*(\\d+(?:[.,]\\d+)?)", in: text)
    }

    static func quantity(in text: String) -> Int {
        let words: [(String, Int)] = [("zwei", 2), ("drei", 3), ("vier", 4), ("fünf", 5), ("fuenf", 5),
                                      ("sechs", 6), ("sieben", 7), ("acht", 8)]
        for (word, count) in words where text.contains(word) { return count }
        if let explicit = firstMatch("(\\d+)\\s*(?:stück|x)", in: text)?.first { return Int(explicit) }
        return 1
    }

    static func longestPartName(in text: String, context: AssistantContext) -> String? {
        var best: String?
        for part in context.parts {
            let name = part.name.lowercased()
            if name.count >= 4, text.contains(name), name.count > (best?.count ?? 0) {
                best = part.name
            }
        }
        return best
    }

    static func dimensionLabel(in text: String, context: AssistantContext) -> String? {
        for dimension in context.dimensions {
            let label = dimension.label.lowercased()
            if label.count >= 3, text.contains(label) { return dimension.label }
        }
        return nil
    }

    /// Profil aus drei Abmessungen: Katalogtreffer bevorzugen, sonst benutzerdefiniert.
    static func profileSpec(height: Double, width: Double, thickness: Double, hint: String) -> ProfileSpec? {
        var type: ProfileType = height == width ? .vierkantrohr : .rechteckrohr
        if hint.contains("rundrohr") { type = .rundrohr }
        else if hint.contains("flachstahl") { type = .flachstahl }
        else if hint.contains("rundstahl") { type = .rundstahl }
        else if hint.contains("rechteckrohr") { type = .rechteckrohr }
        else if hint.contains("vierkantrohr") { type = .vierkantrohr }
        if let catalogue = ProfileCatalog.standardCatalog().first(where: {
            $0.type == type && $0.heightMm == height && $0.widthMm == width && $0.thicknessMm == thickness
        }) {
            return catalogue
        }
        let name = type == .rundrohr
            ? "Ø\(DeFormat.number(height)) × \(DeFormat.number(thickness))"
            : "\(DeFormat.number(height)) × \(DeFormat.number(width)) × \(DeFormat.number(thickness))"
        let spec = ProfileSpec(type: type, name: name, heightMm: height, widthMm: width,
                               thicknessMm: thickness, isCustom: true)
        guard (try? spec.validate()) != nil else { return nil }
        return spec
    }
}
