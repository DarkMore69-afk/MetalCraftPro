//
//  ExportEngine.swift
//  MetalCraftPro
//
//  Export & technische Zeichnungen: Das Blatt wird als reine Wertstruktur
//  (Millimeter, deterministisch) aus dem parametrischen Modell aufgebaut und von
//  getrennten Renderern nach PDF, SVG, DXF, PNG und JPEG überführt. Montage-PDF,
//  Schweißprotokoll (bestehende Engine), CSV-Listen und STL nutzen dieselbe
//  Schnappschuss-Bridge. Formate, die (noch) nicht vollständig möglich sind
//  (STEP), sind gekapselt und werden in der UI klar als „In Entwicklung"
//  gekennzeichnet statt als toter Button zu erscheinen.
//

import Foundation
import UIKit

// MARK: - Blatt-Primitive (Millimeter, Blattkoordinaten, y zeigt nach unten)

public enum SheetPrimitive: Equatable, Sendable {
    case line(start: Vec2, end: Vec2)
    /// Hilfslinie: gestrichelt, dünner.
    case dashed(start: Vec2, end: Vec2)
    case polyline(points: [Vec2])
    case circle(center: Vec2, radius: Double)
    /// Bogen im Blatraumsystem: 0° = +x, positive Winkel Richtung +y (Blatt unten).
    case arc(center: Vec2, radius: Double, startDeg: Double, sweepDeg: Double)
    case text(position: Vec2, content: String, heightMm: Double)
}

// MARK: - Technisches Blatt

public struct TechnicalSheet: Equatable, Sendable {
    public enum Format: String, Sendable, CaseIterable {
        case a4 = "A4"
        case a3 = "A3"
        public var sizeMm: Vec2 {
            switch self {
            case .a4: return Vec2(x: 297, y: 210)
            case .a3: return Vec2(x: 420, y: 297)
            }
        }
    }

    public struct ViewBlock: Equatable, Sendable, Identifiable {
        public var title: String
        public var scaleLabel: String
        public var primitives: [SheetPrimitive]
        public var id: String { title }
    }

    public struct Table: Equatable, Sendable {
        public var title: String
        public var header: [String]
        public var rows: [[String]]
        public var columnWidths: [Double]
        public var overflowNote: String

        public init(title: String, header: [String], rows: [[String]],
                    columnWidths: [Double], overflowNote: String = "") {
            self.title = title; self.header = header; self.rows = rows
            self.columnWidths = columnWidths; self.overflowNote = overflowNote
        }
    }

    public struct TitleRow: Equatable, Sendable {
        public var label: String
        public var value: String
        public init(label: String, value: String) {
            self.label = label; self.value = value
        }
    }

    public var format: Format
    public var views: [ViewBlock]
    public var partsList: Table
    public var titleBlock: [TitleRow]
    public var mainScaleLabel: String

    public init(format: Format, views: [ViewBlock], partsList: Table,
                titleBlock: [TitleRow], mainScaleLabel: String) {
        self.format = format; self.views = views; self.partsList = partsList
        self.titleBlock = titleBlock; self.mainScaleLabel = mainScaleLabel
    }
}

// MARK: - Eingabeschnappschuss

public struct ExportPartInput: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var positionNumber: Int
    public var quantity: Int
    public var lengthMm: Double
    public var role: String?
    public var profile: ProfileSpec
    public var isReference: Bool

    public init(id: UUID, name: String, positionNumber: Int, quantity: Int, lengthMm: Double,
                role: String?, profile: ProfileSpec, isReference: Bool) {
        self.id = id; self.name = name; self.positionNumber = positionNumber
        self.quantity = quantity; self.lengthMm = lengthMm; self.role = role
        self.profile = profile; self.isReference = isReference
    }
}

public struct ExportInput: Sendable {
    public var projectName: String
    public var projectNumber: String
    public var materialGrade: String
    public var revisionLabel: String
    public var widthMm: Double
    public var heightMm: Double
    public var profile: ProfileSpec
    public var parts: [ExportPartInput]
    public var drawing: CADDrawing
    public var approved: Bool
    public var generatedAt: Date

    public init(projectName: String, projectNumber: String, materialGrade: String,
                revisionLabel: String, widthMm: Double, heightMm: Double, profile: ProfileSpec,
                parts: [ExportPartInput], drawing: CADDrawing, approved: Bool, generatedAt: Date) {
        self.projectName = projectName; self.projectNumber = projectNumber
        self.materialGrade = materialGrade; self.revisionLabel = revisionLabel
        self.widthMm = widthMm; self.heightMm = heightMm; self.profile = profile
        self.parts = parts; self.drawing = drawing; self.approved = approved
        self.generatedAt = generatedAt
    }
}

// MARK: - Zeichnungs-Builder

public enum TechnicalDrawingBuilder {

    /// Einheitliche Schnappschuss-Zeichnung: Rahmenansichten aus den Projektparametern,
    /// CAD-Elemente als Überlagerung, Schnitte und Details aus dem Profilquerschnitt.
    public static func sheet(for input: ExportInput, format: TechnicalSheet.Format) throws -> TechnicalSheet {
        let frame = try FrameParameters(width: input.widthMm, height: input.heightMm, profile: input.profile)
        let w = frame.width, h = frame.height, t = frame.profile.widthMm

        // Blattraster
        let sheetSize = format.sizeMm
        let margin = 10.0
        let contentW = sheetSize.x - margin * 2
        let contentH = sheetSize.y - margin * 2
        let bandH = 62.0
        let titleBlockW = 96.0
        let viewsX = margin, viewsY = margin
        let viewsW = contentW - titleBlockW - 4
        let viewsH = contentH - bandH - 4

        struct Slot {
            var minX: Double, minY: Double, maxX: Double, maxY: Double
            var w: Double { maxX - minX }
            var h: Double { maxY - minY }
            var usableW: Double { w - 6 }
            var usableH: Double { h - 6 }
        }
        let front = Slot(minX: 0, minY: 0, maxX: 0.56 * viewsW, maxY: 0.70 * viewsH)
        let side = Slot(minX: 0.58 * viewsW, minY: 0, maxX: 0.72 * viewsW, maxY: 0.70 * viewsH)
        let top = Slot(minX: 0, minY: 0.72 * viewsH, maxX: 0.56 * viewsW, maxY: viewsH)
        let section = Slot(minX: 0.74 * viewsW, minY: 0, maxX: viewsW, maxY: 0.48 * viewsH)
        let detail = Slot(minX: 0.74 * viewsW, minY: 0.52 * viewsH, maxX: viewsW, maxY: viewsH)

        // CAD-Inhalt (kann über den Rahmen hinausragen) in den Ansichts-Umfang einbeziehen
        var contentMin = Vec2(x: 0, y: 0)
        var contentMax = Vec2(x: w, y: h)
        for element in input.drawing.elements {
            for point in element.keyPoints {
                contentMin = Vec2(x: min(contentMin.x, point.x), y: min(contentMin.y, point.y))
                contentMax = Vec2(x: max(contentMax.x, point.x), y: max(contentMax.y, point.y))
            }
        }
        let contentWModel = max(1, contentMax.x - contentMin.x)
        let contentHModel = max(1, contentMax.y - contentMin.y)

        // Hauptmaßstab: Vorder-, Seiten- und Draufsicht teilen ihn (Bemaßung braucht 12 mm)
        let candidates: [Double] = [1, 2, 2.5, 4, 5, 8, 10, 12, 15, 20, 25, 40, 50, 100, 200, 500]
        var mainScale = 1 / max(1, (1 / min(front.usableW / contentWModel,
                                            (front.usableH - 12) / contentHModel,
                                            side.usableH / contentHModel,
                                            top.usableW / contentWModel)).rounded(.up))
        for denominator in candidates {
            let candidate = 1 / denominator
            let fits = contentWModel * candidate <= front.usableW
                && contentHModel * candidate + 12 <= front.usableH
                && contentHModel * candidate <= side.usableH && t * candidate <= side.usableW
                && contentWModel * candidate <= top.usableW && t * candidate <= top.usableH
            if fits { mainScale = candidate; break }
        }
        let mainLabel = Self.scaleLabel(mainScale)

        func place(_ point: Vec2, origin: Vec2, baseY: Double, scale: Double) -> Vec2 {
            // Modell (y nach oben) → Blatt (y nach unten), zentriert im Slot
            Vec2(x: origin.x + (point.x - contentMin.x) * scale,
                 y: origin.y + (baseY - point.y) * scale)
        }

        func origin(for slot: Slot, modelW: Double, modelH: Double, scale: Double) -> Vec2 {
            Vec2(x: viewsX + slot.minX + (slot.w - modelW * scale) / 2,
                 y: viewsY + slot.minY + (slot.h - modelH * scale) / 2)
        }

        var views: [TechnicalSheet.ViewBlock] = []

        // Vorderansicht: Rahmenkonturen + CAD-Elemente + Positionskugeln + Bemaßung
        var frontPrims: [SheetPrimitive] = []
        let frontOrigin = origin(for: front, modelW: contentWModel, modelH: contentHModel, scale: mainScale)
        let baseY = contentMax.y

        func push(_ point: Vec2) -> Vec2 { place(point, origin: frontOrigin, baseY: baseY, scale: mainScale) }

        let outerCorners = [Vec2.zero, .init(x: w, y: 0), .init(x: w, y: h), .init(x: 0, y: h)]
        let innerCorners = [Vec2(x: t, y: t), .init(x: w - t, y: t), .init(x: w - t, y: h - t), .init(x: t, y: h - t)]
        frontPrims.append(.polyline(points: outerCorners.map(push) + [push(outerCorners[0])]))
        frontPrims.append(.polyline(points: innerCorners.map(push) + [push(innerCorners[0])]))

        for element in input.drawing.elements {
            switch element.kind {
            case .line:
                frontPrims.append(.line(start: push(element.a), end: push(element.b)))
            case .profile:
                let direction = element.b - element.a
                let length = max(1e-9, direction.magnitude)
                let unit = direction * (1 / length)
                let normal = Vec2(x: -unit.y, y: unit.x)
                let half = (element.profileWidthMm ?? t) / 2
                frontPrims.append(.line(start: push(element.a + normal * half), end: push(element.b + normal * half)))
                frontPrims.append(.line(start: push(element.a - normal * half), end: push(element.b - normal * half)))
            case .rectangle:
                frontPrims.append(.polyline(points: element.corners.map(push) + [push(element.corners[0])]))
            case .circle, .hole:
                if let radius = element.radius {
                    frontPrims.append(.circle(center: push(element.a), radius: radius * mainScale))
                }
            case .arc:
                if let radius = element.radius {
                    let start = atan2(element.b.y - element.a.y, element.b.x - element.a.x) * 180 / .pi
                    let end = atan2((element.c ?? element.b).y - element.a.y,
                                    (element.c ?? element.b).x - element.a.x) * 180 / .pi
                    let sweep = (try? Geometry2D.arcSweep(start: start, end: end)) ?? 0
                    if sweep > 0 {
                        frontPrims.append(.arc(center: push(element.a), radius: radius * mainScale,
                                               startDeg: Self.normalized(-(start + sweep)), sweepDeg: sweep))
                    }
                }
            case .construction:
                frontPrims.append(.dashed(start: push(element.a), end: push(element.b)))
            case .text:
                if let content = element.text, !content.isEmpty {
                    frontPrims.append(.text(position: push(element.a), content: content, heightMm: 3))
                }
            case .dimension:
                if let endpoints = element.dimensionEndpoints(frame: frame),
                   let value = element.dimensionValue(frame: frame) {
                    let from = push(endpoints.from), to = push(endpoints.to)
                    let linePoint = push(endpoints.linePoint)
                    // Senkrechte zur Maßlinie, Richtung zum Maßlinienpunkt
                    let direction = to - from
                    let length = max(1e-9, direction.magnitude)
                    let unit = direction * (1 / length)
                    var perp = linePoint - ((from + to) * 0.5)
                    perp = perp - unit * perp.dot(unit)
                    let magnitude = perp.magnitude
                    guard magnitude > 1e-6 else { break }
                    perp = perp * (1 / magnitude)
                    frontPrims.append(contentsOf: Self.dimension(from: from, to: to, perp: perp,
                                                                 label: DeFormat.number(value, maxFractionDigits: 2)))
                }
            case .angle: break // Winkelmaße bleiben im CAD-Editor, nicht auf dem Blatt
            }
        }

        // Positionsnummern aus den Platzierungen des parametrischen Modells
        if let placements = try? ThreeDModelBuilder.placements(for: ThreeDInput(
            widthMm: input.widthMm, heightMm: input.heightMm, profile: input.profile,
            parts: input.parts.map { part in
                ThreeDPartInput(id: part.id, name: part.name, positionNumber: part.positionNumber,
                                quantity: part.quantity, role: part.role, profile: part.profile)
            })) {
            let modelCenter = Vec2(x: w / 2, y: h / 2)
            var seen = Set<UUID>()
            for instance in placements where !seen.contains(instance.partID) {
                seen.insert(instance.partID)
                let point = push(Vec2(x: instance.start.x, y: instance.start.y))
                var direction = Vec2(x: instance.start.x - modelCenter.x, y: instance.start.y - modelCenter.y)
                let magnitude = direction.magnitude
                direction = magnitude > 1e-9 ? direction * (1 / magnitude) : Vec2(x: 0, y: -1)
                // Modellrichtung (y nach oben) → Blattrichtung (y nach unten)
                direction = Vec2(x: direction.x, y: -direction.y)
                frontPrims.append(contentsOf: Self.balloon(at: point, number: instance.positionNumber,
                                                           direction: direction))
            }
        }

        // Gesamt-Bemaßung: Breite unten, Höhe links
        let bottomLeft = push(.zero), bottomRight = push(Vec2(x: w, y: 0))
        frontPrims.append(contentsOf: Self.dimension(from: bottomLeft, to: bottomRight, perp: Vec2(x: 0, y: 10),
                                                     label: DeFormat.number(w, maxFractionDigits: 0)))
        let topLeft = push(Vec2(x: 0, y: h))
        frontPrims.append(contentsOf: Self.dimension(from: bottomLeft, to: topLeft, perp: Vec2(x: -10, y: 0),
                                                     label: DeFormat.number(h, maxFractionDigits: 0)))
        views.append(TechnicalSheet.ViewBlock(title: "Vorderansicht", scaleLabel: mainLabel, primitives: frontPrims))

        // Seitenansicht: Profilbreite (Tiefe) × Höhe
        let sideOrigin = origin(for: side, modelW: t, modelH: contentHModel, scale: mainScale)
        var sidePrims: [SheetPrimitive] = []
        func pushSide(_ point: Vec2) -> Vec2 {
            Vec2(x: sideOrigin.x + point.x * mainScale, y: sideOrigin.y + (contentMax.y - point.y) * mainScale)
        }
        let sideOuter = [Vec2.zero, .init(x: t, y: 0), .init(x: t, y: h), .init(x: 0, y: h)]
        sidePrims.append(.polyline(points: sideOuter.map(pushSide) + [pushSide(sideOuter[0])]))
        sidePrims.append(.line(start: pushSide(Vec2(x: 0, y: t)), end: pushSide(Vec2(x: t, y: t))))
        sidePrims.append(.line(start: pushSide(Vec2(x: 0, y: h - t)), end: pushSide(Vec2(x: t, y: h - t))))
        views.append(TechnicalSheet.ViewBlock(title: "Seitenansicht", scaleLabel: mainLabel, primitives: sidePrims))

        // Draufsicht: Breite × Profilbreite
        let topOrigin = origin(for: top, modelW: contentWModel, modelH: t, scale: mainScale)
        var topPrims: [SheetPrimitive] = []
        func pushTop(_ point: Vec2) -> Vec2 {
            Vec2(x: topOrigin.x + (point.x - contentMin.x) * mainScale, y: topOrigin.y + (t - point.y) * mainScale)
        }
        let topOuter = [Vec2.zero, .init(x: w, y: 0), .init(x: w, y: t), .init(x: 0, y: t)]
        topPrims.append(.polyline(points: topOuter.map(pushTop) + [pushTop(topOuter[0])]))
        topPrims.append(.line(start: pushTop(Vec2(x: t, y: 0)), end: pushTop(Vec2(x: t, y: t))))
        topPrims.append(.line(start: pushTop(Vec2(x: w - t, y: 0)), end: pushTop(Vec2(x: w - t, y: t))))
        views.append(TechnicalSheet.ViewBlock(title: "Draufsicht", scaleLabel: mainLabel, primitives: topPrims))

        // Schnitt A-A: Profilquerschnitt mit Schraffur, eigener Maßstab
        let cross = try ProfileSection.crossSection(for: input.profile)
        var sectionBoxLow = Vec2(x: .infinity, y: .infinity), sectionBoxHigh = Vec2(x: -.infinity, y: -.infinity)
        for loop in [cross.outer] + cross.holes {
            for point in loop {
                sectionBoxLow = Vec2(x: min(sectionBoxLow.x, point.x), y: min(sectionBoxLow.y, point.y))
                sectionBoxHigh = Vec2(x: max(sectionBoxHigh.x, point.x), y: max(sectionBoxHigh.y, point.y))
            }
        }
        let sectionW = max(1e-9, sectionBoxHigh.x - sectionBoxLow.x)
        let sectionH = max(1e-9, sectionBoxHigh.y - sectionBoxLow.y)
        let sectionScalePair = Self.enlargeScale(fitting: min(section.usableW / sectionW, section.usableH / sectionH))
        let sectionScale = sectionScalePair.scale
        let sectionMid = Vec2(x: viewsX + section.minX + section.w / 2, y: viewsY + section.minY + section.h / 2)
        var sectionPrims: [SheetPrimitive] = []
        func pushSection(_ point: Vec2) -> Vec2 {
            Vec2(x: sectionMid.x + point.x * sectionScale, y: sectionMid.y - point.y * sectionScale)
        }
        sectionPrims.append(.polyline(points: cross.outer.map(pushSection) + [pushSection(cross.outer[0])]))
        for hole in cross.holes {
            sectionPrims.append(.polyline(points: hole.map(pushSection) + [pushSection(hole[0])]))
        }
        for line in Self.hatch(polygon: cross.outer.map(pushSection), spacing: 2.5) {
            sectionPrims.append(line)
        }
        views.append(TechnicalSheet.ViewBlock(title: "Schnitt A-A · \(input.profile.dimensionLabel)",
                                              scaleLabel: sectionScalePair.label, primitives: sectionPrims))

        // Detail Z: erste Bohrung bzw. erster Kreis im CAD, vergrößert
        if let hole = input.drawing.elements.first(where: { $0.kind == .hole }) ?? input.drawing.elements.first(where: { $0.kind == .circle }),
           let radius = hole.radius, radius > 0 {
            let detailFit = min(detail.usableW, detail.usableH) / (radius * 4.5)
            let detailPair = Self.enlargeScale(fitting: max(1, detailFit))
            let detailScale = detailPair.scale
            let center = push(Vec2(x: hole.a.x, y: hole.a.y))
            let detailMid = Vec2(x: viewsX + detail.minX + detail.w / 2, y: viewsY + detail.minY + detail.h / 2)
            var detailPrims: [SheetPrimitive] = []
            let radiusSheet = radius * detailScale
            detailPrims.append(.circle(center: detailMid, radius: radiusSheet))
            detailPrims.append(.dashed(start: Vec2(x: detailMid.x - radiusSheet * 1.7, y: detailMid.y),
                                       end: Vec2(x: detailMid.x + radiusSheet * 1.7, y: detailMid.y)))
            detailPrims.append(.dashed(start: Vec2(x: detailMid.x, y: detailMid.y - radiusSheet * 1.7),
                                       end: Vec2(x: detailMid.x, y: detailMid.y + radiusSheet * 1.7)))
            _ = center
            views.append(TechnicalSheet.ViewBlock(
                title: "Detail Z · Ø\(DeFormat.number(radius * 2, maxFractionDigits: 1))",
                scaleLabel: detailPair.label, primitives: detailPrims))
        }

        // Stückliste
        var rows: [[String]] = []
        for part in input.parts.sorted(by: { $0.positionNumber < $1.positionNumber }) {
            rows.append([
                "\(part.positionNumber)", part.name,
                part.isReference ? "Zukaufteil" : part.profile.dimensionLabel,
                part.isReference ? "–" : input.materialGrade.isEmpty ? "–" : input.materialGrade,
                "\(max(1, part.quantity))",
                part.isReference || part.lengthMm <= 0 ? "–" : DeFormat.number(part.lengthMm, maxFractionDigits: 1)
            ])
        }
        let partsList = TechnicalSheet.Table(
            title: "Stückliste",
            header: ["Pos", "Bezeichnung", "Profil", "Werkstoff", "Stk", "Länge mm"],
            rows: rows, columnWidths: [10, 1.9, 1.3, 0.9, 0.6, 1.1],
            overflowNote: "Weitere Positionen siehe Materialliste")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy"
        let titleBlock: [TechnicalSheet.TitleRow] = [
            .init(label: "Projekt", value: input.projectName),
            .init(label: "Zeichnungsnummer", value: input.projectNumber.isEmpty ? "–" : "\(input.projectNumber)-Z01"),
            .init(label: "Maßstab", value: mainLabel), .init(label: "Revision", value: input.revisionLabel),
            .init(label: "Datum", value: formatter.string(from: input.generatedAt)),
            .init(label: "Werkstoff", value: input.materialGrade.isEmpty ? "–" : input.materialGrade),
            .init(label: "Blatt", value: "1 / 1 · \(format.rawValue)"),
            .init(label: "Freigabe", value: input.approved ? "Geometrie freigegeben" : "nicht freigegeben")
        ]

        return TechnicalSheet(format: format, views: views, partsList: partsList,
                              titleBlock: titleBlock, mainScaleLabel: mainLabel)
    }

    // MARK: Hilfsfunktionen

    static func scaleLabel(_ scale: Double) -> String {
        if scale >= 0.999 {
            let magnification = (scale).rounded()
            return magnification >= 2 ? "\(Int(magnification)):1" : "1:1"
        }
        let denominator = (1 / scale).rounded()
        let value = denominator >= 9.5 ? "\(Int(denominator))" : DeFormat.number(denominator, maxFractionDigits: 1)
        return "1:\(value)"
    }

    static func enlargeScale(fitting fit: Double) -> (scale: Double, label: String) {
        for magnification in [10.0, 5.0, 2.0] where magnification <= fit {
            return (magnification, "\(Int(magnification)):1")
        }
        let candidates: [Double] = [1, 2, 2.5, 4, 5, 8, 10, 12, 15, 20, 25, 40, 50, 100]
        for denominator in candidates {
            let scale = 1 / denominator
            if scale <= fit { return (scale, scaleLabel(scale)) }
        }
        return (fit, scaleLabel(fit))
    }

    static func normalized(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    /// Bemaßung in Blattkoordinaten: Maßlinie mit Pfeilen, Maßhilfslinien und Wert.
    static func dimension(from: Vec2, to: Vec2, perp: Vec2, label: String) -> [SheetPrimitive] {
        var result: [SheetPrimitive] = []
        let direction = to - from
        let length = max(1e-9, direction.magnitude)
        let unit = direction * (1 / length)
        let perpUnit = perp.magnitude > 1e-9 ? perp * (1 / perp.magnitude) : Vec2(x: 0, y: 1)
        let offset = perp.magnitude
        let a = from + perp, b = to + perp
        result.append(.line(start: from + perpUnit * 1.5, end: from + perp * 1 + unit * 2))
        result.append(.line(start: to + perpUnit * 1.5, end: to + perp * 1 - unit * 2))
        result.append(.line(start: a, end: b))
        func arrow(_ tip: Vec2, inward: Bool) {
            let sign: Double = inward ? 1 : -1
            result.append(.line(start: tip, end: tip + unit * (sign * 2.6) + perpUnit * 0.8))
            result.append(.line(start: tip, end: tip + unit * (sign * 2.6) - perpUnit * 0.8))
        }
        arrow(a, inward: false)
        arrow(b, inward: true)
        let middle = (a + b) * 0.5 + perpUnit * 2.2
        let width = 0.62 * 3.2 * Double(label.count)
        result.append(.text(position: Vec2(x: middle.x - width / 2, y: middle.y - 3.2), content: label, heightMm: 3.2))
        _ = offset
        return result
    }

    /// Positionsnummer: Führungslinie, Kreis und Nummer.
    static func balloon(at point: Vec2, number: Int, direction: Vec2) -> [SheetPrimitive] {
        let center = point + direction * 13
        var result: [SheetPrimitive] = [.line(start: point, end: center),
                                        .circle(center: center, radius: 4.5)]
        let label = "\(number)"
        let width = 0.62 * 3 * Double(label.count)
        result.append(.text(position: Vec2(x: center.x - width / 2, y: center.y - 1.6), content: label, heightMm: 3))
        return result
    }

    /// Schraffur: 45°-Linien (Richtung 1,1) über Even-Odd-Schnitte mit dem Polygon.
    static func hatch(polygon: [Vec2], spacing: Double) -> [SheetPrimitive] {
        guard polygon.count > 2 else { return [] }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for point in polygon {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        var result: [SheetPrimitive] = []
        var d = minX - maxY
        let dMax = maxX - minY
        while d <= dMax {
            var crossings: [Double] = []
            for index in polygon.indices {
                let p = polygon[index], q = polygon[(index + 1) % polygon.count]
                let dp = p.x - p.y, dq = q.x - q.y
                if dp == dq { continue }
                let t = (d - dp) / (dq - dp)
                if t >= 0, t <= 1 {
                    let point = p + (q - p) * t
                    crossings.append(point.x)
                }
            }
            crossings.sort()
            if crossings.count % 2 == 0 {
                for index in stride(from: 0, to: crossings.count - 1, by: 2) {
                    let x1 = crossings[index], x2 = crossings[index + 1]
                    if x2 - x1 > 1e-6 {
                        result.append(.line(start: Vec2(x: x1, y: x1 - d), end: Vec2(x: x2, y: x2 - d)))
                    }
                }
            }
            d += spacing
        }
        return result
    }
}

// MARK: - Renderer: PDF, PNG/JPEG

public enum SheetRenderer {
    /// Zeichnet das Blatt in den aktuellen UIKit-Kontext (Millimeter → Punkte).
    public static func draw(_ sheet: TechnicalSheet, mm: CGFloat) {
        let black = UIColor.black
        black.setStroke(); black.setFill()

        func stroke(_ path: UIBezierPath, width: CGFloat = 0.3) {
            path.lineWidth = width; path.stroke()
        }
        func point(_ v: Vec2) -> CGPoint { CGPoint(x: CGFloat(v.x) * mm, y: CGFloat(v.y) * mm) }

        func drawPrimitives(_ primitives: [SheetPrimitive]) {
            for primitive in primitives {
                switch primitive {
                case .line(let a, let b):
                    let path = UIBezierPath(); path.move(to: point(a)); path.addLine(to: point(b))
                    stroke(path)
                case .dashed(let a, let b):
                    let path = UIBezierPath(); path.move(to: point(a)); path.addLine(to: point(b))
                    path.setLineDash([1.5 * mm, 1.1 * mm], count: 2, phase: 0)
                    stroke(path, width: 0.2)
                    path.setLineDash([], count: 0, phase: 0)
                case .polyline(let points):
                    guard points.count > 1 else { continue }
                    let path = UIBezierPath(); path.move(to: point(points[0]))
                    for p in points.dropFirst() { path.addLine(to: point(p)) }
                    stroke(path)
                case .circle(let center, let radius):
                    let path = UIBezierPath()
                    path.addArc(withCenter: point(center), radius: CGFloat(radius) * mm,
                                startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                    stroke(path)
                case .arc(let center, let radius, let startDeg, let sweepDeg):
                    let path = UIBezierPath()
                    path.addArc(withCenter: point(center), radius: CGFloat(radius) * mm,
                                startAngle: CGFloat(startDeg) * .pi / 180,
                                endAngle: CGFloat(startDeg + sweepDeg) * .pi / 180, clockwise: true)
                    stroke(path)
                case .text(let position, let content, let heightMm):
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: CGFloat(heightMm) * mm),
                        .foregroundColor: black
                    ]
                    NSAttributedString(string: content, attributes: attributes).draw(at: point(position))
                }
            }
        }

        // Rahmen: Außenlinie 5 mm, Innenlinie 10 mm
        let size = sheet.format.sizeMm
        func rect(_ inset: Double, width: CGFloat) {
            let path = UIBezierPath(rect: CGRect(x: CGFloat(inset) * mm, y: CGFloat(inset) * mm,
                                                 width: CGFloat(size.x - inset * 2) * mm,
                                                 height: CGFloat(size.y - inset * 2) * mm))
            stroke(path, width: width)
        }
        rect(5, width: 0.5)
        rect(10, width: 0.8)

        let margin = 10.0
        let contentX = margin, contentY = margin
        let contentW = size.x - margin * 2
        let contentH = size.y - margin * 2
        let bandH = 62.0
        let titleBlockW = 96.0

        for viewBlock in sheet.views { drawPrimitives(viewBlock.primitives) }

        // Ansichtsbeschriftungen liegen in den Primitives nicht — Titel unter jedem Slot
        // entfällt bewusst: Die Titel stehen in den ViewBlocks und werden hier gezeichnet.
        var labelY = contentY
        // Ansichtstitel: unter dem jeweiligen Slot (gleiche Aufteilung wie im Builder)
        let viewsW = contentW - titleBlockW - 4
        let viewsH = contentH - bandH - 4
        let slots: [(Double, Double, Double, Double)] = [
            (0, 0, 0.56, 0.70), (0.58, 0, 0.14, 0.70), (0, 0.72, 0.56, 0.28),
            (0.74, 0, 0.26, 0.48), (0.74, 0.52, 0.26, 0.48)
        ]
        for (index, slot) in slots.enumerated() where index < sheet.views.count {
            labelY = contentY + (slot.1 + slot.3) * viewsH + 2.5
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 3.2 * mm, weight: .medium), .foregroundColor: black
            ]
            let title = "\(sheet.views[index].title)  \(sheet.views[index].scaleLabel)"
            NSAttributedString(string: title, attributes: attributes).draw(at: CGPoint(x: CGFloat(contentX + slot.0 * viewsW) * mm, y: CGFloat(labelY) * mm))
        }

        // Stückliste
        let tableW = contentW - titleBlockW - 4
        let tableX = contentX
        let tableTop = contentY + contentH - bandH
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 3 * mm, weight: .semibold), .foregroundColor: black
        ]
        NSAttributedString(string: sheet.partsList.title, attributes: titleAttributes)
            .draw(at: CGPoint(x: CGFloat(tableX) * mm, y: CGFloat(tableTop) * mm))
        let widths = sheet.partsList.columnWidths
        let widthSum = widths.reduce(0, +)
        let columns = widths.map { $0 / widthSum * tableW }
        var y = tableTop + 4.5
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 2.4 * mm, weight: .medium), .foregroundColor: black
        ]
        let cellAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 2.4 * mm), .foregroundColor: black
        ]
        func rowLine(_ y: Double, width: CGFloat = 0.2) {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: CGFloat(tableX) * mm, y: CGFloat(y) * mm))
            path.addLine(to: CGPoint(x: CGFloat(tableX + tableW) * mm, y: CGFloat(y) * mm))
            stroke(path, width: width)
        }
        rowLine(y - 1)
        for (column, header) in sheet.partsList.header.enumerated() {
            let x = tableX + columns.prefix(column).reduce(0, +)
            NSAttributedString(string: header, attributes: headerAttributes)
                .draw(at: CGPoint(x: CGFloat(x + 0.8) * mm, y: CGFloat(y) * mm))
        }
        y += 5
        var shown = 0
        for row in sheet.partsList.rows {
            guard y + 5.5 < contentY + contentH - 1 else { break }
            for (column, cell) in row.enumerated() where column < columns.count {
                let x = tableX + columns.prefix(column).reduce(0, +)
                NSAttributedString(string: cell, attributes: cellAttributes)
                    .draw(at: CGPoint(x: CGFloat(x + 0.8) * mm, y: CGFloat(y) * mm))
            }
            y += 5.2
            rowLine(y - 0.6)
            shown += 1
        }
        if shown < sheet.partsList.rows.count, !sheet.partsList.overflowNote.isEmpty {
            NSAttributedString(string: sheet.partsList.overflowNote, attributes: cellAttributes)
                .draw(at: CGPoint(x: CGFloat(tableX + 0.8) * mm, y: CGFloat(y) * mm))
        }

        // Schriftfeld
        let blockX = contentX + contentW - titleBlockW
        let blockY = contentY + contentH - bandH
        let blockPath = UIBezierPath(rect: CGRect(x: CGFloat(blockX) * mm, y: CGFloat(blockY) * mm,
                                                  width: CGFloat(titleBlockW) * mm, height: CGFloat(bandH) * mm))
        stroke(blockPath, width: 0.5)
        let rowCount = sheet.titleBlock.count
        let rowHeight = bandH / Double(max(1, rowCount))
        let labelFont = UIFont.systemFont(ofSize: 2.2 * mm)
        let valueFont = UIFont.systemFont(ofSize: 2.7 * mm, weight: .medium)
        for (index, entry) in sheet.titleBlock.enumerated() {
            let rowY = blockY + Double(index) * rowHeight
            if index > 0 {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: CGFloat(blockX) * mm, y: CGFloat(rowY) * mm))
                path.addLine(to: CGPoint(x: CGFloat(blockX + titleBlockW) * mm, y: CGFloat(rowY) * mm))
                stroke(path, width: 0.2)
            }
            NSAttributedString(string: entry.label, attributes: [.font: labelFont, .foregroundColor: black])
                .draw(at: CGPoint(x: CGFloat(blockX + 1.2) * mm, y: CGFloat(rowY + 0.9) * mm))
            NSAttributedString(string: entry.value, attributes: [.font: valueFont, .foregroundColor: black])
                .draw(at: CGPoint(x: CGFloat(blockX + 22) * mm, y: CGFloat(rowY + 0.6) * mm))
        }
    }
}

public enum SheetPDF {
    /// DIN-A4/A3-Blatt als PDF (Punkte = Millimeter × 72/25,4).
    public static func data(_ sheet: TechnicalSheet) -> Data {
        let mm = CGFloat(72.0 / 25.4)
        let size = sheet.format.sizeMm
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(size.x) * mm, height: CGFloat(size.y) * mm)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Zeichnung \(sheet.titleBlock.first?.value ?? "")",
            kCGPDFContextCreator as String: "MetalCraft Pro"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        return renderer.pdfData { context in
            context.beginPage()
            SheetRenderer.draw(sheet, mm: mm)
        }
    }

    public static func write(_ sheet: TechnicalSheet, projectName: String) throws -> URL {
        let safe = projectName.isEmpty ? "Zeichnung" : projectName
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Zeichnung-\(safe)-\(UUID().uuidString).pdf")
        try data(sheet).write(to: url, options: .atomic)
        return url
    }
}

public enum SheetImage {
    public static func png(_ sheet: TechnicalSheet, dpi: Int = 200) -> Data {
        render(sheet, dpi: dpi).pngData() ?? Data()
    }

    public static func jpeg(_ sheet: TechnicalSheet, dpi: Int = 200, quality: CGFloat = 0.92) -> Data {
        render(sheet, dpi: dpi).jpegData(compressionQuality: quality) ?? Data()
    }

    private static func render(_ sheet: TechnicalSheet, dpi: Int) -> UIImage {
        let mm = CGFloat(72.0 / 25.4)
        let size = sheet.format.sizeMm
        let format = UIGraphicsImageRendererFormat()
        format.scale = CGFloat(dpi) / 72
        let renderer = UIGraphicsImageRenderer(bounds: CGRect(x: 0, y: 0, width: CGFloat(size.x) * mm,
                                                              height: CGFloat(size.y) * mm), format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(size.x) * mm, height: CGFloat(size.y) * mm))
            SheetRenderer.draw(sheet, mm: mm)
        }
    }
}

// MARK: - Renderer: SVG

public enum SheetSVG {
    /// Vektor-Export: Linien, Polylinien, Kreise, Bögen und Text in Millimetern.
    public static func render(_ sheet: TechnicalSheet) -> String {
        let size = sheet.format.sizeMm
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(dot(size.x))mm\" height=\"\(dot(size.y))mm\" viewBox=\"0 0 \(dot(size.x)) \(dot(size.y))\">\n"
        out += "<rect x=\"0\" y=\"0\" width=\"\(dot(size.x))\" height=\"\(dot(size.y))\" fill=\"white\"/>\n"
        func attributes(dashed: Bool) -> String {
            dashed ? " stroke=\"black\" stroke-width=\"0.2\" stroke-dasharray=\"1.5,1.1\" fill=\"none\""
                   : " stroke=\"black\" stroke-width=\"0.25\" fill=\"none\""
        }
        for viewBlock in sheet.views {
            for primitive in viewBlock.primitives {
                switch primitive {
                case .line(let a, let b):
                    out += "<line x1=\"\(dot(a.x))\" y1=\"\(dot(a.y))\" x2=\"\(dot(b.x))\" y2=\"\(dot(b.y))\"\(attributes(dashed: false))/>\n"
                case .dashed(let a, let b):
                    out += "<line x1=\"\(dot(a.x))\" y1=\"\(dot(a.y))\" x2=\"\(dot(b.x))\" y2=\"\(dot(b.y))\"\(attributes(dashed: true))/>\n"
                case .polyline(let points):
                    guard points.count > 1 else { continue }
                    let coordinates = points.map { "\(dot($0.x)),\(dot($0.y))" }.joined(separator: " ")
                    out += "<polyline points=\"\(coordinates)\"\(attributes(dashed: false))/>\n"
                case .circle(let center, let radius):
                    out += "<circle cx=\"\(dot(center.x))\" cy=\"\(dot(center.y))\" r=\"\(dot(radius))\"\(attributes(dashed: false))/>\n"
                case .arc(let center, let radius, let startDeg, let sweepDeg):
                    let startRad = startDeg * .pi / 180, endRad = (startDeg + sweepDeg) * .pi / 180
                    let startPoint = Vec2(x: center.x + radius * cos(startRad), y: center.y + radius * sin(startRad))
                    let endPoint = Vec2(x: center.x + radius * cos(endRad), y: center.y + radius * sin(endRad))
                    let largeArc = abs(sweepDeg) > 180 ? 1 : 0
                    out += "<path d=\"M \(dot(startPoint.x)) \(dot(startPoint.y)) A \(dot(radius)) \(dot(radius)) 0 \(largeArc) 1 \(dot(endPoint.x)) \(dot(endPoint.y))\"\(attributes(dashed: false))/>\n"
                case .text(let position, let content, let heightMm):
                    out += "<text x=\"\(dot(position.x))\" y=\"\(dot(position.y + heightMm * 0.8))\" font-size=\"\(dot(heightMm))\" font-family=\"Helvetica\" fill=\"black\">\(escape(content))</text>\n"
                }
            }
            out += "<!-- \(escape(viewBlock.title)) · \(viewBlock.scaleLabel) -->\n"
        }
        out += "</svg>\n"
        return out
    }

    static func dot(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Renderer: DXF (ASCII R12)

public enum SheetDXF {
    /// 2D-Austausch mit LINE-, CIRCLE-, ARC- und TEXT-Entities in Millimetern.
    /// Volumenkörper sind im DXF-Export nicht enthalten (2D-Zeichnung).
    public static func render(_ sheet: TechnicalSheet) -> String {
        let size = sheet.format.sizeMm
        func y(_ value: Double) -> Double { size.y - value } // DXF: y nach oben
        var out = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n"
        out += "0\nSECTION\n2\nENTITIES\n"
        func number(_ value: Double) -> String { SheetSVG.dot(value) }
        func entity(_ kind: String, _ pairs: [(Int, String)], layer: String = "0") {
            out += "0\n\(kind)\n8\n\(layer)\n"
            for pair in pairs { out += "\(pair.0)\n\(pair.1)\n" }
        }
        for viewBlock in sheet.views {
            let layer = viewBlock.title.contains("Vorderansicht") ? "0" : "ANSICHT"
            for primitive in viewBlock.primitives {
                switch primitive {
                case .line(let a, let b):
                    entity("LINE", [(10, number(a.x)), (20, number(y(a.y))), (30, "0"),
                                    (11, number(b.x)), (21, number(y(b.y))), (31, "0")], layer: layer)
                case .dashed(let a, let b):
                    entity("LINE", [(10, number(a.x)), (20, number(y(a.y))), (30, "0"),
                                    (11, number(b.x)), (21, number(y(b.y))), (31, "0")], layer: "HILFSLINIEN")
                case .polyline(let points):
                    guard points.count > 1 else { continue }
                    out += "0\nPOLYLINE\n8\n\(layer)\n70\n1\n"
                    for point in points {
                        out += "0\nVERTEX\n8\n\(layer)\n10\n\(number(point.x))\n20\n\(number(y(point.y)))\n30\n0\n"
                    }
                    out += "0\nSEQEND\n"
                case .circle(let center, let radius):
                    entity("CIRCLE", [(10, number(center.x)), (20, number(y(center.y))), (30, "0"),
                                      (40, number(radius))], layer: layer)
                case .arc(let center, let radius, let startDeg, let sweepDeg):
                    let start = TechnicalDrawingBuilder.normalized(-(startDeg + sweepDeg))
                    let end = TechnicalDrawingBuilder.normalized(-startDeg)
                    entity("ARC", [(10, number(center.x)), (20, number(y(center.y))), (30, "0"),
                                   (40, number(radius)), (50, number(start)), (51, number(end))], layer: layer)
                case .text(let position, let content, let heightMm):
                    entity("TEXT", [(10, number(position.x)), (20, number(y(position.y + heightMm * 0.8))),
                                    (30, "0"), (40, number(heightMm)),
                                    (1, content.replacingOccurrences(of: "\n", with: " "))], layer: layer)
                }
            }
        }
        out += "0\nENDSEC\n0\nEOF\n"
        return out
    }
}

// MARK: - Montage-PDF

public struct MontageCheck: Sendable, Equatable {
    public var title: String
    public var targetMm: Double
    public var toleranceMm: Double
    public init(title: String, targetMm: Double, toleranceMm: Double) {
        self.title = title; self.targetMm = targetMm; self.toleranceMm = toleranceMm
    }
}

public struct MontageStepInput: Sendable, Equatable {
    public var index: Int
    public var title: String
    public var parts: String
    public var movement: String
    public var connection: String
    public var tool: String
    public var lengthMm: Double
    public var positionNote: String
    public var note: String
    public var check: MontageCheck?

    public init(index: Int, title: String, parts: String, movement: String, connection: String,
                tool: String, lengthMm: Double, positionNote: String, note: String, check: MontageCheck? = nil) {
        self.index = index; self.title = title; self.parts = parts; self.movement = movement
        self.connection = connection; self.tool = tool; self.lengthMm = lengthMm
        self.positionNote = positionNote; self.note = note; self.check = check
    }
}

public enum MontagePDF {
    /// Montageanleitung als DIN-A4-Dokument: ein Block je Schritt.
    public static func data(steps: [MontageStepInput], projectName: String, projectNumber: String,
                            generatedAt: Date) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let margin: CGFloat = 48
        let contentWidth = pageRect.width - margin * 2
        let bottomLimit = pageRect.height - 56
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "Montageanleitung \(projectName)",
                               kCGPDFContextCreator as String: "MetalCraft Pro"]
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
            let string = NSAttributedString(string: text, attributes: attributes(size, weight, color))
            string.draw(in: CGRect(x: x, y: y, width: width, height: 300))
            return string.size().height
        }
        func rule(x: CGFloat, y: CGFloat, width: CGFloat) {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x + width, y: y))
            UIColor(white: 0.8, alpha: 1).setStroke(); path.lineWidth = 0.6; path.stroke()
        }

        return renderer.pdfData { context in
            var y: CGFloat = margin
            func newPage() { context.beginPage(); y = margin }
            func ensure(_ height: CGFloat) { if y + height > bottomLimit { newPage() } }

            context.beginPage()
            y += draw("Montageanleitung", at: CGPoint(x: margin, y: y), size: 24, weight: .bold, color: .black) + 6
            y += drawWrapped("\(projectName) · \(projectNumber)", x: margin, y: y, width: contentWidth,
                             size: 12, weight: .regular, color: .darkGray) + 4
            y += drawWrapped("Erzeugt am \(generatedAt.formatted(date: .long, time: .shortened)) · lokal in MetalCraft Pro",
                             x: margin, y: y, width: contentWidth, size: 10, weight: .regular, color: .gray) + 14
            rule(x: margin, y: y, width: contentWidth)
            y += 14

            if steps.isEmpty {
                _ = drawWrapped("Keine Montageschritte vorhanden.", x: margin, y: y,
                                width: contentWidth, size: 12, weight: .regular, color: .darkGray)
            }
            for step in steps {
                ensure(140)
                y += draw("Schritt \(step.index) · \(step.title)", at: CGPoint(x: margin, y: y),
                          size: 14, weight: .semibold, color: .black) + 8
                let rows: [(String, String)] = [
                    ("Bauteile", step.parts.isEmpty ? "–" : step.parts),
                    ("Bewegung", step.movement), ("Verbindung", step.connection.isEmpty ? "–" : step.connection),
                    ("Werkzeug", step.tool.isEmpty ? "–" : step.tool),
                    ("Länge", step.lengthMm > 0 ? "\(DeFormat.number(step.lengthMm, maxFractionDigits: 1)) mm" : "–"),
                    ("Position", step.positionNote.isEmpty ? "–" : step.positionNote)
                ]
                for row in rows {
                    ensure(18)
                    _ = draw(row.0, at: CGPoint(x: margin, y: y), size: 10, weight: .regular, color: .gray)
                    _ = drawWrapped(row.1, x: margin + 110, y: y, width: contentWidth - 110,
                                    size: 10, weight: .medium, color: .black)
                    y += 15
                }
                if !step.note.isEmpty {
                    ensure(30)
                    y += drawWrapped("Hinweis: \(step.note)", x: margin, y: y, width: contentWidth,
                                     size: 10, weight: .regular, color: .darkGray) + 6
                }
                if let check = step.check {
                    ensure(30)
                    y += drawWrapped("Prüfung: \(check.title) · Sollwert \(DeFormat.number(check.targetMm, maxFractionDigits: 2)) mm · Toleranz ±\(DeFormat.number(check.toleranceMm)) mm",
                                     x: margin, y: y, width: contentWidth, size: 10, weight: .medium, color: .black) + 6
                }
                y += 6
                rule(x: margin, y: y, width: contentWidth)
                y += 10
            }
        }
    }
}

// MARK: - Baustellen-Aufmaß-PDF

public struct WorksiteSurveyPDFEntry: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var label: String
    public var value: Double
    public var unit: String
    public var partLabel: String?
    public var note: String?
    public var measuredAt: Date

    public init(id: UUID, label: String, value: Double, unit: String,
                partLabel: String? = nil, note: String? = nil, measuredAt: Date) {
        self.id = id; self.label = label; self.value = value; self.unit = unit
        self.partLabel = partLabel; self.note = note; self.measuredAt = measuredAt
    }
}

public struct WorksiteSurveyPDFInput: Sendable {
    public var projectName: String
    public var projectNumber: String
    public var revisionLabel: String
    public var projectDescription: String
    public var widthMm: Double
    public var heightMm: Double
    public var profileLabel: String
    public var materialGrade: String
    public var entries: [WorksiteSurveyPDFEntry]
    public var generatedAt: Date

    public init(projectName: String, projectNumber: String, revisionLabel: String,
                projectDescription: String, widthMm: Double, heightMm: Double,
                profileLabel: String, materialGrade: String,
                entries: [WorksiteSurveyPDFEntry], generatedAt: Date) {
        self.projectName = projectName; self.projectNumber = projectNumber
        self.revisionLabel = revisionLabel; self.projectDescription = projectDescription
        self.widthMm = widthMm; self.heightMm = heightMm; self.profileLabel = profileLabel
        self.materialGrade = materialGrade; self.entries = entries; self.generatedAt = generatedAt
    }
}

public enum WorksiteSurveyPDF {
    public static func data(for input: WorksiteSurveyPDFInput) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let margin: CGFloat = 46
        let contentWidth = pageRect.width - margin * 2
        let bottomLimit = pageRect.height - 48
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "Baustellen-Aufmaß · \(input.projectName)",
                               kCGPDFContextCreator as String: "MetalCraft Pro",
                               kCGPDFContextSubject as String: "Chronologisches Baustellen-Messprotokoll"]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let black = UIColor.black
        let darkGray = UIColor(white: 0.28, alpha: 1)
        let gray = UIColor(white: 0.48, alpha: 1)
        let accent = UIColor(red: 0.72, green: 0.38, blue: 0.08, alpha: 1)

        func attributes(_ size: CGFloat, _ weight: UIFont.Weight, _ color: UIColor) -> [NSAttributedString.Key: Any] {
            [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        }
        func measuredHeight(_ text: String, width: CGFloat, attrs: [NSAttributedString.Key: Any]) -> CGFloat {
            let rect = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
            return ceil(rect.height)
        }
        func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
                      attrs: [NSAttributedString.Key: Any]) -> CGFloat {
            let height = measuredHeight(text, width: width, attrs: attrs)
            (text as NSString).draw(in: CGRect(x: x, y: y, width: width, height: height + 2),
                                    withAttributes: attrs)
            return height
        }
        func drawRule(y: CGFloat) {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: margin, y: y)); path.addLine(to: CGPoint(x: pageRect.width - margin, y: y))
            UIColor(white: 0.82, alpha: 1).setStroke(); path.lineWidth = 0.7; path.stroke()
        }

        return renderer.pdfData { context in
            var y: CGFloat = margin
            var pageNumber = 0

            func beginPage(continuation: Bool) {
                context.beginPage()
                pageNumber += 1
                y = margin
                let title = continuation ? "Baustellen-Aufmaß · Fortsetzung" : "Baustellen-Aufmaß"
                y += drawText(title, x: margin, y: y, width: contentWidth,
                              attrs: attributes(23, .bold, black)) + 7
                let projectLine = [input.projectName, input.projectNumber.isEmpty ? nil : input.projectNumber,
                                   input.revisionLabel.isEmpty ? nil : "Rev. \(input.revisionLabel)"]
                    .compactMap { $0 }.joined(separator: " · ")
                y += drawText(projectLine, x: margin, y: y, width: contentWidth,
                              attrs: attributes(12, .medium, darkGray)) + 4

                if !continuation {
                    let dimensions = input.widthMm.isFinite && input.heightMm.isFinite
                        ? "Rahmenmaß: \(DeFormat.number(input.widthMm)) × \(DeFormat.number(input.heightMm)) mm" : nil
                    let profile = input.profileLabel.isEmpty ? nil : "Profil: \(input.profileLabel)"
                    let grade = input.materialGrade.isEmpty ? nil : "Werkstoff: \(input.materialGrade)"
                    let details = [dimensions, profile, grade].compactMap { $0 }.joined(separator: "   ·   ")
                    if !details.isEmpty {
                        y += drawText(details, x: margin, y: y, width: contentWidth,
                                      attrs: attributes(9.5, .regular, gray)) + 4
                    }
                    let description = input.projectDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !description.isEmpty {
                        y += drawText(description, x: margin, y: y, width: contentWidth,
                                      attrs: attributes(10, .regular, darkGray)) + 4
                    }
                    let generated = "Erstellt: \(input.generatedAt.formatted(date: .long, time: .shortened))"
                    y += drawText(generated, x: margin, y: y, width: contentWidth,
                                  attrs: attributes(9, .regular, gray)) + 10
                    drawRule(y: y)
                    y += 15
                } else {
                    y += 12
                }
            }

            func ensureRoom(_ height: CGFloat) {
                if y + height > bottomLimit {
                    beginPage(continuation: true)
                }
            }

            beginPage(continuation: false)
            let chronologicallySorted = input.entries.sorted {
                if $0.measuredAt != $1.measuredAt { return $0.measuredAt < $1.measuredAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            if chronologicallySorted.isEmpty {
                _ = drawText("Noch keine Baustellenmessungen erfasst.", x: margin, y: y,
                             width: contentWidth, attrs: attributes(12, .regular, darkGray))
            }

            for (index, entry) in chronologicallySorted.enumerated() {
                let labelAttrs = attributes(13, .semibold, black)
                let valueAttrs = attributes(13, .bold, accent)
                let detailAttrs = attributes(10, .regular, darkGray)
                let dateAttrs = attributes(9, .regular, gray)
                let labelHeight = measuredHeight(entry.label, width: contentWidth - 150, attrs: labelAttrs)
                var rowHeight: CGFloat = max(22, labelHeight) + 12
                rowHeight += measuredHeight("\(DeFormat.number(entry.value)) \(entry.unit)",
                                            width: contentWidth, attrs: valueAttrs) + 5
                if let part = entry.partLabel, !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rowHeight += measuredHeight("Bauteil: \(part)", width: contentWidth, attrs: detailAttrs) + 3
                }
                if let note = entry.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rowHeight += measuredHeight("Notiz: \(note)", width: contentWidth, attrs: detailAttrs) + 3
                }
                rowHeight += measuredHeight(entry.measuredAt.formatted(date: .long, time: .shortened),
                                            width: contentWidth, attrs: dateAttrs) + 12
                ensureRoom(rowHeight)

                let rowTop = y
                _ = drawText(entry.label, x: margin, y: rowTop, width: contentWidth - 150,
                             attrs: labelAttrs)
                let valueText = "\(DeFormat.number(entry.value)) \(entry.unit)"
                let valueWidth = (valueText as NSString).size(withAttributes: valueAttrs).width
                (valueText as NSString).draw(at: CGPoint(x: pageRect.width - margin - valueWidth, y: rowTop),
                                             withAttributes: valueAttrs)
                y = rowTop + max(22, labelHeight) + 5

                if let part = entry.partLabel, !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    y += drawText("Bauteil: \(part)", x: margin, y: y, width: contentWidth,
                                  attrs: detailAttrs) + 3
                }
                if let note = entry.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    y += drawText("Notiz: \(note)", x: margin, y: y, width: contentWidth,
                                  attrs: detailAttrs) + 3
                }
                y += drawText(entry.measuredAt.formatted(date: .long, time: .shortened),
                              x: margin, y: y, width: contentWidth, attrs: dateAttrs) + 9
                drawRule(y: y)
                y += 10
                if index < chronologicallySorted.count - 1, y > bottomLimit { beginPage(continuation: true) }
            }

            let footer = "MetalCraft Pro · Seite \(pageNumber)"
            let footerWidth = (footer as NSString).size(withAttributes: attributes(8, .regular, gray)).width
            (footer as NSString).draw(at: CGPoint(x: pageRect.width - margin - footerWidth,
                                                  y: pageRect.height - 30),
                                      withAttributes: attributes(8, .regular, gray))
        }
    }
}

// MARK: - CSV: Materialliste

public struct MaterialRow: Sendable, Equatable {
    public var positionNumber: Int
    public var name: String
    public var profileLabel: String
    public var grade: String
    public var quantity: Int
    public var totalLengthMm: Double
    public var isReference: Bool

    public init(positionNumber: Int, name: String, profileLabel: String, grade: String,
                quantity: Int, totalLengthMm: Double, isReference: Bool) {
        self.positionNumber = positionNumber; self.name = name; self.profileLabel = profileLabel
        self.grade = grade; self.quantity = quantity; self.totalLengthMm = totalLengthMm
        self.isReference = isReference
    }
}

public enum MaterialListCSV {
    /// Deutsche CSV (Semikolon, Dezimalkomma) mit Summen über Länge und Gewicht.
    public static func export(rows: [MaterialRow], projectName: String, projectNumber: String,
                              generatedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy"
        var lines = ["Materialliste;\(field(projectName));\(field(projectNumber));Stand \(formatter.string(from: generatedAt))"]
        lines.append("Pos;Bezeichnung;Profil;Werkstoff;Stück;Gesamtlänge (mm);Gewicht (kg)")
        var totalCount = 0, totalLength = 0.0, totalWeight = 0.0
        for row in rows.sorted(by: { $0.positionNumber < $1.positionNumber }) {
            if row.isReference {
                lines.append([ "\(row.positionNumber)", field(row.name), field(row.profileLabel),
                               "–", "\(max(1, row.quantity))", "Zukaufteil", "–" ].joined(separator: ";"))
                continue
            }
            let weight = (try? CalculationEngine.profileWeight(lengthMm: row.totalLengthMm,
                                                               profile: ProfileCatalog.spec(named: row.profileLabel) ?? ProfileCatalog.squareTube40x40x2)) ?? 0
            totalCount += max(1, row.quantity)
            totalLength += row.totalLengthMm
            totalWeight += weight
            lines.append([
                "\(row.positionNumber)", field(row.name), field(row.profileLabel), field(row.grade),
                "\(max(1, row.quantity))", DeFormat.number(row.totalLengthMm, maxFractionDigits: 1),
                DeFormat.number(weight, maxFractionDigits: 2)
            ].joined(separator: ";"))
        }
        lines.append("Summe;;;;\(totalCount);\(DeFormat.number(totalLength, maxFractionDigits: 1));\(DeFormat.number(totalWeight, maxFractionDigits: 2))")
        return lines.joined(separator: "\n") + "\n"
    }

    static func field(_ value: String) -> String {
        if value.contains(";") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

// MARK: - STL

public enum STLExporter {
    /// ASCII-STL aller Bauteil-Meshes in Millimetern; Normale aus dem Dreieck.
    public static func ascii(parts: [BuiltPart], modelName: String) -> String {
        let name = sanitized(modelName)
        var lines: [String] = ["solid \(name)"]
        let number = { (value: Double) in String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) }
        for part in parts {
            let mesh = part.mesh
            guard mesh.indices.count >= 3 else { continue }
            for triangle in 0..<(mesh.indices.count / 3) {
                let a = mesh.positions[Int(mesh.indices[triangle * 3])]
                let b = mesh.positions[Int(mesh.indices[triangle * 3 + 1])]
                let c = mesh.positions[Int(mesh.indices[triangle * 3 + 2])]
                let cross = (b - a).cross(c - a)
                let magnitude = cross.magnitude
                let normal = magnitude > 1e-12 ? cross * (1 / magnitude) : Vec3.zero
                lines.append("  facet normal \(number(normal.x)) \(number(normal.y)) \(number(normal.z))")
                lines.append("    outer loop")
                for vertex in [a, b, c] {
                    lines.append("      vertex \(number(vertex.x)) \(number(vertex.y)) \(number(vertex.z))")
                }
                lines.append("    endloop")
                lines.append("  endfacet")
            }
        }
        lines.append("endsolid \(name)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Baut die Bauteile direkt aus dem parametrischen Modell (reine Domäne).
    public static func buildParts(widthMm: Double, heightMm: Double, profile: ProfileSpec,
                                  parts: [ThreeDPartInput]) throws -> [BuiltPart] {
        let placements = try ThreeDModelBuilder.placements(for: ThreeDInput(widthMm: widthMm, heightMm: heightMm,
                                                                            profile: profile, parts: parts))
        return try ThreeDModelBuilder.build(placements)
    }

    static func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalar = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return scalar.isEmpty ? "Modell" : scalar
    }
}

// MARK: - STEP (gekapselt, in Entwicklung)

public enum STEPExporter {
    /// Volumenkörper im ISO-10303-21-Format erfordern einen B-Rep-Kern; der Export
    /// bleibt bewusst gekapselt und wird in der UI als „In Entwicklung" gezeigt.
    public static let note = "STEP mit Volumenkörpern (ISO 10303-21) erfordert einen B-Rep-Kern und ist in Entwicklung. Für den 3D-Austausch steht STL bereit, für 2D-Austausch DXF und SVG."
}

// MARK: - Formatkatalog

public enum ExportFormatID: String, CaseIterable, Sendable {
    case quotePDF, drawingPDF, drawingPNG, drawingJPEG, drawingSVG, drawingDXF
    case montagePDF, weldingPDF, worksiteSurveyPDF, cutListCSV, materialCSV
    case modelSTL, modelSTEP
}

public struct ExportFormatSpec: Sendable, Identifiable, Equatable {
    public enum Availability: Equatable, Sendable {
        case ready
        case inDevelopment(note: String)
    }
    public var id: ExportFormatID
    public var title: String
    public var subtitle: String
    public var systemImage: String
    public var fileExtension: String
    public var availability: Availability

    public var isReady: Bool {
        if case .ready = availability { return true }
        return false
    }
}

public enum ExportCatalog {
    public static var specs: [ExportFormatSpec] {
        [
            ExportFormatSpec(id: .quotePDF, title: "Angebots-PDF", subtitle: "Projekt- und Positionskalkulation · mit Preishinweisen",
                             systemImage: "doc.text.image", fileExtension: "pdf", availability: .ready),
            ExportFormatSpec(id: .drawingPDF, title: "Technische Zeichnung", subtitle: "PDF · Ansichten, Bemaßung, Stückliste",
                             systemImage: "doc.richtext", fileExtension: "pdf", availability: .ready),
            ExportFormatSpec(id: .drawingPNG, title: "Zeichnung als PNG", subtitle: "Bild · 200 dpi, weißes Blatt",
                             systemImage: "photo", fileExtension: "png", availability: .ready),
            ExportFormatSpec(id: .drawingJPEG, title: "Zeichnung als JPEG", subtitle: "Bild · komprimiert für Chat & Mail",
                             systemImage: "photo.fill", fileExtension: "jpg", availability: .ready),
            ExportFormatSpec(id: .drawingSVG, title: "Zeichnung als SVG", subtitle: "Vektor · Grafik und Web",
                             systemImage: "vectorpath", fileExtension: "svg", availability: .ready),
            ExportFormatSpec(id: .drawingDXF, title: "Zeichnung als DXF", subtitle: "2D-Austausch · Linien, Kreise, Bögen, Text",
                             systemImage: "square.split.2x1", fileExtension: "dxf", availability: .ready),
            ExportFormatSpec(id: .montagePDF, title: "Montage-PDF", subtitle: "Schritt-für-Schritt-Anleitung zum Ausdrucken",
                             systemImage: "wrench.and.screwdriver", fileExtension: "pdf", availability: .ready),
            ExportFormatSpec(id: .weldingPDF, title: "Schweißprotokoll", subtitle: "PDF je Projekt und Bauteil",
                             systemImage: "flame", fileExtension: "pdf", availability: .ready),
            ExportFormatSpec(id: .worksiteSurveyPDF, title: "Baustellen-Aufmaß", subtitle: "PDF · chronologisches Messprotokoll",
                             systemImage: "ruler", fileExtension: "pdf", availability: .ready),
            ExportFormatSpec(id: .cutListCSV, title: "Zuschnittliste", subtitle: "CSV · Excel-kompatibel, mit Schnittplan",
                             systemImage: "square.3.layers.3d", fileExtension: "csv", availability: .ready),
            ExportFormatSpec(id: .materialCSV, title: "Materialliste", subtitle: "CSV · Stück, Länge und Gewicht",
                             systemImage: "shippingbox", fileExtension: "csv", availability: .ready),
            ExportFormatSpec(id: .modelSTL, title: "3D-Modell als STL", subtitle: "Alle Bauteile als Dreiecksnetz (mm)",
                             systemImage: "cube", fileExtension: "stl", availability: .ready),
            ExportFormatSpec(id: .modelSTEP, title: "3D-Modell als STEP", subtitle: "Volumenkörper · ISO 10303",
                             systemImage: "cube.transparent", fileExtension: "step",
                             availability: .inDevelopment(note: STEPExporter.note))
        ]
    }
}

// MARK: - Dateien

public enum ExportFiles {
    /// Schreibt Exportdaten in den temporären Ordner und liefert die Datei zum Teilen.
    public static func write(_ data: Data, fileName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(fileName)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
