//
//  WeldProtocol.swift
//  MetalCraftPro
//
//  Schweißmodul für MIG/MAG, WIG und E-Hand: Nahtdaten als reine Wertobjekte,
//  Protokollaufbau je Projekt und Bauteil, deterministische PDF-Erzeugung.
//

import Foundation
import UIKit

// MARK: - Nahtdaten

public struct WeldRecord: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    /// mig | wig | ehand
    public var method: String
    public var material: String
    public var thicknessMm: Double
    public var filler: String
    public var gas: String
    public var currentA: Double
    public var voltageV: Double
    public var wireFeedMMin: Double
    public var position: String
    public var seamType: String
    public var sequence: String
    public var note: String
    public var partID: UUID?

    public static let methods = ["mig", "wig", "ehand"]

    public init(id: UUID = UUID(), label: String, method: String, material: String,
                thicknessMm: Double, filler: String, gas: String, currentA: Double,
                voltageV: Double, wireFeedMMin: Double, position: String,
                seamType: String, sequence: String, note: String = "", partID: UUID? = nil) {
        self.id = id; self.label = label; self.method = method; self.material = material
        self.thicknessMm = thicknessMm; self.filler = filler; self.gas = gas
        self.currentA = currentA; self.voltageV = voltageV; self.wireFeedMMin = wireFeedMMin
        self.position = position; self.seamType = seamType; self.sequence = sequence
        self.note = note; self.partID = partID
    }

    public var methodLabel: String {
        switch method {
        case "wig": return "WIG"
        case "ehand": return "E-Hand"
        default: return "MIG/MAG"
        }
    }

    /// E-Hand und WIG haben keinen Drahtvorschub; 0 bedeutet „nicht angegeben“.
    public var wireFeedLabel: String {
        wireFeedMMin > 0 ? "\(DeFormat.number(wireFeedMMin)) m/min" : "–"
    }
    public var currentLabel: String {
        currentA > 0 ? "\(DeFormat.number(currentA, maxFractionDigits: 0)) A" : "–"
    }

    /// Parameterzeilen in fester Reihenfolge – Grundlage für Karte, Protokoll und Prüfung.
    public var parameterRows: [(String, String)] {
        [("Werkstoff", material),
         ("Dicke", thicknessMm > 0 ? "\(DeFormat.number(thicknessMm)) mm" : ""),
         ("Draht/Elektrode", filler),
         ("Gas", gas),
         ("Strom", currentA > 0 ? "\(DeFormat.number(currentA, maxFractionDigits: 0)) A" : ""),
         ("Spannung", voltageV > 0 ? "\(DeFormat.number(voltageV)) V" : ""),
         ("Drahtvorschub", wireFeedLabel),
         ("Position", position),
         ("Nahtart", seamType),
         ("Schweißfolge", sequence)]
    }

    /// Vollständig dokumentiert: jeder Parameter ist gesetzt; der Strich beim
    /// Drahtvorschub gilt als gültiger Wert.
    public var isDocumented: Bool {
        parameterRows.allSatisfy { !$0.1.isEmpty }
    }
}

public struct WeldPartInput: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var positionNumber: Int

    public init(id: UUID, name: String, positionNumber: Int) {
        self.id = id; self.name = name; self.positionNumber = positionNumber
    }
}

// MARK: - Protokoll je Projekt und Bauteil

public struct WeldProtocolEntry: Equatable, Sendable, Identifiable {
    public var partLabel: String
    public var records: [WeldRecord]
    public var id: String { partLabel }
}

public enum WeldProtocolBuilder {
    /// Nähte nach Bauteil gruppiert, Bauteile nach Positionsnummer; Nähte ohne
    /// Zuordnung bleiben am Ende sichtbar, statt still zu verschwinden.
    public static func entries(parts: [WeldPartInput], welds: [WeldRecord]) -> [WeldProtocolEntry] {
        var result: [WeldProtocolEntry] = []
        for part in parts.sorted(by: { ($0.positionNumber, $0.name) < ($1.positionNumber, $1.name) }) {
            let records = welds.filter { $0.partID == part.id }
            guard !records.isEmpty else { continue }
            result.append(WeldProtocolEntry(partLabel: "Pos \(part.positionNumber) · \(part.name)", records: records))
        }
        let orphans = welds.filter { weld in !parts.contains(where: { $0.id == weld.partID }) }
        if !orphans.isEmpty {
            result.append(WeldProtocolEntry(partLabel: "Ohne Bauteilzuordnung", records: orphans))
        }
        return result
    }

    public static func summary(entries: [WeldProtocolEntry]) -> (seams: Int, documented: Int) {
        let all = entries.flatMap(\.records)
        return (all.count, all.filter(\.isDocumented).count)
    }
}

// MARK: - PDF-Erzeugung

public enum WeldProtocolPDF {
    /// DIN-A4-Protokoll mit Kopf, Bauteilabschnitten und Parameterblöcken je Naht.
    public static func data(entries: [WeldProtocolEntry], projectName: String, projectNumber: String,
                            materialGrade: String, generatedAt: Date) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let margin: CGFloat = 48
        let contentWidth = pageRect.width - margin * 2
        let bottomLimit = pageRect.height - 56

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Schweißprotokoll \(projectName)",
            kCGPDFContextCreator as String: "MetalCraft Pro"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        func attributes(_ size: CGFloat, _ weight: UIFont.Weight, _ color: UIColor) -> [NSAttributedString.Key: Any] {
            [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        }

        func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> CGFloat {
            let string = NSAttributedString(string: text, attributes: attributes(size, weight, color))
            string.draw(at: point)
            return string.size().height
        }

        func drawWrapped(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
                         size: CGFloat, weight: UIFont.Weight, color: UIColor) -> CGFloat {
            let bounds = CGRect(x: x, y: y, width: width, height: 400)
            let string = NSAttributedString(string: text, attributes: attributes(size, weight, color))
            string.draw(in: bounds)
            return string.size().height
        }

        return renderer.pdfData { context in
            var y: CGFloat = margin

            func newPage() {
                context.beginPage()
                y = margin
            }
            func ensure(_ height: CGFloat) {
                if y + height > bottomLimit { newPage() }
            }

            context.beginPage()
            y += draw("Schweißprotokoll", at: CGPoint(x: margin, y: y), size: 24, weight: .bold, color: .black) + 6
            y += drawWrapped("\(projectName) · \(projectNumber) · Werkstoff \(materialGrade.isEmpty ? "–" : materialGrade)",
                             x: margin, y: y, width: contentWidth, size: 12, weight: .regular, color: .darkGray) + 4
            y += drawWrapped("Erzeugt am \(generatedAt.formatted(date: .long, time: .shortened)) · lokal in MetalCraft Pro",
                             x: margin, y: y, width: contentWidth, size: 10, weight: .regular, color: .gray) + 14
            drawLine(x: margin, y: y, width: contentWidth)
            y += 14

            if entries.isEmpty {
                y += drawWrapped("Keine Nähte dokumentiert.", x: margin, y: y, width: contentWidth,
                                 size: 12, weight: .regular, color: .darkGray)
            }
            for entry in entries {
                ensure(60)
                y += draw(entry.partLabel, at: CGPoint(x: margin, y: y), size: 15, weight: .semibold, color: .black) + 10
                for record in entry.records {
                    ensure(120)
                    y += draw("\(record.label.isEmpty ? "Naht" : record.label) · \(record.methodLabel)",
                              at: CGPoint(x: margin, y: y), size: 12, weight: .semibold, color: .black) + 8
                    for (label, value) in record.parameterRows {
                        ensure(22)
                        _ = draw(label, at: CGPoint(x: margin, y: y), size: 10, weight: .regular, color: .gray)
                        _ = drawWrapped(value.isEmpty ? "–" : value, x: margin + 130, y: y,
                                        width: contentWidth - 130, size: 10, weight: .medium, color: .black)
                        y += 16
                    }
                    y += 8
                }
                y += 6
            }
            ensure(24)
            _ = draw("Alle Angaben lokal im Projekt gespeichert.", at: CGPoint(x: margin, y: y),
                     size: 9, weight: .regular, color: .gray)
        }
    }

    private static func drawLine(x: CGFloat, y: CGFloat, width: CGFloat) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + width, y: y))
        UIColor(white: 0.8, alpha: 1).setStroke()
        path.lineWidth = 0.6
        path.stroke()
    }

    /// Schreibt das Protokoll in den temporären Ordner und liefert die Datei zum Teilen.
    public static func write(entries: [WeldProtocolEntry], projectName: String, projectNumber: String,
                             materialGrade: String, generatedAt: Date) throws -> URL {
        let data = data(entries: entries, projectName: projectName, projectNumber: projectNumber,
                        materialGrade: materialGrade, generatedAt: generatedAt)
        let safeName = projectName.isEmpty ? "Schweißprotokoll" : projectName
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Schweißprotokoll-\(safeName)-\(UUID().uuidString).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }
}
